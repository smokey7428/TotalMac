/*
 * tmac_archive.c — implementation of the libarchive shim.
 *
 * libarchive's own headers are not part of the macOS SDK anymore, so the
 * handful of symbols we use are declared here with signatures that match the
 * public ABI (libarchive keeps its ABI stable; the constants below are copied
 * verbatim from archive.h / archive_entry.h).
 */
#include "include/tmac_archive.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

/* ------------------------------------------------------------------ */
/* libarchive declarations                                             */
/* ------------------------------------------------------------------ */

struct archive;
struct archive_entry;

#define ARCHIVE_EOF     1
#define ARCHIVE_OK      0
#define ARCHIVE_RETRY   (-10)
#define ARCHIVE_WARN    (-20)
#define ARCHIVE_FAILED  (-25)
#define ARCHIVE_FATAL   (-30)

#define ARCHIVE_EXTRACT_OWNER          (0x0001)
#define ARCHIVE_EXTRACT_PERM           (0x0002)
#define ARCHIVE_EXTRACT_TIME           (0x0004)
#define ARCHIVE_EXTRACT_NO_OVERWRITE   (0x0008)
#define ARCHIVE_EXTRACT_UNLINK         (0x0010)
#define ARCHIVE_EXTRACT_ACL            (0x0020)
#define ARCHIVE_EXTRACT_FFLAGS         (0x0040)
#define ARCHIVE_EXTRACT_XATTR          (0x0080)
#define ARCHIVE_EXTRACT_SECURE_SYMLINKS (0x0100)
#define ARCHIVE_EXTRACT_SECURE_NODOTDOT (0x0200)
#define ARCHIVE_EXTRACT_NO_AUTODIR     (0x0400)
#define ARCHIVE_EXTRACT_MAC_METADATA   (0x2000)

