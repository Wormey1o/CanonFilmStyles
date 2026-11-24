/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef CANON_IDLE_BATCH_H
#define CANON_IDLE_BATCH_H
#include <stddef.h>
#include <stdint.h>
#define CB_MAX_JOBS 64u
#define CB_HEADER_BYTES 64u
#define CB_RECORD_BYTES 224u
#define CB_RECEIPT_BYTES 320u
#define CB_PATH_BYTES 128u
#define CB_INPUT_MAX (32u * 1024u * 1024u)
#define CB_OUTPUT_MAX (8u * 1024u * 1024u)
typedef struct {
    uint8_t record[CB_RECORD_BYTES];
    char source_path[CB_PATH_BYTES];
    uint32_t source_bytes, amount, cell, seed;
    uint8_t source_sha[32], job_id[32];
} cb_job;
typedef struct {
    size_t count;
    cb_job jobs[CB_MAX_JOBS];
} cb_manifest;
/* The caller retains immutable wire bytes for the full lifetime of a valid
   view. The wire, result view and decoded job storage must be disjoint. */
typedef struct {
    const uint8_t *data;
    size_t length, count;
} cb_manifest_view;
int cb_manifest_view_parse(cb_manifest_view *, const uint8_t *, size_t);
int cb_manifest_view_get(const cb_manifest_view *, size_t index, cb_job *);
int cb_manifest_parse(cb_manifest *, const uint8_t *, size_t);
int cb_receipt_make(uint8_t [CB_RECEIPT_BYTES], const cb_job *,
                    uint32_t, const uint8_t [32]);
int cb_receipt_parse(const uint8_t [CB_RECEIPT_BYTES], const cb_job *,
                     uint32_t *, uint8_t [32]);
typedef enum {
    CB_QUEUED, CB_ACTIVE, CB_COMPLETED, CB_SKIPPED_OFF, CB_SKIPPED_VERIFIED,
    CB_CLEAN_INELIGIBLE, CB_CANCELLED, CB_HOLD, CB_FINISHED
} cb_state;
typedef struct {
    size_t index, total;
    cb_state state;
    const char *stage;
    uint32_t bytes;
} cb_progress;
typedef struct {
    /* Only the exclusive owner drives the controller. Backends finish the
       operation or return HOLD without claiming uncertain resources retired. */
    cb_state (*run)(void *, const cb_job *, cb_progress *);
    int (*continuing)(void *);
} cb_ops;
typedef struct {
    const cb_manifest *manifest;
    cb_ops ops;
    void *context;
    cb_progress progress;
    size_t next;
    int cancelled, initialized;
} cb_batch;
/* Initialize a zeroed controller once, with a successfully parsed manifest.
   The caller retains the immutable manifest through the entire run. */
int cb_batch_init(cb_batch *, const cb_manifest *, const cb_ops *, void *);
void cb_batch_cancel(cb_batch *);
cb_state cb_batch_poll(cb_batch *);
/* Compact controller. The validated view's immutable bytes must survive the
   entire controller lifetime, including any backend HOLD. active_job is owned
   by the controller and stays stable during callbacks and terminal HOLD. */
typedef struct {
    cb_manifest_view view;
    cb_job active_job;
    cb_ops ops;
    void *context;
    cb_progress progress;
    size_t next;
    int cancelled, initialized;
} cb_view_batch;
/* Initialize a zeroed controller once from a successfully parsed view. */
int cb_view_batch_init(cb_view_batch *, const cb_manifest_view *, const cb_ops *, void *);
void cb_view_batch_cancel(cb_view_batch *);
cb_state cb_view_batch_poll(cb_view_batch *);
#endif
