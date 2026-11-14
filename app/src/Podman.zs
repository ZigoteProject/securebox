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
    /// Its bind mounts, each as source and destination. Only binds: they come from the
    /// command line that made the container, where a volume can be the image's doing.
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

/// On the host, in the session's runtime directory: what securebox keeps for a box's
/// session grants. The D-Bus filter's socket and the sound front-end's are each in a
/// directory of their own, which is what the box gets; the front-end's configuration is not.
let hostBoxDir (ctx: Ctx) (name: string) = $"{ctx.runtime}/securebox/{name}"
let hostBusDir (ctx: Ctx) (name: string) = $"{ctx.runtime}/securebox/{name}/dbus"
let hostSoundDir (ctx: Ctx) (name: string) = $"{ctx.runtime}/securebox/{name}/pulse"
let hostSoundConf (ctx: Ctx) (name: string) = $"{ctx.runtime}/securebox/{name}/sound"

/// The units of the user's systemd that the filter and the front-end run as.
/// Named in full: a box may be called `x.service` or `x.socket`.
let busUnit (name: string) = $"securebox-dbus-{name}.service"
let soundUnit (name: string) = $"securebox-sound-{name}.service"

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
    if Option.isSome spec.wayland || spec.sound || spec.dbus <> [] then
      [ "--security-opt"; "label=disable"
        "--mount"; $"type=tmpfs,dst={runtimeDir ctx},tmpfs-mode=0700,chown=true" ]
    else []
  let wayland =
    match spec.wayland with
    | Some socket -> [ "--mount"; $"type=bind,src={socket},dst={waylandSocket ctx},ro" ]
    | None -> []
  // directories, not the sockets: a server that restarts makes a new socket in the same place
  let sound =
    if spec.sound then [ "--mount"; $"type=bind,src={hostSoundDir ctx spec.name},dst={pulseDir ctx},ro" ] else []
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

/// The name, the state and the label on one line, then the mounts on another. The label
/// and the mounts are printed as JSON, so whatever an image put in a label or in the path
/// of a volume stays inside its string.
let inspectArgs (name: string) =
  [ "inspect"; "--type"; "container"; "--format"
    "{{.Name}}|{{.State.Status}}|{{json (index .Config.Labels \"securebox\")}}{{\"\\n\"}}{{json .Mounts}}"
    name ]

/// The bind mounts in podman's JSON of a container's mounts, as source and destination.
let private binds (line: string) : list<string * string> =
  let text (key: string) (fields: list<string * Json>) =
    match List.tryFind (fun (k, _) -> k = key) fields with
    | Some (_, JString s) -> Some s
    | _ -> None
  let bind (mount: Json) =
    match mount with
    | JObject fields ->
      match (text "Type" fields, text "Source" fields, text "Destination" fields) with
      | (Some "bind", Some source, Some destination) -> Some (source, destination)
      | _ -> None
    | _ -> None
  match Json.parse line with
  | Ok (JArray mounts) -> List.choose bind mounts
  | _ -> []

/// Reads `inspectArgs`' output: `dev|running|"1"`, then the mounts as a JSON array, of which
/// the binds are kept.
let parseInspect (output: string) : BoxState =
  match String.splitLines (String.trim output) with
  | first :: rest ->
    match String.split "|" first with
    | name :: status :: label ->
      { name = name; running = status = "running"; labelled = String.join "|" label = "\"1\""
        mounts = (match rest with
                  | line :: _ -> binds line
                  | [] -> []) }
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

/// Whether the box was created with `--dbus` or `--sound`: it has securebox's own
/// directory for it bound where the grant goes. Nothing an image declares looks like that.
let hasBus (ctx: Ctx) (state: BoxState) = mountedAt (busDir ctx) state = Some (hostBusDir ctx state.name)
let hasSound (ctx: Ctx) (state: BoxState) = mountedAt (pulseDir ctx) state = Some (hostSoundDir ctx state.name)

/// What a box with session grants needs from the host to start: each as what it is and
/// where it must be. (The D-Bus filter and the sound front-end are started by securebox.)
let sessionNeeds (ctx: Ctx) (state: BoxState) : list<string * string> =
  Option.toList (Option.map (fun s -> ("the Wayland compositor's socket", s)) (mountedAt (waylandSocket ctx) state))

