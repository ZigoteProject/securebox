// The C side of the posix package: execvp over a packed argv, realpath, and the passwd entry.
#include <errno.h>
#include <limits.h>
#include <pwd.h>
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

// The path with every symbolic link, "." and ".." resolved, or "" when it doesn't exist.
// The text is valid until the next call.
const char *posix_realpath(const char *path) {
  static char resolved[PATH_MAX];
  return realpath(path, resolved) ? resolved : "";
}

// The user's name and home directory as the passwd database has them, or "" when it has
// no entry for the uid (a static binary reads /etc/passwd only).
const char *posix_user_name(void) {
  struct passwd *pw = getpwuid(getuid());
  return pw && pw->pw_name ? pw->pw_name : "";
}

const char *posix_user_home(void) {
  struct passwd *pw = getpwuid(getuid());
  return pw && pw->pw_dir ? pw->pw_dir : "";
}

// Whether the path is a socket (after following symbolic links).
#include <sys/stat.h>
int32_t posix_is_socket(const char *path) {
  struct stat st;
  return stat(path, &st) == 0 && S_ISSOCK(st.st_mode);
}