extern struct archive *archive_read_new(void);
extern int archive_read_support_filter_all(struct archive *);
extern int archive_read_support_format_all(struct archive *);
extern int archive_read_open_filename(struct archive *, const char *, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern ssize_t archive_read_data(struct archive *, void *, size_t);
extern int archive_read_close(struct archive *);
extern int archive_read_free(struct archive *);
extern int archive_read_has_encrypted_entries(struct archive *);
extern const char *archive_read_format_name(struct archive *);
extern const char *archive_error_string(struct archive *);
extern const char *archive_format_name(struct archive *);

extern struct archive *archive_write_new(void);
extern int archive_write_set_format_zip(struct archive *);
extern int archive_write_set_format_pax_restricted(struct archive *);
extern int archive_write_add_filter_gzip(struct archive *);
extern int archive_write_add_filter_none(struct archive *);
extern int archive_write_set_format_option(struct archive *, const char *, const char *, const char *);
extern int archive_write_set_filter_option(struct archive *, const char *, const char *, const char *);
extern int archive_write_open_filename(struct archive *, const char *);
extern int archive_write_header(struct archive *, struct archive_entry *);
extern ssize_t archive_write_data(struct archive *, const void *, size_t);
extern int archive_write_finish_entry(struct archive *);
extern int archive_write_close(struct archive *);
extern int archive_write_free(struct archive *);

extern struct archive *archive_write_disk_new(void);
extern int archive_write_disk_set_options(struct archive *, int);

extern struct archive_entry *archive_entry_new(void);
extern void archive_entry_free(struct archive_entry *);
extern const char *archive_entry_pathname(struct archive_entry *);
extern int64_t archive_entry_size(struct archive_entry *);
extern int archive_entry_size_is_set(struct archive_entry *);
extern int64_t archive_entry_mtime(struct archive_entry *);
extern unsigned int archive_entry_filetype(struct archive_entry *);
extern unsigned int archive_entry_perm(struct archive_entry *);
extern const char *archive_entry_symlink(struct archive_entry *);
extern const char *archive_entry_hardlink(struct archive_entry *);
extern int archive_entry_is_encrypted(struct archive_entry *);
extern void archive_entry_set_pathname(struct archive_entry *, const char *);
extern void archive_entry_set_size(struct archive_entry *, int64_t);
extern void archive_entry_set_filetype(struct archive_entry *, unsigned int);
extern void archive_entry_set_perm(struct archive_entry *, mode_t);
extern void archive_entry_set_mtime(struct archive_entry *, int64_t, long);
extern void archive_entry_set_symlink(struct archive_entry *, const char *);

extern const char *archive_version_string(void);

/* ------------------------------------------------------------------ */
/* helpers                                                             */
/* ------------------------------------------------------------------ */

static char tmac_last_error[512];

static void set_error(char *err, size_t errlen, const char *message)
{
    if (message == NULL) message = "unknown libarchive error";
    snprintf(tmac_last_error, sizeof(tmac_last_error), "%s", message);
    if (err != NULL && errlen > 0) {
        snprintf(err, errlen, "%s", message);
    }
}

const char *tmac_error(void) { return tmac_last_error; }

const char *tmac_version(void) { return archive_version_string(); }

/* The AE_IF* constants are multi-bit fields, so they must be compared after
 * masking the type bits out (a plain "&" would make IREG match IFLNK). */
int tmac_is_dir(uint32_t filetype)     { return (filetype & 0170000u) == TMAC_IFDIR; }
int tmac_is_regular(uint32_t filetype) { return (filetype & 0170000u) == TMAC_IFREG; }
int tmac_is_symlink(uint32_t filetype) { return (filetype & 0170000u) == TMAC_IFLNK; }

/* ------------------------------------------------------------------ */
/* reading                                                             */
/* ------------------------------------------------------------------ */

void *tmac_read_open(const char *path, char *err, size_t errlen)
{
    if (path == NULL || path[0] == '\0') {
        set_error(err, errlen, "empty path");
        return NULL;
    }

    struct archive *a = archive_read_new();
    if (a == NULL) {
        set_error(err, errlen, "cannot allocate archive reader");
        return NULL;
    }

    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);

    int r = archive_read_open_filename(a, path, 64 * 1024);
    if (r != ARCHIVE_OK) {
        set_error(err, errlen, archive_error_string(a));
        archive_read_free(a);
        return NULL;
    }
    return a;
}

int tmac_read_next(void *handle, tmac_entry_info *info, char *err, size_t errlen)
{
    struct archive *a = (struct archive *)handle;
    if (a == NULL || info == NULL) return -1;

    memset(info, 0, sizeof(*info));

    struct archive_entry *entry = NULL;
    int r = archive_read_next_header(a, &entry);
    if (r == ARCHIVE_EOF) return 0;
    if (r < ARCHIVE_WARN) {
        set_error(err, errlen, archive_error_string(a));
        return -1;
    }
    if (entry == NULL) return 0;

    unsigned int filetype = archive_entry_filetype(entry);

    info->pathname = archive_entry_pathname(entry);
    info->symlink = archive_entry_symlink(entry);
    info->hardlink = archive_entry_hardlink(entry);
    info->filetype = filetype & 0170000u;
    info->perm = archive_entry_perm(entry) & 07777u;
    info->mtime = archive_entry_mtime(entry);
    info->is_encrypted = archive_entry_is_encrypted(entry);

    if (tmac_is_regular(info->filetype) && archive_entry_size_is_set(entry)) {
        info->size = archive_entry_size(entry);
    } else {
        info->size = 0;
    }

    if (info->pathname == NULL) info->pathname = "";
    return 1;
}

int64_t tmac_read_data(void *handle, void *buf, size_t len)
{
    struct archive *a = (struct archive *)handle;
    if (a == NULL) return -1;
    ssize_t r = archive_read_data(a, buf, len);
    if (r <= 0) {
        const char *e = archive_error_string(a);
        snprintf(tmac_last_error, sizeof(tmac_last_error), "read=%ld err=%s",
                 (long)r, (e != NULL) ? e : "(none)");
    }
    return (int64_t)r;
}

