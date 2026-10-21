/*
 * tmac_archive.h — a small, self contained wrapper over the libarchive that
 * ships with macOS (/usr/lib/libarchive.2.dylib).
 *
 * Only the entry points TotalMac needs are declared, so the project does not
 * depend on libarchive's headers being present in the SDK.
 */
#ifndef TMAC_ARCHIVE_H
#define TMAC_ARCHIVE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Entry type bits (AE_IF* from archive_entry.h). */
#define TMAC_IFREG  ((uint32_t)0100000)
#define TMAC_IFLNK  ((uint32_t)0120000)
#define TMAC_IFDIR  ((uint32_t)0040000)

typedef struct {
    const char *pathname;   /* valid until the next tmac_read_next call      */
    const char *symlink;    /* link target, or NULL                          */
    const char *hardlink;   /* hard link target, or NULL                     */
    int64_t size;
    int64_t mtime;
    uint32_t filetype;      /* TMAC_IF*                                      */
    uint32_t perm;          /* permission bits (no type bits)                */
    int is_encrypted;
} tmac_entry_info;

/* -------- reading -------- */

/* Returns a handle, or NULL (err filled) on failure. */
void *tmac_read_open(const char *path, char *err, size_t errlen);

/* 1 = filled info, 0 = end of archive, -1 = error. */
int tmac_read_next(void *a, tmac_entry_info *info, char *err, size_t errlen);

/* Bytes copied into buf; 0 at the end of the entry; -1 on error. */
int64_t tmac_read_data(void *a, void *buf, size_t len);

/* Frees the handle. */
int tmac_read_close(void *a);

/* -------- writing to disk (extraction) -------- */

void *tmac_disk_new(uint64_t extract_flags, char *err, size_t errlen);

/* Creates one filesystem entry at dest_path. Regular files are followed by
 * tmac_disk_write_data calls plus tmac_disk_finish_entry. */
int tmac_disk_write_entry(void *d, const char *dest_path, uint32_t filetype, uint32_t perm,
                          int64_t size, int64_t mtime, const char *symlink,
                          char *err, size_t errlen);

int tmac_disk_write_data(void *d, const void *buf, size_t len);
int tmac_disk_finish_entry(void *d, char *err, size_t errlen);

/* Closes and frees the handle. */
int tmac_disk_close(void *d, char *err, size_t errlen);

/* -------- creating archives -------- */

/* format: "zip", "tar", "tar.gz", "tar.bz2", "tar.xz". level: 0-9. */
void *tmac_write_new(const char *dest_path, const char *format, int level,
                     char *err, size_t errlen);

int tmac_write_entry(void *w, const char *name, uint32_t filetype, uint32_t perm,
                     int64_t size, int64_t mtime, const char *symlink,
                     char *err, size_t errlen);

int tmac_write_data(void *w, const void *buf, size_t len);
int tmac_write_finish_entry(void *w, char *err, size_t errlen);

/* Closes and frees the handle (1 on success). */
int tmac_write_close(void *w, char *err, size_t errlen);

/* Frees an unfinished writer and removes the partial file. */
void tmac_write_abort(void *w);

/* -------- helpers -------- */

int tmac_is_dir(uint32_t filetype);
int tmac_is_regular(uint32_t filetype);
int tmac_is_symlink(uint32_t filetype);

const char *tmac_version(void);
const char *tmac_error(void);

/* Detected container format of an open reader, e.g. "ZIP 2.0 (deflation)". */
const char *tmac_format_name(void *handle);

#ifdef __cplusplus
}
#endif

#endif /* TMAC_ARCHIVE_H */
