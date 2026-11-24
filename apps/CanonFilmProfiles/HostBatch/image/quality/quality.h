#ifndef QUALITY_H
#define QUALITY_H
#include "../codec/codec.h"
typedef struct {int amount,cell,arm; unsigned seed; int gain_q12; uint32_t blocks,edits,ac_caps,dc_bounds,guarded_blocks;
 /* Caller zero-initializes; Y-only refreshes cache at first MCU of each image. */
 uint32_t qrecip[64],qcache_valid;
} quality_grain;
/* Closed pilot domain: amount {0,11,16,27}, cell1..3, gain4096,
 * grain arm0..3 / Y-only arm metadata0..4. Any uint32_t seed valid.
 * Context must be fully zero-initialized before setting job parameters. */
int quality_grain_hook(void *,cg_mcu *);
/* Explicit Y-only transform comparator; amount0 is a transport control,
 * not product Noop. Every Y coefficient is in the transform mask. */
int quality_yonly_hook(void *,cg_mcu *);
typedef struct {uint32_t width,height,read_bytes,write_bytes,prefix_bytes,arena_peak;int status;} quality_result;
/* Caller provides >= 393216 bytes workspace, input callback exact transfer.
 * Reference grain fixed seed 0x5EED by source definition. */
int quality_reference(uint32_t,cg_read_fn,void*,cg_write_fn,void*,void*,uint32_t,int,int,quality_result*);
#endif
