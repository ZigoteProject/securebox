// The podman command lines, as pure functions of what was asked for. The security defaults
// of DESIGN.md, section 3, are the contents of these lists.
open Box

/// What `inspect` says about a container.
type BoxState =
  { name: string
    running: bool
    /// It carries securebox's label. An image can carry it too, so this alone doesn't make
    /// the container a box: `ours` does.
    labelled: bool
    /// Its mounts, each as source and destination.
    mounts: list<string * string> }

/// The directory securebox keeps for a box, and the home directory inside it.
let boxDir (ctx: Ctx) (name: string) = $"{ctx.dataDir}/{name}"
let boxHome (ctx: Ctx) (name: string) = $"{ctx.dataDir}/{name}/home"

/// The box's own runtime directory, and the compositor's socket in it, of a `--wayland` box.
let runtimeDir (ctx: Ctx) = $"/run/user/{ctx.uid}"
let waylandSocket (ctx: Ctx) = $"/run/user/{ctx.uid}/wayland-0"

let createArgs (ctx: Ctx) (spec: CreateSpec) : list<string> =
  let share (s: Share) =
    [ "--mount"; $"type=bind,src={s.path},dst={s.path},relabel=shared" + (if s.readOnly then ",ro" else "") ]
  let net =
    match spec.network with
    | Private -> [ "--network"; "pasta" ]
    | NoNetwork -> [ "--network"; "none" ]
    | HostNetwork -> [ "--network"; "host" ]
  // The compositor is a process of the session: SELinux lets a confined container connect
  // to it only with labelling off, so that is what --wayland costs.
  let wayland =
    match spec.wayland with
    | Some socket ->
      [ "--security-opt"; "label=disable"
        "--mount"; $"type=tmpfs,dst={runtimeDir ctx},tmpfs-mode=0700,chown=true"
        "--mount"; $"type=bind,src={socket},dst={waylandSocket ctx}" ]
    | None -> []
  List.concat [
    [ "create"; "--name"; spec.name; "--hostname"; spec.name; "--label"; "securebox=1" ]
    [ "--init"; "--entrypoint"; "[\"sleep\",\"infinity\"]" ]
    [ "--userns=keep-id"; "--user"; $"{ctx.uid}:{ctx.gid}" ]
    [ "--passwd-entry"; $"{ctx.user}:*:{ctx.uid}:{ctx.gid}::{ctx.home}:/bin/sh" ]
    [ "--security-opt"; "no-new-privileges" ]
    // podman would otherwise copy the host's proxy variables and /etc/hosts into the box
    [ "--http-proxy=false"; "--hosts-file=none" ]
    [ "--mount"; $"type=bind,src={boxHome ctx spec.name},dst={ctx.home},relabel=private" ]
    List.collect share spec.shares
    [ "--workdir"; ctx.home ]
    net
    List.collect (fun p -> [ "--publish"; p ]) spec.publish
    List.collect (fun d -> [ "--device"; d ]) spec.devices
    wayland
    [ spec.image ] ]

/// The name, the state and the label on one line, then a mount per line. The label is
/// printed as JSON, so whatever an image put in it stays on that line.
let inspectArgs (name: string) =
  [ "inspect"; "--type"; "container"; "--format"
    "{{.Name}}|{{.State.Status}}|{{json (index .Config.Labels \"securebox\")}}{{range .Mounts}}{{\"\\n\"}}{{.Source}}{{\"\\t\"}}{{.Destination}}{{end}}"
    name ]

/// Reads `inspectArgs`' output: `dev|running|"1"`, then `source<TAB>destination` lines.
let parseInspect (output: string) : BoxState =
  let mount (line: string) =
    match String.split "\t" line with
    | [ source; destination ] -> Some (source, destination)
    | _ -> None
  match String.splitLines (String.trim output) with
  | first :: rest ->
    match String.split "|" first with
    | name :: status :: label ->
      { name = name; running = status = "running"; labelled = String.join "|" label = "\"1\""
        mounts = List.choose mount rest }
    | _ -> { name = ""; running = false; labelled = false; mounts = [] }
  | [] -> { name = ""; running = false; labelled = false; mounts = [] }

