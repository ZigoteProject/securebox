// What the tests share: a user's context, and a Host that records instead of running podman.
open Box
open Effects

let ctx : Ctx =
  { user = "ada"; uid = 1000; gid = 1000; home = "/home/ada"
    dataDir = "/home/ada/.local/share/securebox"; cwd = "/home/ada/Projects/web/src"
    shell = "zsh"; tty = true; passEnv = [ "TERM"; "LANG" ] }

/// Runs `app` with podman answered by `answer` (from its arguments) and the directories in
/// `dirs` existing: the result, and what was asked of the host, in order.
let record (answer: list<string> -> ProcessResult) (dirs: list<string>) (app: unit -> 'a) =
  let mutable calls = []
  let result =
    handle app () with
    | Host.capture args, k ->
      calls <- ("podman " + String.join " " args) :: calls
      k (Ok (answer args))
    | Host.exec args, k ->
      calls <- ("exec podman " + String.join " " args) :: calls
      k 0
    | Host.dirExists path, k -> k (List.contains path dirs)
    | Host.ensureDir path, k ->
      calls <- ("mkdir " + path) :: calls
      k (Ok ())
    | Host.say _, k -> k ()
  (result, List.rev calls)

/// podman's answers for one container: `inspect` prints `state` (or fails when it is ""),
/// everything else succeeds.
let box (state: string) (args: list<string>) : ProcessResult =
  match args with
  | "inspect" :: _ -> if state = "" then { code = 125; output = "" } else { code = 0; output = state }
  | _ -> { code = 0; output = "" }
