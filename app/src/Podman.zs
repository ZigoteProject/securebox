// The podman command lines, as pure functions of what was asked for. The security defaults
// of DESIGN.md, section 3, are the contents of these lists.
open Box

/// What `inspect` says about a container.
type BoxState =
  { /// It carries securebox's label.
    ours: bool
    running: bool
    /// The shared directories: the mounts whose source is their destination.
    shares: list<string> }

/// The directory securebox keeps for a box, and the home directory inside it.
let boxDir (ctx: Ctx) (name: string) = $"{ctx.dataDir}/{name}"
let boxHome (ctx: Ctx) (name: string) = $"{ctx.dataDir}/{name}/home"

let createArgs (ctx: Ctx) (spec: CreateSpec) : list<string> =
  let share (s: Share) =
    [ "--mount"; $"type=bind,src={s.path},dst={s.path},relabel=shared" + (if s.readOnly then ",ro" else "") ]
  let net =
    match spec.network with
    | Private -> []
    | NoNetwork -> [ "--network"; "none" ]
    | HostNetwork -> [ "--network"; "host" ]
  List.concat [
    [ "create"; "--name"; spec.name; "--hostname"; spec.name; "--label"; "securebox=1" ]
    [ "--init"; "--entrypoint"; "[\"sleep\",\"infinity\"]" ]
    [ "--userns=keep-id"; "--passwd-entry"; $"{ctx.user}:*:{ctx.uid}:{ctx.gid}::{ctx.home}:/bin/sh" ]
    [ "--security-opt"; "no-new-privileges" ]
    [ "--mount"; $"type=bind,src={boxHome ctx spec.name},dst={ctx.home},relabel=private" ]
    List.collect share spec.shares
    [ "--workdir"; ctx.home ]
    net
    List.collect (fun p -> [ "--publish"; p ]) spec.publish
    (if spec.gpu then [ "--device"; "/dev/dri" ] else [])
    [ spec.image ] ]

let inspectArgs (name: string) =
  [ "inspect"; "--type"; "container"; "--format"
    "{{index .Config.Labels \"securebox\"}}|{{.State.Status}}{{range .Mounts}}{{if eq .Source .Destination}}{{\"\\n\"}}{{.Destination}}{{end}}{{end}}"
    name ]

/// Reads `inspectArgs`' output: `1|running`, then a shared directory per line.
let parseInspect (output: string) : BoxState =
  match String.splitLines (String.trim output) with
  | first :: shares ->
    { ours = String.startsWith "1|" first; running = String.endsWith "|running" first
      shares = List.filter (fun s -> s <> "") shares }
  | [] -> { ours = false; running = false; shares = [] }

/// Where a command starts in the box: the host's working directory when a share holds it,
/// the home directory otherwise.
let workdir (ctx: Ctx) (shares: list<string>) =
  if List.exists (fun s -> ctx.cwd = s || String.startsWith (s + "/") ctx.cwd) shares then ctx.cwd else ctx.home

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

let execArgs (ctx: Ctx) (name: string) (root: bool) (dir: string) (cmd: list<string>) : list<string> =
  List.concat [
    [ "exec"; "--interactive" ]
    (if ctx.tty then [ "--tty" ] else [])
    [ "--detach-keys=" ]
    (if root then [ "--user"; "0"; "--env"; "HOME=/root"; "--env"; "USER=root" ]
     else [ "--env"; $"HOME={ctx.home}"; "--env"; $"USER={ctx.user}" ])
    [ "--workdir"; dir; "--env"; $"SECUREBOX={name}" ]
    List.collect (fun v -> [ "--env"; v ]) ctx.passEnv
    [ name ]
    (if cmd = [] then shellCommand ctx.shell else cmd) ]

/// Run as root in a new box: an image that already has a user with this uid (ubuntu's
/// `ubuntu`, 1000) keeps its own passwd line, so podman's entry isn't written. This rewrites
/// that line's name and home; where podman wrote the entry it changes nothing.
let fixPasswdArgs (ctx: Ctx) (name: string) =
  [ "exec"; "--user"; "0"; name; "sh"; "-c"
    "sed -i \"s|^[^:]*:\\([^:]*\\):$1:\\([0-9]*\\):[^:]*:[^:]*:|$2:\\1:$1:\\2::$3:|\" /etc/passwd"
    "sh"; $"{ctx.uid}"; ctx.user; ctx.home ]
