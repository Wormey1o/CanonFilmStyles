/* SPDX-License-Identifier: GPL-2.0-only */
#include "caller.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef enum {
    EXACT, BAD_SIZE, SHORT_READ, EXTRA_EOF, CHANGED, CANCELLED,
    IN_FLIGHT, CLOSE_FAILED
} scenario;

typedef struct {
    fc_caller *caller;
    scenario test;
    uint32_t size, offset;
    unsigned opens, stats, reads, eof_reads, closes;
    int stopped, busy;
} mock_file;

static fc_open_result open_readonly(void *opaque, const char *path, int *descriptor)
{
    mock_file *file = opaque;
    assert(strcmp(path, "B:/CFPSTYLE.BIN") == 0);
    assert(++file->opens == 1);
    *descriptor = 7;
    return FC_OPENED;
}

static int identity(void *opaque, int descriptor, fc_identity *id)
{
    mock_file *file = opaque;
    assert(descriptor == 7);
    assert(++file->stats <= 2);
    id->size = file->size;
    id->token[0] = file->stats == 2 && file->test == CHANGED ? 2 : 1;
    return 0;
}

static uint8_t byte_at(uint32_t offset)
{
    return (uint8_t)(offset * 31u + 19u);
}

static int read_at(void *opaque, int descriptor, uint32_t offset,
                   uint8_t *dst, uint32_t length, uint32_t *actual)
{
    mock_file *file = opaque;
    assert(descriptor == 7 && offset == file->offset);
    assert(length >= 1 && length <= FC_READ_MAX);
    ++file->reads;
    if (offset == file->size) {
        assert(dst == file->caller->eof_probe && length == 1);
        assert(++file->eof_reads == 1);
        *dst = 0;
        *actual = file->test == EXTRA_EOF ? 1 : 0;
        return 0;
    }

    assert(dst == file->caller->dst + offset && length <= file->size - offset);
    *actual = file->test == SHORT_READ && file->reads == 2 ? length - 1 : length;
    for (uint32_t i = 0; i < *actual; ++i)
        dst[i] = byte_at(offset + i);
    file->offset += *actual;
    if (file->reads == 2) {
        file->stopped = file->test == CANCELLED;
        file->busy = file->test == IN_FLIGHT;
    }
    return 0;
}

static int close_owned(void *opaque, int descriptor)
{
    mock_file *file = opaque;
    assert(descriptor == 7 && ++file->closes == 1);
    assert(!file->busy && file->caller->descriptor == FC_CLOSE_ATTEMPTED);
    return file->test == CLOSE_FAILED ? -1 : 0;
}

static int stop_requested(void *opaque) { return ((mock_file *)opaque)->stopped; }
static int quiescent(void *opaque) { return !((mock_file *)opaque)->busy; }

static int cleanup_permitted(void *opaque, int descriptor)
{
    assert(descriptor == 7);
    return quiescent(opaque);
}

static const fc_ops operations = {
    open_readonly, identity, read_at, close_owned,
    stop_requested, quiescent, cleanup_permitted
};

static void check(scenario test, uint32_t size, fc_result result,
                  fc_descriptor descriptor, uint32_t reason, unsigned closes)
{
    uint8_t dst[FC_PIN_BYTES];
    memset(dst, 0xde, sizeof dst);
    fc_caller caller = { .dst = dst };
    mock_file file = { .caller = &caller, .test = test, .size = size };

    assert(fc_run(&caller, &operations, &file) == result);
    assert(caller.descriptor == descriptor && caller.reason == reason);
    assert(file.opens == 1 && file.closes == closes);
    assert(caller.close_attempted == closes);
    if (result == FC_OK) {
        assert(caller.loaded_bytes == size && caller.size == size);
        assert(file.stats == 2 && file.eof_reads == 1);
        for (uint32_t i = 0; i < size; ++i)
            assert(dst[i] == byte_at(i));
        for (uint32_t i = size; i < sizeof dst; ++i)
            assert(dst[i] == 0xde);
    }
    unsigned reads = file.reads;
    assert(fc_run(&caller, &operations, &file) == result);
    assert(file.opens == 1 && file.reads == reads && file.closes == closes);
}

int main(void)
{
    check(EXACT, FC_V1_BYTES, FC_OK, FC_CLOSED, 0, 1);
    check(EXACT, FC_PIN_BYTES, FC_OK, FC_CLOSED, 0, 1);
    check(BAD_SIZE, FC_V1_BYTES - 1, FC_REJECTED, FC_CLOSED, 1, 1);
    check(SHORT_READ, FC_PIN_BYTES, FC_REJECTED, FC_CLOSED, 2, 1);
    check(EXTRA_EOF, FC_PIN_BYTES, FC_REJECTED, FC_CLOSED, 3, 1);
    check(CHANGED, FC_PIN_BYTES, FC_REJECTED, FC_CLOSED, 4, 1);
    check(CANCELLED, FC_PIN_BYTES, FC_STOPPED, FC_CLOSED, 0, 1);
    check(IN_FLIGHT, FC_PIN_BYTES, FC_HOLD, FC_OWNED, 0, 0);
    check(CLOSE_FAILED, FC_PIN_BYTES, FC_HOLD, FC_UNKNOWN, 0, 1);
    puts("PASS Camera Styles v3 read-only caller (9 cases)");
    return 0;
}
