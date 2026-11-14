// The C side of the posix package: execvp over a packed argv.
#include <errno.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Replaces the process with argv[0], found on PATH. The argv is argc strings, each ended by
// a NUL, filling buf[0..len) exactly. Returns only on failure, with errno.
int32_t posix_exec(const uint8_t *buf, size_t len, int32_t argc) {
  if (argc < 1) return EINVAL;
  char **argv = calloc((size_t)argc + 1, sizeof *argv);
  if (!argv) return ENOMEM;
  size_t off = 0;
  for (int32_t i = 0; i < argc; i++) {
    const uint8_t *end = off < len ? memchr(buf + off, 0, len - off) : NULL;
    if (!end) {
      free(argv);
      return EINVAL;
    }
    argv[i] = (char *)(buf + off);
    off = (size_t)(end - buf) + 1;
  }
  if (off != len) {
    free(argv);
    return EINVAL;
  }
  // What exec would lose or leak: the runtime prints through C's stdout, whose buffer dies
  // with this image, and it ignores SIGPIPE, which the new program would inherit ignored.
  fflush(NULL);
  signal(SIGPIPE, SIG_DFL);
  execvp(argv[0], argv);
  int32_t e = errno;
  signal(SIGPIPE, SIG_IGN);
  free(argv);
  return e;
}
