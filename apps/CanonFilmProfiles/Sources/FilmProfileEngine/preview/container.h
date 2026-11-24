/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef WF_JPEG_CONTAINER_H
#define WF_JPEG_CONTAINER_H
#include <stdint.h>
/* Owned encoder header only. Move complete APP1 ahead of its fixed18-byte
 * JFIF APP0, preserving both segments and every subsequent byte. No heap.
 * Requires the complete APP1 in the caller-owned chunk. Validation failure
 * leaves it untouched. Apply orientation BEFORE this normalization. */
int wf_output_exif_first(volatile uint8_t *,uint32_t bytes);
#endif
