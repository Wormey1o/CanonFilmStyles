/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef Y_READONLY_H
#define Y_READONLY_H
#include "ystorage.h"
typedef struct {
 void *ctx;uint32_t tick_hz;
 int (*open_ro)(void *,const char *,int *);
 int (*identity)(void *,int,ys_identity *);
 int (*read_at)(void *,int,uint32_t,uint8_t *,uint32_t,uint32_t *);
 int (*close)(void *,int);
 uint32_t (*ticks)(void *);int (*continuing)(void *);
 /* Required: no in-flight/unknown FIO consumer before any close/reclaim. */
 int (*io_quiescent)(void *);
 void (*trace)(void *,uint32_t,uint32_t,uint32_t,int);
} yr_ops;
typedef struct {
 const char *source_path,*raw_path;
 uint32_t source_bytes,raw_bytes,expected_output_bytes;
 uint8_t source_sha[32],raw_sha[32],expected_output_sha[32];
 uint32_t seed,amount,cell;
} yr_job;
enum{YR_PIN=1,YR_PREHASH,YR_PROCESS,YR_POSTHASH,YR_CLOSE,YR_COMPLETE};
typedef struct {
 uint32_t magic,started,phase,error,safe,complete,codec_status;
 yr_ops ops;yr_job job;int source_fd,raw_fd;
 ys_identity source_id,raw_id;
 uint32_t source_read_bytes,raw_read_bytes,sink_bytes,read_ticks,process_ticks,process_read_ticks;
 uint32_t phase_start[7],phase_end[7];
 uint8_t source_pre_sha[32],source_post_sha[32],raw_pre_sha[32],raw_post_sha[32],output_sha[32];
 int32_t last_open_rc,last_read_rc,last_close_rc;uint32_t last_read_actual;
 CSha256 sink;quality_grain grain;cg_result result;
 uint8_t io[YS_IO_BYTES];void *workspace;uint32_t workspace_bytes;
} yr_readonly;
/* Zero-init once; job strings and supplied buffers immutable/exclusive through
 * safe drain. No create/write/sync/rename/delete/catalogue/LOG service exists.
 * complete means measured compute sink+original proofs+known closes ONLY. */
int yr_init(yr_readonly *,const yr_ops *,const yr_job *,void *,uint32_t);
int yr_run(yr_readonly *);
int yr_drain(yr_readonly *);
#endif