int tmac_read_close(void *handle)
{
    struct archive *a = (struct archive *)handle;
    if (a == NULL) return ARCHIVE_OK;
    archive_read_close(a);
    return archive_read_free(a);
}

const char *tmac_format_name(void *handle)
{
    struct archive *a = (struct archive *)handle;
    if (a == NULL) return "";
    const char *name = archive_format_name(a);
    return (name != NULL) ? name : "";
}

/* ------------------------------------------------------------------ */
/* extraction                                                          */
/* ------------------------------------------------------------------ */

void *tmac_disk_new(uint64_t extract_flags, char *err, size_t errlen)
{
    struct archive *d = archive_write_disk_new();
    if (d == NULL) {
        set_error(err, errlen, "cannot allocate disk writer");
        return NULL;
    }
    archive_write_disk_set_options(d, (int)(extract_flags | ARCHIVE_EXTRACT_PERM |
                                           ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_ACL |
                                           ARCHIVE_EXTRACT_XATTR));
    return d;
}

int tmac_disk_write_entry(void *handle, const char *dest_path, uint32_t filetype,
                          uint32_t perm, int64_t size, int64_t mtime,
                          const char *symlink, char *err, size_t errlen)
{
    struct archive *d = (struct archive *)handle;
    if (d == NULL || dest_path == NULL) return ARCHIVE_FATAL;

    struct archive_entry *e = archive_entry_new();
    if (e == NULL) {
        set_error(err, errlen, "cannot allocate archive entry");
        return ARCHIVE_FATAL;
    }

    archive_entry_set_pathname(e, dest_path);
    archive_entry_set_filetype(e, filetype);
    archive_entry_set_perm(e, (mode_t)(perm & 07777u));
    archive_entry_set_mtime(e, mtime, 0);
    if (tmac_is_regular(filetype)) {
        archive_entry_set_size(e, size);
    } else {
        archive_entry_set_size(e, 0);
    }
    if (symlink != NULL && symlink[0] != '\0') {
        archive_entry_set_symlink(e, symlink);
    }

    /* The disk writer shares archive_write_header with the archive writer. */
    int r = archive_write_header(d, e);
    archive_entry_free(e);

    if (r < ARCHIVE_WARN) {
        set_error(err, errlen, archive_error_string(d));
    }
    return r;
}

int tmac_disk_write_data(void *handle, const void *buf, size_t len)
{
    struct archive *d = (struct archive *)handle;
    if (d == NULL) return ARCHIVE_FATAL;
    ssize_t r = archive_write_data(d, buf, len);
    if (r < 0) return ARCHIVE_FAILED;
    return ARCHIVE_OK;
}

int tmac_disk_finish_entry(void *handle, char *err, size_t errlen)
{
    struct archive *d = (struct archive *)handle;
    if (d == NULL) return ARCHIVE_FATAL;
    int r = archive_write_finish_entry(d);
    if (r < ARCHIVE_WARN) set_error(err, errlen, archive_error_string(d));
    return r;
}

int tmac_disk_close(void *handle, char *err, size_t errlen)
{
    struct archive *d = (struct archive *)handle;
    if (d == NULL) return ARCHIVE_OK;
    int r = archive_write_close(d);
    if (r < ARCHIVE_WARN) set_error(err, errlen, archive_error_string(d));
    archive_write_free(d);
    return r;
}

/* ------------------------------------------------------------------ */
/* creating archives                                                   */
/* ------------------------------------------------------------------ */