/// Whether the container is the box of this name: it has the name (podman also takes a
/// name for the start of another container's id), the label, and this box's home directory
/// mounted as the home, which no image can bring along.
let ours (ctx: Ctx) (name: string) (state: BoxState) =
  state.name = name && state.labelled && List.contains (boxHome ctx name, ctx.home) state.mounts

/// The shared directories: the mounts whose source is their destination.
let shares (ctx: Ctx) (state: BoxState) =
  state.mounts |> List.filter (fun (source, destination) -> source = destination && destination <> waylandSocket ctx) |> List.map snd

/// The compositor's socket on the host, for a box created with `--wayland`.
let waylandSource (ctx: Ctx) (state: BoxState) =
  state.mounts |> List.tryFind (fun (_, destination) -> destination = waylandSocket ctx) |> Option.map fst

/// Where a command starts in the box: the host's working directory when a share holds it,
/// the home directory otherwise.
let workdir (ctx: Ctx) (shared: list<string>) =
  if List.exists (fun s -> under s ctx.cwd) shared then ctx.cwd else ctx.home

let existsArgs (name: string) = [ "container"; "exists"; name ]
let startArgs (name: string) = [ "start"; name ]
let stopArgs (name: string) = [ "stop"; name ]
let rmArgs (name: string) = [ "rm"; "--force"; name ]

/// Deletes a box's directory inside podman's user namespace: files the box's root made are
/// owned by a subordinate uid there, which the user alone cannot remove.
let purgeArgs (ctx: Ctx) (name: string) = [ "unshare"; "rm"; "-rf"; "--"; boxDir ctx name ]

let listArgs =
  [ "ps"; "--all"; "--filter"; "label=securebox=1"; "--format"
    "table {{.Names}}\t{{.State}}\t{{.Image}}\t{{.Mounts}}\t{{.Networks}}\t{{.Ports}}" ]

/// The box's own shell: the user's, when the box has it, then bash, then sh.
let private shellCommand (shell: string) =
  [ "sh"; "-c"; "exec \"$(command -v \"$0\" || command -v bash || echo sh)\" -l"; shell ]

let execArgs (ctx: Ctx) (name: string) (root: bool) (wayland: bool) (dir: string) (cmd: list<string>) : list<string> =
  List.concat [
    [ "exec"; "--interactive" ]
    (if ctx.tty then [ "--tty" ] else [])
    [ "--detach-keys=" ]
    (if root then [ "--user"; "0"; "--env"; "HOME=/root"; "--env"; "USER=root" ]
     else [ "--env"; $"HOME={ctx.home}"; "--env"; $"USER={ctx.user}" ])
    [ "--workdir"; dir; "--env"; $"SECUREBOX={name}" ]
    (if wayland then [ "--env"; $"XDG_RUNTIME_DIR={runtimeDir ctx}"; "--env"; "WAYLAND_DISPLAY=wayland-0" ] else [])
    List.collect (fun v -> [ "--env"; v ]) ctx.passEnv
    [ name ]
    (if cmd = [] then shellCommand ctx.shell else cmd) ]

/// Run as the user in a new box: whether its passwd line has the user's name and home. It
/// has when podman wrote the entry; an image that already has a user with this uid
/// (ubuntu's `ubuntu`, 1000) keeps its own line.
let passwdOkArgs (ctx: Ctx) (name: string) =
  [ "exec"; name; "sh"; "-c"
    "while IFS=: read -r n p u g c h s; do if [ \"$u\" = \"$1\" ]; then [ \"$n\" = \"$2\" ] && [ \"$h\" = \"$3\" ]; exit; fi; done </etc/passwd; exit 1"
    "sh"; $"{ctx.uid}"; ctx.user; ctx.home ]

/// Run as root in a new box whose passwd line is the image's: rewrites its name and home.
/// `homePath` keeps what sed would read as syntax out of the home.
let fixPasswdArgs (ctx: Ctx) (name: string) =
  [ "exec"; "--user"; "0"; name; "sh"; "-c"
    "sed -i \"s|^[^:]*:\\([^:]*\\):$1:\\([0-9]*\\):[^:]*:[^:]*:|$2:\\1:$1:\\2::$3:|\" /etc/passwd"
    "sh"; $"{ctx.uid}"; ctx.user; ctx.home ]
