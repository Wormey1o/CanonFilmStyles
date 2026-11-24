/* Caller owns distinct buffers; baked recipe must come from validated book.
 * JPEG input is admitted sRGB; orientation is carried into new EXIF.
 * No output is publishable unless return0; no FIO/native calls. */
#ifndef WF_PROCESS_H
#define WF_PROCESS_H
/* SPDX-License-Identifier: GPL-2.0-only */

#include "../detail.h"
#include "../jpeg_dec.h"
typedef struct { uint32_t bytes,hash,rows,peak; int decode_rc,look_rc,encode_rc; } process_result;
int wf_process_preview(const void *recipe904,size_t recipe_size,uint32_t orientation,
 const void *header,size_t header_size,uint32_t total,
 se_jdec_read_fn read,void *read_ctx,void *arena,size_t arena_size,
 volatile uint8_t *output,size_t capacity,process_result *result);

#define WF_PROCESS_FIRST_CHUNK_SIZE 4096u
#define WF_PROCESS_OUTPUT_LIMIT 1310720u
/* Synchronous whole-chunk consumer: 0 accepts all n bytes; any other return
 * stops processing. A failed callback may already have external side effects;
 * its entire artifact remains unpublishable. The callback must not retain the
 * data pointer, modify it, reenter this pipeline or reuse arena/header/scratch.
 * Raw transport errors/ownership are recorded by the callback's caller. */
typedef int (*wf_process_sink)(void *ctx,const uint8_t *data,size_t n);
/* Streaming variant. Same pixel/recipe/metadata/quality/dimensions as above.
 * No full-image output allocation. first_chunk owns at least4096 mutable CPU
 * bytes, distinct from recipe/header/arena/result and callback-owned state.
 * A declared scratch span wrapping uintptr_t is refused before decoding.
 * All buffers/result remain owned and valid through return. Later callback
 * bytes are encoder-owned and valid only during that callback. First chunk
 * must contain the complete generated APP1 or the operation refuses.
 * bytes/hash describe only fully accepted transformed chunks, even on error;
 * a failed chunk is not counted (its external partial write is unknowable).
 * Successful output is at most1310720 bytes. Only return0 permits later
 * independent close/readback/RAW/publication validation; it proves no I/O. */
int wf_process_preview_sink(const void *recipe904,size_t recipe_size,uint32_t orientation,
 const void *header,size_t header_size,uint32_t total,
 se_jdec_read_fn read,void *read_ctx,void *arena,size_t arena_size,
 uint8_t *first_chunk,size_t first_chunk_capacity,
 wf_process_sink sink,void *sink_ctx,process_result *result);
int wf_process_preview_detail_sink(const void *recipe904,size_t recipe_size,const se_detail *detail,uint32_t orientation,
 const void *header,size_t header_size,uint32_t total,
 se_jdec_read_fn read,void *read_ctx,void *arena,size_t arena_size,
 uint8_t *first_chunk,size_t first_chunk_capacity,
 wf_process_sink sink,void *sink_ctx,process_result *result);

#endif
