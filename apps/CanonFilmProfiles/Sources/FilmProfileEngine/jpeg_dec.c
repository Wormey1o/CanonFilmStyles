/* SPDX-License-Identifier: GPL-2.0-only
 * Adaptive exact32-bit IDCT performance copy of the pinned hardened decoder.
 * All parser/entropy/bounds and the original64-bit fallback are retained. */
/*
 * jpeg_dec.c - baseline JPEG decoder.
 *
 * The mirror image of jpeg_enc.c, and deliberately shaped like it: the same
 * zigzag table, the same integer DCT constants, the same stuffed-0xFF
 * convention. Fixed point throughout, because the body this runs on has no
 * FPU and no divide instruction.
 */
#include "jpeg_dec.h"
#include "se_libc.h"

#define JD_MAXCOMP 4

static const uint8_t jd_zigzag[64] = {
     0, 1, 8,16, 9, 2, 3,10, 17,24,32,25,18,11, 4, 5,
    12,19,26,33,40,48,41,34, 27,20,13, 6, 7,14,21,28,
    35,42,49,56,57,50,43,36, 29,22,15,23,30,37,44,51,
    58,59,52,45,38,31,39,46, 53,60,61,54,47,55,62,63
};

/* ===================================================================== */
/* Bit reader                                                             */
/* ===================================================================== */

typedef struct {
    const uint8_t *p;
    size_t         len, pos;
    uint32_t       buf;
    int            cnt;
    int            marker;      /* a marker was met: stop consuming entropy */

    /*
     * Optional streaming source. The 5D Classic cannot hand out a block big
     * enough to hold the preview: a develop asked for 2.2 MB with 2264 KB
     * reported free and was still refused, because no single run that large
     * exists. With this set, `p` is a small window refilled as the decoder
     * consumes it, and nothing larger than the window is ever needed.
     */
    se_jdec_read_fn read;
    void           *rctx;
    uint8_t        *win;
    uint32_t        next_off;
    uint32_t        remaining;

    /*
     * A refill that could not be satisfied.
     *
     * This has to be distinguishable from reaching the end of the entropy
     * data, and it was not: jd_refill used to set remaining = 0 and return,
     * which is exactly what running out legitimately looks like. The decoder
     * then padded from frozen DC predictors to the bottom of the frame and
     * returned success, so a card that stalled for longer than read_at was
     * willing to retry produced a complete, plausible, wrong JPEG with rc=0.
     * That is what reached the camera: correct for the first rows, then
     * flat bands of drifting colour.
     */
    int             ioerr;
    int             error; /* sticky malformed/truncated entropy */
} jd_bits;

#define JD_WINDOW 8192

static void jd_init(jd_bits *b, const uint8_t *p, size_t len)
{
    b->p = p; b->len = len; b->pos = 0;
    b->buf = 0; b->cnt = 0; b->marker = 0;
    b->read = 0; b->rctx = 0; b->win = 0;
    b->next_off = 0; b->remaining = 0; b->ioerr = 0; b->error = 0;
}

/*
 * Pull the next chunk in, keeping whatever has not been consumed. The unread
 * tail matters: telling a stuffed 0xFF00 from a real marker needs a one-byte
 * lookahead, and that pair can straddle a refill.
 */
static void jd_refill(jd_bits *b)
{
    size_t   keep = b->len - b->pos;
    uint32_t want;
    size_t   k;

    if (!b->read || !b->remaining) return;
    for (k = 0; k < keep; k++) b->win[k] = b->win[b->pos + k];
    want = (uint32_t)(JD_WINDOW - keep);
    if (want > b->remaining) want = b->remaining;
    if (b->read(b->rctx, b->next_off, b->win + keep, want) != 0) {
        b->ioerr = 1;              /* NOT the same as running out */
        b->remaining = 0;
        return;
    }
    b->next_off  += want;
    b->remaining -= want;
    b->p   = b->win;
    b->len = keep + want;
    b->pos = 0;
}

static void jd_fill(jd_bits *b)
{
    while (b->cnt <= 24 && !b->marker && !b->error && !b->ioerr) {
        if (b->len-b->pos < 2) jd_refill(b);
        if (b->ioerr) return;
        if (b->pos == b->len) { b->marker=1; return; }
        uint32_t c=b->p[b->pos];
        if (c==0xff) {
            if (b->len-b->pos < 2) { b->error=SE_E_TRUNCATED; return; }
            if (b->p[b->pos+1]!=0) { b->marker=1; return; }
            b->pos++;
        }
        b->pos++;
        b->buf |= c << (24-b->cnt);
        b->cnt += 8;
    }
}

