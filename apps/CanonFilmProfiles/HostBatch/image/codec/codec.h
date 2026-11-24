/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef CG_CODEC_H
#define CG_CODEC_H
#include <stddef.h>
#include <stdint.h>
#define CG_WORKSPACE_BYTES 24576u
#define CG_CORE_STACK_RESERVE 1024u
#define CG_INPUT_MAX (32u * 1024u * 1024u)
#define CG_OUTPUT_MAX (8u * 1024u * 1024u)
#define CG_HEADER_MAX 65536u
/* Callbacks transfer exactly n bytes and return 0; any nonzero is fatal.
 * The caller owns files, publication and rollback of incomplete private output.
 * Callback contexts/buffers and grain hook storage are additional RAM.
 * ram_limit accounts supplied workspace capacity plus CG_CORE_STACK_RESERVE, a
 * checked conservative core-only stack allowance. Callback stack/storage is
 * caller-owned. */
typedef int (*cg_read_fn)(void *, uint32_t offset, uint8_t *, uint32_t n);
typedef int (*cg_write_fn)(void *, const uint8_t *, uint32_t n);
typedef struct {
  /* Natural order [v*8+u]. Blocks 0/1 Y, 2 Cb, 3 Cr. Quantizers:
   * table 0 for Y, table 1 for Cb/Cr, also natural order. */
  int16_t coef[4][64];
  const uint16_t (*quant)[64];
  uint32_t mcu_x, mcu_y, width, height;
  /* Global block coordinates: Y=(2*mcu_x+b,mcu_y), chroma=(mcu_x,mcu_y). */
} cg_mcu;
typedef int (*cg_edit_fn)(void *, cg_mcu *);
typedef struct {
  uint32_t input_limit, output_limit, header_limit, ram_limit;
  cg_edit_fn edit;
  void *edit_ctx;
} cg_options;
typedef struct {
  uint32_t input_bytes, output_bytes, prefix_bytes, width, height;
  uint32_t mcus, blocks, input_symbols, output_symbols;
  uint32_t read_calls, write_calls, read_bytes, write_bytes;
  uint32_t workspace_bytes, padding_bits;
  uint32_t core_ram_bytes;
  int status;
} cg_result;
enum {
  CG_OK = 0,
  CG_ARGUMENT = 1,
  CG_INPUT_LIMIT = 2,
  CG_OUTPUT_LIMIT = 3,
  CG_HEADER_LIMIT = 4,
  CG_RAM_LIMIT = 5,
  CG_IO_READ = 6,
  CG_IO_WRITE = 7,
  CG_TRUNCATED = 8,
  CG_CORRUPT = 9,
  CG_UNSUPPORTED = 10,
  CG_EDIT_RANGE = 11,
  CG_HOOK = 12
};
/* workspace must be pointer-aligned; capacity >= cg_workspace_required().
 * Zero option limits use the published maxima. Core has no allocation/globals,
 * no RGB/IDCT/FDCT. Result remains informative on every failure. */
uint32_t cg_workspace_required(void);
int cg_run(uint32_t input_size, cg_read_fn read_at, void *read_ctx,
           cg_write_fn write, void *write_ctx, void *workspace,
           uint32_t workspace_capacity, const cg_options *, cg_result *);
#endif
