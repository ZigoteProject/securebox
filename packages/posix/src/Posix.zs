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
