/* SPDX-License-Identifier: GPL-2.0-only */
#include "../include/FilmProfileEngine.h"
#include "process.h"
#include "capture/metadata.h"
#include "../jpeg_enc.h"
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
typedef struct { atomic_bool stopped; } cancellation;
static _Thread_local cancellation *active;
void *cfp_preview_token(void) { cancellation *c=calloc(1,sizeof *c);if(c)atomic_init(&c->stopped,0);return c; }
void cfp_preview_cancel(void *c) { if(c)atomic_store(&((cancellation *)c)->stopped,1); }
void cfp_preview_token_free(void *c) { free(c); }
int wf_cooperate(int yield) { (void)yield;return !active || !atomic_load(&active->stopped); }
int cfp_preview_extract(const uint8_t *bytes,size_t size,uint32_t *offset,uint32_t *length,uint32_t *orientation) {
 if(!bytes||size>67108864||size<16||!offset||!length||!orientation)return -1;
 cap_metadata m={0};
 if(!cap_cr2_admit(bytes,size<8192?size:8192,(uint32_t)size,&m))return -1;
 if(!cap_preview_jpeg_admit(bytes+m.preview.offset,m.preview.bytes<8192?m.preview.bytes:8192,&m))return -2;
 *offset=m.preview.offset;*length=m.preview.bytes;*orientation=m.preview.orientation;return 0;
}
typedef struct { const uint8_t *input;size_t size;uint8_t *output;size_t capacity,used; } buffers;
static int read_bytes(void *ctx,uint32_t offset,void *dst,uint32_t n) {
 buffers *b=ctx;if(offset>b->size||n>b->size-offset)return -1;memcpy(dst,b->input+offset,n);return 0;
}
static int write_bytes(void *ctx,const uint8_t *src,size_t n) {
 buffers *b=ctx;if(n>b->capacity-b->used)return -1;memcpy(b->output+b->used,src,n);b->used+=n;return 0;
}
int cfp_preview_prepare_rgba(const uint8_t *rgba,uint8_t *out,size_t capacity,size_t *written) {
 if(!rgba||!out||!written||capacity>1310720)return -1;
 *written=0;se_jpeg *encoder=calloc(1,sizeof *encoder);uint8_t *strip=malloc(2256*8*3),*row=malloc(2256*3);
 if(!encoder||!strip||!row){free(encoder);free(strip);free(row);return -4;}
 buffers b={0,0,out,capacity,0};se_jpeg_exif ex={0};ex.make="Canon";ex.model="Canon EOS 450D";ex.software="Canon Film Profiles Mac preview";
 int rc=se_jpeg_begin(encoder,2256,1504,88,strip,&ex,write_bytes,&b);
 for(int y=0;!rc&&y<1504;y++){
  for(int x=0;x<2256;x++)memcpy(row+3*x,rgba+((size_t)y*2256+x)*4,3);
  rc=se_jpeg_write_rows(encoder,row,1);
 }
 if(!rc)rc=se_jpeg_end(encoder);
 free(encoder);free(strip);free(row);if(!rc)*written=b.used;return rc;
}
int cfp_preview_jpeg(const uint8_t body[904],const uint8_t *jpeg,size_t size,uint32_t orientation,int shading,int sharpness,int clarity,int mixer,uint8_t *out,size_t capacity,size_t *written,void *token) {
 if(written)*written=0;
 if(!body||!jpeg||!out||!written||size<4||size>16777216||capacity>1310720||shading<-4||shading>4||sharpness<-4||sharpness>4||clarity<-4||clarity>4||(mixer!=0&&mixer!=1))return -1;
 if(jpeg[size-2]!=255||jpeg[size-1]!=217)return -3;
 void *memory=malloc(286720);uint8_t *first=malloc(4096);
 if(!memory||!first){free(memory);free(first);return -4;}
 cfp_engine_prepare();
 buffers b={jpeg,size,out,capacity,0};process_result result;
 se_detail detail={shading,sharpness,clarity,mixer};
 active=token;
 int rc=wf_cooperate(0)?wf_process_preview_detail_sink(body,904,&detail,orientation,jpeg,size<8192?size:8192,(uint32_t)size,read_bytes,&b,memory,286720,first,4096,write_bytes,&b,&result):-6;
 if(!wf_cooperate(0))rc=-6;
 active=0;free(first);free(memory);if(!rc)*written=b.used;return rc;
}
