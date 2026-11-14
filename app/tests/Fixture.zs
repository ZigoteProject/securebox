// What the tests share: a user's context, and a Host that records instead of running podman.
open Box
open Effects

/// A user whose home is reached two ways, as on Fedora Atomic (/home -> /var/home).
let ctx : Ctx =
  { user = "ada"; uid = 1000; gid = 1000; home = "/home/ada"
    homes = [ "/home/ada"; "/var/home/ada" ]
    dataDir = "/home/ada/.local/share/securebox"
    offLimits = [ "/home/ada/.local/share/securebox"; "/run/user/1000" ]
    cwd = "/home/ada/Projects/web/src"
    shell = "zsh"; tty = true; passEnv = [ "TERM"; "LANG" ] }

/// Symbolic links of the recorded host: where each leads.
let links = [ ("/srv/to-ssh", "/var/home/ada/.ssh"); ("/srv/to-web", "/home/ada/Projects/web") ]

/// Runs `app` with podman answered by `answer` (from its arguments) and the paths in
/// `present` existing: the result, and what was asked of the host, in order.
let record (answer: list<string> -> ProcessResult) (present: list<string>) (app: unit -> 'a) =
  let mutable calls = []
  let result =
    handle app () with
    | Host.capture args, k ->
      calls <- ("podman " + String.join " " args) :: calls
      k (Ok (answer args))
    | Host.exec args, k ->
      calls <- ("exec podman " + String.join " " args) :: calls
      k 0
    | Host.dirExists path, k -> k (List.contains path present)
    | Host.pathExists path, k -> k (List.contains path present)
    | Host.realPath path, k ->
      k (match List.tryFind (fun (link, _) -> link = path) links with
         | Some (_, target) -> target
         | None -> if List.contains path present then path else "")
    | Host.ensureDir path, k ->
      calls <- ("mkdir " + path) :: calls
      k (Ok ())
    | Host.say _, k -> k ()
  (result, List.rev calls)

/// What `podman inspect` prints for a container, as `Podman.inspectArgs` asks for it.
let inspected (name: string) (status: string) (label: string) (mounts: list<string * string>) =
  $"{name}|{status}|{label}\n" + String.concat (List.map (fun (source, destination) -> $"{source}\t{destination}\n") mounts)

/// The home mount that makes a container the box `dev`.
let devHome = ("/home/ada/.local/share/securebox/dev/home", "/home/ada")

/// podman's answers for one container: `inspect` prints `state` (or fails when it is "",
/// and `container exists` then says there is none); everything else succeeds.
let box (state: string) (args: list<string>) : ProcessResult =
  match args with
  | "inspect" :: _ -> if state = "" then { code = 125; output = "" } else { code = 0; output = state }
  | "container" :: "exists" :: _ -> { code = (if state = "" then 1 else 0); output = "" }
  | _ -> { code = 0; output = "" }
