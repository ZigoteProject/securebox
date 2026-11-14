// Posix: the libc calls securebox needs and Std doesn't have. All of the project's C is here.

extern posix_exec : span<u8> -> i32 -> i32
extern strerror : i32 -> cstr
extern geteuid : unit -> u32
extern getuid : unit -> u32
extern getgid : unit -> u32
extern isatty : i32 -> i32

/// The effective user id: 0 is root.
let effectiveUserId () = int (geteuid ())

/// The real user id.
let userId () = int (getuid ())

/// The real group id.
let groupId () = int (getgid ())

/// Whether a file descriptor (0 standard input, 1 output, 2 error) is a terminal.
let isTerminal (fd: int) = isatty (i32 fd) = i32 1

/// Replaces this process with `program`, found on PATH, run with `args`: the program gets
/// this process's id, terminal and streams, and its exit code is this process's. Returns
/// only when it couldn't start, with the reason.
let exec (program: string) (args: list<string>) : string =
  let argv = program :: args
  if List.exists (String.contains "\0") argv then
    $"cannot run {program}: an argument contains a NUL byte"
  else
    let packed = String.concat (List.map (fun a -> a + "\0") argv)
    let e = posix_exec (String.bytes packed) (i32 (List.length argv))
    $"cannot run {program}: {String.ofCStr (strerror e)}"

extern chmod : cstr -> u32 -> i32

/// Sets a file's or directory's permission bits (448 is 0700). Whether it worked.
let setMode (path: string) (mode: int) = chmod path (u32 mode) = i32 0

extern posix_realpath : cstr -> cstr
extern posix_user_name : unit -> cstr
extern posix_user_home : unit -> cstr
extern access : cstr -> i32 -> i32

/// The path with every symbolic link, `.` and `..` resolved; "" when it doesn't exist.
let realPath (path: string) = String.ofCStr (posix_realpath path)

/// The user's name in the passwd database, "" when it has no entry for the uid.
let userName () = String.ofCStr (posix_user_name ())

/// The user's home directory in the passwd database, "" when it has no entry for the uid.
let userHome () = String.ofCStr (posix_user_home ())

/// Whether the path exists, whatever it is: a file, a directory, a socket.
let exists (path: string) = access path (i32 0) = i32 0

extern posix_is_socket : cstr -> i32

/// Whether the path is a socket.
let isSocket (path: string) = posix_is_socket path = i32 1

extern posix_entry : cstr -> i32
extern posix_create_file : cstr -> span<u8> -> u32 -> i32
extern unlink : cstr -> i32

/// Whether anything is at the path itself: a symbolic link counts, dangling or not.
let entryExists (path: string) = posix_entry path <> i32 0

/// Whether the path is a regular file itself, not a symbolic link to one.
let isRegularFile (path: string) = posix_entry path = i32 1

/// Creates a file with `text` in it and the permission bits `mode` (420 is 0644, 493 is
/// 0755). Fails when anything is at the path already, and never writes through a symbolic
/// link there, dangling or not.
let createFile (path: string) (text: string) (mode: int) : result<unit, string> =
  let e = posix_create_file path (String.bytes text) (u32 mode)
  if e = i32 0 then Ok () else Error $"cannot create {path}: {String.ofCStr (strerror e)}"

/// Removes the file or the symbolic link at the path itself. Whether it worked.
let removeFile (path: string) = unlink path = i32 0

extern posix_capture : span<u8> -> i32 -> i32 -> cstr
extern posix_capture_code : unit -> i32
extern posix_lock : cstr -> i32 -> i32

/// Runs `program`, found on PATH, for a caller that does not trust what it prints: its exit
/// code and its standard output, of which at most 64 KB is taken. It has `seconds` to end,
/// reads nothing, and its standard error is dropped. The code is 124 when it ran out of
/// time, 125 when it printed more, 127 when it could not be started; the output is then "".
let capture (program: string) (args: list<string>) (seconds: int) : int * string =
  let argv = program :: args
  if List.exists (String.contains "\0") argv then (127, "")
  else
    let packed = String.concat (List.map (fun a -> a + "\0") argv)
    let output = String.ofCStr (posix_capture (String.bytes packed) (i32 (List.length argv)) (i32 seconds))
    (int (posix_capture_code ()), output)

/// How `lock` ended.
type Lock =
  | Held
  /// Another process has it, and it was not waited for.
  | Busy
  | Failed of string

/// Takes the lock that the file at `path` is (made if it is not there), until this process
/// ends or is replaced by `exec`. With `wait` it is waited for. A process has one lock: once
/// it holds one, every call is `Held`.
let lock (path: string) (wait: bool) : Lock =
  let e = posix_lock path (i32 (if wait then 1 else 0))
  if e = i32 0 then Held
  else if e < i32 0 then Busy
  else Failed $"cannot lock {path}: {String.ofCStr (strerror e)}"
