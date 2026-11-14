// What the tests share: a user's context, and a Host that records instead of running podman.
open Box
open Effects

/// A user whose home is reached two ways, as on Fedora Atomic (/home -> /var/home).
let ctx : Ctx =
  { user = "ada"; uid = 1000; gid = 1000; home = "/home/ada"
    homes = [ "/home/ada"; "/var/home/ada" ]
    dataDir = "/home/ada/.local/share/securebox"
    offLimits = [ "/home/ada/.local/share/securebox"; "/run/user/1000" ]
    runtime = "/run/user/1000"; busAddress = "unix:path=/run/user/1000/bus"
    cwd = "/home/ada/Projects/web/src"
    shell = "zsh"; tty = true; passEnv = [ "TERM"; "LANG" ] }

/// Symbolic links of the recorded host: where each leads.
let links = [ ("/srv/to-ssh", "/var/home/ada/.ssh"); ("/srv/to-web", "/home/ada/Projects/web") ]

/// Runs `app` with podman answered by `answer` (from its arguments) and the paths in
/// `present` existing: the result, and what was asked of the host, in order. A box's
/// units (its D-Bus filter, its sound front-end) are running when `present` has "units".
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
    | Host.isSocket path, k -> k (List.contains path present)
    | Host.realPath path, k ->
      k (match List.tryFind (fun (link, _) -> link = path) links with
         | Some (_, target) -> target
         | None -> if List.contains path present then path else "")
    | Host.ensureDir path, k ->
      calls <- ("mkdir " + path) :: calls
      k (Ok ())
    | Host.tool (program, args), k ->
      calls <- (program + " " + String.join " " args) :: calls
      k (if List.contains "is-active" args && not (List.contains "units" present) then 3 else 0)
    | Host.removeTree path, k ->
      calls <- ("remove " + path) :: calls
      k ()
    | Host.writeFile (path, _), k ->
      calls <- ("write " + path) :: calls
      k (Ok ())
    | Host.copyFile (source, target), k ->
      calls <- ($"copy {source} {target}") :: calls
      k (Ok ())
    | Host.awaitPath _, k -> k true
    | Host.say _, k -> k ()
  (result, List.rev calls)

/// What `podman inspect` prints for a container, as `Podman.inspectArgs` asks for it:
/// bind mounts as source and destination, and the destinations of volumes an image declared.
let inspectedWith (name: string) (status: string) (label: string) (binds: list<string * string>) (volumes: list<string>) =
  let mount (kind: string) (source: string) (destination: string) =
    "{\"Type\":\"" + kind + "\",\"Source\":\"" + source + "\",\"Destination\":\"" + destination + "\"}"
  let bind (source, destination) = mount "bind" source destination
  let volume destination = mount "volume" "/var/lib/containers/volumes/x/_data" destination
  $"{name}|{status}|{label}\n[" + String.join "," (List.append (List.map bind binds) (List.map volume volumes)) + "]\n"

let inspected (name: string) (status: string) (label: string) (mounts: list<string * string>) =
  inspectedWith name status label mounts []

/// What the host must have for a sound front-end to be started.
let pipewire = [ "/run/user/1000/pipewire-0"; "/usr/share/pipewire/pipewire-pulse.conf" ]

/// The home mount that makes a container the box `dev`.
let devHome = ("/home/ada/.local/share/securebox/dev/home", "/home/ada")

/// podman's answers for one container: `inspect` prints `state` (or fails when it is "",
/// and `container exists` then says there is none); everything else succeeds.
let box (state: string) (args: list<string>) : ProcessResult =
  match args with
  | "inspect" :: _ -> if state = "" then { code = 125; output = "" } else { code = 0; output = state }
  | "container" :: "exists" :: _ -> { code = (if state = "" then 1 else 0); output = "" }
  | _ -> { code = 0; output = "" }

/// podman's answers around a `create` of `dev`: no such container before it, the container
/// in `state` once it is made; `exec` in it answers with `execCode`.
let creating (state: string) (execCode: int) : list<string> -> ProcessResult =
  let made = ref false
  fun args ->
    match args with
    | "create" :: _ ->
      made.Value <- true
      { code = 0; output = "" }
    | "exec" :: "dev" :: _ -> { code = execCode; output = "" }
    | _ -> box (if made.Value then state else "") args
