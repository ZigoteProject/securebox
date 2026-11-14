// The commands, over the Host effect. Each gives the exit code, or what to tell the user.
open Box
open Podman
open Effects

let private podman (args: list<string>) (failure: string) : result<string, string> =
  match Host.capture args with
  | Error e -> Error $"cannot run podman: {e}"
  | Ok r -> if r.code = 0 then Ok r.output else Error failure

type private Found =
  | Missing
  | Foreign
  | Ours of BoxState

/// What podman has under a name. Only "no such container" is `Missing`: a podman that
/// fails for another reason is an error, so nothing is taken for gone that may be there.
let private look (ctx: Ctx) (name: string) : result<Found, string> =
  match Host.capture (inspectArgs name) with
  | Error e -> Error $"cannot run podman: {e}"
  | Ok r ->
    if r.code = 0 then
      let state = parseInspect r.output
      // another name: podman took this one for the start of a container's id
      Ok (if state.name <> name then Missing else if ours ctx name state then Ours state else Foreign)
    else
      match Host.capture (existsArgs name) with
      | Ok e when e.code = 1 -> Ok Missing
      | _ -> Error $"podman could not inspect '{name}'"

let private missing (name: string) = $"no box named '{name}'; create it with: securebox create {name}"
let private foreign (name: string) = $"the container '{name}' is not a box of securebox's (with this data directory), and is left alone"

/// The box's state. A container that isn't the box is never touched: every command that
/// names a box comes through here or through `look`.
let private find (ctx: Ctx) (name: string) : result<BoxState, string> =
  match look ctx name with
  | Error e -> Error e
  | Ok Missing -> Error (missing name)
  | Ok Foreign -> Error (foreign name)
  | Ok (Ours state) -> Ok state

/// A directory to share, from what the user typed: it must exist, and it is checked with
/// its symbolic links resolved, so a link to the home directory is refused as the home is.
let share (ctx: Ctx) (given: string) (readOnly: bool) : result<Share, string> =
  match absolutePath ctx given with
  | Error e -> Error e
  | Ok asked ->
    let resolved = Host.realPath asked
    if resolved = "" || not (Host.dirExists resolved) then Error $"cannot share '{asked}': no such directory"
    else Result.map (fun path -> { path = path; readOnly = readOnly }) (sharePath ctx resolved)

/// After a new box's start: it must be up, and its passwd line the user's. The check runs
/// as the user; root is used only for an image that has its own line for the uid.
let private settle (ctx: Ctx) (name: string) : result<unit, string> =
  match Host.capture (passwdOkArgs ctx name) with
  | Ok r when r.code = 0 -> Ok ()
  | _ ->
    match look ctx name with
    | Ok (Ours state) when state.running ->
      match Host.capture (fixPasswdArgs ctx name) with
      | Ok r when r.code = 0 -> Ok ()
      | _ ->
        Host.say "securebox: your passwd entry could not be written in the box (its image may have no 'sed'): programs that read the home directory from passwd will not find it"
        Ok ()
    | _ -> Error $"the box '{name}' did not stay up: its image needs a 'sleep' that takes 'infinity'. Remove it with: securebox rm {name}"

let create (ctx: Ctx) (spec: CreateSpec) : result<int, string> =
  let absent = Option.exists (fun socket -> not (Host.pathExists socket)) spec.wayland
  match spec.wayland with
  | Some socket when absent -> Error $"--wayland: there is no compositor socket at {socket}"
  | _ ->
    let home = boxHome ctx spec.name
    let kept = Host.dirExists home
    let _ = (Host.ensureDir home)?
    let _ = (podman (createArgs ctx spec) $"podman could not create the box '{spec.name}'")?
    let _ = (podman (startArgs spec.name) $"the box '{spec.name}' was created but did not start")?
    let _ = (settle ctx spec.name)?
    Host.say (if kept then $"created the box '{spec.name}', with the home directory an earlier box of that name left"
              else $"created the box '{spec.name}'")
    Host.say $"enter it with: securebox enter {spec.name}"
    Ok 0

let enter (ctx: Ctx) (name: string) (root: bool) (cmd: list<string>) : result<int, string> =
  let state = (find ctx name)?
  let socket = waylandSource ctx state
  let absent = Option.exists (fun s -> not (Host.pathExists s)) socket
  let started =
    if state.running then Ok ""
    else
      match socket with
      | Some s when absent ->
        Error $"the box '{name}' was created with --wayland, and the compositor's socket {s} is not there: start it from your graphical session"
      | _ -> podman (startArgs name) $"the box '{name}' did not start"
  let _ = started?
  Ok (Host.exec (execArgs ctx name root (Option.isSome socket) (workdir ctx (shares ctx state)) cmd))

let list () : result<int, string> = Ok (Host.exec listArgs)

let stop (ctx: Ctx) (name: string) : result<int, string> =
  let state = (find ctx name)?
  let stopped = if state.running then podman (stopArgs name) $"the box '{name}' did not stop" else Ok ""
  Result.map (fun _ -> 0) stopped

let private purged (ctx: Ctx) (name: string) (failure: string) : result<int, string> =
  match podman (purgeArgs ctx name) failure with
  | Error e -> Error e
  | Ok _ ->
    Host.say $"removed the box '{name}' and deleted {boxDir ctx name}"
    Ok 0

let rm (ctx: Ctx) (name: string) (purge: bool) : result<int, string> =
  let dir = boxDir ctx name
  match look ctx name with
  | Error e -> Error e
  | Ok Foreign -> Error (foreign name)
  | Ok Missing ->
    // the container is gone already: what it left can still be purged, when it is a box's
    if purge && Host.dirExists (boxHome ctx name) then purged ctx name $"could not delete {dir}" else Error (missing name)
  | Ok (Ours _) ->
    match podman (rmArgs name) $"the box '{name}' was not removed" with
    | Error e -> Error e
    | Ok _ ->
      if purge then purged ctx name $"the box is removed, but {dir} could not be deleted"
      else
        if Host.dirExists dir then
          Host.say $"removed the box '{name}'; its home directory is kept in {dir} (rm --purge deletes it)"
        Ok 0