/// The environment that tells programs in the box where its session grants are.
let sessionEnv (ctx: Ctx) (state: BoxState) : list<string> =
  let each =
    List.concat [
      (if Option.isSome (mountedAt (waylandSocket ctx) state) then [ "WAYLAND_DISPLAY=wayland-0" ] else [])
      (if hasSound ctx state then [ $"PULSE_SERVER=unix:{pulseDir ctx}/native" ] else [])
      (if hasBus ctx state then [ $"DBUS_SESSION_BUS_ADDRESS=unix:path={busDir ctx}/bus" ] else []) ]
  if each = [] then [] else $"XDG_RUNTIME_DIR={runtimeDir ctx}" :: each

/// A `--dbus` box's names, as `create` wrote them in its label.
let busLabelArgs (name: string) =
  [ "inspect"; "--type"; "container"; "--format"; "{{index .Config.Labels \"securebox.dbus\"}}"; name ]

/// The D-Bus filter of a box, run by the user's systemd so that it outlives securebox:
/// xdg-dbus-proxy between the session bus and a socket of the box's. For each name granted
/// it lets through calls to the interface of that name, and that interface's signals: not
/// everything the process owning the name exports, which `--talk` would give (gnome-shell
/// owns notification names, and its remote-desktop interface on the same connection).
let unitActiveArgs (unit: string) = [ "--user"; "is-active"; "--quiet"; unit ]
let unitStopArgs (unit: string) = [ "--user"; "stop"; unit ]
let proxyStartArgs (ctx: Ctx) (name: string) (names: list<string>) =
  List.concat [
    [ "--user"; "--quiet"; "--collect"; "--unit"; busUnit name; "--"; "xdg-dbus-proxy" ]
    [ ctx.busAddress; hostBusDir ctx name + "/bus"; "--filter" ]
    List.collect (fun n -> [ "--see=" + n; $"--call={n}={n}.*"; $"--broadcast={n}={n}.*" ]) names ]

/// Where a command starts in the box: the host's working directory when a share holds it,
/// the home directory otherwise.
let workdir (ctx: Ctx) (shared: list<string>) =
  if List.exists (fun s -> under s ctx.cwd) shared then ctx.cwd else ctx.home

let existsArgs (name: string) = [ "container"; "exists"; name ]
let startArgs (name: string) = [ "start"; name ]
let stopArgs (name: string) = [ "stop"; name ]
/// With the anonymous volumes an image declared, which nothing else would ever remove.
let rmArgs (name: string) = [ "rm"; "--force"; "--volumes"; name ]

/// Deletes a box's directory inside podman's user namespace: files the box's root made are
/// owned by a subordinate uid there, which the user alone cannot remove.
let purgeArgs (ctx: Ctx) (name: string) = [ "unshare"; "rm"; "-rf"; "--"; boxDir ctx name ]

let listArgs = [ "ps"; "--all"; "--filter"; "label=securebox=1"; "--format"; "json" ]

/// The mounts of the containers `list` shows, a line each: `ps` tells where things are
/// mounted, not what they are.
let listMountsArgs (names: list<string>) =
  List.append [ "container"; "inspect"; "--format"; "{{.Name}}|{{json .Mounts}}" ] names

/// The containers `listArgs` found, by name.
let listed (output: string) : list<string> =
  match Json.parse (if String.trim output = "" then "[]" else output) with
  | Ok (JArray boxes) ->
    List.collect (fun box ->
      match box with
      | JObject b ->
        match List.tryFind (fun (k, _) -> k = "Names") b with
        | Some (_, JArray names) -> List.choose (fun n -> match n with
                                                          | JString s -> Some s
                                                          | _ -> None) names
        | _ -> []
      | _ -> []) boxes
  | _ -> []

/// Of those, the ones created with `--dbus`: securebox's directory for the filter is bound
/// where the bus goes. A volume an image declares there is not a bind.
let withBus (uid: int) (mounts: string) : list<string> =
  String.splitLines mounts |> List.choose (fun line ->
    match String.indexOf "|" line with
    | Some i ->
      let name = String.sub line 0 i
      let bound = binds (String.sub line (i + 1) (String.length line - i - 1))
      let ours (source: string, destination: string) =
        destination = $"/run/user/{uid}/dbus" && String.endsWith $"/securebox/{name}/dbus" source
      if List.exists ours bound then Some name else None
    | None -> None)