static uint32_t jd_get(jd_bits *b, int n)
{
    if (!n) return 0;
    if (n<0 || n>16) { b->error=SE_E_CORRUPT; return 0; }
    if (b->cnt<n) jd_fill(b);
    if (b->cnt<n) { b->error=SE_E_TRUNCATED; return 0; }
    uint32_t v=b->buf>>(32-n);
    b->buf <<= n; b->cnt-=n;
    return v;
}

/* Entropy ends on a byte boundary with at most seven one-padding bits. */
static se_err jd_end_bits(jd_bits *b, int expected)
{
    jd_fill(b);
    if (b->ioerr) return SE_E_IO;
    if (b->error) return b->error;
    if (b->cnt>7) return SE_E_CORRUPT;
    if (b->cnt && (b->buf>>(32-b->cnt))!=((1u<<b->cnt)-1)) return SE_E_CORRUPT;
    b->cnt=0; b->buf=0;
    if (b->len-b->pos<2) jd_refill(b);
    if (b->ioerr) return SE_E_IO;
    if (b->pos==b->len || b->p[b->pos++]!=0xff) return SE_E_TRUNCATED;
    for (;;) {
        if (b->pos==b->len) jd_refill(b);
        if (b->ioerr) return SE_E_IO;
        if (b->pos==b->len) return SE_E_TRUNCATED;
        int marker=b->p[b->pos++];
        if (marker==0xff) continue;
        if (marker!=expected) return SE_E_CORRUPT;
        break;
    }
    b->marker=0;
    return SE_OK;
}

/* JPEG's sign extension: a value whose top bit is clear is negative. */
static int jd_extend(uint32_t v, int n)
{
    if (!n) return 0;
    return ((int)v < (1 << (n - 1))) ? (int)v - (1 << n) + 1 : (int)v;
}

/* ===================================================================== */
/* Huffman                                                                */
/* ===================================================================== */

/*
 * `look` is the whole reason this file is fast enough to run on the camera.
 *
 * Decoding a Huffman code one bit at a time is a call, a compare and a
 * shift per bit, and a JPEG is nothing but Huffman codes: a 2496x1664
 * preview is about 97,000 blocks and a million-odd codes. Most of those
 * codes are short -- that is what Huffman coding is for -- so eight bits of
 * the stream are peeked at once and looked up directly. Every code of eight
 * bits or fewer is resolved in one step, and the bit-at-a-time walk below
 * survives only for the rare long ones.
 *
 * Entry layout: value in the high bits, code length in the low five. Zero
 * means "longer than eight bits, take the slow path", which is unambiguous
 * because a length of zero is not a code.
 */
typedef struct {
    uint8_t  bits[17];
    uint8_t  vals[256];
    int      mincode[17];
    int      maxcode[18];
    int      valptr[17];
    uint16_t look[256];
    int      present;
} jd_huff;

static void jd_huff_build(jd_huff *h)
{
    int code = 0, k = 0, i, j;

    for (i = 0; i < 256; i++) h->look[i] = 0;

    for (i = 1; i <= 16; i++) {
        h->valptr[i]  = k;
        h->mincode[i] = code;
        /* Fill the short-code table as we go: a code of length i occupies
         * every eight-bit prefix that starts with it. */
        if (i <= 8) {
            for (j = 0; j < h->bits[i]; j++) {
                int    pfx = (code + j) << (8 - i);
                int    n   = 1 << (8 - i);
                uint16_t e = (uint16_t)((h->vals[k + j] << 5) | i);
                int    q;
                for (q = 0; q < n; q++) h->look[pfx + q] = e;
            }
        }
        code += h->bits[i];
        k    += h->bits[i];
        h->maxcode[i] = code - 1;
        if (!h->bits[i]) h->maxcode[i] = -1;
        code <<= 1;
    }
    h->maxcode[17] = 0x7fffffff;
}

static int jd_decode(jd_bits *b, const jd_huff *h)
{
    if (b->cnt<=24) jd_fill(b);
    uint32_t e=h->look[b->buf>>24];
    int l=(int)(e&31);
    if (e && l<=b->cnt) {
        b->buf<<=l; b->cnt-=l; return (int)(e>>5);
    }
    int code=0;
    for (l=1;l<=16;l++) {
        code=(code<<1)|(int)jd_get(b,1);
        if (b->error || b->ioerr) return 0;
        if (h->maxcode[l]>=0 && code>=h->mincode[l] && code<=h->maxcode[l])
            return h->vals[h->valptr[l]+code-h->mincode[l]];
    }
    b->error=SE_E_CORRUPT; return 0;
}

/* ===================================================================== */
/* IDCT                                                                   */
/* ===================================================================== */
/*
 * A separable 8-point inverse DCT done as a matrix multiply, in Q14.
 *
 * The hand-unrolled butterfly that usually appears here is perhaps three
 * times faster and far harder to be sure of; this version is the definition
 * written out, so it can be checked against a floating-point reference
 * coefficient by coefficient -- which tools/jpegtest does. At roughly a
 * million blocks for a 4 MP frame it costs a second or two on this body,
 * and correctness was the scarcer commodity here.
 *
 *   jd_ct[u][x] = 1/2 * C(u) * cos((2x+1) u pi / 16),  C(0) = 1/sqrt(2)
 */
