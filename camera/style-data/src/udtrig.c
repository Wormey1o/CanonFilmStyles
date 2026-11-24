/* SPDX-License-Identifier: GPL-2.0-only */
/* candidate-combined-v3 install trigger; see udtrig.h. */
#include "udtrig.h"
static int ud(uint32_t s) { return s >= 0x21u && s <= 0x23u; }
uint32_t ud_trigger_step(ud_trigger *t, uint32_t style, uint32_t dialog, uint32_t eligible, uint32_t now, uint32_t rate)
{
    if (!t || t->attempted || rate < 16u || rate > 9000u) return 0;
    if (!t->init) {   /* boot baseline: never a trigger */
        t->init = 1; t->last_style = style; t->dialog_tick = now - 10u * rate;
        if (dialog) t->dialog_tick = now;
        return 0;
    }
    if (dialog) t->dialog_tick = now;
    if (style != t->last_style) {
        t->last_style = style; t->changes++;
        if (t->pending) { t->pending = 0; t->cancelled++; }
        if (ud(style)) {
            if ((uint32_t)(now - t->dialog_tick) > rate) { t->not_gui++; return 0; }
            t->pending = 1; t->pending_style = style; t->change_tick = now;
        }
        return 0;
    }
    if (!t->pending || (uint32_t)(now - t->change_tick) < rate) return 0;
    t->pending = 0;
    if (!eligible) { t->deferred++; return 0; }
    t->attempted = 1; t->slot = t->pending_style;
    return t->slot;
}