/// The table `list` prints, from `listArgs`' output: for each box its state, its image, and
/// its grants as podman has them: what is mounted, its network, its ports, and the names on
/// the session bus it may talk to. The names are shown only for the boxes in `granted`
/// (`withBus`), so a label an image carries is not listed as a grant. Control characters
/// are not printed.
let listing (granted: list<string>) (output: string) : result<string, string> =
  let field (key: string) (fields: list<string * Json>) = List.tryFind (fun (k, _) -> k = key) fields |> Option.map snd
  let text (j: option<Json>) =
    match j with
    | Some (JString s) -> s
    | Some (JInt n) -> $"{n}"
    | Some (JUInt n) -> $"{n}"
    | _ -> ""
  let texts (j: option<Json>) =
    match j with
    | Some (JArray items) -> List.map (fun item -> text (Some item)) items
    | _ -> []
  let port (j: Json) =
    match j with
    | JObject p ->
      let ip = text (field "host_ip" p)
      (if ip = "" then "0.0.0.0" else ip) + ":" + text (field "host_port" p) + "->" + text (field "container_port" p) + "/" + text (field "protocol" p)
    | _ -> ""
  let clean (s: string) = String.ofChars (List.map (fun c -> if int c < 32 || int c = 127 then '?' else c) (String.chars s))
  let row (box: Json) =
    match box with
    | JObject b ->
      let mounts = texts (field "Mounts" b)
      let ports =
        match field "Ports" b with
        | Some (JArray ps) -> List.map port ps
        | _ -> []
      let named = texts (field "Names" b)
      let names =
        match field "Labels" b with
        | Some (JObject labels) when List.exists (fun n -> List.contains n granted) named -> text (field "securebox.dbus" labels)
        | _ -> ""
      Some (List.map clean [ String.join "," named; text (field "State" b); text (field "Image" b)
                             String.join " " mounts; String.join "," (texts (field "Networks" b)); String.join " " ports; names ])
    | _ -> None
  match Json.parse (if String.trim output = "" then "[]" else output) with
  | Ok (JArray boxes) ->
    let rows = [ "NAME"; "STATE"; "IMAGE"; "MOUNTS"; "NETWORKS"; "PORTS"; "DBUS" ] :: List.choose row boxes
    let width (i: int) = List.fold (fun w (r: list<string>) -> max w (String.length (List.item i r))) 0 rows
    let widths = List.init 7 width
    let line (r: list<string>) = String.trimEnd (String.join "  " (List.map2 (fun w cell -> String.padRight w cell) widths r))
    Ok (String.concat (List.map (fun r -> line r + "\n") rows))
  | _ -> Error "podman's list of containers could not be read"

/// The box's own shell: the user's, when the box has it, then bash, then sh.
let private shellCommand (shell: string) =
  [ "sh"; "-c"; "exec \"$(command -v \"$0\" || command -v bash || echo sh)\" -l"; shell ]

/// The sound front-end of a box: a pipewire-pulse of its own, beside the session's, that
/// listens only in the box's directory and takes no `load-module`. The session's sound
/// server does take them from whoever reaches its socket, and a module can make files and
/// open ports on the host, which is why the box never gets that socket.
let soundConfigFiles = [ "/etc/pipewire/pipewire-pulse.conf"; "/usr/share/pipewire/pipewire-pulse.conf" ]
let soundOverride (ctx: Ctx) (name: string) =
  String.concat [
    "# written by securebox: the sound front-end of the box " + name + "\n"
    "pulse.properties = {\n"
    "    server.address = [ { address = \"unix:" + hostSoundDir ctx name + "/native\" client.access = \"restricted\" } ]\n"
    "    pulse.allow-module-loading = false\n"
    "}\n" ]
let soundStartArgs (ctx: Ctx) (name: string) =
  [ "--user"; "--quiet"; "--collect"; "--unit"; soundUnit name
    "--setenv"; $"PIPEWIRE_CONFIG_DIR={hostSoundConf ctx name}"
    "--setenv"; $"PULSE_RUNTIME_PATH={hostSoundDir ctx name}"
    "--"; "pipewire-pulse" ]

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
