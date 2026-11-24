/* Owned full-resolution adapter; frozen codec source copies are unchanged. */
#include "quality.h"
#include "frozen/jpeg_enc.c"
#include "frozen/jpeg_dec.c"
#include "grain_verbatim.inc"
void se_arena_init(se_arena*a,void*p,size_t n){a->base=p;a->size=n;a->used=a->peak=0;}
void *se_arena_alloc(se_arena*a,size_t n,size_t al){size_t x=(a->used+al-1)&~(al-1);if(x>a->size||n>a->size-x)return 0;a->used=x+n;if(a->peak<a->used)a->peak=a->used;return a->base+x;}
void se_arena_reset(se_arena*a){a->used=0;}
void se_log(const char *fmt,...){(void)fmt;}
void se_progress(const char*a,int b){(void)a;(void)b;}
/* Closed pilot domain: validate before coordinate division or strength arithmetic. */
static int quality_amount_valid(int amount)
{
    return amount==0 || amount==11 || amount==16 || amount==27;
}
static int quality_grain_parameters_valid(const quality_grain *g,int max_arm)
{
    return g && quality_amount_valid(g->amount) && g->cell>=1 && g->cell<=3 &&
           g->gain_q12==4096 && g->arm>=0 && g->arm<=max_arm;
}
/* Global coordinate integer noise + source block-DC envelope, preserving legacy
 * signed-shift bias intentionally. arm=0 dense DC; 1 dense AC-only; 2 low-9 AC; 3 dense DC with conservative source-range guard.
 * Quantization round-to-nearest, ties away from zero. Frequency natural order. */
int quality_grain_hook(void *ctx,cg_mcu*m){quality_grain*g=ctx;
 if(!m||!quality_grain_parameters_valid(g,3))return 1;
 for(int b=0;b<2;b++){
  g->blocks++;
  if(g->arm==3){
   /* Every AC orthonormal JPEG IDCT basis magnitude <= 1/4.
    * In eighth-pixel units mean=(1024+DCQ)/8; radius<=2*sumabsACQ.
    * One-value endpoint margin covers integer reconstruction rounding. */
   int32_t l1=0;for(int k=1;k<64;k++){int32_t z=m->coef[b][k]*(int32_t)m->quant[0][k];l1+=z<0?-z:z;}
   int32_t center=1024+m->coef[b][0]*(int32_t)m->quant[0][0];
   if(center-2*l1<=8||center+2*l1>=2032){g->guarded_blocks++;continue;}
  }
  int v=128+((m->coef[b][0]*m->quant[0][0]+4)>>3);if(v<0)v=0;if(v>255)v=255;
  int w=(v*(255-v))>>6,amp=g->amount*38/100;int32_t d[64];
  for(int y=0;y<8;y++)for(int x=0;x<8;x++){
   unsigned gx=(m->mcu_x*16+b*8+x)/(unsigned)g->cell,gy=(m->mcu_y*8+y)/(unsigned)g->cell;
   int n=(int)(grain_hash(gx,gy,g->seed)&65535),z=((n-32768)*amp)>>15;
   d[y*8+x]=(((z*w)>>8)*g->gain_q12+2048)>>12;
  }
  fdct(d);
  for(int k=0;k<64;k++){
   if(((g->arm==1||g->arm==2) && !k)||(g->arm==2 && (k/8+k%8>3)))continue;
   int den=8*m->quant[0][k],z=d[k],delta=z<0?-((-z+den/2)/den):(z+den/2)/den;
   int n=m->coef[b][k]+delta;
   if(k && (n>1023||n< -1023)){n=n<0?-1023:1023;g->ac_caps++;}
   /* Absolute DC is not its differential category. Preserve source exactly
    * for delta0; representable edited DC passes to checked writer predictors. */
   if(!k && !delta)continue;
   if(!k && (n>32767||n< -32768)){g->dc_bounds++;return 1;}
   if(n!=m->coef[b][k])g->edits++;
   m->coef[b][k]=(int16_t)n;
  }
 }return 0;}
/* Optional A4 comparator. Decode each Y block with the frozen adaptive IDCT,
 * apply source grain arithmetic to each reconstructed Y sample, then frozen
 * FDCT/Q16 reciprocal quantization of absolute Y. Original chroma is untouched.
 * This is luma-only, not exact per-RGB grain on clipped/saturated colors. */
/* Keep cell 1 separate so the ARM compiler cannot fold it into division. */
static __attribute__((noinline)) void grain_cell1_samples(
    const uint8_t samples[64], int32_t spatial[64], unsigned base_x,
    unsigned base_y, unsigned seed, int amp)
{
    unsigned row_h = base_x * 374761393u + base_y * 668265263u +
                     seed * 2246822519u;
    for (int y=0; y<8; y++) {
        unsigned h = row_h;
        for (int x=0; x<8; x++) {
            unsigned mixed = (h ^ (h >> 13)) * 1274126177u;
            int n = (int)((mixed ^ (mixed >> 16)) & 65535u);
            int d = ((n-32768)*amp)>>15;
            int v = samples[y*8+x];
            int weight = (v*(255-v))>>6;
            spatial[y*8+x] = clamp8(v+((d*weight)>>8))-128;
            h += 374761393u;
        }
        row_h += 668265263u;
    }
}

