/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef NRO_READ511_H
#define NRO_READ511_H

#include "../adapter.h"

#define NRO_READ511_MAX 511u

/* Experimental wrapper over an admitted read_at operation and its stop check.
 * total is the pinned length of the already-owned fd. An EOF probe is one
 * byte at total and must return zero. On failure actual is zero, and dst
 * may contain a prefix that must be discarded. No retries or lifetime claims.
 */
int nro_read511(const yr_ops *ops, int fd, uint32_t total, uint32_t off,
                uint8_t *dst, uint32_t count, uint32_t *actual);

#endif
