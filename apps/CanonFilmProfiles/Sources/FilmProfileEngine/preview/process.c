/* SPDX-License-Identifier: GPL-2.0-only
 * Shared host/ARM preview pipeline; no camera API or mutable input. */
#include "process.h"
#include "../jpeg_enc.h"
#include "../look.h"
#include "../se_libc.h"
#include "metadata.h"
#include "container.h"
#include "profile.h"
#include "host_hooks.h"
typedef struct { se_jpeg *encoder;se_look_run *look;volatile uint8_t *output;
 size_t capacity;process_result *result;uint32_t orientation; } pipeline;
static int encoded(void *opaque,const uint8_t *data,size_t n) {
 pipeline *p=opaque;process_result *r=p->result;
 if(n>p->capacity-r->bytes)return -1;
 if(!r->bytes){
  /* This encoder flushes4096B chunks or its complete final remainder. Its
   * bounded APP1 is wholly present in the first sink call. Patch private
   * output before hashing, avoiding a second full-image hash pass. */
  for(size_t i=0;i<n;i++)p->output[r->bytes++]=data[i];
  if(wf_output_orientation(p->output,r->bytes,p->orientation))return -1;
  if(wf_output_exif_first(p->output,r->bytes))return -1;
  for(size_t i=0;i<n;i++)r->hash=(r->hash^p->output[i])*16777619u;
 }else for(size_t i=0;i<n;i++){p->output[r->bytes++]=data[i];r->hash=(r->hash^data[i])*16777619u;}
 return 0;
}
static int looked(void *opaque,const uint8_t *rgb,int width) {
 pipeline *p=opaque;
 if(width!=2256)return -1;
 p->result->rows++;
 unsigned old=profile_enter(P_ENCODE);
 int rc=se_jpeg_write_rows(p->encoder,rgb,1);
 profile_leave(old);return rc;
}
static int decoded(void *opaque,const uint8_t *rgb,int n,int width) {
 pipeline *p=opaque;
 if(width!=2256)return -1;
 if(!(p->result->rows&15u) && !wf_cooperate(1))return -1;
 unsigned old=profile_enter(P_LOOK);
 p->result->look_rc=se_look_rows(p->look,rgb,n,looked,p);
 profile_leave(old);
 return p->result->look_rc;
}
int wf_process_preview(const void *recipe,size_t recipe_size,uint32_t orientation,
 const void *header,size_t header_size,uint32_t total,
 se_jdec_read_fn read,void *read_ctx,void *memory,size_t arena_size,
 volatile uint8_t *output,size_t capacity,process_result *result) {
 if(!result)return SE_E_CORRUPT;
 memset(result,0,sizeof *result);result->hash=2166136261u;
 if(!recipe || recipe_size!=sizeof(se_look) || !header || !read || !memory || !output || capacity>UINT32_MAX ||
    (orientation!=1 && orientation!=3 && orientation!=6 && orientation!=8))return SE_E_UNSUPPORTED;
 se_jdec_info info={0};int rc=se_jpeg_dec_info(header,header_size,&info);
 if(rc)return rc;
 if(info.width!=2256 || info.height!=1504 || info.ncomp!=3)return SE_E_UNSUPPORTED;
 se_arena arena;se_arena_init(&arena,memory,arena_size);
 se_look look;
 if(sizeof look!=904)return SE_E_CORRUPT;
 memcpy(&look,recipe,sizeof look);
 pipeline p={0};p.result=result;p.output=output;p.capacity=capacity;p.orientation=orientation;
 p.encoder=SE_NEW(&arena,se_jpeg,1);
 if(!p.encoder)return SE_E_NOMEM;
 rc=se_look_begin(&p.look,&look,2256,&arena);
 if(rc)return rc;
 uint8_t *strip=SE_NEW(&arena,uint8_t,8u*2256*3);
 if(!strip)return SE_E_NOMEM;
 se_jpeg_exif ex={0};ex.make="Canon";ex.model="Canon EOS 450D";ex.software="Canon Film Workflow";
 rc=se_jpeg_begin(p.encoder,2256,1504,88,strip,&ex,encoded,&p);
 if(!rc){profile_phase(P_DECODE);result->decode_rc=se_jpeg_decode_stream_scaled(header,header_size,total,read,read_ctx,1,&arena,decoded,&p,&info);rc=result->decode_rc;}
 if(!rc){profile_phase(P_LOOK);result->look_rc=se_look_end(p.look,looked,&p);rc=result->look_rc;}
 if(!rc){profile_phase(P_ENCODE);result->encode_rc=se_jpeg_end(p.encoder);rc=result->encode_rc;}
 profile_phase(P_SETUP);
 result->peak=(uint32_t)arena.peak;
 if(!rc && (result->rows!=1504 || info.width!=2256 || info.height!=1504))return SE_E_CORRUPT;
 return rc;
}

/* Separate streaming adapter: the buffered implementation above is retained
 * exactly, so it remains an independent whole-output parity oracle. */
