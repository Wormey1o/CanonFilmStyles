/* SPDX-License-Identifier: GPL-2.0-only */
/* Copied from film-native-readonly-trial-v1/candidate-v2/caller/caller.c
 * (physically run a494778b). Changes: pinned path, two accepted lengths
 * (50,356 v1 or 50,420 v1 + WB block), the data chunks are
 * copied into c->dst instead of hashed, the EOF probe byte goes to a private
 * scratch, and the final digest comparison is removed (the style job validates
 * FNV-1a and every record SHA-256 after the acknowledged close). Open, the two
 * fd stats, sequential <=511-byte reads, one EOF probe, quiescence checks and
 * the single drain/close are unchanged. */
#include "caller.h"

static const char pin_path[] = "B:/CFPSTYLE.BIN";

static int stopped(fc_caller *c, const fc_ops *ops, void *ctx)
{
    c->stopped = c->stopped || ops->stop_requested(ctx);
    return c->stopped;
}

static int same_identity(const fc_identity *a, const fc_identity *b)
{
    if (a->size != b->size)
        return 0;
    for (unsigned i = 0; i < 8; ++i)
        if (a->token[i] != b->token[i])
            return 0;
    return 1;
}

static fc_result load_source(fc_caller *c, const fc_ops *ops, void *ctx)
{
    if (stopped(c, ops, ctx))
        return FC_STOPPED;
    int rc = ops->identity(ctx, c->fd, &c->before);
    if (!ops->quiescent(ctx))
        return FC_HOLD;
    if (stopped(c, ops, ctx))
        return FC_STOPPED;
    if (rc || (c->before.size != FC_PIN_BYTES && c->before.size != FC_V1_BYTES)) {
        c->reason = 1;
        return FC_REJECTED;
    }
    c->size = c->before.size;

    for (uint32_t off = 0;;) {
        const uint32_t left = c->size - off;
        /* At pinned EOF read one byte into private scratch and require a zero return. */
        const uint32_t request = left ? (left < FC_READ_MAX ? left : FC_READ_MAX) : 1;
        uint8_t *const to = left ? c->dst + off : c->eof_probe;
        c->actual = 0;
        if (stopped(c, ops, ctx))
            return FC_STOPPED;
        rc = ops->read_at(ctx, c->fd, off, to, request, &c->actual);
        if (!ops->quiescent(ctx))
            return FC_HOLD;
        if (stopped(c, ops, ctx))
            return FC_STOPPED;
        if (rc || c->actual != (left ? request : 0)) {
            c->reason = left ? 2 : 3;
            return FC_REJECTED;
        }
        if (!left)
            break;
        off += request;
        c->loaded_bytes = off;
    }

    if (stopped(c, ops, ctx))
        return FC_STOPPED;
    rc = ops->identity(ctx, c->fd, &c->after);
    if (!ops->quiescent(ctx))
        return FC_HOLD;
    if (stopped(c, ops, ctx))
        return FC_STOPPED;
    if (rc || !same_identity(&c->before, &c->after)) {
        c->reason = 4;
        return FC_REJECTED;
    }
    return FC_OK;
}

static fc_result drain(fc_caller *c, const fc_ops *ops, void *ctx, fc_result result)
{
    stopped(c, ops, ctx);
    if (result == FC_HOLD || !ops->quiescent(ctx) ||
        !ops->cleanup_permitted(ctx, c->fd))
        return FC_HOLD;

    c->close_attempted = 1;
    c->descriptor = FC_CLOSE_ATTEMPTED;
    const int rc = ops->close_owned(ctx, c->fd);
    const int retired = ops->quiescent(ctx);
    const int off = stopped(c, ops, ctx);
    if (rc || !retired) {
        c->descriptor = FC_UNKNOWN;
        return FC_HOLD;
    }
    c->descriptor = FC_CLOSED;
    return off ? FC_STOPPED : result;
}

fc_result fc_run(fc_caller *c, const fc_ops *ops, void *ctx)
{
    if (!c || !c->dst || !ops || !ops->open_ro || !ops->identity || !ops->read_at ||
        !ops->close_owned || !ops->stop_requested || !ops->quiescent ||
        !ops->cleanup_permitted)
        return FC_INVALID;
    if (c->state != FC_READY)
        return c->state;

    c->state = FC_RUNNING;
    c->fd = -1;
    if (stopped(c, ops, ctx))
        return c->state = FC_STOPPED;
    if (!ops->quiescent(ctx))
        return c->state = FC_HOLD;
    if (stopped(c, ops, ctx))
        return c->state = FC_STOPPED;

    const fc_open_result opened = ops->open_ro(ctx, pin_path, &c->fd);
    const int idle = ops->quiescent(ctx);
    const int off = stopped(c, ops, ctx);
    if (!idle || (opened == FC_OPENED ? c->fd < 0 :
                  opened != FC_NOT_OPENED || c->fd != -1)) {
        c->descriptor = FC_UNKNOWN;
        return c->state = FC_HOLD;
    }
    if (opened == FC_NOT_OPENED)
        return c->state = off ? FC_STOPPED : FC_REJECTED;

    c->descriptor = FC_OWNED;
    const fc_result result = off ? FC_STOPPED : load_source(c, ops, ctx);
    return c->state = drain(c, ops, ctx, result);
}
