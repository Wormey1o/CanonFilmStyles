/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef FILM_CAPTURE_PREVIEW_H
#define FILM_CAPTURE_PREVIEW_H
#include <stddef.h>
#include <stdint.h>
#define CAP_PREVIEW_MAX 1048576u
typedef struct {uint32_t offset,bytes,width,height,orientation_offset,orientation;} cap_preview;
/* Header-only bounded locator; caller separately validates JPEG syntax and
 * immutable source ownership. No reads outside header, even if total is larger. */
int cap_preview_locate(const uint8_t *header,size_t header_bytes,uint32_t total,cap_preview *out);
#endif
