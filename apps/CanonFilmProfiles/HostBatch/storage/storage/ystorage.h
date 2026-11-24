/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef YSTORAGE_H
#define YSTORAGE_H
#include <stdint.h>
#include "../../image/codec/codec.h"
#include "../../image/quality/quality.h"
#include "sha256.h"
#define YS_IO_BYTES 8192u
#define YS_RECEIPT_BYTES 4096u
#define YS_OUTPUT_MAX (8u*1024u*1024u)
/* Explicit existing COMPLETE file pinned before worker startup. No enumeration,
 * UI state, stable-size heuristic, FCS or catalogue calls. */
typedef struct {uint32_t size, token[8];} ys_identity;
typedef struct {
 void *ctx;
 uint32_t tick_hz;
 /* Owned nonnegative fd token, -1 on clean open refusal. close failure is
  * ambiguous: never retry/reclaim; retain the context and all buffers. */
 int (*open_ro)(void *,const char *,int *fd);
 int (*create_excl)(void *,const char *,int *fd);
 int (*identity)(void *,int,ys_identity *);
 int (*read_at)(void *,int,uint32_t,uint8_t *,uint32_t,uint32_t *actual);
 int (*write)(void *,int,const uint8_t *,uint32_t,uint32_t *actual);
 int (*sync)(void *,int); int (*close)(void *,int);
 int (*space)(void *,const char *,uint32_t *free_bytes);
 uint32_t (*ticks)(void *); int (*continuing)(void *);
 void (*trace)(void *,uint32_t phase,uint32_t begin,uint32_t end,int status);
 int (*continue_control)(void *);void *continue_ctx;
 /* Optional synchronous-domain proof. False forbids even close/descriptor
  * reclamation: retain every handle/buffer if native FIO may be in flight. */
 int (*io_quiescent)(void *);
} ys_ops;
typedef struct {
 const char *source_path,*raw_path,*output_path,*receipt_path;
 const void *identity_blob;uint32_t identity_bytes;
 uint32_t source_bytes,raw_bytes; uint8_t source_sha[32],raw_sha[32];
 uint32_t seed,amount,cell;
} ys_job;
enum {YS_OK,YS_ARGUMENT,YS_OPEN,YS_IDENTITY,YS_READ,YS_WRITE,YS_SPACE,YS_COLLISION,YS_CANCEL,YS_CHANGED,YS_SYNC,YS_CLOSE,YS_CODEC,YS_VERIFY,YS_STATE};
enum {YS_PIN=1,YS_PREHASH,YS_PROCESS,YS_SYNC_PHASE,YS_READBACK,YS_POSTHASH,YS_DIAGNOSTIC,YS_DRAIN};
typedef struct {
 uint32_t magic;ys_ops ops; ys_job job; int source_fd,raw_fd,output_fd,verify_fd,receipt_fd;
 ys_identity source_id,raw_id,output_id;
 uint32_t phase,started,created,verified,diagnostic,safe,error,codec_status;
 uint32_t receipt_reserved,receipt_verified,receipt_bytes;
 int32_t last_read_rc,last_write_rc,last_sync_rc,last_close_rc;
 uint32_t last_read_actual,last_write_actual;
 uint32_t input_bytes,raw_read_bytes,output_bytes,readback_bytes;
 uint32_t read_ticks,write_ticks,process_ticks,sync_ticks,readback_ticks;
 uint32_t process_read_ticks,process_write_ticks;
 uint32_t phase_start[9],phase_end[9];
 uint8_t output_sha[32],readback_sha[32],receipt_sha[32];
 uint8_t source_pre_sha[32],source_post_sha[32],raw_pre_sha[32],raw_post_sha[32];
 CSha256 emitted_sha; cg_result result; quality_grain grain;
 uint8_t io[YS_IO_BYTES];
 void *workspace; uint32_t workspace_bytes;
} ys_storage;
/* No delete/rename APIs. Failed/verified private TMP remains evidence. Caller
 * owns alias-safe buffers, task/power lifetime and RAM bounds. create_excl must
 * atomically refuse existing paths. sync is backend durability barrier; it does
 * not itself prove hardware power-loss durability. Ticks are uint32 wrap-safe.
 * I/O ticks nest within PROCESS; process minus IO is a CPU estimate only. */
/* Zero-initialize context once; initialized contexts are never rearmed. Job
 * paths/blob remain immutable and live through DRAIN; bridge makes its copy. */
int ys_init(ys_storage *,const ys_ops *,const ys_job *,void *,uint32_t);
int ys_pin(ys_storage *); int ys_prehash(ys_storage *);
int ys_process(ys_storage *); int ys_verify(ys_storage *);
int ys_diagnostic(ys_storage *); int ys_drain(ys_storage *);
#endif
