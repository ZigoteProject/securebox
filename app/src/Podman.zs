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

/// The box's own runtime directory, which a box with a session grant has, and where each
/// grant is in it: the compositor's socket (`--wayland`), the directory of the sound
/// server's PulseAudio socket (`--sound`), and that of the D-Bus filter's (`--dbus`).
let runtimeDir (ctx: Ctx) = $"/run/user/{ctx.uid}"
let waylandSocket (ctx: Ctx) = $"/run/user/{ctx.uid}/wayland-0"
let pulseDir (ctx: Ctx) = $"/run/user/{ctx.uid}/pulse"
let busDir (ctx: Ctx) = $"/run/user/{ctx.uid}/dbus"

/// On the host: where a box's D-Bus filter listens, and the unit it runs as.
let hostBusDir (ctx: Ctx) (name: string) = $"{ctx.runtime}/securebox/{name}"
let busUnit (name: string) = $"securebox-dbus-{name}"

let createArgs (ctx: Ctx) (spec: CreateSpec) : list<string> =
  let share (s: Share) =
    [ "--mount"; $"type=bind,src={s.path},dst={s.path},relabel=shared" + (if s.readOnly then ",ro" else "") ]
  let net =
    match spec.network with
    | Private -> [ "--network"; "pasta" ]
    | NoNetwork -> [ "--network"; "none" ]
    | HostNetwork -> [ "--network"; "host" ]
  // The compositor, the sound server and the D-Bus filter are processes of the session:
  // SELinux lets a confined container connect to one only with labelling off, so that is
  // what each of these grants costs. They share one runtime directory of the box's own.
  let session =
    if Option.isSome spec.wayland || Option.isSome spec.sound || spec.dbus <> [] then
      [ "--security-opt"; "label=disable"
        "--mount"; $"type=tmpfs,dst={runtimeDir ctx},tmpfs-mode=0700,chown=true" ]
    else []
  let wayland =
    match spec.wayland with
    | Some socket -> [ "--mount"; $"type=bind,src={socket},dst={waylandSocket ctx}" ]
    | None -> []
  // directories, not the sockets: a server that restarts makes a new socket in the same place
  let sound =
    match spec.sound with
    | Some dir -> [ "--mount"; $"type=bind,src={dir},dst={pulseDir ctx},ro" ]
    | None -> []
  let dbus =
    if spec.dbus <> [] then
      [ "--label"; "securebox.dbus=" + String.join "," spec.dbus
        "--mount"; $"type=bind,src={hostBusDir ctx spec.name},dst={busDir ctx},ro" ]
    else []
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
    session
    wayland
    sound
    dbus
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

/// The shared directories: the mounts whose source is their destination, the session
/// grants in the box's runtime directory aside.
let shares (ctx: Ctx) (state: BoxState) =
  state.mounts
  |> List.filter (fun (source, destination) -> source = destination && not (under (runtimeDir ctx) destination))
  |> List.map snd

let private mountedAt (destination: string) (state: BoxState) =
  state.mounts |> List.tryFind (fun (_, d) -> d = destination) |> Option.map fst

/// Whether the box was created with `--dbus`.
let hasBus (ctx: Ctx) (state: BoxState) = Option.isSome (mountedAt (busDir ctx) state)

/// What a box with session grants needs from the host to start: each as what it is and
/// where it must be. (The D-Bus filter is started by securebox itself.)
let sessionNeeds (ctx: Ctx) (state: BoxState) : list<string * string> =
  List.concat [
    Option.toList (Option.map (fun s -> ("the Wayland compositor's socket", s)) (mountedAt (waylandSocket ctx) state))
    Option.toList (Option.map (fun d -> ("the sound server's socket", d + "/native")) (mountedAt (pulseDir ctx) state)) ]

/// The environment that tells programs in the box where its session grants are.
let sessionEnv (ctx: Ctx) (state: BoxState) : list<string> =
  let granted destination = Option.isSome (mountedAt destination state)
  let each =
    List.concat [
      (if granted (waylandSocket ctx) then [ "WAYLAND_DISPLAY=wayland-0" ] else [])
      (if granted (pulseDir ctx) then [ $"PULSE_SERVER=unix:{pulseDir ctx}/native" ] else [])
      (if granted (busDir ctx) then [ $"DBUS_SESSION_BUS_ADDRESS=unix:path={busDir ctx}/bus" ] else []) ]
  if each = [] then [] else $"XDG_RUNTIME_DIR={runtimeDir ctx}" :: each

/// A `--dbus` box's names, as `create` wrote them in its label.
let busLabelArgs (name: string) =
  [ "inspect"; "--type"; "container"; "--format"; "{{index .Config.Labels \"securebox.dbus\"}}"; name ]

/// The D-Bus filter of a box, run by the user's systemd so that it outlives securebox:
/// xdg-dbus-proxy between the session bus and a socket of the box's, letting through only
/// calls to the names granted.
let proxyActiveArgs (name: string) = [ "--user"; "is-active"; "--quiet"; busUnit name ]
let proxyStopArgs (name: string) = [ "--user"; "stop"; busUnit name ]
let proxyStartArgs (ctx: Ctx) (name: string) (names: list<string>) =
  List.concat [
    [ "--user"; "--quiet"; "--collect"; "--unit"; busUnit name; "--"; "xdg-dbus-proxy" ]
    [ ctx.busAddress; hostBusDir ctx name + "/bus"; "--filter" ]
    List.map (fun n -> "--talk=" + n) names ]

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

let execArgs (ctx: Ctx) (name: string) (root: bool) (session: list<string>) (dir: string) (cmd: list<string>) : list<string> =
  List.concat [
    [ "exec"; "--interactive" ]
    (if ctx.tty then [ "--tty" ] else [])
    [ "--detach-keys=" ]
    (if root then [ "--user"; "0"; "--env"; "HOME=/root"; "--env"; "USER=root" ]
     else [ "--env"; $"HOME={ctx.home}"; "--env"; $"USER={ctx.user}" ])
    [ "--workdir"; dir; "--env"; $"SECUREBOX={name}" ]
    List.collect (fun v -> [ "--env"; v ]) session
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
