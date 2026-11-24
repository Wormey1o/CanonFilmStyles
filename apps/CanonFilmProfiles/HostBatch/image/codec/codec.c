/* SPDX-License-Identifier: GPL-2.0-only
 * Owned streaming coefficient adapter. Huffman lookup/canonical arithmetic,
 * sign extension, zigzag and entropy emission derive from repository
 * jpeg_dec.c/jpeg_enc.c; no transform or RGB path is linked. */
#include "codec.h"
#include "annexk.inc"
static const uint8_t zz[64] = {
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63};
typedef struct {
  uint16_t look[256];
  int32_t min[17], max[17], ptr[17];
  uint32_t enc[256];
  const uint8_t *val;
} huff;
typedef struct {
  uint8_t in[8192], out[4096];
  huff h[4];
  uint16_t quant[2][64];
  cg_mcu m;
  cg_read_fn read;
  cg_write_fn write;
  void *rc, *wc;
  cg_options opt;
  cg_result *r;
  uint32_t size, pos, in_at, in_len, out_len, olen, ibuf, icnt, obuf, ocnt;
  int32_t ipred[3], opred[3];
  int err, prefix;
  uint32_t qseen, hseen;
} state;
static void zero(void *p, uint32_t n) {
  uint8_t *b = (uint8_t *)p;
  while (n--)
    *b++ = 0;
}
uint32_t cg_workspace_required(void) { return (uint32_t)sizeof(state); }
static int fail(state *s, int e) {
  if (!s->err)
    s->err = e;
  return 0;
}
static int flush(state *s) {
  uint32_t n = s->out_len;
  if (s->err)
    return 0;
  if (!n)
    return 1;
  s->r->write_calls++;
  if (s->write(s->wc, s->out, n))
    return fail(s, CG_IO_WRITE);
  s->r->write_bytes += n;
  s->out_len = 0;
  return 1;
}
static int put(state *s, uint32_t v) {
  if (s->err)
    return 0;
  if (s->olen >= s->opt.output_limit)
    return fail(s, CG_OUTPUT_LIMIT);
  s->out[s->out_len++] = (uint8_t)v;
  s->olen++;
  s->r->output_bytes = s->olen;
  if (s->out_len == sizeof(s->out))
    return flush(s);
  return 1;
}
static int get(state *s) {
  uint32_t n;
  int v;
  if (s->err)
    return 0;
  if (s->prefix && s->pos >= s->opt.header_limit)
    return fail(s, CG_HEADER_LIMIT);
  if (s->pos >= s->size)
    return fail(s, CG_TRUNCATED);
  if (s->in_at == s->in_len) {
    n = s->size - s->pos;
    if (n > sizeof(s->in))
      n = sizeof(s->in);
    s->r->read_calls++;
    if (s->read(s->rc, s->pos, s->in, n))
      return fail(s, CG_IO_READ);
    s->r->read_bytes += n;
    s->in_at = 0;
    s->in_len = n;
  }
  v = s->in[s->in_at++];
  s->pos++;
  if (s->prefix)
    put(s, (uint32_t)v);
  return v;
}
static uint32_t word(state *s) {
  uint32_t a = (uint32_t)get(s);
  return (a << 8) | (uint32_t)get(s);
}
static void build(huff *h, const uint8_t *b, const uint8_t *v) {
  int l, k = 0, j, c = 0;
  h->val = v;
  for (l = 1; l <= 16; l++) {
    h->ptr[l] = k;
    h->min[l] = c;
    h->max[l] = b[l] ? c + b[l] - 1 : -1;
    for (j = 0; j < b[l]; j++, k++, c++) {
      h->enc[v[k]] = ((uint32_t)l << 16) | (uint32_t)c;
      if (l <= 8) {
        int p = c << (8 - l), n = 1 << (8 - l), q;
        for (q = 0; q < n; q++)
          h->look[p + q] = (uint16_t)((v[k] << 5) | l);
      }
    }
    c <<= 1;
  }
}
static const uint8_t *bits(unsigned i) {
  switch (i) {
  case 0:
    return g_dc_lum_bits;
  case 1:
    return g_ac_lum_bits;
  case 2:
    return g_dc_chr_bits;
  default:
    return g_ac_chr_bits;
  }
}
static const uint8_t *vals(unsigned i) {
  switch (i) {
  case 0:
    return g_dc_lum_val;
  case 1:
    return g_ac_lum_val;
  case 2:
    return g_dc_chr_val;
  default:
    return g_ac_chr_val;
  }
}
static int header(state *s) {
  int sof = 0;
  uint32_t end, len, i, k, id, mask, mark, a;
  s->prefix = 1;
  if (get(s) != 255 || get(s) != 216)
    return fail(s, CG_CORRUPT);
  while (!s->err) {
    if (get(s) != 255)
      return fail(s, CG_CORRUPT);
    do {
      mark = (uint32_t)get(s);
    } while (mark == 255 && !s->err);
    if (mark == 0 || mark == 216 || mark == 217 || (mark >= 208 && mark <= 215))
      return fail(s, CG_CORRUPT);
    len = word(s);
    if (s->err)
      return 0;
    if (len < 2)
      return fail(s, CG_CORRUPT);
    if (len > s->size - s->pos + 2)
      return fail(s, CG_TRUNCATED);
    if (len - 2 > s->opt.header_limit - s->pos)
      return fail(s, CG_HEADER_LIMIT);
    end = s->pos + len - 2;
    if (mark == 219) {
      if (len == 2)
        return fail(s, CG_CORRUPT);
      while (s->pos < end && !s->err) {
        id = (uint32_t)get(s);
        if (id > 1)
          return fail(s, CG_UNSUPPORTED);
        mask = 1u << id;
        if (s->qseen & mask)
          return fail(s, CG_UNSUPPORTED);
        if (end - s->pos < 64)
          return fail(s, CG_CORRUPT);
        for (k = 0; k < 64; k++) {
          a = (uint32_t)get(s);
          if (!a)
            return fail(s, CG_CORRUPT);
          s->quant[id][zz[k]] = (uint16_t)a;
        }
        s->qseen |= mask;
      }
    } else if (mark == 196) {
      if (len == 2)
        return fail(s, CG_CORRUPT);
      while (s->pos < end && !s->err) {
        id = (uint32_t)get(s);
        if (id != 0 && id != 1 && id != 16 && id != 17)
          return fail(s, CG_UNSUPPORTED);
        i = ((id & 1u) << 1) + (id >> 4);
        mask = 1u << i;
        if (s->hseen & mask)
          return fail(s, CG_UNSUPPORTED);
        if (end - s->pos < 16)
          return fail(s, CG_CORRUPT);
        for (k = 1; k <= 16; k++)
          if (get(s) != bits(i)[k])
            return fail(s, CG_UNSUPPORTED);
        a = (i & 1u) ? 162 : 12;
        if (end - s->pos < a)
          return fail(s, CG_CORRUPT);
        for (k = 0; k < a; k++)
          if (get(s) != vals(i)[k])
            return fail(s, CG_UNSUPPORTED);
        s->hseen |= mask;
      }
    } else if (mark == 192) {
      if (sof || len != 17)
        return fail(s, CG_UNSUPPORTED);
      if (get(s) != 8)
        return fail(s, CG_UNSUPPORTED);
      s->r->height = word(s);
      s->r->width = word(s);
      if (!s->r->height || !s->r->width || (s->r->height & 7) ||
          (s->r->width & 15))
        return fail(s, CG_UNSUPPORTED);
      if (get(s) != 3)
        return fail(s, CG_UNSUPPORTED);
      for (i = 0; i < 3; i++) {
        if (get(s) != (int)i + 1 || get(s) != (i ? 17 : 33) ||
            get(s) != (i ? 1 : 0))
          return fail(s, CG_UNSUPPORTED);
      }
      sof = 1;
    } else if (mark == 218) {
      if (!sof || s->qseen != 3 || s->hseen != 15 || len != 12)
        return fail(s, CG_UNSUPPORTED);
      if (get(s) != 3)
        return fail(s, CG_UNSUPPORTED);
      for (i = 0; i < 3; i++)
        if (get(s) != (int)i + 1 || get(s) != (i ? 17 : 0))
          return fail(s, CG_UNSUPPORTED);
      if (get(s) != 0 || get(s) != 63 || get(s) != 0)
        return fail(s, CG_UNSUPPORTED);
      if (s->pos != end)
        return fail(s, CG_CORRUPT);
      s->prefix = 0;
      s->r->prefix_bytes = s->pos;
      return !s->err;
    } else if ((mark >= 224 && mark <= 239) || mark == 254) {
      while (s->pos < end && !s->err)
        get(s);
    } else
      return fail(s, CG_UNSUPPORTED);
    if (s->pos != end)
      return fail(s, CG_CORRUPT);
  }
  return 0;
}
/* Lookahead stops before a marker, preserving byte position for strict EOI. */
static void fill(state *s) {
  while (s->icnt <= 24 && !s->err) {
    int c;
    uint32_t keep, n, j;
    if (s->pos >= s->size)
      return;
    if (s->in_len - s->in_at < 2 && s->size - s->pos > s->in_len - s->in_at) {
      keep = s->in_len - s->in_at;
      for (j = 0; j < keep; j++)
        s->in[j] = s->in[s->in_at + j];
      n = s->size - s->pos - keep;
      if (n > sizeof(s->in) - keep)
        n = sizeof(s->in) - keep;
      s->r->read_calls++;
      if (s->read(s->rc, s->pos + keep, s->in + keep, n)) {
        fail(s, CG_IO_READ);
        return;
      }
      s->r->read_bytes += n;
      s->in_at = 0;
      s->in_len = keep + n;
    }
    c = s->in[s->in_at];
    if (c == 255) {
      if (s->in_len - s->in_at < 2) {
        fail(s, CG_TRUNCATED);
        return;
      }
      if (s->in[s->in_at + 1] != 0)
        return;
      s->in_at++;
      s->pos++;
    }
    s->in_at++;
    s->pos++;
    s->ibuf |= (uint32_t)c << (24 - s->icnt);
    s->icnt += 8;
  }
}
static uint32_t take(state *s, unsigned n) {
  uint32_t v;
  if (!n)
    return 0;
  if (n > 16) {
    fail(s, CG_CORRUPT);
    return 0;
  }
  if (s->icnt < n)
    fill(s);
  if (s->icnt < n) {
    fail(s, CG_TRUNCATED);
    return 0;
  }
  v = s->ibuf >> (32 - n);
  s->ibuf <<= n;
  s->icnt -= n;
  return v;
}
static int decode(state *s, huff *h) {
  int l, c = 0;
  uint32_t e;
  if (s->icnt <= 24)
    fill(s);
  if (s->err)
    return 0;
  e = h->look[s->ibuf >> 24];
  l = (int)(e & 31);
  s->r->input_symbols++;
  if (e && (unsigned)l <= s->icnt) {
    s->ibuf <<= l;
    s->icnt -= (unsigned)l;
    return (int)(e >> 5);
  }
  for (l = 1; l <= 16; l++) {
    c = (c << 1) | (int)take(s, 1);
    if (s->err)
      return 0;
    if (h->max[l] >= 0 && c >= h->min[l] && c <= h->max[l])
      return h->val[h->ptr[l] + c - h->min[l]];
  }
  fail(s, CG_CORRUPT);
  return 0;
}
static int extend(uint32_t v, unsigned n) {
  return !n ? 0 : ((v < (1u << (n - 1))) ? (int)v - (1 << n) + 1 : (int)v);
}
static int readblock(state *s, int16_t *q, int b) {
  int comp = b < 2 ? 0 : b - 1, h = comp ? 2 : 0, k = 1, v, rs, n, run;
  zero(q, 128);
  n = decode(s, &s->h[h]);
  if (n < 0 || n > 11)
    return fail(s, CG_CORRUPT);
  v = extend(take(s, (unsigned)n), (unsigned)n);
  s->ipred[comp] += v;
  if (s->ipred[comp] < -32768 || s->ipred[comp] > 32767)
    return fail(s, CG_CORRUPT);
  q[0] = (int16_t)s->ipred[comp];
  while (k < 64 && !s->err) {
    rs = decode(s, &s->h[h + 1]);
    n = rs & 15;
    run = rs >> 4;
    if (!n) {
      if (rs == 0)
        break;
      if (rs != 240 || k + 16 > 64)
        return fail(s, CG_CORRUPT);
      k += 16;
      continue;
    }
    if (n > 10 || k + run >= 64)
      return fail(s, CG_CORRUPT);
    k += run;
    v = extend(take(s, (unsigned)n), (unsigned)n);
    q[zz[k++]] = (int16_t)v;
  }
  return !s->err;
}
static int rawentropy(state *s, uint32_t c) {
  return put(s, c) && (c != 255 || put(s, 0));
}
static int emitbits(state *s, uint32_t v, unsigned n) {
  if (!n || n > 16)
    return fail(s, CG_EDIT_RANGE);
  s->obuf = (s->obuf << n) | (v & ((1u << n) - 1));
  s->ocnt += n;
  while (s->ocnt >= 8 && !s->err) {
    s->ocnt -= 8;
    rawentropy(s, (s->obuf >> s->ocnt) & 255);
  }
  return !s->err;
}
static int symbol(state *s, huff *h, unsigned v) {
  uint32_t c;
  if (v > 255)
    return fail(s, CG_EDIT_RANGE);
  c = h->enc[v];
  if (!(c >> 16))
    return fail(s, CG_EDIT_RANGE);
  s->r->output_symbols++;
  return emitbits(s, c & 65535, c >> 16);
}
static unsigned mag(int32_t v) {
  uint32_t a = (uint32_t)(v < 0 ? -v : v);
  unsigned n = 0;
  while (a) {
    a >>= 1;
    n++;
  }
  return n;
}
static int writeblock(state *s, const int16_t *q, int b) {
  int comp = b < 2 ? 0 : b - 1, h = comp ? 2 : 0, k, run = 0;
  int32_t v = (int32_t)q[0] - s->opred[comp];
  unsigned n = mag(v);
  if (n > 11)
    return fail(
        s, CG_EDIT_RANGE); /* validate entire block before first emission */
  for (k = 1; k < 64; k++)
    if (q[k] < -1023 || q[k] > 1023)
      return fail(s, CG_EDIT_RANGE);
  s->opred[comp] = q[0];
  symbol(s, &s->h[h], n);
  if (n)
    emitbits(s, (uint32_t)(v < 0 ? v - 1 : v), n);
  for (k = 1; k < 64 && !s->err; k++) {
    v = q[zz[k]];
    if (!v) {
      run++;
      continue;
    }
    while (run > 15) {
      symbol(s, &s->h[h + 1], 240);
      run -= 16;
    }
    n = mag(v);
    symbol(s, &s->h[h + 1], (unsigned)(run << 4) | n);
    emitbits(s, (uint32_t)(v < 0 ? v - 1 : v), n);
    run = 0;
  }
  if (run)
    symbol(s, &s->h[h + 1], 0);
  return !s->err;
}
int cg_run(uint32_t size, cg_read_fn read, void *rc, cg_write_fn write,
           void *wc, void *workspace, uint32_t cap, const cg_options *opt,
           cg_result *r) {
  state *s = (state *)workspace;
  uint32_t x, y, i;
  int result;
  if (!r)
    return CG_ARGUMENT;
  zero(r, sizeof(*r));
  r->input_bytes = size;
  r->workspace_bytes = sizeof(state);
  r->core_ram_bytes = cap > UINT32_MAX - CG_CORE_STACK_RESERVE
                          ? UINT32_MAX
                          : cap + CG_CORE_STACK_RESERVE;
  if (!read || !write || !workspace || ((uintptr_t)workspace % sizeof(void *)))
    return r->status = CG_ARGUMENT;
  if (cap < sizeof(state))
    return r->status = CG_RAM_LIMIT;
  zero(s, sizeof(*s));
  s->r = r;
  s->read = read;
  s->write = write;
  s->rc = rc;
  s->wc = wc;
  s->size = size;
  if (opt)
    s->opt = *opt;
  if (!s->opt.input_limit)
    s->opt.input_limit = CG_INPUT_MAX;
  if (!s->opt.output_limit)
    s->opt.output_limit = CG_OUTPUT_MAX;
  if (!s->opt.header_limit)
    s->opt.header_limit = CG_HEADER_MAX;
  if (!s->opt.ram_limit)
    s->opt.ram_limit = 65536;
  if (s->opt.input_limit > CG_INPUT_MAX)
    s->opt.input_limit = CG_INPUT_MAX;
  if (s->opt.output_limit > CG_OUTPUT_MAX)
    s->opt.output_limit = CG_OUTPUT_MAX;
  if (s->opt.header_limit > CG_HEADER_MAX)
    s->opt.header_limit = CG_HEADER_MAX;
  if (s->opt.ram_limit > 65536)
    s->opt.ram_limit = 65536;
  if (size > s->opt.input_limit)
    return r->status = CG_INPUT_LIMIT;
  if (r->core_ram_bytes > s->opt.ram_limit)
    return r->status = CG_RAM_LIMIT;
  if (!s->opt.edit && size > s->opt.output_limit)
    return r->status = CG_OUTPUT_LIMIT;
  for (i = 0; i < 4; i++)
    build(&s->h[i], bits(i), vals(i));
  if (!header(s))
    goto done;
  s->m.quant = (const uint16_t (*)[64])s->quant;
  s->m.width = r->width;
  s->m.height = r->height;
  for (y = 0; y < r->height / 8 && !s->err; y++)
    for (x = 0; x < r->width / 16 && !s->err; x++) {
      s->m.mcu_x = x;
      s->m.mcu_y = y;
      for (i = 0; i < 4; i++) {
        if (!readblock(s, s->m.coef[i], (int)i))
          break;
        r->blocks++;
      }
      if (s->err)
        break;
      if (s->opt.edit && s->opt.edit(s->opt.edit_ctx, &s->m)) {
        fail(s, CG_HOOK);
        break;
      }
      for (i = 0; i < 4; i++)
        if (!writeblock(s, s->m.coef[i], (int)i))
          break;
      if (!s->err)
        r->mcus++;
    }
  if (s->err)
    goto done;
  fill(s);
  if (s->err)
    goto done;
  if (s->icnt > 7 ||
      (s->icnt && (s->ibuf >> (32 - s->icnt)) != ((1u << s->icnt) - 1))) {
    fail(s, CG_CORRUPT);
    goto done;
  }
  r->padding_bits = s->icnt;
  if (get(s) != 255 || get(s) != 217) {
    fail(s, CG_CORRUPT);
    goto done;
  }
  if (s->pos != size) {
    fail(s, CG_UNSUPPORTED);
    goto done;
  }
  if (s->ocnt)
    emitbits(s, (1u << (8 - s->ocnt)) - 1, 8 - s->ocnt);
  put(s, 255);
  put(s, 217);
  flush(s);
done:
  result = s->err;
  r->status = result;
  return result;
}