static const int16_t jd_ct[8][8] = {
    {   5793,   5793,   5793,   5793,   5793,   5793,   5793,   5793 },
    {   8035,   6811,   4551,   1598,  -1598,  -4551,  -6811,  -8035 },
    {   7568,   3135,  -3135,  -7568,  -7568,  -3135,   3135,   7568 },
    {   6811,  -1598,  -8035,  -4551,   4551,   8035,   1598,  -6811 },
    {   5793,  -5793,  -5793,   5793,   5793,  -5793,  -5793,   5793 },
    {   4551,  -8035,   1598,   6811,  -6811,  -1598,   8035,  -4551 },
    {   3135,  -7568,   7568,  -3135,  -3135,   7568,  -7568,   3135 },
    {   1598,  -4551,   6811,  -8035,   8035,  -6811,   4551,  -1598 },
};

#define JD_DESCALE(x, n) (((x) + (1 << ((n) - 1))) >> (n))

/*
 * Flat block: every coefficient but DC is zero, so the transform collapses
 * to one value repeated. Worth testing for because it is the common case --
 * empty sky, out-of-focus background, and most chroma blocks in most
 * frames. The test costs at most 63 compares against 1024
 * multiply-accumulates.
 */
static int jd_flat(const int *in, int n)
{
    int x, y;
    for (y = 0; y < n; y++)
        for (x = 0; x < n; x++)
            if ((x | y) && in[y * 8 + x]) return 0;
    return 1;
}

static void jd_fill_block(uint8_t *out, int stride, int n, int dc)
{
    int64_t v = JD_DESCALE(JD_DESCALE((int64_t)5793 * dc, 11) * 5793, 17) + 128;
    int x, y;
    uint8_t c = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
    for (y = 0; y < n; y++)
        for (x = 0; x < n; x++) out[y * stride + x] = c;
}

/* Exact cosine-basis factoring. The original 64-bit bounds and both
 * rounding stages are retained. Each 1D vector uses 22 rather than 64
 * basis multiplications; this is not a hardware timing claim.
 * Conservative signed-int32 coefficient bound: column <=138040248893440,
 * descaled tmp <=67402465280, row <=4332630468198400 (<INT64_MAX).
 */
static void jd_basis8(const int64_t *v, int64_t *o)
{
    int64_t a = 5793 * (v[0] + v[4]);
    int64_t b = 5793 * (v[0] - v[4]);
    int64_t c = 7568 * v[2] + 3135 * v[6];
    int64_t d = 3135 * v[2] - 7568 * v[6];
    int64_t e0 = a + c, e1 = b + d, e2 = b - d, e3 = a - c;
    int64_t q0 = 8035*v[1] + 6811*v[3] + 4551*v[5] + 1598*v[7];
    int64_t q1 = 6811*v[1] - 1598*v[3] - 8035*v[5] - 4551*v[7];
    int64_t q2 = 4551*v[1] - 8035*v[3] + 1598*v[5] + 6811*v[7];
    int64_t q3 = 1598*v[1] - 4551*v[3] + 6811*v[5] - 8035*v[7];
    o[0]=e0+q0; o[7]=e0-q0;
    o[1]=e1+q1; o[6]=e1-q1;
    o[2]=e2+q2; o[5]=e2-q2;
    o[3]=e3+q3; o[4]=e3-q3;
}

static void jd_basis8_32(const int32_t *v, int32_t *o)
{
    int32_t a = 5793 * (v[0] + v[4]);
    int32_t b = 5793 * (v[0] - v[4]);
    int32_t c = 7568 * v[2] + 3135 * v[6];
    int32_t d = 3135 * v[2] - 7568 * v[6];
    int32_t e0 = a + c, e1 = b + d, e2 = b - d, e3 = a - c;
    int32_t q0 = 8035*v[1] + 6811*v[3] + 4551*v[5] + 1598*v[7];
    int32_t q1 = 6811*v[1] - 1598*v[3] - 8035*v[5] - 4551*v[7];
    int32_t q2 = 4551*v[1] - 8035*v[3] + 1598*v[5] + 6811*v[7];
    int32_t q3 = 1598*v[1] - 4551*v[3] + 6811*v[5] - 8035*v[7];
    o[0]=e0+q0; o[7]=e0-q0;
    o[1]=e1+q1; o[6]=e1-q1;
    o[2]=e2+q2; o[5]=e2-q2;
    o[3]=e3+q3; o[4]=e3-q3;
}

