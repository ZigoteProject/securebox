// The C side of the posix package: execvp over a packed argv, realpath, the passwd entry,
// and files created and removed without following a symbolic link.
#include <errno.h>
#include <fcntl.h>
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

// What is at the path itself, a symbolic link not followed: 0 nothing, 1 a regular file,
// 2 anything else (a link, dangling or not, a directory, a socket).
int32_t posix_entry(const char *path) {
  struct stat st;
  if (lstat(path, &st) != 0) return 0;
  return S_ISREG(st.st_mode) ? 1 : 2;
}

// Creates the file with buf[0..len) in it and exactly these permission bits. Fails with
// EEXIST when anything is at the path: O_EXCL does not follow a link there, dangling or
// not. Returns 0, or errno with nothing left at the path.
int32_t posix_create_file(const char *path, const uint8_t *buf, size_t len, uint32_t mode) {
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, (mode_t)mode);
  if (fd < 0) return errno;
  int32_t e = 0;
  size_t off = 0;
  while (off < len) {
    ssize_t n = write(fd, buf + off, len - off);
    if (n < 0) {
      if (errno == EINTR) continue;
      e = errno;
      break;
    }
    off += (size_t)n;
  }
  // the bits asked for, whatever the umask took at open
  if (e == 0 && fchmod(fd, (mode_t)mode) != 0) e = errno;
  if (close(fd) != 0 && e == 0) e = errno;
  if (e != 0) unlink(path);
  return e;
}
