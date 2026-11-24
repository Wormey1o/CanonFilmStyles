/* SPDX-License-Identifier: GPL-2.0-only */
#define _DARWIN_C_SOURCE
#include "batch.h"
#include "codec.h"
#include "quality.h"
#include "read511.h"
#include "sha256.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/statvfs.h>
#include <inttypes.h>
#include <time.h>
#include <unistd.h>

#define OUTPUT_PARENT "/private/tmp"
#define OUTPUT_PREFIX "canon-idle-batch."
#define READ_FLAGS (O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
#define DIR_FLAGS (READ_FLAGS | O_DIRECTORY)
/* Covers new directory, two control files, and their directory entries. */
#define JOB_SPACE_BYTES (CB_OUTPUT_MAX + CB_RECORD_BYTES + CB_RECEIPT_BYTES + 128u * 1024u)
#define NEW_FLAGS (O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC)

typedef enum { IO_OK, IO_FAULT, IO_CANCEL } io_result;

typedef enum {
    PREFLIGHT_SOURCE, PREFLIGHT_RESUME, NAMESPACE, SOURCE, SPACE, RESERVE,
    CODEC, READBACK, RECEIPT, COMMIT, RESUME, PHASE_COUNT
} host_phase;

static const char *const phase_names[PHASE_COUNT] = {
    "preflight-source", "preflight-resume", "namespace", "source-pin", "space", "reserve",
    "codec", "readback", "receipt", "commit", "resume-proof"
};

static const char *const state_names[] = {
    "QUEUED", "ACTIVE", "COMPLETED", "SKIPPED_OFF", "SKIPPED_VERIFIED",
    "CLEAN_INELIGIBLE", "CANCELLED", "HOLD", "FINISHED"
};

typedef struct {
    uint64_t elapsed_ns, read_bytes, write_bytes, hash_bytes;
    int reached;
} phase_metrics;

typedef struct {
    int parent, output, source_root;
    struct stat source_pins[CB_MAX_JOBS];
    phase_metrics metrics[CB_MAX_JOBS][PHASE_COUNT];
    phase_metrics *active;
    uint64_t phase_started, reported_bytes, reported_at;
    size_t active_job, total_jobs;
    host_phase phase;
    int json, stream_closed, job_ran;
    const char *fault;
    char output_name[sizeof OUTPUT_PREFIX + 6];
    int injected, uncertain, cancel_on_read;
    union {
        void *alignment;
        uint8_t bytes[CG_WORKSPACE_BYTES];
    } workspace;
} host;

typedef struct {
    host *h;
    int dir, input, output;
    const cb_job *job;
    cb_progress *progress;
    struct stat output_identity, receipt_identity;
    CSha256 emitted;
    quality_grain grain;
} transaction;

static volatile sig_atomic_t cancelled;

static void stop(int signal_number)
{
    (void)signal_number;
    cancelled = 1;
}

static int continuing(void *opaque)
{
    (void)opaque;
    return !cancelled;
}

static uint64_t monotonic_ns(void)
{
    struct timespec stamp;
    if (clock_gettime(CLOCK_MONOTONIC, &stamp))
        return 0;
    return (uint64_t)stamp.tv_sec * UINT64_C(1000000000) + stamp.tv_nsec;
}

/* Machine events include only fixed tokens and validated root names. */
static void flush_event(host *h)
{
    if (fflush(stdout) || ferror(stdout)) {
        h->stream_closed = 1;
        cancelled = 1;
    }
}

static void report_progress(host *h, int force)
{
    if (!h || !h->json || h->stream_closed || !h->active)
        return;
    const phase_metrics *m = h->active;
    uint64_t bytes = m->read_bytes + m->write_bytes + m->hash_bytes;
    uint64_t now = monotonic_ns();
    if (!force && (bytes == h->reported_bytes ||
                   (bytes - h->reported_bytes < 256 * 1024 &&
                    now - h->reported_at < UINT64_C(100000000))))
        return;
    printf("{\"v\":1,\"type\":\"progress\",\"job\":%zu,\"total\":%zu,\"phase\":\"%s\","
           "\"readBytes\":%" PRIu64 ",\"writeBytes\":%" PRIu64 ",\"hashBytes\":%" PRIu64 "}\n",
           h->active_job + 1, h->total_jobs, phase_names[h->phase],
           m->read_bytes, m->write_bytes, m->hash_bytes);
    h->reported_bytes = bytes;
    h->reported_at = now;
    flush_event(h);
}

