/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef SE_DETAIL_H
#define SE_DETAIL_H
#include "se.h"
typedef struct {int shading,sharpness,clarity,mixer;} se_detail;
typedef struct se_detail_run se_detail_run;
typedef int (*se_detail_emit)(void *,const uint8_t *,int);
/* Integer Canon interpretation: -4..4. Clarity uses a radius-8 luma box;
 * sharpness a radius-1 luma box. Zero spatial values allocate no buffers. */
se_err se_detail_begin(se_detail_run **,const se_detail *,int width,int height,se_arena *);
se_err se_detail_rows(se_detail_run *,const uint8_t *,int,se_detail_emit,void *);
se_err se_detail_end(se_detail_run *,se_detail_emit,void *);
/* Negative shading darkens corners, positive lifts them; centre unchanged. */
void se_detail_shade(uint8_t *,int width,int height,int y,int amount);
#endif
