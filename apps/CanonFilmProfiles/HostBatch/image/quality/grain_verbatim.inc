#include <stdint.h>

#include <string.h>

typedef struct {int grain_cell;int grain;} se_look;
#define SE_GRAIN_AMP 38
static int clamp8(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }
static unsigned grain_hash(unsigned x, unsigned y, unsigned seed)
{
    unsigned h = x * 374761393u + y * 668265263u + seed * 2246822519u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return h ^ (h >> 16);
}
static void grain_row_legacy(const se_look *lk, uint8_t *row, int w, int y)
{
    int x, cell = lk->grain_cell;
    /* 0..100 -> about +-15 at full strength. This was 72/100, which put
     * +-28 on a midtone: at that amplitude a coarse stock stopped reading
     * as emulsion and started reading as sensor noise, which is the one
     * thing grain must not look like. */
    int amp = (lk->grain * SE_GRAIN_AMP) / 100;
    if (amp <= 0) return;
    for (x = 0; x < w; x++) {
        int n = (int)(grain_hash((unsigned)(x / cell), (unsigned)(y / cell),
                                 0x5EEDu) & 0xFFFF);
        int d = ((n - 32768) * amp) >> 15;
        int c;
        for (c = 0; c < 3; c++) {
            int v = row[x * 3 + c];
            /* 4v(1-v), in eighths, so grain fades out at both ends */
            int wgt = (v * (255 - v)) >> 6;     /* 0..254 */
            row[x * 3 + c] = (uint8_t)clamp8(v + ((d * wgt) >> 8));
        }
    }
}
static void grain_row(const se_look *lk, uint8_t *row, int w, int y)
{
    int cell = lk->grain_cell;
    int amp = (lk->grain * SE_GRAIN_AMP) / 100;
    if (amp <= 0) return;
    if (cell <= 0 || y < 0) { grain_row_legacy(lk, row, w, y); return; }
    if (cell == 1) {
        for (int x = 0; x < w; x++) {
            int n = (int)(grain_hash((unsigned)x, (unsigned)y, 0x5EEDu) & 0xFFFF);
            int d = ((n - 32768) * amp) >> 15;
            for (int c = 0; c < 3; c++) {
                int v = row[x * 3 + c];
                int wgt = (v * (255 - v)) >> 6;
                row[x * 3 + c] = (uint8_t)clamp8(v + ((d * wgt) >> 8));
            }
        }
        return;
    }
    unsigned gy = (unsigned)(y / cell), gx = 0;
    for (int x = 0; x < w; gx++) {
        int end = cell > w - x ? w : x + cell;
        int n = (int)(grain_hash(gx, gy, 0x5EEDu) & 0xFFFF);
        int d = ((n - 32768) * amp) >> 15;
        for (; x < end; x++) {
            for (int c = 0; c < 3; c++) {
                int v = row[x * 3 + c];
                int wgt = (v * (255 - v)) >> 6;
                row[x * 3 + c] = (uint8_t)clamp8(v + ((d * wgt) >> 8));
            }
        }
    }
}