static void finish_phase(host *h)
{
    if (h->active) {
        if (h->active->read_bytes + h->active->write_bytes + h->active->hash_bytes != h->reported_bytes)
            report_progress(h, 1);
        uint64_t end = monotonic_ns();
        if (h->phase_started && end >= h->phase_started)
            h->active->elapsed_ns += end - h->phase_started;
        h->active = NULL;
    }
}

static void start_phase(host *h, size_t index, host_phase phase)
{
    finish_phase(h);
    h->active = &h->metrics[index][phase];
    h->active->reached = 1;
    h->phase_started = monotonic_ns();
    h->active_job = index;
    h->phase = phase;
    report_progress(h, 1);
}

static void set_phase(transaction *t, host_phase phase)
{
    t->progress->stage = phase_names[phase];
    start_phase(t->h, t->progress->index, phase);
}

static void print_metrics(const host *h, size_t count)
{
    for (size_t i = 0; i < count; ++i) {
        for (size_t phase = 0; phase < PHASE_COUNT; ++phase) {
            const phase_metrics *m = &h->metrics[i][phase];
            if (m->reached)
                printf("host_phase job=%zu stage=%s elapsed_ns=%" PRIu64
                       " read_bytes=%" PRIu64 " write_bytes=%" PRIu64 " hash_bytes=%" PRIu64 "\n",
                       i + 1, phase_names[phase], m->elapsed_ns,
                       m->read_bytes, m->write_bytes, m->hash_bytes);
        }
    }
}

static int fault(host *h, const char *name)
{
    if (!h->fault || h->injected || strcmp(h->fault, name))
        return 0;
    h->injected = 1;
    return 1;
}

/* POSIX does not permit assuming the descriptor survives an ambiguous close.
   Forget the number before calling close and stop this run on any error. */
static int retire(host *h, int *fd, const char *fault_name)
{
    if (*fd < 0)
        return 0;
    int owned = *fd;
    *fd = -1;
    int rc = close(owned);
    if (rc || (fault_name && fault(h, fault_name))) {
        h->uncertain = 1;
        return 1;
    }
    return 0;
}

static int barrier(host *h, int fd, const char *fault_name)
{
    return (fault_name && fault(h, fault_name)) || fsync(fd) != 0;
}

static int regular(int fd, nlink_t links, struct stat *st)
{
    return fstat(fd, st) || !S_ISREG(st->st_mode) || st->st_nlink != links;
}

static int same_inode(const struct stat *a, const struct stat *b)
{
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}

static int same_identity(const struct stat *a, const struct stat *b)
{
    return same_inode(a, b) && a->st_size == b->st_size &&
           a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec &&
           a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec &&
           a->st_ctimespec.tv_sec == b->st_ctimespec.tv_sec &&
           a->st_ctimespec.tv_nsec == b->st_ctimespec.tv_nsec;
}

/* Traverse every component with a directory FD and O_NOFOLLOW. The source
   manifest is relative and already rejects unsafe components. */
static int anchored_open(host *h, int anchor, const char *path, int flags)
{
    if (!*path || strlen(path) >= PATH_MAX)
        return -1;
    char components[PATH_MAX];
    strcpy(components, path);
    int owned = -1;
    char *name = components;
    for (;;) {
        char *slash = strchr(name, '/');
        if (slash)
            *slash = 0;
        if (!*name || !strcmp(name, ".") || !strcmp(name, ".."))
            break;
        int next = openat(owned < 0 ? anchor : owned, name, slash ? DIR_FLAGS : flags);
        if (retire(h, &owned, NULL) || next < 0) {
            retire(h, &next, NULL);
            return -1;
        }
        if (!slash)
            return next;
        owned = next;
        name = slash + 1;
    }
    retire(h, &owned, NULL);
    return -1;
}

static int posix_read(void *opaque, int fd, uint32_t offset, uint8_t *destination,
                      uint32_t count, uint32_t *actual)
{
    host *h = opaque;
    ssize_t got = pread(fd, destination, count, offset);
    *actual = got < 0 ? 0 : (uint32_t)got;
    if (h && h->active)
        h->active->read_bytes += *actual;
    if (h && h->cancel_on_read && got > 0) {
        h->cancel_on_read = 0;
        cancelled = 1;
    }
    return got < 0 ? YS_READ : YS_OK;
}

static io_result read_checked(host *h, int fd, uint32_t size, uint32_t offset, uint8_t *destination,
                        uint32_t count, uint32_t expected)
{
    yr_ops ops = {.ctx = h, .read_at = posix_read, .continuing = continuing};
    uint32_t actual = 0;
    int rc = nro_read511(&ops, fd, size, offset, destination, count, &actual);
    report_progress(h, 0);
    if (rc == YS_CANCEL)
        return IO_CANCEL;
    return rc || actual != expected ? IO_FAULT : IO_OK;
}

