/*
 * zdtd.h - C ABI for the embeddable zdtd simulation library (libzdtd).
 *
 * ABI version: 1 (ZDTD_ABI_VERSION). The value returned by
 * zdtd_abi_version() must equal this macro; a mismatch means the header and
 * the archive were built from different sources and the caller must stop.
 *
 * Scope:
 *   A world is the zdtd ECS simulation. Networking, block storage,
 *   persistence and plugins belong to the server executable and are not part
 *   of this ABI. This slice exposes only lifecycle, one simulation tick and
 *   the last error text; state accessors arrive in a later ABI version.
 *
 * Ownership:
 *   - zdtd_create() returns a handle owned by the caller. The caller must
 *     destroy it exactly once with zdtd_destroy(). A NULL handle may be
 *     passed to zdtd_destroy(); it is ignored.
 *   - No pointer other than the opaque handle refers to library memory.
 *     Strings are copied into caller buffers.
 *   - Worlds are independent: separate handles share no simulation state.
 *   - A handle must not be used by two threads at once, and must not be used
 *     after zdtd_destroy().
 *   - Error text is per thread: zdtd_last_error() reports the most recent
 *     failure from a libzdtd call on the calling thread. A successful call
 *     clears it.
 *
 * Status codes (zdtd_tick):
 *   ZDTD_OK                   0  the tick ran
 *   ZDTD_ERR_INVALID_ARGUMENT 1  null world, or a delta that is not finite,
 *                                not positive, or greater than one second;
 *                                the world was not advanced and error text
 *                                was set
 *
 * zdtd_last_error() returns the full message length excluding the NUL
 * terminator, and writes at most length-1 characters plus a NUL. A return
 * value of 0 means there is no error text. With a NULL buffer or length == 0
 * nothing is written and the required length is returned. A buffer of 256
 * bytes fits every message this version produces.
 */

#ifndef ZDTD_H
#define ZDTD_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ZDTD_ABI_VERSION 1u

#define ZDTD_OK 0
#define ZDTD_ERR_INVALID_ARGUMENT 1

typedef struct zdtd_world zdtd_world;

uint32_t zdtd_abi_version(void);

zdtd_world *zdtd_create(void);
void zdtd_destroy(zdtd_world *world);

int32_t zdtd_tick(zdtd_world *world, float delta_seconds);

size_t zdtd_last_error(char *buffer, size_t length);

#ifdef __cplusplus
}
#endif

#endif /* ZDTD_H */
