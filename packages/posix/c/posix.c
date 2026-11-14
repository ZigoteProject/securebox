// The C side of the posix package: execvp over a packed argv, realpath, the passwd entry,
// and files created and removed without following a symbolic link.
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

// An argv from its packed form: argc strings, each ended by a NUL, filling buf[0..len)
// exactly. NULL with errno set when it is not that; the caller frees it.
static char **unpack(const uint8_t *buf, size_t len, int32_t argc) {
  if (argc < 1) {
    errno = EINVAL;
    return NULL;
  }
  char **argv = calloc((size_t)argc + 1, sizeof *argv);
  if (!argv) return NULL;
  size_t off = 0;
  for (int32_t i = 0; i < argc; i++) {
    const uint8_t *end = off < len ? memchr(buf + off, 0, len - off) : NULL;
    if (!end) {
      free(argv);
      errno = EINVAL;
      return NULL;
    }
    argv[i] = (char *)(buf + off);
    off = (size_t)(end - buf) + 1;
  }
  if (off != len) {
    free(argv);
    errno = EINVAL;
    return NULL;
  }
  return argv;
}

// Replaces the process with argv[0], found on PATH, from a packed argv. Returns only on
// failure, with errno.
int32_t posix_exec(const uint8_t *buf, size_t len, int32_t argc) {
  char **argv = unpack(buf, len, argc);
  if (!argv) return errno;
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

// What a program printed, for a caller that does not trust the program: at most
// CAPTURE_MAX bytes are kept, it has `seconds` to end, and its standard error and input
// are /dev/null. One that prints more or takes longer is killed. The text is valid until
// the next call (and ends at a NUL byte, if the program printed one); posix_capture_code
// gives how it ended: the exit code, 128 plus a signal's number, 124 when it ran out of
// time, 125 when it printed too much, 127 when it could not be started.
enum { CAPTURE_MAX = 65536 };
static int32_t capture_code;

static int64_t now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

const char *posix_capture(const uint8_t *buf, size_t len, int32_t argc, int32_t seconds) {
  static char out[CAPTURE_MAX + 1];
  out[0] = 0;
  capture_code = 127;
  char **argv = unpack(buf, len, argc);
  if (!argv) return out;
  int fds[2];
  if (pipe(fds) != 0) {
    free(argv);
    return out;
  }
  fflush(NULL);
  pid_t pid = fork();
  if (pid < 0) {
    close(fds[0]);
    close(fds[1]);
    free(argv);
    return out;
  }
  if (pid == 0) {
    int null = open("/dev/null", O_RDWR);
    if (null < 0 || dup2(null, 0) < 0 || dup2(fds[1], 1) < 0 || dup2(null, 2) < 0) _exit(127);
    if (null > 2) close(null);
    close(fds[0]);
    close(fds[1]);
    signal(SIGPIPE, SIG_DFL);
    execvp(argv[0], argv);
    _exit(127);
  }
  close(fds[1]);
  free(argv);
  int64_t deadline = now_ms() + (int64_t)seconds * 1000;
  size_t n = 0;
  int32_t stopped = 0;   // 124 or 125 when it is this function that ends the program
  for (;;) {
    int64_t left = deadline - now_ms();
    if (left <= 0) {
      stopped = 124;
      break;
    }
    struct pollfd p = { .fd = fds[0], .events = POLLIN };
    int ready = poll(&p, 1, left > 1000 ? 1000 : (int)left);
    if (ready < 0 && errno != EINTR) {
      stopped = 124;
      break;
    }
    if (ready <= 0) continue;
    char over;
    ssize_t r = n < CAPTURE_MAX ? read(fds[0], out + n, CAPTURE_MAX - n) : read(fds[0], &over, 1);
    if (r < 0 && errno == EINTR) continue;
    if (r <= 0) break;     // the end of what it prints (or an error reading it)
    if (n == CAPTURE_MAX) {
      stopped = 125;
      break;
    }
    n += (size_t)r;
  }
  out[n] = 0;
  close(fds[0]);
  // Printing has ended, not yet the program: it has until the deadline to go.
  if (stopped) kill(pid, SIGKILL);
  int status = 0;
  for (;;) {
    pid_t w = waitpid(pid, &status, stopped ? 0 : WNOHANG);
    if (w == pid) break;
    if (w < 0) {
      if (errno == EINTR) continue;
      status = 0;
      if (!stopped) stopped = 127;
      break;
    }
    if (now_ms() >= deadline) {
      stopped = 124;
      kill(pid, SIGKILL);
    } else {
      struct timespec nap = { 0, 10 * 1000000 };
      nanosleep(&nap, NULL);
    }
  }
  if (stopped) {
    out[0] = 0;
    capture_code = stopped;
  } else if (WIFEXITED(status)) {
    capture_code = WEXITSTATUS(status);
  } else {
    capture_code = 128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0);
  }
  return out;
}

int32_t posix_capture_code(void) { return capture_code; }

// Takes the lock that the file at the path is, for the rest of this process's life (and
// not beyond an exec): the file is made if it is not there. With `wait` 0 a lock that is
// held is not waited for. Returns 0, -1 when it is held and was not waited for, or errno.
// A process has one lock: a second call is the first one's.
int32_t posix_lock(const char *path, int32_t wait) {
  static int fd = -1;
  if (fd < 0) fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0) return errno;
  static int held = 0;
  while (!held) {
    if (flock(fd, wait ? LOCK_EX : LOCK_EX | LOCK_NB) == 0) held = 1;
    else if (errno == EWOULDBLOCK) return -1;
    else if (errno != EINTR) return errno;
  }
  return 0;
}
