/* SPDX-License-Identifier: GPL-2.0-only */
/* Single-file loader. Copied from the physically run read-only trial caller
 * (film-native-readonly-trial-v1/candidate-v2/caller/caller.h, a494778b) and
 * narrowed: the pinned file is CFPSTYLE.BIN, its bytes are copied into the
 * module's own retained buffer instead of being hashed, and the content check
 * moves to the style job after the acknowledged close. The fc_ops contract,
 * descriptor states and result codes are unchanged, so the unchanged a494
 * backend (backend.c) serves it as before. */
#ifndef CANON_FILE_CALLER_H
#define CANON_FILE_CALLER_H

#include <stdint.h>

#define FC_READ_MAX 511u
#define FC_PIN_BYTES 50420u   /* CFPSTYLE.BIN maximum: v1 (50,356) + 64-byte CFWB block */
#define FC_V1_BYTES 50356u    /* CFPSTYLE.BIN v1: 316-byte configuration + 3 x 16,680-byte records */

typedef struct {
    uint32_t size, token[8];
} fc_identity;

typedef enum {
    FC_OPENED, FC_NOT_OPENED, FC_OPEN_UNKNOWN
} fc_open_result;

typedef enum {
    FC_NONE, FC_OWNED, FC_CLOSE_ATTEMPTED, FC_CLOSED, FC_UNKNOWN
} fc_descriptor;

typedef enum {
    FC_READY, FC_RUNNING, FC_OK, FC_STOPPED, FC_REJECTED, FC_HOLD, FC_INVALID
} fc_result;

/* Callback contract unchanged from a494 (see the original caller.h). */
typedef struct {
    fc_open_result (*open_ro)(void *, const char *, int *);
    int (*identity)(void *, int, fc_identity *);
    int (*read_at)(void *, int, uint32_t, uint8_t *, uint32_t, uint32_t *);
    int (*close_owned)(void *, int);
    int (*stop_requested)(void *);
    int (*quiescent)(void *);
    int (*cleanup_permitted)(void *, int);
} fc_ops;

/* Zero-initialize once, retain exclusively. dst must point at FC_PIN_BYTES of
 * the module's own retained storage. Repeating fc_run makes no further FIO.
 * Accepted sizes: exactly FC_V1_BYTES or FC_PIN_BYTES; size holds the one read.
 * reason: 0, or 1 size differs, 2 short/failed read, 3 EOF probe returned
 * data, 4 identity changed between the two fd stats. */
typedef struct {
    fc_result state;
    fc_descriptor descriptor;
    unsigned stopped, close_attempted;
    int fd;
    uint32_t loaded_bytes, actual, reason, size;
    fc_identity before, after;
    uint8_t *dst;
    uint8_t eof_probe[4];
} fc_caller;

fc_result fc_run(fc_caller *, const fc_ops *, void *);

#endif
