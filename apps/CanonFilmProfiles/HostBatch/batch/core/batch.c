/* SPDX-License-Identifier: GPL-2.0-only */
#include "batch.h"
#include "sha256.h"
#include <string.h>

static uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
           (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static void put32(uint8_t *p, uint32_t value)
{
    for (size_t i = 0; i < 4; ++i)
        p[i] = (uint8_t)(value >> (8 * i));
}

static int zeroes(const uint8_t *p, size_t length)
{
    for (size_t i = 0; i < length; ++i)
        if (p[i])
            return 0;
    return 1;
}

static int lower(int c)
{
    return c >= 'A' && c <= 'Z' ? c + 'a' - 'A' : c;
}

static int folded_equal(const char *a, const char *b)
{
    while (*a && lower(*a) == lower(*b)) {
        ++a;
        ++b;
    }
    return lower(*a) == lower(*b);
}

static int valid_path(const uint8_t *path)
{
    const uint8_t *end = memchr(path, 0, CB_PATH_BYTES);
    if (!end || end == path || !zeroes(end, CB_PATH_BYTES - (size_t)(end - path)))
        return 0;
    const uint8_t *component = path;
    for (const uint8_t *p = path; p <= end; ++p) {
        int c = lower(*p);
        if (c == '/' || c == 0) {
            size_t length = (size_t)(p - component);
            if (!length || (length == 1 && component[0] == '.') ||
                (length == 2 && component[0] == '.' && component[1] == '.'))
                return 0;
            component = p + 1;
        } else if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
                     c == '.' || c == '_' || c == '-')) {
            return 0;
        }
    }
    const char *extension = strrchr((const char *)path, '.');
    return extension && (folded_equal(extension, ".jpg") || folded_equal(extension, ".jpeg"));
}

static int validate_record(const uint8_t *p)
{
    uint32_t amount = le32(p + 168);
    uint32_t cell = le32(p + 172);
    uint32_t bytes = le32(p + 128);
    if (!valid_path(p) || !bytes || bytes > CB_INPUT_MAX || le32(p + 164) != 1 ||
        (amount != 0 && amount != 11 && amount != 16 && amount != 27) ||
        cell < 1 || cell > 3 || le32(p + 180) != CB_OUTPUT_MAX || !zeroes(p + 216, 8))
        return 1;

    static const uint8_t domain[] = "CanonIdleBatch/job/v1";
    CSha256 sha;
    uint8_t id[32];
    Sha256_Init(&sha);
    Sha256_Update(&sha, domain, sizeof domain);
    Sha256_Update(&sha, p, 184);
    Sha256_Final(&sha, id);
    return memcmp(id, p + 184, sizeof id) != 0;
}

static void decode_job(cb_job *job, const uint8_t *p)
{
    memcpy(job->record, p, CB_RECORD_BYTES);
    memcpy(job->source_path, p, CB_PATH_BYTES);
    memcpy(job->source_sha, p + 132, 32);
    memcpy(job->job_id, p + 184, 32);
    job->source_bytes = le32(p + 128);
    job->amount = le32(p + 168);
    job->cell = le32(p + 172);
    job->seed = le32(p + 176);
}

int cb_manifest_view_parse(cb_manifest_view *view, const uint8_t *p, size_t length)
{
    if (!view)
        return 1;
    *view = (cb_manifest_view){0};
    if (!p || length < CB_HEADER_BYTES || memcmp(p, "CBATCH1", 8) ||
        p[8] != 1 || p[9] || p[10] != CB_HEADER_BYTES || p[11] ||
        le32(p + 12) != CB_RECORD_BYTES || le32(p + 20) || !zeroes(p + 56, 8))
        return 1;

    size_t count = le32(p + 16);
    if (!count || count > CB_MAX_JOBS || count > (SIZE_MAX - CB_HEADER_BYTES) / CB_RECORD_BYTES ||
        length != CB_HEADER_BYTES + count * CB_RECORD_BYTES)
        return 1;
    CSha256 sha;
    uint8_t hash[32];
    Sha256_Init(&sha);
    Sha256_Update(&sha, p + CB_HEADER_BYTES, count * CB_RECORD_BYTES);
    Sha256_Final(&sha, hash);
    if (memcmp(hash, p + 24, sizeof hash))
        return 1;

    const uint8_t *records = p + CB_HEADER_BYTES;
    for (size_t i = 0; i < count; ++i) {
        const uint8_t *record = records + i * CB_RECORD_BYTES;
        if (validate_record(record))
            return 1;
        for (size_t j = 0; j < i; ++j) {
            const uint8_t *earlier = records + j * CB_RECORD_BYTES;
            if (folded_equal((const char *)record, (const char *)earlier) ||
                !memcmp(record + 184, earlier + 184, 32))
                return 1;
        }
    }
    *view = (cb_manifest_view){.data = p, .length = length, .count = count};
    return 0;
}

int cb_manifest_view_get(const cb_manifest_view *view, size_t index, cb_job *job)
{
    if (!view || !job || !view->data || view->count > CB_MAX_JOBS ||
        index >= view->count || view->length != CB_HEADER_BYTES + view->count * CB_RECORD_BYTES)
        return 1;
    decode_job(job, view->data + CB_HEADER_BYTES + index * CB_RECORD_BYTES);
    return 0;
}

int cb_manifest_parse(cb_manifest *manifest, const uint8_t *p, size_t length)
{
    if (!manifest)
        return 1;
    manifest->count = 0;
    cb_manifest_view view;
    if (cb_manifest_view_parse(&view, p, length))
        return 1;
    for (size_t i = 0; i < view.count; ++i)
        decode_job(&manifest->jobs[i], view.data + CB_HEADER_BYTES + i * CB_RECORD_BYTES);
    manifest->count = view.count;
    return 0;
}

