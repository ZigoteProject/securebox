// The outside world, as an effect: the commands perform these, `real` gives them podman and
// the disk, and the tests give them a recorder.

effect Host =
  /// Runs podman and waits: its exit code and what it printed. Its errors go to the terminal.
  abstract capture : list<string> -> result<ProcessResult, string>
  /// Replaces securebox with podman. Gives an exit code only when podman couldn't start.
  abstract exec : list<string> -> int
  abstract dirExists : string -> bool
  /// Creates a directory, private to the user, and those above it.
  abstract ensureDir : string -> result<unit, string>
  /// A line for the user.
  abstract say : string -> unit

let rec private createAll (path: string) : result<unit, string> =
  if Directory.exists path then Ok ()
  else
    match createAll (Path.getDirectoryName path) with
    | Error e -> Error e
    | Ok () ->
      match Directory.create path with
      | Error e -> Error e
      | Ok () -> if Posix.setMode path 448 then Ok () else Error $"cannot make {path} private"

let real (app: unit -> 'a) =
  handle app () with
  | Host.capture args, k -> k (Process.run "podman" args)
  | Host.exec args, k ->
    eprintln ("securebox: " + Posix.exec "podman" args)
    k 125
  | Host.dirExists path, k -> k (Directory.exists path)
  | Host.ensureDir path, k -> k (createAll path)
  | Host.say line, k ->
    eprintln line
    k ()
