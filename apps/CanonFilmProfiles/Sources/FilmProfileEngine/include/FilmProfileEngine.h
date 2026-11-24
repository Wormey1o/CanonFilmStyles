#ifndef CFP_ENGINE_H
#define CFP_ENGINE_H
#include <stdint.h>
#include <stddef.h>
int cfp_bake(const char *text, size_t bytes, uint8_t out[904]);
/* Host verification of a validated 904-byte profile; no image/file/device I/O. */
int cfp_render(const uint8_t body[904], const uint8_t *rgb, int width, int height, uint8_t *out);
/* Explicit effects path: width/height up to4096 when any effect is enabled. */
int cfp_render_effects(const uint8_t body[904], const uint8_t *rgb, int width, int height, int shading, int sharpness, int clarity, int mixer, uint8_t *out);
/* Colour-only sampling for LUT export: no grain or spatial effects. */
int cfp_render_color(const uint8_t body[904], const uint8_t *rgb, int width, int height, int mixer, uint8_t *out);
void cfp_engine_prepare(void);
void *cfp_preview_token(void);
void cfp_preview_cancel(void *token);
void cfp_preview_token_free(void *token);
int cfp_preview_extract(const uint8_t *bytes,size_t size,uint32_t *offset,uint32_t *length,uint32_t *orientation);
int cfp_preview_jpeg(const uint8_t body[904],const uint8_t *jpeg,size_t size,uint32_t orientation,int shading,int sharpness,int clarity,int mixer,uint8_t *out,size_t capacity,size_t *written,void *token);
int cfp_preview_prepare_rgba(const uint8_t *rgba,uint8_t *out,size_t capacity,size_t *written);
#endif
