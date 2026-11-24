/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef WF_OUTPUT_METADATA_H
#define WF_OUTPUT_METADATA_H
#include <stdint.h>
/* Accept only SOI, one JFIF APP0, APP1 little-endian TIFF and a unique
 * inline SHORT Orientation=1. Only that two-byte value may be changed.
 * Caller exclusively owns a complete private JPEG header/chunk containing
 * the entire APP1; the image body may still be streaming. Never use a source
 * photo buffer. Only successful whole-pipeline output may be published. */
int wf_output_orientation(volatile uint8_t *,uint32_t bytes,uint32_t orientation);
#endif