static void jd_idct_wide(const int *in, uint8_t *out, int stride)
{
    int64_t tmp[64], v[8], o[8];
    int x, y;
    if (jd_flat(in, 8)) { jd_fill_block(out, stride, 8, in[0]); return; }
    for (x=0; x<8; x++) {
        for (y=0; y<8; y++) v[y]=(int64_t)in[y*8+x];
        jd_basis8(v,o);
        for (y=0; y<8; y++) tmp[y*8+x]=JD_DESCALE(o[y],11);
    }
    for (y=0; y<8; y++) {
        jd_basis8(tmp+y*8,o);
        for (x=0; x<8; x++) {
            int64_t value=JD_DESCALE(o[x],17)+128;
            out[y*stride+x]=(uint8_t)(value<0 ? 0 : value>255 ? 255 : value);
        }
    }
}


/* Fast-path proof: every dequantized coefficient is in [-2300,2300].
 * Basis row L1 norm43284 gives |stage1|<=99553200 and |tmp|<=48610.
 * Stage2 including round65536 is <=2104100776 < INT32_MAX. Every
 * factored intermediate has no larger L1 norm. See proof.json/report.
 * All other coefficients use the original signed64 transform unchanged. */
static int jd_can32(const int *in)
{
    for (int i=0;i<64;i++)
        if ((uint32_t)in[i] + 2300u > 4600u) return 0;
    return 1;
}
static void jd_idct_small(const int *in, uint8_t *out, int stride)
{
    int32_t tmp[64], v[8], o[8];
    int x,y;
    for(x=0;x<8;x++) {
        for(y=0;y<8;y++) v[y]=in[y*8+x];
        jd_basis8_32(v,o);
        for(y=0;y<8;y++) tmp[y*8+x]=JD_DESCALE(o[y],11);
    }
    for(y=0;y<8;y++) {
        jd_basis8_32(tmp+y*8,o);
        for(x=0;x<8;x++) {
            int32_t value=JD_DESCALE(o[x],17)+128;
            out[y*stride+x]=(uint8_t)(value<0 ? 0 : value>255 ? 255 : value);
        }
    }
}
static void jd_idct(const int *in, uint8_t *out, int stride)
{
    if (jd_flat(in,8)) { jd_fill_block(out,stride,8,in[0]); return; }
    if (jd_can32(in)) jd_idct_small(in,out,stride);
    else jd_idct_wide(in,out,stride);
}

/*
 * The same transform, stopped at four points: the top-left 4x4 coefficients
 * in, a 4x4 block out, which is the image at half size.
 *
 * This is not a decode followed by a resize. The DCT basis for N=4 is the
 * even rows of the basis for N=8 restricted to the first four columns --
 *
 *     1/2 C(u) cos((2x+1) u pi / 8)  ==  1/2 C(2u) cos((2x+1) 2u pi / 16)
 *
 * -- so no new table is needed and none is kept: jd_ct[2u][x] for u,x < 4
 * is exactly it.
 *
 * The scale factor works out identically. With only DC present the 8-point
 * transform gives F00/8, and 1/4 * C(0)C(0) * F00 = F00/8 here as well, so
 * the Q14 shifts below are the ones above, unchanged. `filmdev selftest`
 * holds that to the letter: a flat field decoded half-size comes back at
 * exactly its original level, which is the assertion a wrong normalisation
 * cannot pass.
 *
 * What it buys: 128 multiply-accumulates a block instead of 1024, a quarter
 * as many pixels through the colour conversion, and a quarter as many
 * through the encoder. The high-frequency coefficients are discarded rather
 * than reconstructed and then averaged away, which is also a better
 * downscale than the 2x2 box filter it replaces -- a box filter is a poor
 * lowpass, and this one is the DCT's own.
 */
static void jd_idct4(const int *in, uint8_t *out, int stride)
{
    int64_t tmp[16];
    int u, x, y;

    if (jd_flat(in, 4)) { jd_fill_block(out, stride, 4, in[0]); return; }

    for (x = 0; x < 4; x++) {
        for (y = 0; y < 4; y++) {
            int64_t acc = 0;
            for (u = 0; u < 4; u++) acc += (int64_t)jd_ct[u * 2][y] * in[u * 8 + x];
            tmp[y * 4 + x] = JD_DESCALE(acc, 11);
        }
    }
    for (y = 0; y < 4; y++) {
        uint8_t *o = out + y * stride;
        for (x = 0; x < 4; x++) {
            int64_t acc = 0;
            for (u = 0; u < 4; u++) acc += jd_ct[u * 2][x] * tmp[y * 4 + u];
            acc = JD_DESCALE(acc, 17) + 128;
            o[x] = (uint8_t)(acc < 0 ? 0 : acc > 255 ? 255 : acc);
        }
    }
}

/* ===================================================================== */
/* Frame state                                                            */
/* ===================================================================== */