static io_result hash_file(host *h, int fd, const struct stat *identity, nlink_t links,
                     uint32_t length, uint8_t digest[32])
{
    struct stat current;
    if (identity->st_size != length || regular(fd, links, &current) ||
        !same_identity(identity, &current))
        return IO_FAULT;
    uint8_t buffer[8192];
    CSha256 sha;
    Sha256_Init(&sha);
    for (uint32_t offset = 0; offset < length;) {
        uint32_t bytes = length - offset > sizeof buffer ? sizeof buffer : length - offset;
        io_result rc = read_checked(h, fd, length, offset, buffer, bytes, bytes);
        if (rc == IO_CANCEL && (regular(fd, links, &current) ||
                               !same_identity(identity, &current)))
            return IO_FAULT;
        if (rc)
            return rc;
        Sha256_Update(&sha, buffer, bytes);
        if (h->active)
            h->active->hash_bytes += bytes;
        offset += bytes;
        report_progress(h, 0);
    }
    io_result rc = read_checked(h, fd, length, length, buffer, 1, 0);
    if (regular(fd, links, &current) || !same_identity(identity, &current))
        return IO_FAULT;
    if (rc)
        return rc;
    Sha256_Final(&sha, digest);
    return IO_OK;
}

static int exact_file(host *h, int dir, const char *name, nlink_t links,
                      uint8_t *bytes, uint32_t length, struct stat *identity)
{
    int fd = openat(dir, name, READ_FLAGS);
    struct stat after;
    uint8_t extra;
    int bad = fd < 0 || regular(fd, links, identity) ||
              identity->st_size != length ||
              read_checked(h, fd, length, 0, bytes, length, length) ||
              read_checked(h, fd, length, length, &extra, 1, 0) ||
              regular(fd, links, &after) || !same_identity(identity, &after);
    return retire(h, &fd, NULL) || bad;
}

static io_result pin_source(host *h, int fd, const cb_job *job, struct stat *identity)
{
    uint8_t digest[32];
    if (regular(fd, 1, identity) || h->uncertain)
        return IO_FAULT;
    h->cancel_on_read = fault(h, "cancel-source-hash");
    io_result rc = hash_file(h, fd, identity, 1, job->source_bytes, digest);
    h->cancel_on_read = 0;
    if (rc)
        return rc;
    return memcmp(digest, job->source_sha, sizeof digest) ? IO_FAULT : IO_OK;
}

static int source_unchanged(transaction *t, const struct stat *expected)
{
    struct stat descriptor, path_identity;
    int fd = anchored_open(t->h, t->h->source_root, t->job->source_path, READ_FLAGS);
    int bad = fd < 0 || pin_source(t->h, t->input, t->job, &descriptor) ||
              regular(fd, 1, &path_identity) ||
              !same_identity(&descriptor, expected) ||
              !same_identity(&path_identity, expected);
    return retire(t->h, &fd, NULL) || bad;
}

static int verify_output(transaction *t, uint32_t length, const uint8_t sha[32],
                         const struct stat *expected)
{
    int fd = openat(t->dir, "output.jpg", READ_FLAGS);
    struct stat identity;
    uint8_t actual[32];
    int bad = fd < 0 || regular(fd, 1, &identity) ||
              (expected && !same_identity(expected, &identity)) ||
              hash_file(t->h, fd, &identity, 1, length, actual) ||
              memcmp(sha, actual, sizeof actual);
    if (!bad)
        t->output_identity = identity;
    return retire(t->h, &fd, "output-read-close") || bad;
}

static void hex(const uint8_t bytes[32], char string[65])
{
    static const char digits[] = "0123456789abcdef";
    for (size_t i = 0; i < 32; ++i) {
        string[i * 2] = digits[bytes[i] >> 4];
        string[i * 2 + 1] = digits[bytes[i] & 15];
    }
    string[64] = 0;
}

