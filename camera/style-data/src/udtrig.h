/* SPDX-License-Identifier: GPL-2.0-only */
/* candidate-combined-v3: install trigger, replacing the Standard, Standard, User Def. 3 gesture
 * (control.c, no longer linked). The install runs once per boot, on the first eligible
 * User Def. selection made in Canon's GUI:
 *  - a change of the selected-style mirror (word at 0x20C8, as the v1 stop check reads it) to
 *    0x21, 0x22 or 0x23 while Canon's dialog word 0x4750 is nonzero now or was within 1 s
 *    (the wb.c WB_R_NOT_GUI rule);
 *  - the new slot then held for 1 s (the v1 gesture also required 1 s on User Def. 3); a
 *    change away cancels that selection;
 *  - the style at the first observation after the startup cue is the boot baseline and never
 *    triggers (never at boot);
 *  - eligibility (no Live View session, creative-zone dial) is decided by the caller when the
 *    1 s has passed. An ineligible selection is DEFERRED: it is not an attempt, and the next
 *    eligible GUI User Def. selection in the same boot may trigger. At most one attempt per boot.
 * Pure function: no native call, no memory outside the struct (host unit test: test_udtrig.c). */
#ifndef UDTRIG_H
#define UDTRIG_H
#include <stdint.h>
typedef struct {
    uint32_t init, last_style, dialog_tick, pending, pending_style, change_tick;
    uint32_t attempted, slot, deferred, changes, not_gui, cancelled;
} ud_trigger;
/* Returns the slot (0x21..0x23) when the one install attempt starts now, else 0. */
uint32_t ud_trigger_step(ud_trigger *t, uint32_t style, uint32_t dialog, uint32_t eligible, uint32_t now, uint32_t rate);
#endif