void *tmac_write_new(const char *dest_path, const char *format, int level,
                     char *err, size_t errlen)
{
    if (dest_path == NULL || format == NULL) {
        set_error(err, errlen, "invalid arguments");
        return NULL;
    }

    struct archive *w = archive_write_new();
    if (w == NULL) {
        set_error(err, errlen, "cannot allocate archive writer");
        return NULL;
    }

    char buffer[16];
    if (level >= 0 && level <= 9) {
        snprintf(buffer, sizeof(buffer), "%d", level);
    } else {
        buffer[0] = '\0';
    }

    int ok = 0;
    if (strcmp(format, "zip") == 0) {
        archive_write_set_format_zip(w);
        if (buffer[0] != '\0') {
            archive_write_set_format_option(w, "zip", "compression-level", buffer);
        }
        ok = 1;
    } else if (strcmp(format, "tar") == 0) {
        archive_write_set_format_pax_restricted(w);
        archive_write_add_filter_none(w);
        ok = 1;
    } else if (strcmp(format, "tar.gz") == 0) {
        archive_write_set_format_pax_restricted(w);
        archive_write_add_filter_gzip(w);
        if (buffer[0] != '\0') {
            archive_write_set_filter_option(w, "gzip", "compression-level", buffer);
        }
        ok = 1;
    }

    if (!ok) {
        set_error(err, errlen, "unsupported archive format");
        archive_write_free(w);
        return NULL;
    }

    /* A seekable output lets the zip writer fix up sizes afterwards. */
    int r = archive_write_open_filename(w, dest_path);
    if (r != ARCHIVE_OK) {
        set_error(err, errlen, archive_error_string(w));
        archive_write_free(w);
        return NULL;
    }
    return w;
}

int tmac_write_entry(void *handle, const char *name, uint32_t filetype, uint32_t perm,
                     int64_t size, int64_t mtime, const char *symlink,
                     char *err, size_t errlen)
{
    struct archive *w = (struct archive *)handle;
    if (w == NULL || name == NULL) return ARCHIVE_FATAL;

    struct archive_entry *e = archive_entry_new();
    if (e == NULL) {
        set_error(err, errlen, "cannot allocate archive entry");
        return ARCHIVE_FATAL;
    }

    archive_entry_set_pathname(e, name);
    archive_entry_set_filetype(e, filetype);
    archive_entry_set_perm(e, (mode_t)(perm & 07777u));
    archive_entry_set_mtime(e, mtime, 0);
    if (tmac_is_regular(filetype)) {
        archive_entry_set_size(e, size);
    } else {
        archive_entry_set_size(e, 0);
    }
    if (symlink != NULL && symlink[0] != '\0') {
        archive_entry_set_symlink(e, symlink);
    }

    int r = archive_write_header(w, e);
    archive_entry_free(e);

    if (r < ARCHIVE_WARN) {
        set_error(err, errlen, archive_error_string(w));
    }
    return r;
}

int tmac_write_data(void *handle, const void *buf, size_t len)
{
    struct archive *w = (struct archive *)handle;
    if (w == NULL) return ARCHIVE_FATAL;
    ssize_t r = archive_write_data(w, buf, len);
    if (r < 0) return ARCHIVE_FAILED;
    return ARCHIVE_OK;
}

int tmac_write_finish_entry(void *handle, char *err, size_t errlen)
{
    struct archive *w = (struct archive *)handle;
    if (w == NULL) return ARCHIVE_FATAL;
    int r = archive_write_finish_entry(w);
    if (r < ARCHIVE_WARN) set_error(err, errlen, archive_error_string(w));
    return r;
}

int tmac_write_close(void *handle, char *err, size_t errlen)
{
    struct archive *w = (struct archive *)handle;
    if (w == NULL) return ARCHIVE_OK;
    int r = archive_write_close(w);
    if (r < ARCHIVE_WARN) set_error(err, errlen, archive_error_string(w));
    int r2 = archive_write_free(w);
    return (r < ARCHIVE_WARN) ? r : r2;
}

void tmac_write_abort(void *handle)
{
    struct archive *w = (struct archive *)handle;
    if (w != NULL) archive_write_free(w);
}