static int namespace_matches(transaction *t, int complete)
{
    static const char *const names[] = {"BEGIN", "output.jpg", "receipt.bin", "COMPLETE"};
    size_t count = complete ? 4 : 3;
    int scan = openat(t->dir, ".", DIR_FLAGS);
    DIR *directory = scan < 0 ? NULL : fdopendir(scan);
    if (!directory) {
        retire(t->h, &scan, NULL);
        return 1;
    }
    unsigned mask = 0;
    int bad = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (!entry) {
            bad = errno != 0;
            break;
        }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
            continue;
        size_t i = 0;
        while (i < count && strcmp(entry->d_name, names[i]))
            ++i;
        if (i == count || (mask & (1u << i))) {
            bad = 1;
            break;
        }
        mask |= 1u << i;
    }
    if (closedir(directory))
        t->h->uncertain = 1;
    return bad || t->h->uncertain || mask != (1u << count) - 1;
}

static int file_named(int dir, const char *name, const struct stat *expected)
{
    struct stat identity;
    return fstatat(dir, name, &identity, AT_SYMLINK_NOFOLLOW) ||
           !S_ISREG(identity.st_mode) || identity.st_nlink != expected->st_nlink ||
           !same_identity(&identity, expected);
}

static int private_directory(int fd, struct stat *identity)
{
    return fstat(fd, identity) || !S_ISDIR(identity->st_mode) ||
           identity->st_uid != geteuid() || (identity->st_mode & 0777) != 0700;
}

static int directory_named(int parent, const char *name, int fd)
{
    struct stat current, anchored, parent_identity;
    return fstat(parent, &parent_identity) || private_directory(fd, &anchored) ||
           parent_identity.st_dev != anchored.st_dev ||
           fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) ||
           !S_ISDIR(current.st_mode) || !same_inode(&current, &anchored);
}

static int verify_complete(transaction *t, const char *name, const struct stat *source)
{
    uint8_t begin[CB_RECORD_BYTES], receipt[CB_RECEIPT_BYTES], complete[CB_RECEIPT_BYTES];
    uint8_t sha[32];
    uint32_t bytes;
    struct stat marker, identity, link_identity;
    if (!t->job->amount || directory_named(t->h->output, name, t->dir) ||
        namespace_matches(t, 1) ||
        exact_file(t->h, t->dir, "BEGIN", 1, begin, sizeof begin, &marker) ||
        memcmp(begin, t->job->record, sizeof begin) ||
        exact_file(t->h, t->dir, "receipt.bin", 2, receipt, sizeof receipt, &identity) ||
        exact_file(t->h, t->dir, "COMPLETE", 2, complete, sizeof complete, &link_identity) ||
        !same_identity(&identity, &link_identity) || memcmp(receipt, complete, sizeof receipt) ||
        cb_receipt_parse(receipt, t->job, &bytes, sha) ||
        verify_output(t, bytes, sha, NULL) || source_unchanged(t, source) ||
        file_named(t->dir, "BEGIN", &marker) ||
        file_named(t->dir, "receipt.bin", &identity) ||
        file_named(t->dir, "COMPLETE", &link_identity) ||
        file_named(t->dir, "output.jpg", &t->output_identity) ||
        barrier(t->h, t->dir, "resume-dir-sync") ||
        barrier(t->h, t->h->output, "resume-parent-sync"))
        return 1;
    t->progress->bytes = bytes;
    return 0;
}

static int write_exact(host *h, int fd, const uint8_t *data, uint32_t bytes,
                       const char *fault_name)
{
    size_t request = fault(h, fault_name) ? bytes / 2 : bytes;
    ssize_t written = write(fd, data, request);
    if (written > 0 && h->active)
        h->active->write_bytes += (uint64_t)written;
    return written != (ssize_t)bytes;
}

static int write_record(transaction *t, const char *leaf, const uint8_t *data,
                        uint32_t length, const char *write_fault, const char *close_fault)
{
    int fd = openat(t->dir, leaf, NEW_FLAGS, 0600);
    int bad = fd < 0 || write_exact(t->h, fd, data, length, write_fault) ||
              barrier(t->h, fd, NULL);
    return retire(t->h, &fd, close_fault) || bad;
}

static int codec_read(void *opaque, uint32_t offset, uint8_t *bytes, uint32_t count)
{
    transaction *t = opaque;
    return read_checked(t->h, t->input, t->job->source_bytes, offset, bytes, count, count);
}

static int codec_write(void *opaque, const uint8_t *bytes, uint32_t count)
{
    transaction *t = opaque;
    if (!continuing(t->h) || count > CB_OUTPUT_MAX - t->progress->bytes ||
        write_exact(t->h, t->output, bytes, count, "output-short-write"))
        return 1;
    Sha256_Update(&t->emitted, bytes, count);
    if (t->h->active)
        t->h->active->hash_bytes += count;
    t->progress->bytes += count;
    report_progress(t->h, 0);
    return 0;
}