typedef struct {
    int id, hs, vs, tq, td, ta;
    int dcpred;
    uint8_t *plane;       /* hs*8 x vs*8 per MCU, full image width */
    int      pw, ph;      /* plane dimensions in samples */
} jd_comp;

typedef struct {
    uint16_t qt[4][64];
    jd_huff hdc[4], hac[4];
} jd_tables;

typedef struct {
    int      w, h, ncomp;          /* as coded                           */
    int      bs;                   /* samples per block side: 8 or 4      */
    int      ow, oh;               /* as delivered, after bs              */
    int      hmax, vmax;
    int      mcux, mcuy, mcuw, mcuh;   /* mcuw/mcuh in delivered samples  */
    int      restart;
    jd_tables *tables;
    unsigned qtmask, dcmask, acmask;
    jd_comp  c[JD_MAXCOMP];
} jd_state;

static uint16_t jd_rd16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }

/*
 * Walk the marker segments. `upto_sos` stops at the scan header, which is
 * all se_jpeg_dec_info needs.
 */
static se_err jd_parse(const uint8_t *d, size_t len, jd_state *s,
                       size_t *scan_off, int header_only)
{
    size_t p=2;
    (void)header_only;
    if (len<2 || !d || d[0]!=0xff || d[1]!=0xd8) return SE_E_BADFILE;
    for (;;) {
        if (p==len) return SE_E_TRUNCATED;
        if (d[p++]!=0xff) return SE_E_CORRUPT;
        while (p<len && d[p]==0xff) p++;
        if (p==len) return SE_E_TRUNCATED;
        int m=d[p++];
        if (!m || m==0xd8 || m==0xd9 || m==1 || (m>=0xd0 && m<=0xd7)) return SE_E_CORRUPT;
        if (len-p<2) return SE_E_TRUNCATED;
        size_t l=jd_rd16(d+p);
        if (l<2 || l>len-p) return SE_E_TRUNCATED;
        const uint8_t *q=d+p+2,*end=d+p+l;
        size_t n=l-2;
        switch (m) {
        case 0xc0: case 0xc1: {
            if (s->ncomp || n<6) return SE_E_CORRUPT;
            if (q[0]!=8) return SE_E_UNSUPPORTED;
            s->h=jd_rd16(q+1);s->w=jd_rd16(q+3);s->ncomp=q[5];
            if (!s->w || !s->h || (s->ncomp!=1 && s->ncomp!=3)) return SE_E_UNSUPPORTED;
            if (n!=6u+3u*s->ncomp) return SE_E_CORRUPT;
            s->hmax=s->vmax=1;
            for (int i=0;i<s->ncomp;i++) {
                jd_comp *c=&s->c[i];const uint8_t *r=q+6+3*i;
                c->id=r[0];c->hs=r[1]>>4;c->vs=r[1]&15;c->tq=r[2];
                if (c->tq>3) return SE_E_CORRUPT;
                if (c->hs<1 || c->hs>2 || c->vs<1 || c->vs>2) return SE_E_UNSUPPORTED;
                for (int j=0;j<i;j++) if (s->c[j].id==c->id) return SE_E_CORRUPT;
                if (c->hs>s->hmax)s->hmax=c->hs;
                if (c->vs>s->vmax)s->vmax=c->vs;
            }
            if (s->ncomp==1 && (s->hmax!=1 || s->vmax!=1))return SE_E_UNSUPPORTED;
            if (s->ncomp==3 && (s->c[0].hs!=s->hmax || s->c[0].vs!=s->vmax))return SE_E_UNSUPPORTED;
            break;
        }
        case 0xc2: case 0xc3: case 0xc5: case 0xc6: case 0xc7:
        case 0xc9: case 0xca: case 0xcb: case 0xcd: case 0xce: case 0xcf:
            return SE_E_UNSUPPORTED;
        case 0xc4:
            if (!n) return SE_E_CORRUPT;
            while (q<end) {
                if ((size_t)(end-q)<17) return SE_E_CORRUPT;
                int tc=q[0]>>4,th=q[0]&15,count=0,code=0;
                if (tc>1 || th>3) return SE_E_CORRUPT;
                const uint8_t *counts=q+1; q+=17;
                for (int i=1;i<=16;i++) {
                    code+=counts[i-1];count+=counts[i-1];
                    if (code >= (1<<i)) return SE_E_CORRUPT;
                    code<<=1;
                }
                if (!count || count>256 || (size_t)(end-q)<(size_t)count) return SE_E_CORRUPT;
                for (int i=0;i<count;i++) {
                    int value=q[i];
                    if (!tc && value>11) return SE_E_CORRUPT;
                    if (tc && ((value&15)>10 || (!(value&15) && value!=0 && value!=0xf0)))return SE_E_CORRUPT;
                }
                if (s->tables) {
                    jd_huff *h=tc?&s->tables->hac[th]:&s->tables->hdc[th];
                    h->bits[0]=0;memcpy(h->bits+1,counts,16);memcpy(h->vals,q,(size_t)count);
                    jd_huff_build(h);h->present=1;
                }
                if (tc)s->acmask|=1u<<th;else s->dcmask|=1u<<th;
                q+=count;
            }
            break;
        case 0xdb:
            if (!n)return SE_E_CORRUPT;
            while (q<end) {
                int precision=*q>>4,id=*q&15;q++;
                if (precision>1 || id>3)return SE_E_CORRUPT;
                if ((size_t)(end-q)<(precision?128u:64u))return SE_E_CORRUPT;
                for (int i=0;i<64;i++) {
                    unsigned value=precision?jd_rd16(q+2*i):q[i];
                    if (!value)return SE_E_CORRUPT;
                    if (s->tables)s->tables->qt[id][jd_zigzag[i]]=(uint16_t)value;
                }
                q+=precision?128:64;s->qtmask|=1u<<id;
            }
            break;
        case 0xdd:
            if (n!=2)return SE_E_CORRUPT;
            s->restart=jd_rd16(q);break;
        case 0xda:
            if (!s->ncomp || n<1 || q[0]!=s->ncomp || n!=4u+2u*s->ncomp)return SE_E_CORRUPT;
            for (int i=0;i<s->ncomp;i++) {
                jd_comp *c=&s->c[i];
                /* Decoder reconstructs components in frame order. */
                if (q[1+2*i]!=c->id)return SE_E_UNSUPPORTED;
                c->td=q[2+2*i]>>4;c->ta=q[2+2*i]&15;
                if (c->td>3 || c->ta>3 || !(s->qtmask&(1u<<c->tq)) ||
                    !(s->dcmask&(1u<<c->td)) || !(s->acmask&(1u<<c->ta)))return SE_E_CORRUPT;
            }
            if (q[n-3]!=0 || q[n-2]!=63 || q[n-1]!=0)return SE_E_UNSUPPORTED;
            *scan_off=p+l;return SE_OK;
        default:
            if (m!=0xfe && !(m>=0xe0 && m<=0xef))return SE_E_UNSUPPORTED;
            break;
        }
        p+=l;
    }
}