int quality_yonly_hook(void *ctx,cg_mcu *m)
{
    quality_grain *g=ctx;
    if (!m || !quality_grain_parameters_valid(g,4)) return 1;
    if (!g->qcache_valid || (!m->mcu_x && !m->mcu_y)) {
        for (int k=0;k<64;k++) {
            uint32_t q=m->quant[0][k];
            g->qrecip[k]=(65536u+4u*q)/(8u*q);
        }
        g->qcache_valid=1;
    }
    int amp=(g->amount*38)/100;
    for (int b=0;b<2;b++) {
        int dequant[64];
        int32_t spatial[64];
        uint8_t samples[64];
        for (int k=0;k<64;k++)
            dequant[k]=m->coef[b][k]*(int)m->quant[0][k];
        jd_idct(dequant,samples,8);
        unsigned base_x=m->mcu_x*16+(unsigned)b*8;
        if (g->cell==1 && amp>0) {
            grain_cell1_samples(samples, spatial, base_x, m->mcu_y*8,
                                g->seed, amp);
        } else {
            for (int y=0;y<8;y++) {
                unsigned global_y=m->mcu_y*8+(unsigned)y;
                unsigned gy=global_y/(unsigned)g->cell;
                for (int x=0;x<8;x++) {
                    int v=samples[y*8+x];
                    if (amp>0) {
                        unsigned global_x=base_x+(unsigned)x;
                        unsigned gx=global_x/(unsigned)g->cell;
                        int n=(int)(grain_hash(gx,gy,g->seed)&65535);
                        int d=((n-32768)*amp)>>15;
                        int weight=(v*(255-v))>>6;
                        v=clamp8(v+((d*weight)>>8));
                    }
                    spatial[y*8+x]=v-128;
                }
            }
        }
        fdct(spatial);
        g->blocks++;
        for (int k=0;k<64;k++) {
            uint32_t reciprocal=g->qrecip[k];
            int32_t v=spatial[k];
            int n=v>=0 ? (int)(((int64_t)v*reciprocal+32768)>>16)
                       : -(int)(((int64_t)-v*reciprocal+32768)>>16);
            if (k && (n>1023 || n< -1023)) {
                n=n<0?-1023:1023;
                g->ac_caps++;
            }
            if (!k && (n>32767 || n< -32768)) {
                g->dc_bounds++;
                return 1;
            }
            if (n!=m->coef[b][k]) g->edits++;
            m->coef[b][k]=(int16_t)n;
        }
    }
    return 0;
}
typedef struct {cg_read_fn rd;void*rc;cg_write_fn wr;void*wc;quality_result*r;se_jpeg*j;int amount,cell,y;} qrctx;
static int qrread(void*p,uint32_t off,void*d,uint32_t n){qrctx*c=p;int r=c->rd(c->rc,off,d,n);if(!r)c->r->read_bytes+=n;return r;}
static int qrwrite(void*p,const uint8_t*d,size_t n){qrctx*c=p;if(n>8388608u-c->r->write_bytes)return -1;int r=c->wr(c->wc,d,(uint32_t)n);if(!r)c->r->write_bytes+=(uint32_t)n;return r;}
static int qrrows(void*p,const uint8_t*rgb,int n,int w){qrctx*c=p;se_look lk={c->cell,c->amount};
 for(int i=0;i<n;i++){uint8_t*row=(uint8_t*)rgb+(size_t)i*w*3;if(c->amount)grain_row(&lk,row,w,c->y);c->y++;if(se_jpeg_write_rows(c->j,row,1))return -1;}return 0;}
int quality_reference(uint32_t n,cg_read_fn rd,void*rc,cg_write_fn wr,void*wc,void*mem,uint32_t cap,int amount,int cell,quality_result*r){
 memset(r,0,sizeof*r);if(cap<393216||!rd||!wr||cell<1||cell>3||!quality_amount_valid(amount))return r->status=-1;
 se_arena a;se_arena_init(&a,mem,cap);uint8_t*hdr=se_arena_alloc(&a,65536,32);uint32_t p=2;
 qrctx c={rd,rc,wr,wc,r,0,amount,cell,0};if(qrread(&c,0,hdr,2)||hdr[0]!=255||hdr[1]!=216)return r->status=-2;
 while(p+4<=65536){if(qrread(&c,p,hdr+p,4)||hdr[p]!=255)return r->status=-3;int marker=hdr[p+1],sz=(hdr[p+2]<<8)|hdr[p+3];if(sz<2||p+2+(unsigned)sz>65536)return r->status=-4;
  if(qrread(&c,p+4,hdr+p+4,sz-2))return r->status=-5;
  p+=2+sz;if(marker==218)break;}
 jd_state s; jd_tables tab;memset(&s,0,sizeof s);memset(&tab,0,sizeof tab);s.tables=&tab;size_t scan;int e=jd_parse(hdr,p,&s,&scan,0);if(e)return r->status=e;
 r->width=s.w;r->height=s.h;r->prefix_bytes=p;if(s.ncomp!=3||s.c[0].hs!=2||s.c[0].vs!=1)return r->status=-7;
 se_jpeg*j=se_arena_alloc(&a,sizeof(se_jpeg),32);memset(j,0,sizeof*j);c.j=j;build_all_codes();j->sink=qrwrite;j->ctx=&c;j->width=s.w;j->height=s.h;j->strip=se_arena_alloc(&a,8*s.w*3,32);if(!j->strip)return r->status=-8;
 for(int t=0;t<2;t++)for(int k=0;k<64;k++){j->qt[t][k]=(uint8_t)tab.qt[t][k];j->qrecip[t][k]=(65536u+4u*j->qt[t][k])/(8u*j->qt[t][k]);}
 if(qrwrite(&c,hdr,p))return r->status=-9;
 se_jdec_info info;e=se_jpeg_decode_stream(hdr,p,n,qrread,&c,&a,qrrows,&c,&info);if(!e)e=se_jpeg_end(j);r->arena_peak=(uint32_t)a.peak;r->status=e;return e;
}
