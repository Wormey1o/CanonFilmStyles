/* SPDX-License-Identifier: GPL-2.0-only */
#include "batch.h"
#include "sha256.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static cb_state fail_job(void *context, const cb_job *job, cb_progress *progress)
{
    unsigned *calls = context;
    assert(job->amount == 16);
    assert(progress->state == CB_ACTIVE);
    ++*calls;
    return CB_HOLD;
}

static int continuing(void *context)
{
    (void)context;
    return 1;
}

static void bind_hash(uint8_t *target, const uint8_t *bytes, size_t count)
{
    CSha256 hash;
    Sha256_Init(&hash);
    Sha256_Update(&hash, bytes, count);
    Sha256_Final(&hash, target);
}

typedef struct {
    cb_view_batch *batch;
    size_t calls;
    cb_state result;
} view_fixture;

static int view_continuing(void *opaque)
{
    view_fixture *fixture = opaque;
    assert(cb_view_batch_poll(fixture->batch) == CB_ACTIVE);
    return 1;
}

static cb_state observe_job(void *opaque, const cb_job *job, cb_progress *progress)
{
    view_fixture *fixture = opaque;
    char expected[32];
    snprintf(expected, sizeof expected, "input%02zu.jpg", fixture->calls);
    assert(!strcmp(job->source_path, expected));
    assert(job == &fixture->batch->active_job && progress->index == fixture->calls);
    assert(cb_view_batch_poll(fixture->batch) == CB_ACTIVE);
    assert(!strcmp(job->source_path, expected));
    ++fixture->calls;
    return fixture->result;
}

static void test_view_batch(const cb_manifest_view *view)
{
    cb_ops ops = {.run = observe_job, .continuing = view_continuing};
    cb_view_batch batch = {0};
    view_fixture fixture = {.batch = &batch, .result = CB_COMPLETED};
    assert(!cb_view_batch_init(&batch, view, &ops, &fixture));
    assert(batch.view.data == view->data && !batch.active_job.source_bytes);
    for (size_t i = 0; i < CB_MAX_JOBS; ++i)
        assert(cb_view_batch_poll(&batch) == CB_COMPLETED && fixture.calls == i + 1);
    assert(cb_view_batch_poll(&batch) == CB_FINISHED && fixture.calls == CB_MAX_JOBS);

    cb_view_batch cancel = {0};
    fixture = (view_fixture){.batch = &cancel, .result = CB_COMPLETED};
    assert(!cb_view_batch_init(&cancel, view, &ops, &fixture));
    cb_view_batch_cancel(&cancel);
    assert(cb_view_batch_poll(&cancel) == CB_CANCELLED && !fixture.calls);
    assert(cb_view_batch_init(&cancel, view, &ops, &fixture));
    assert(cb_view_batch_poll(&cancel) == CB_CANCELLED && !cancel.active_job.source_bytes);

    cb_view_batch hold = {0};
    fixture = (view_fixture){.batch = &hold, .result = CB_HOLD};
    assert(!cb_view_batch_init(&hold, view, &ops, &fixture));
    assert(cb_view_batch_poll(&hold) == CB_HOLD && fixture.calls == 1);
    cb_view_batch_cancel(&hold);
    assert(cb_view_batch_init(&hold, view, &ops, &fixture));
    assert(cb_view_batch_poll(&hold) == CB_HOLD && fixture.calls == 1);
    assert(!strcmp(hold.active_job.source_path, "input00.jpg"));

    cb_view_batch settled_cancel = {0};
    fixture = (view_fixture){.batch = &settled_cancel, .result = CB_CANCELLED};
    assert(!cb_view_batch_init(&settled_cancel, view, &ops, &fixture));
    assert(cb_view_batch_poll(&settled_cancel) == CB_CANCELLED);
    assert(cb_view_batch_poll(&settled_cancel) == CB_CANCELLED && fixture.calls == 1);
    assert(!strcmp(settled_cancel.active_job.source_path, "input00.jpg"));
}