se_err se_jpeg_dec_info(const void *buf, size_t len, se_jdec_info *out)
{
    jd_state s;
    size_t so = 0;
    se_err rc;
    memset(&s, 0, sizeof s);
    rc = jd_parse((const uint8_t *)buf, len, &s, &so, 1);
    if (rc != SE_OK) return rc;
    out->width = s.w; out->height = s.h; out->ncomp = s.ncomp;
    return SE_OK;
}

/* ===================================================================== */
/* Colour                                                                 */
/* ===================================================================== */
/* Q16 BT.601, the inverse of what jpeg_enc.c uses on the way in. */
static void jd_ycc_row(const uint8_t *y, const uint8_t *cb, const uint8_t *cr,
                       uint8_t *rgb, int n)
{
    int i;
    for (i = 0; i < n; i++) {
        int Y  = y[i] << 16;
        int Cb = cb[i] - 128, Cr = cr[i] - 128;
        int r = (Y + 91881 * Cr) >> 16;
        int g = (Y - 22554 * Cb - 46802 * Cr) >> 16;
        int b = (Y + 116130 * Cb) >> 16;
        rgb[i * 3 + 0] = (uint8_t)(r < 0 ? 0 : r > 255 ? 255 : r);
        rgb[i * 3 + 1] = (uint8_t)(g < 0 ? 0 : g > 255 ? 255 : g);
        rgb[i * 3 + 2] = (uint8_t)(b < 0 ? 0 : b > 255 ? 255 : b);
    }
}

/* ===================================================================== */
/* Decode                                                                 */
/* ===================================================================== */

/*
 * Both entry points run the same decoder: `d`/`len` describe a buffer that
 * holds at least the header, and when `rd` is set everything past the scan
 * header is pulled through a window instead of being addressed directly.
 */