int cb_receipt_make(uint8_t out[CB_RECEIPT_BYTES], const cb_job *job,
                    uint32_t bytes, const uint8_t sha[32])
{
    if (!out || !job || !sha || !job->amount || !bytes || bytes > CB_OUTPUT_MAX)
        return 1;
    memset(out, 0, CB_RECEIPT_BYTES);
    memcpy(out, "CBRCPT1", 8);
    out[8] = 1;
    out[10] = (uint8_t)CB_RECEIPT_BYTES;
    out[11] = CB_RECEIPT_BYTES >> 8;
    memcpy(out + 16, job->record, CB_RECORD_BYTES);
    put32(out + 240, bytes);
    memcpy(out + 244, sha, 32);
    put32(out + 276, 1);
    return 0;
}

int cb_receipt_parse(const uint8_t in[CB_RECEIPT_BYTES], const cb_job *job,
                     uint32_t *bytes, uint8_t sha[32])
{
    if (!in || !job || !bytes || !sha)
        return 1;
    uint8_t expected[CB_RECEIPT_BYTES];
    uint32_t length = le32(in + 240);
    if (cb_receipt_make(expected, job, length, in + 244) ||
        memcmp(in, expected, sizeof expected))
        return 1;
    *bytes = length;
    memcpy(sha, in + 244, 32);
    return 0;
}

static int valid_batch_ops(const cb_ops *ops)
{
    return ops && ops->run && ops->continuing;
}

static cb_progress initial_progress(size_t count)
{
    return (cb_progress){.total = count, .state = CB_QUEUED, .stage = "queued"};
}

/* Only a fresh transition to ACTIVE returns true. A reentrant poll can
   observe ACTIVE but cannot decode or run a second job. */
static int admit_poll(cb_progress *p, size_t next, const int *cancelled,
                      const cb_ops *ops, void *context)
{
    if (p->state == CB_HOLD || p->state == CB_CANCELLED || p->state == CB_FINISHED ||
        p->state == CB_ACTIVE)
        return 0;
    p->state = CB_ACTIVE;
    /* The continuation callback can latch cancellation while checking readiness. */
    if (*cancelled || !ops->continuing(context) || *cancelled) {
        p->state = CB_CANCELLED;
        return 0;
    }
    if (next == p->total) {
        p->state = CB_FINISHED;
        return 0;
    }

    p->index = next;
    p->stage = "admit";
    p->bytes = 0;
    return 1;
}

static cb_state finish_poll(cb_progress *p, size_t *next, cb_state state)
{
    switch (state) {
    case CB_COMPLETED:
    case CB_SKIPPED_OFF:
    case CB_SKIPPED_VERIFIED:
    case CB_CLEAN_INELIGIBLE:
        ++*next;
        break;
    case CB_CANCELLED:
    case CB_HOLD:
        break;
    default:
        state = CB_HOLD;
        break;
    }
    return p->state = state;
}

int cb_batch_init(cb_batch *batch, const cb_manifest *manifest, const cb_ops *ops, void *context)
{
    if (!batch || batch->initialized || !manifest || !manifest->count ||
        manifest->count > CB_MAX_JOBS || !valid_batch_ops(ops))
        return 1;
    *batch = (cb_batch){.manifest = manifest, .ops = *ops, .context = context,
                        .progress = initial_progress(manifest->count), .initialized = 1};
    return 0;
}

void cb_batch_cancel(cb_batch *batch)
{
    if (batch && batch->initialized)
        batch->cancelled = 1;
}

cb_state cb_batch_poll(cb_batch *batch)
{
    if (!batch || !batch->initialized)
        return CB_HOLD;
    cb_progress *p = &batch->progress;
    if (!admit_poll(p, batch->next, &batch->cancelled, &batch->ops, batch->context))
        return p->state;
    cb_state state = batch->ops.run(batch->context, &batch->manifest->jobs[p->index], p);
    return finish_poll(p, &batch->next, state);
}

int cb_view_batch_init(cb_view_batch *batch, const cb_manifest_view *view,
                       const cb_ops *ops, void *context)
{
    if (!batch || batch->initialized || !view || !view->data || !view->count ||
        view->count > CB_MAX_JOBS ||
        view->length != CB_HEADER_BYTES + view->count * CB_RECORD_BYTES ||
        !valid_batch_ops(ops))
        return 1;
    /* Preserve one owned slot without a full-manifest copy. */
    batch->view = *view;
    batch->ops = *ops;
    batch->context = context;
    batch->progress = initial_progress(view->count);
    batch->next = 0;
    batch->cancelled = 0;
    batch->initialized = 1;
    return 0;
}

void cb_view_batch_cancel(cb_view_batch *batch)
{
    if (batch && batch->initialized)
        batch->cancelled = 1;
}

cb_state cb_view_batch_poll(cb_view_batch *batch)
{
    if (!batch || !batch->initialized)
        return CB_HOLD;
    cb_progress *p = &batch->progress;
    if (!admit_poll(p, batch->next, &batch->cancelled, &batch->ops, batch->context))
        return p->state;
    if (cb_manifest_view_get(&batch->view, p->index, &batch->active_job))
        return finish_poll(p, &batch->next, CB_HOLD);
    cb_state state = batch->ops.run(batch->context, &batch->active_job, p);
    return finish_poll(p, &batch->next, state);
}