static int edit(void *opaque, cg_mcu *block)
{
    transaction *t = opaque;
    if (fault(t->h, "cancel-in-codec"))
        cancelled = 1;
    return !continuing(t->h) || quality_yonly_hook(&t->grain, block);
}

static int available_space(host *h)
{
    struct statvfs volume;
    if (fstatvfs(h->output, &volume) || !volume.f_frsize)
        return 0;
    /* Compare block counts without multiplying filesystem-sized numbers. */
    uint64_t size = volume.f_frsize;
    uint64_t required = JOB_SPACE_BYTES / size + (JOB_SPACE_BYTES % size != 0);
    uint64_t available = fault(h, "low-space") ? required - 1 : volume.f_bavail;
    return available >= required;
}

static io_result produce(transaction *t, const char *name, const struct stat *source)
{
    host *h = t->h;
    set_phase(t, RESERVE);
    if (!continuing(h))
        return h->json ? IO_CANCEL : IO_FAULT;
    if (directory_named(h->parent, h->output_name, h->output) ||
        mkdirat(h->output, name, 0700))
        return IO_FAULT;
    t->dir = openat(h->output, name, DIR_FLAGS);
    if (t->dir < 0 || directory_named(h->output, name, t->dir) ||
        barrier(h, h->output, "job-parent-sync") ||
        write_record(t, "BEGIN", t->job->record, CB_RECORD_BYTES, "begin-short-write", "begin-close") ||
        barrier(h, t->dir, "begin-dir-sync"))
        return IO_FAULT;
    if (fault(h, "crash-after-begin"))
        _exit(86);
    if (fault(h, "cancel-after-begin"))
        cancelled = 1;
    if (!continuing(h))
        return IO_FAULT;

    set_phase(t, CODEC);
    t->output = openat(t->dir, "output.jpg", NEW_FLAGS, 0600);
    if (t->output < 0)
        return IO_FAULT;
    t->grain.amount = (int)t->job->amount;
    t->grain.cell = (int)t->job->cell;
    t->grain.seed = t->job->seed;
    t->grain.gain_q12 = 4096;
    Sha256_Init(&t->emitted);
    cg_options options = {
        .input_limit = t->job->source_bytes, .output_limit = CB_OUTPUT_MAX,
        .header_limit = CG_HEADER_MAX, .ram_limit = 65536,
        .edit = edit, .edit_ctx = t
    };
    cg_result result;
    struct stat written;
    if (cg_run(t->job->source_bytes, codec_read, t, codec_write, t,
               h->workspace.bytes, sizeof h->workspace.bytes, &options, &result) ||
        !t->progress->bytes || result.output_bytes != t->progress->bytes ||
        barrier(h, t->output, "output-sync") || regular(t->output, 1, &written) ||
        retire(h, &t->output, "output-close"))
        return IO_FAULT;
    uint8_t sha[32];
    Sha256_Final(&t->emitted, sha);

    set_phase(t, READBACK);
    if (verify_output(t, result.output_bytes, sha, &written) ||
        source_unchanged(t, source) || retire(h, &t->input, "source-close") ||
        !continuing(h))
        return IO_FAULT;

    set_phase(t, RECEIPT);
    uint8_t expected[CB_RECEIPT_BYTES], observed[CB_RECEIPT_BYTES];
    if (cb_receipt_make(expected, t->job, result.output_bytes, sha) ||
        write_record(t, "receipt.bin", expected, sizeof expected, "receipt-short-write", "receipt-close") ||
        exact_file(h, t->dir, "receipt.bin", 1, observed, sizeof observed, &t->receipt_identity) ||
        memcmp(expected, observed, sizeof expected) || namespace_matches(t, 0) ||
        !continuing(h) || barrier(h, t->dir, "prelink-dir-sync"))
        return IO_FAULT;

    set_phase(t, COMMIT);
    if (!continuing(h) || directory_named(h->output, name, t->dir) ||
        file_named(t->dir, "receipt.bin", &t->receipt_identity) ||
        file_named(t->dir, "output.jpg", &t->output_identity) ||
        fault(h, "commit-link") || linkat(t->dir, "receipt.bin", t->dir, "COMPLETE", 0))
        return IO_FAULT;
    struct stat complete, receipt;
    if (fstatat(t->dir, "COMPLETE", &complete, AT_SYMLINK_NOFOLLOW) ||
        fstatat(t->dir, "receipt.bin", &receipt, AT_SYMLINK_NOFOLLOW) ||
        !S_ISREG(complete.st_mode) || complete.st_nlink != 2 || receipt.st_nlink != 2 ||
        !same_inode(&complete, &t->receipt_identity) || !same_identity(&complete, &receipt) ||
        namespace_matches(t, 1) || barrier(h, t->dir, "postlink-dir-sync"))
        return IO_FAULT;
    return IO_OK;
}