static void test_view(const uint8_t *golden)
{
    static uint8_t wire[CB_HEADER_BYTES + CB_MAX_JOBS * CB_RECORD_BYTES];
    memcpy(wire, golden, CB_HEADER_BYTES);
    wire[16] = CB_MAX_JOBS;
    for (size_t i = 0; i < CB_MAX_JOBS; ++i) {
        static const uint8_t domain[] = "CanonIdleBatch/job/v1";
        uint8_t *record = wire + CB_HEADER_BYTES + i * CB_RECORD_BYTES;
        memcpy(record, golden + CB_HEADER_BYTES, CB_RECORD_BYTES);
        memset(record, 0, CB_PATH_BYTES);
        snprintf((char *)record, CB_PATH_BYTES, "input%02zu.jpg", i);
        CSha256 hash;
        Sha256_Init(&hash);
        Sha256_Update(&hash, domain, sizeof domain);
        Sha256_Update(&hash, record, 184);
        Sha256_Final(&hash, record + 184);
    }
    bind_hash(wire + 24, wire + CB_HEADER_BYTES, sizeof wire - CB_HEADER_BYTES);

    cb_manifest_view view = {0};
    cb_job job;
    assert(!cb_manifest_view_parse(&view, wire, sizeof wire));
    assert(view.data == wire && view.length == sizeof wire && view.count == CB_MAX_JOBS);
    assert(!cb_manifest_view_get(&view, 0, &job));
    assert(!strcmp(job.source_path, "input00.jpg"));
    assert(!cb_manifest_view_get(&view, CB_MAX_JOBS - 1, &job));
    assert(!strcmp(job.source_path, "input63.jpg"));
    assert(!memcmp(job.record, wire + sizeof wire - CB_RECORD_BYTES, CB_RECORD_BYTES));
    assert(job.amount == 16 && job.seed == 0x5eed);
    assert(cb_manifest_view_get(&view, CB_MAX_JOBS, &job));
    assert(cb_manifest_view_get(&view, SIZE_MAX, &job));
    test_view_batch(&view);
    assert(cb_manifest_view_parse(&view, golden, CB_HEADER_BYTES + CB_RECORD_BYTES - 1));
    assert(!view.data && !view.length && !view.count);
    assert(cb_manifest_view_get(&view, 0, &job));
    wire[CB_HEADER_BYTES + CB_RECORD_BYTES - 1] = 1;
    bind_hash(wire + 24, wire + CB_HEADER_BYTES, sizeof wire - CB_HEADER_BYTES);
    assert(cb_manifest_view_parse(&view, wire, sizeof wire));
    assert(!view.data && !view.length && !view.count);
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    FILE *f = fopen(argv[1], "rb");
    assert(f);
    uint8_t wire[CB_HEADER_BYTES + CB_RECORD_BYTES];
    assert(fread(wire, 1, sizeof wire, f) == sizeof wire && fgetc(f) == EOF);
    assert(!fclose(f));
    test_view(wire);
    cb_manifest manifest;
    assert(!cb_manifest_parse(&manifest, wire, sizeof wire));
    assert(manifest.count == 1);

    cb_batch batch = {0};
    unsigned calls = 0;
    cb_ops ops = {.run = fail_job, .continuing = continuing};
    assert(!cb_batch_init(&batch, &manifest, &ops, &calls));
    assert(cb_batch_poll(&batch) == CB_HOLD);
    assert(cb_batch_init(&batch, &manifest, &ops, &calls));
    cb_batch_cancel(&batch);
    assert(cb_batch_poll(&batch) == CB_HOLD && calls == 1);

    cb_batch cancelled = {0};
    assert(!cb_batch_init(&cancelled, &manifest, &ops, &calls));
    cb_batch_cancel(&cancelled);
    assert(cb_batch_poll(&cancelled) == CB_CANCELLED);
    assert(cb_batch_init(&cancelled, &manifest, &ops, &calls));
    assert(cb_batch_poll(&cancelled) == CB_CANCELLED && calls == 1);

    uint8_t receipt[CB_RECEIPT_BYTES], digest[32] = {1}, observed[32];
    uint32_t output_bytes = 0;
    assert(cb_receipt_make(receipt, &manifest.jobs[0], 0, digest));
    assert(cb_receipt_make(receipt, &manifest.jobs[0], CB_OUTPUT_MAX + 1, digest));
    assert(!cb_receipt_make(receipt, &manifest.jobs[0], CB_OUTPUT_MAX, digest));
    assert(!cb_receipt_parse(receipt, &manifest.jobs[0], &output_bytes, observed));
    assert(output_bytes == CB_OUTPUT_MAX && observed[0] == 1);
    receipt[319] = 1;
    assert(cb_receipt_parse(receipt, &manifest.jobs[0], &output_bytes, observed));
    puts("core: sticky HOLD, clean cancellation, init-once, receipt bounds, zero-copy view and compact controller passed");
}