static se_err jd_run(const uint8_t *d, size_t len,
                     se_jdec_read_fn rd, void *rctx, uint32_t total,
                     int scale, se_arena *a, se_jdec_sink sink, void *ctx,
                     se_jdec_info *info)
{
    jd_state *s;
    jd_bits   bits;
    size_t    scan = 0;
    se_err    rc;
    int       i, mx, my, blk[64];
    uint8_t  *rgb;

    if (scale != 1 && scale != 2) return SE_E_UNSUPPORTED;

    s = SE_NEW(a, jd_state, 1);
    if (!s) return SE_E_NOMEM;
    memset(s, 0, sizeof *s);
    s->tables = SE_NEW(a, jd_tables, 1);
    if (!s->tables) return SE_E_NOMEM;
    memset(s->tables,0,sizeof *s->tables);
    s->bs = 8 / scale;

    rc = jd_parse(d, len, s, &scan, 0);
    if (rc != SE_OK) return rc;
    if (!s->w || !s->h) return SE_E_CORRUPT;
    if (rd && scan>total) return SE_E_TRUNCATED;

    /*
     * The MCU grid is a property of the coded stream, so it is counted in
     * coded samples whatever we intend to deliver. Only the sizes of what
     * comes out of the transform follow s->bs.
     */
    s->mcux = (s->w + s->hmax * 8 - 1) / (s->hmax * 8);
    s->mcuy = (s->h + s->vmax * 8 - 1) / (s->vmax * 8);
    s->mcuw = s->hmax * s->bs;
    s->mcuh = s->vmax * s->bs;
    se_jpeg_scaled_size(s->w, s->h, scale, &s->ow, &s->oh);

    /* One MCU row per component, full image width. */
    for (i = 0; i < s->ncomp; i++) {
        s->c[i].pw = s->mcux * s->c[i].hs * s->bs;
        s->c[i].ph = s->c[i].vs * s->bs;
        s->c[i].plane = SE_NEW(a, uint8_t, (size_t)s->c[i].pw * s->c[i].ph);
        if (!s->c[i].plane) return SE_E_NOMEM;
        s->c[i].dcpred = 0;
    }
    rgb = SE_NEW(a, uint8_t, (size_t)s->ow * 3);
    if (!rgb) return SE_E_NOMEM;

    if (rd) {
        if (s->restart) {
            /* Resynchronising means scanning forward for a marker, which a
             * window that only moves forward cannot do. Canon's previews
             * carry no DRI, so refuse rather than decode out of step. */
            se_log("jpeg: restart intervals are not supported when streaming");
            return SE_E_UNSUPPORTED;
        }
        jd_init(&bits, 0, 0);
        bits.win = (uint8_t *)se_arena_alloc(a, JD_WINDOW, 32);
        if (!bits.win) return SE_E_NOMEM;
        bits.read      = rd;
        bits.rctx      = rctx;
        bits.next_off  = (uint32_t)scan;
        bits.remaining = total - (uint32_t)scan;
        bits.p   = bits.win;
        bits.len = bits.pos = 0;
        jd_refill(&bits);
    } else {
        jd_init(&bits, d + scan, len - scan);
    }

    for (my = 0; my < s->mcuy; my++) {
        int rows, y;

        for (mx = 0; mx < s->mcux; mx++) {
            int ci;

            if (s->restart && ((my * s->mcux + mx) % s->restart) == 0 &&
                (my || mx)) {
                int sequence=((my*s->mcux+mx)/s->restart-1)&7;
                rc=jd_end_bits(&bits,0xd0+sequence);
                if (rc!=SE_OK)return rc;
                for (ci = 0; ci < s->ncomp; ci++) s->c[ci].dcpred = 0;
            }

            for (ci = 0; ci < s->ncomp; ci++) {
                jd_comp *c = &s->c[ci];
                int bx, by;
                for (by = 0; by < c->vs; by++)
                    for (bx = 0; bx < c->hs; bx++) {
                        int t, k = 1, diff;
                        memset(blk, 0, sizeof blk);
                        t = jd_decode(&bits, &s->tables->hdc[c->td]);
                        diff = jd_extend(jd_get(&bits, t), t);
                        if (bits.ioerr)return SE_E_IO;
                        if (bits.error)return bits.error;
                        if (c->dcpred+diff < -32768 || c->dcpred+diff > 32767)return SE_E_CORRUPT;
                        c->dcpred += diff;
                        blk[0] = c->dcpred * s->tables->qt[c->tq][0];
                        while (k < 64) {
                            int rs = jd_decode(&bits, &s->tables->hac[c->ta]);
                            int r = rs >> 4, sz = rs & 15;
                            if (!sz) { if (r != 15) break; if (k+16>64)return SE_E_CORRUPT; k += 16; continue; }
                            k += r;
                            if (k > 63) return SE_E_CORRUPT;
                            blk[jd_zigzag[k]] =
                                jd_extend(jd_get(&bits, sz), sz) *
                                s->tables->qt[c->tq][jd_zigzag[k]];
                            k++;
                        }
                        if (bits.ioerr)return SE_E_IO;
                        if (bits.error)return bits.error;
                        {
                            uint8_t *o = c->plane
                                + (size_t)by * s->bs * c->pw
                                + (size_t)(mx * c->hs + bx) * s->bs;
                            if (s->bs == 8) jd_idct(blk, o, c->pw);
                            else            jd_idct4(blk, o, c->pw);
                        }
                    }
            }
        }

        /* This MCU row is complete: upsample, convert, hand it over. */
        rows = s->mcuh;
        if (my * s->mcuh + rows > s->oh) rows = s->oh - my * s->mcuh;

        for (y = 0; y < rows; y++) {
            uint8_t *orow = rgb;
            if (s->ncomp == 1) {
                const uint8_t *yy = s->c[0].plane + (size_t)y * s->c[0].pw;
                int x;
                for (x = 0; x < s->ow; x++) {
                    orow[x * 3] = orow[x * 3 + 1] = orow[x * 3 + 2] = yy[x];
                }
            } else {
                const jd_comp *Y = &s->c[0], *Cb = &s->c[1], *Cr = &s->c[2];
                const uint8_t *yy = Y->plane + (size_t)y * Y->pw;
                const uint8_t *bb = Cb->plane +
                    (size_t)(y >> (Cb->vs == s->vmax ? 0 : 1)) * Cb->pw;
                const uint8_t *rr = Cr->plane +
                    (size_t)(y >> (Cr->vs == s->vmax ? 0 : 1)) * Cr->pw;
                int x;
                for (x = 0; x < s->ow; x++) {
                    int xb = x >> (Cb->hs == s->hmax ? 0 : 1);
                    int xr = x >> (Cr->hs == s->hmax ? 0 : 1);
                    int Yv  = yy[x] << 16;
                    int Cbv = bb[xb] - 128, Crv = rr[xr] - 128;
                    int r = (Yv + 91881 * Crv) >> 16;
                    int g = (Yv - 22554 * Cbv - 46802 * Crv) >> 16;
                    int b = (Yv + 116130 * Cbv) >> 16;
                    orow[x * 3 + 0] = (uint8_t)(r < 0 ? 0 : r > 255 ? 255 : r);
                    orow[x * 3 + 1] = (uint8_t)(g < 0 ? 0 : g > 255 ? 255 : g);
                    orow[x * 3 + 2] = (uint8_t)(b < 0 ? 0 : b > 255 ? 255 : b);
                }
            }
            if (bits.ioerr)return SE_E_IO;
            if (bits.error)return bits.error;
            if (sink(ctx, rgb, 1, s->ow) != 0) return SE_E_IO;
        }
        /*
         * Checked once per MCU row rather than per read: it costs nothing
         * here, and it means a frame that lost its data stops within one row
         * band of where it happened instead of being finished from stale
         * state and handed back as if it were fine.
         */
        if (bits.ioerr) return SE_E_IO;
        se_progress("jpeg", my * 100 / (s->mcuy ? s->mcuy : 1));
    }

    if (bits.ioerr) return SE_E_IO;
    rc=jd_end_bits(&bits,0xd9);
    if (rc!=SE_OK)return rc;
    /* the delivered size, not the coded one -- see jpeg_dec.h */
    if (info) { info->width = s->ow; info->height = s->oh; info->ncomp = s->ncomp; }
    se_progress("jpeg", 100);
    (void)jd_ycc_row;
    return SE_OK;
}