static cb_state run_job(void *opaque, const cb_job *job, cb_progress *progress)
{
    host *h = opaque;
    h->job_ran = 1;
    transaction t = {.h = h, .dir = -1, .input = -1, .output = -1,
                     .job = job, .progress = progress};
    cb_state state = CB_HOLD;
    char name[65];
    hex(job->job_id, name);
    struct stat source;
    set_phase(&t, NAMESPACE);
    t.dir = openat(h->output, name, DIR_FLAGS);
    if (t.dir < 0 && errno != ENOENT)
        goto done;

    set_phase(&t, SOURCE);
    t.input = anchored_open(h, h->source_root, job->source_path, READ_FLAGS);
    if (t.input < 0)
        goto done;
    io_result pin = pin_source(h, t.input, job, &source);
    if (pin == IO_FAULT || !same_identity(&source, &h->source_pins[progress->index]))
        goto done;
    if (pin == IO_CANCEL || !continuing(h)) {
        if (t.dir < 0)
            state = CB_CANCELLED;
        goto done;
    }

    if (t.dir >= 0) {
        set_phase(&t, RESUME);
        if (!verify_complete(&t, name, &source))
            state = CB_SKIPPED_VERIFIED;
    } else if (!job->amount) {
        state = CB_SKIPPED_OFF;
    } else {
        set_phase(&t, SPACE);
        if (!available_space(h))
            goto done;
        if (!continuing(h))
            state = CB_CANCELLED;
        else {
            io_result produced = produce(&t, name, &source);
            if (produced == IO_OK)
                state = CB_COMPLETED;
            else if (produced == IO_CANCEL)
                state = CB_CANCELLED;
        }
    }

done:
    retire(h, &t.output, NULL);
    retire(h, &t.input, NULL);
    retire(h, &t.dir, NULL);
    finish_phase(h);
    return h->uncertain ? CB_HOLD : state;
}

static io_result preflight(host *h, const cb_manifest *manifest)
{
    int fd = openat(h->output, ".", DIR_FLAGS);
    DIR *dir = fd < 0 ? NULL : fdopendir(fd);
    if (!dir) {
        retire(h, &fd, NULL);
        return IO_FAULT;
    }
    int bad = 0, has_existing = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) {
            bad = errno != 0;
            break;
        }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
            continue;
        has_existing = 1;
        size_t i = 0;
        char name[65];
        while (i < manifest->count) {
            hex(manifest->jobs[i].job_id, name);
            if (!strcmp(name, entry->d_name))
                break;
            ++i;
        }
        if (i == manifest->count) {
            bad = 1;
            break;
        }
    }
    if (closedir(dir))
        h->uncertain = 1;
    if (bad || h->uncertain)
        return IO_FAULT;

    for (size_t i = 0; i < manifest->count; ++i) {
        const cb_job *job = &manifest->jobs[i];
        start_phase(h, i, PREFLIGHT_SOURCE);
        int source = anchored_open(h, h->source_root, job->source_path, READ_FLAGS);
        io_result pin = source < 0 ? IO_FAULT : pin_source(h, source, job, &h->source_pins[i]);
        if (retire(h, &source, "preflight-close") || pin == IO_FAULT)
            return IO_FAULT;
        if (pin == IO_CANCEL)
            return has_existing ? IO_FAULT : IO_CANCEL;
        for (size_t j = 0; j < i; ++j)
            if (same_inode(&h->source_pins[i], &h->source_pins[j]))
                return IO_FAULT;

        char name[65];
        hex(job->job_id, name);
        int existing = openat(h->output, name, DIR_FLAGS);
        if (existing < 0) {
            if (errno != ENOENT)
                return IO_FAULT;
            continue;
        }
        start_phase(h, i, PREFLIGHT_RESUME);
        cb_progress progress = {.index = i};
        transaction t = {.h = h, .dir = existing, .input = -1, .output = -1,
                         .job = job, .progress = &progress};
        t.input = anchored_open(h, h->source_root, job->source_path, READ_FLAGS);
        bad = t.input < 0 || verify_complete(&t, name, &h->source_pins[i]);
        retire(h, &t.input, NULL);
        retire(h, &t.dir, NULL);
        if (bad || h->uncertain)
            return IO_FAULT;
    }
    return IO_OK;
}

