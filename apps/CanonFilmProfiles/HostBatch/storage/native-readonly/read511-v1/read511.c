/* SPDX-License-Identifier: GPL-2.0-only */
#include "read511.h"

int nro_read511(const yr_ops *ops, int fd, uint32_t total, uint32_t off,
                uint8_t *dst, uint32_t count, uint32_t *actual)
{
    if (!actual)
        return YS_ARGUMENT;
    *actual = 0;
    if (!ops || !ops->read_at || !ops->continuing || !dst || !count ||
        count > NRO_IO_BYTES || off > total ||
        (off == total ? count != 1 : count > total - off))
        return YS_ARGUMENT;

    const int eof_probe = off == total;
    uint32_t done = 0;
    while (done < count) {
        if (!ops->continuing(ops->ctx))
            return YS_CANCEL;

        const uint32_t left = count - done;
        const uint32_t request = left < NRO_READ511_MAX ? left : NRO_READ511_MAX;
        uint32_t got = 0;
        const int status = ops->read_at(ops->ctx, fd, off + done,
                                        dst + done, request, &got);
        if (status)
            return status;
        if (got != (eof_probe ? 0u : request))
            return YS_READ;

        done += request;
    }
    *actual = eof_probe ? 0u : done;
    return YS_OK;
}