typedef struct {
 se_jpeg *encoder;
 se_look_run *look;
 uint8_t *first_chunk;
 size_t first_chunk_capacity;
 wf_process_sink sink;
 void *sink_ctx;
 process_result *result;
 uint32_t orientation;
 int sink_error;
 uint32_t decoded_rows;
} stream_pipeline;
static int stream_encoded(void *opaque,const uint8_t *data,size_t n) {
 stream_pipeline *p=opaque;process_result *r=p->result;
 if(p->sink_error)return -1;
 if(!n || n>WF_PROCESS_FIRST_CHUNK_SIZE ||
    r->bytes>WF_PROCESS_OUTPUT_LIMIT || n>WF_PROCESS_OUTPUT_LIMIT-r->bytes){
  p->sink_error=SE_E_IO;return -1;
 }
 const uint8_t *emit=data;
 if(!r->bytes){
  if(n>p->first_chunk_capacity){p->sink_error=SE_E_IO;return -1;}
  memcpy(p->first_chunk,data,n);
  if(wf_output_orientation(p->first_chunk,(uint32_t)n,p->orientation) ||
     wf_output_exif_first(p->first_chunk,(uint32_t)n)){
   p->sink_error=SE_E_CORRUPT;return -1;
  }
  emit=p->first_chunk;
 }
 uint32_t hash=r->hash;
 for(size_t i=0;i<n;i++)hash=(hash^emit[i])*16777619u;
 if(p->sink(p->sink_ctx,emit,n)){p->sink_error=SE_E_IO;return -1;}
 r->hash=hash;r->bytes+=(uint32_t)n;
 return 0;
}
static int stream_looked(void *opaque,const uint8_t *rgb,int width) {
 stream_pipeline *p=opaque;
 if(width!=2256)return -1;
 p->result->rows++;
 unsigned old=profile_enter(P_ENCODE);
 int rc=se_jpeg_write_rows(p->encoder,rgb,1);
 profile_leave(old);
 if(rc && !p->result->encode_rc)p->result->encode_rc=rc;
 return rc;
}
static int stream_decoded(void *opaque,const uint8_t *rgb,int n,int width) {
 stream_pipeline *p=opaque;
 if(width!=2256)return -1;
 if(n<0 || (uint32_t)n>1504u-p->decoded_rows)return -1;
 if(!(p->decoded_rows&15u) && !wf_cooperate(1))return -1;
 p->decoded_rows+=(uint32_t)n;
 unsigned old=profile_enter(P_LOOK);
 p->result->look_rc=se_look_rows(p->look,rgb,n,stream_looked,p);
 profile_leave(old);
 return p->result->look_rc;
}
int wf_process_preview_detail_sink(const void *recipe,size_t recipe_size,const se_detail *detail,uint32_t orientation,
 const void *header,size_t header_size,uint32_t total,
 se_jdec_read_fn read,void *read_ctx,void *memory,size_t arena_size,
 uint8_t *first_chunk,size_t first_chunk_capacity,
 wf_process_sink sink,void *sink_ctx,process_result *result) {
 if(!result)return SE_E_CORRUPT;
 memset(result,0,sizeof *result);result->hash=2166136261u;
 if(!recipe || recipe_size!=sizeof(se_look) || !header || !read || !memory ||
    !first_chunk || first_chunk_capacity<WF_PROCESS_FIRST_CHUNK_SIZE ||
    first_chunk_capacity>UINTPTR_MAX-(uintptr_t)first_chunk || !sink ||
    (orientation!=1 && orientation!=3 && orientation!=6 && orientation!=8))return SE_E_UNSUPPORTED;
 se_jdec_info info={0};int rc=se_jpeg_dec_info(header,header_size,&info);
 if(rc)return rc;
 if(info.width!=2256 || info.height!=1504 || info.ncomp!=3)return SE_E_UNSUPPORTED;
 se_arena arena;se_arena_init(&arena,memory,arena_size);
 se_look look;
 if(sizeof look!=904)return SE_E_CORRUPT;
 memcpy(&look,recipe,sizeof look);
 stream_pipeline p={0};p.result=result;p.first_chunk=first_chunk;
 p.first_chunk_capacity=first_chunk_capacity;p.sink=sink;p.sink_ctx=sink_ctx;
 p.orientation=orientation;
 p.encoder=SE_NEW(&arena,se_jpeg,1);
 if(!p.encoder)return SE_E_NOMEM;
 rc=se_look_begin(&p.look,&look,2256,&arena);
 if(rc)return rc;
 if(detail){rc=se_look_detail(p.look,detail,1504,&arena);if(rc)return rc;}
 uint8_t *strip=SE_NEW(&arena,uint8_t,8u*2256*3);
 if(!strip)return SE_E_NOMEM;
 se_jpeg_exif ex={0};ex.make="Canon";ex.model="Canon EOS 450D";ex.software="Canon Film Workflow";
 rc=se_jpeg_begin(p.encoder,2256,1504,88,strip,&ex,stream_encoded,&p);
 result->encode_rc=rc;
 if(!rc){profile_phase(P_DECODE);result->decode_rc=se_jpeg_decode_stream_scaled(header,header_size,total,read,read_ctx,1,&arena,stream_decoded,&p,&info);rc=result->decode_rc;}
 if(!rc){profile_phase(P_LOOK);result->look_rc=se_look_end(p.look,stream_looked,&p);rc=result->look_rc;}
 if(!rc){profile_phase(P_ENCODE);result->encode_rc=se_jpeg_end(p.encoder);rc=result->encode_rc;}
 profile_phase(P_SETUP);
 result->peak=(uint32_t)arena.peak;
 if(p.sink_error){result->encode_rc=p.sink_error;return p.sink_error;}
 if(!rc && (!result->bytes || result->rows!=1504 || info.width!=2256 || info.height!=1504))return SE_E_CORRUPT;
 return rc;
}

int wf_process_preview_sink(const void *recipe,size_t size,uint32_t orientation,const void *header,size_t header_size,uint32_t total,se_jdec_read_fn read,void *read_ctx,void *memory,size_t arena_size,uint8_t *first,size_t first_size,wf_process_sink sink,void *sink_ctx,process_result *result){
 return wf_process_preview_detail_sink(recipe,size,0,orientation,header,header_size,total,read,read_ctx,memory,arena_size,first,first_size,sink,sink_ctx,result);
}