static int owned_root_name(const char *name)
{
    return strlen(name) == strlen(OUTPUT_PREFIX) + 6 &&
           !strncmp(name, OUTPUT_PREFIX, strlen(OUTPUT_PREFIX)) &&
           strspn(name + strlen(OUTPUT_PREFIX), "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") == 6;
}

static io_result host_setup(host *h, const char *source, const char *restart)
{
    if (*source != '/')
        return IO_FAULT;
    int system_root = open("/", DIR_FLAGS);
    if (system_root < 0)
        return IO_FAULT;
    h->source_root = anchored_open(h, system_root, source + 1, DIR_FLAGS);
    h->parent = anchored_open(h, system_root, &OUTPUT_PARENT[1], DIR_FLAGS);
    if (retire(h, &system_root, NULL) || h->source_root < 0 || h->parent < 0)
        return IO_FAULT;
    struct statfs volume;
    if (fstatfs(h->parent, &volume) || !(volume.f_flags & MNT_LOCAL) ||
        strncmp(volume.f_mntonname, "/Volumes/", 9) == 0 ||
        strcmp(volume.f_fstypename, "apfs"))
        return IO_FAULT;

    char scratch[] = OUTPUT_PARENT "/" OUTPUT_PREFIX "XXXXXX";
    if (!restart) {
#ifdef CB_HOST_MACHINE_TEST_HOOKS
        const char *test_fault = getenv("CB_HOST_TEST_FAULT");
        if (h->json && test_fault && !strcmp(test_fault, "cancel-before-scratch"))
            raise(SIGINT);
#endif
        if (!continuing(h))
            return h->json ? IO_CANCEL : IO_FAULT;
        if (!mkdtemp(scratch))
            return IO_FAULT;
        restart = strrchr(scratch, '/') + 1;
    }
    strcpy(h->output_name, restart);
    if (!h->json) {
        printf("output_root=%s/%s\n", OUTPUT_PARENT, restart);
        fflush(stdout);
    }
    h->output = openat(h->parent, restart, DIR_FLAGS);
    if (h->output < 0 || directory_named(h->parent, restart, h->output) ||
        flock(h->output, LOCK_EX | LOCK_NB) ||
        barrier(h, h->parent, "root-parent-sync"))
        return IO_FAULT;
    if (h->json) {
        printf("{\"v\":1,\"type\":\"root\",\"name\":\"%s\"}\n", restart);
        flush_event(h);
    }
    return IO_OK;
}

static int load_manifest(cb_manifest *manifest, const char *path, const char *expected_sha)
{
    static uint8_t bytes[CB_HEADER_BYTES + CB_MAX_JOBS * CB_RECORD_BYTES + 1];
    int fd = open(path, READ_FLAGS);
    struct stat before, after;
    uint8_t extra;
    int bad = fd < 0 || regular(fd, 1, &before) || before.st_size < CB_HEADER_BYTES ||
              before.st_size >= (off_t)sizeof bytes ||
              read_checked(NULL, fd, (uint32_t)before.st_size, (uint32_t)before.st_size, &extra, 1, 0);
    for (uint32_t off = 0; !bad && off < (uint32_t)before.st_size;) {
        uint32_t left = (uint32_t)before.st_size - off;
        uint32_t count = left > 8192 ? 8192 : left;
        bad = read_checked(NULL, fd, (uint32_t)before.st_size, off, bytes + off, count, count);
        off += count;
    }
    if (!bad && (regular(fd, 1, &after) || !same_identity(&before, &after)))
        bad = 1;
    if (fd >= 0 && close(fd))
        bad = 1;
    if (bad)
        return 1;
    if (expected_sha) {
        CSha256 sha;
        uint8_t digest[32];
        char digest_text[65];
        Sha256_Init(&sha);
        Sha256_Update(&sha, bytes, (size_t)before.st_size);
        Sha256_Final(&sha, digest);
        hex(digest, digest_text);
        if (strcmp(digest_text, expected_sha))
            return 1;
    }
    return cb_manifest_parse(manifest, bytes, (size_t)before.st_size);
}

static void report_result(host *h, const char *state, const char *phase)
{
    if (!h->json || h->stream_closed)
        return;
    printf("{\"v\":1,\"type\":\"result\",\"state\":\"%s\",\"phase\":\"%s\"}\n", state, phase);
    flush_event(h);
}

