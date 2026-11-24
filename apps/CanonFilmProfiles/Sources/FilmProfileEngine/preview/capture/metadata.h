/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef FILM_CAPTURE_METADATA_H
#define FILM_CAPTURE_METADATA_H
#include "preview.h"
typedef struct {cap_preview preview;uint32_t exif_ifd,color_value_offset,color_space;} cap_metadata;
/* Only outer CR2 ExifIFD8769/A001 is authoritative for the Canon embedded
 * preview. The six current previews contain no standalone Exif APP1.
 * The output result and input header must occupy separate owned storage. */
int cap_cr2_admit(const uint8_t *,size_t,uint32_t,cap_metadata *);
/* Baseline8-bit YCbCr header/table/SOS admission for the first fixed geometry.
 * Requires outer sRGB metadata, rejects embedded Exif/ICC/Adobe overrides.
 * Entropy/full decode and exact trailing EOI remain pipeline/snapshot gates. */
int cap_preview_jpeg_admit(const uint8_t *,size_t,const cap_metadata *);
#endif
