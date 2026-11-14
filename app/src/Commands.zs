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

let private look (name: string) : result<Found, string> =
  match Host.capture (inspectArgs name) with
  | Error e -> Error $"cannot run podman: {e}"
  | Ok r ->
    if r.code <> 0 then Ok Missing
    else
      let state = parseInspect r.output
      Ok (if state.ours then Ours state else Foreign)

let private missing (name: string) = $"no box named '{name}'; create it with: securebox create {name}"
let private foreign (name: string) = $"the container '{name}' was not created by securebox, and is left alone"

/// The box's state. A container securebox didn't create is never touched: every command
/// that names a box comes through here or through `look`.
let private find (name: string) : result<BoxState, string> =
  match look name with
  | Error e -> Error e
  | Ok Missing -> Error (missing name)
  | Ok Foreign -> Error (foreign name)
  | Ok (Ours state) -> Ok state

let create (ctx: Ctx) (spec: CreateSpec) : result<int, string> =
  match List.tryFind (fun (s: Share) -> not (Host.dirExists s.path)) spec.shares with
  | Some s -> Error $"cannot share '{s.path}': no such directory"
  | None ->
    let home = boxHome ctx spec.name
    let kept = Host.dirExists home
    let _ = (Host.ensureDir home)?
    let _ = (podman (createArgs ctx spec) $"podman could not create the box '{spec.name}'")?
    let _ = (podman (startArgs spec.name) $"the box '{spec.name}' was created but did not start")?
    match Host.capture (fixPasswdArgs ctx spec.name) with
    | Ok r when r.code = 0 -> ()
    | _ -> Host.say $"securebox: the box is not running after its start: the image may have no 'sleep', which a box needs"
    Host.say (if kept then $"created the box '{spec.name}', with the home directory an earlier box of that name left"
              else $"created the box '{spec.name}'")
    Host.say $"enter it with: securebox enter {spec.name}"
    Ok 0

let enter (ctx: Ctx) (name: string) (root: bool) (cmd: list<string>) : result<int, string> =
  let state = (find name)?
  let started = if state.running then Ok "" else podman (startArgs name) $"the box '{name}' did not start"
  let _ = started?
  Ok (Host.exec (execArgs ctx name root (workdir ctx state.shares) cmd))

let list () : result<int, string> = Ok (Host.exec listArgs)

let stop (name: string) : result<int, string> =
  let state = (find name)?
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
  match look name with
  | Error e -> Error e
  | Ok Foreign -> Error (foreign name)
  | Ok Missing ->
    // the container is gone already: the directory it left can still be purged
    if purge && Host.dirExists dir then purged ctx name $"could not delete {dir}" else Error (missing name)
  | Ok (Ours _) ->
    match podman (rmArgs name) $"the box '{name}' was not removed" with
    | Error e -> Error e
    | Ok _ ->
      if purge then purged ctx name $"the box is removed, but {dir} could not be deleted"
      else
        if Host.dirExists dir then
          Host.say $"removed the box '{name}'; its home directory is kept in {dir} (rm --purge deletes it)"
        Ok 0