static void report_job(host *h, const cb_progress *p, cb_state state)
{
    if (!h->json) {
        printf("%zu/%zu %s stage=%s bytes=%u\n", p->index + 1,
               p->total, state_names[state], p->stage, p->bytes);
    } else if (!h->stream_closed && h->job_ran) {
        printf("{\"v\":1,\"type\":\"job\",\"job\":%zu,\"total\":%zu,\"state\":\"%s\","
               "\"phase\":\"%s\",\"bytes\":%u}\n",
               p->index + 1, p->total, state_names[state], p->stage, p->bytes);
        flush_event(h);
    }
}

int main(int argc, char **argv)
{
    static cb_manifest manifest;
    static host h = {.source_root = -1, .output = -1, .parent = -1};
    int inspect = argc == 3 && !strcmp(argv[1], "inspect");
    h.json = argc > 1 && !strcmp(argv[1], "run-json");
    int mandatory = h.json ? 5 : 4;
    int run = (argc == mandatory || argc == mandatory + 1) &&
              (h.json || !strcmp(argv[1], "run"));
    const char *restart = run && argc == mandatory + 1 ? argv[mandatory] : NULL;
    const char *expected_sha = run && h.json ? argv[4] : NULL;
    if ((!inspect && !run) || (!h.json && restart && !owned_root_name(restart))) {
        fputs("usage: batch_host inspect MANIFEST | run MANIFEST ABSOLUTE_SOURCE_ROOT [RESTART] | "
              "run-json MANIFEST ABSOLUTE_SOURCE_ROOT SHA256 [RESTART]\n", stderr);
        return 2;
    }
    signal(SIGINT, stop);
    signal(SIGTERM, stop);
    if (h.json) {
        signal(SIGPIPE, SIG_IGN);
        puts("{\"v\":1,\"type\":\"hello\",\"mode\":\"host-only\"}");
        flush_event(&h);
        if (strlen(expected_sha) != 64 || strspn(expected_sha, "0123456789abcdef") != 64) {
            report_result(&h, "INVALID_MANIFEST", "manifest");
            return 2;
        }
        if (restart && !owned_root_name(restart)) {
            report_result(&h, "HOLD", "setup");
            return 1;
        }
    }
    if (load_manifest(&manifest, argv[2], expected_sha)) {
        if (h.json && cancelled) {
            report_result(&h, "CANCELLED", "manifest");
            return 3;
        }
        fputs("invalid manifest\n", stderr);
        report_result(&h, "INVALID_MANIFEST", "manifest");
        return 2;
    }
    if (inspect) {
        for (size_t i = 0; i < manifest.count; ++i) {
            char name[65];
            hex(manifest.jobs[i].job_id, name);
            printf("%zu %s %s\n", i, name, manifest.jobs[i].source_path);
        }
        return 0;
    }

    if (!h.json)
        h.fault = getenv("CB_HOST_TEST_FAULT");
    h.total_jobs = manifest.count;
    cb_state state = CB_HOLD;
    const char *result_phase = "setup";
    io_result ready = h.json && cancelled ? IO_CANCEL : host_setup(&h, argv[3], restart);
    if (ready == IO_OK) {
        result_phase = "preflight";
        ready = preflight(&h, &manifest);
    }
    finish_phase(&h);
    if (ready == IO_OK) {
        cb_batch batch = {0};
        cb_ops ops = {.run = run_job, .continuing = continuing};
        if (!cb_batch_init(&batch, &manifest, &ops, &h)) {
            do {
                h.job_ran = 0;
                state = cb_batch_poll(&batch);
                result_phase = state == CB_FINISHED ? "finished" :
                               h.job_ran ? batch.progress.stage : "admit";
                if (state != CB_FINISHED)
                    report_job(&h, &batch.progress, state);
            } while (state != CB_FINISHED && state != CB_HOLD && state != CB_CANCELLED);
        }
    } else if (ready == IO_CANCEL && !h.uncertain) {
        state = CB_CANCELLED;
        if (!h.json)
            puts("CANCELLED stage=preflight");
    } else if (!h.json) {
        puts("HOLD stage=preflight");
    }
    if (!h.json)
        print_metrics(&h, manifest.count);
    retire(&h, &h.source_root, NULL);
    retire(&h, &h.parent, NULL);
    retire(&h, &h.output, NULL);
    if (h.uncertain) {
        fputs("HOLD stage=ambiguous-close\n", stderr);
        state = CB_HOLD;
        result_phase = "ambiguous-close";
    }
    report_result(&h, state_names[state], result_phase);
    return state == CB_FINISHED ? 0 : state == CB_CANCELLED ? 3 : 1;
}