void se_jpeg_scaled_size(int w, int h, int scale, int *ow, int *oh)
{
    int bs = (scale == 2) ? 4 : 8;
    /* round up: a 2495-wide frame still delivers its last column */
    if (ow) *ow = (w * bs + 7) / 8;
    if (oh) *oh = (h * bs + 7) / 8;
}

se_err se_jpeg_decode(const void *buf, size_t len, se_arena *a,
                      se_jdec_sink sink, void *ctx, se_jdec_info *info)
{
    return jd_run((const uint8_t *)buf, len, 0, 0, 0, 1, a, sink, ctx, info);
}

se_err se_jpeg_decode_scaled(const void *buf, size_t len, int scale,
                             se_arena *a, se_jdec_sink sink, void *ctx,
                             se_jdec_info *info)
{
    return jd_run((const uint8_t *)buf, len, 0, 0, 0, scale, a, sink, ctx, info);
}

se_err se_jpeg_decode_stream(const void *hdr, size_t hdrlen, uint32_t total,
                             se_jdec_read_fn read, void *rctx, se_arena *a,
                             se_jdec_sink sink, void *ctx, se_jdec_info *info)
{
    return se_jpeg_decode_stream_scaled(hdr, hdrlen, total, read, rctx, 1,
                                        a, sink, ctx, info);
}

se_err se_jpeg_decode_stream_scaled(const void *hdr, size_t hdrlen,
                                    uint32_t total, se_jdec_read_fn read,
                                    void *rctx, int scale, se_arena *a,
                                    se_jdec_sink sink, void *ctx,
                                    se_jdec_info *info)
{
    if (!read) return SE_E_IO;
    return jd_run((const uint8_t *)hdr, hdrlen, read, rctx, total, scale,
                  a, sink, ctx, info);
}
