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
  match Host.inBox (passwdOkArgs ctx name) with
  | Ok r when r.code = 0 -> Ok ()
  | _ ->
    match look ctx name with
    | Ok (Ours state) when state.running ->
      match Host.inBox (fixPasswdArgs ctx name) with
      | Ok r when r.code = 0 -> Ok ()
      | _ ->
        Host.say "securebox: your passwd entry could not be written in the box (its image may have no 'sed'): programs that read the home directory from passwd will not find it"
        Ok ()
    | _ -> Error $"the box '{name}' did not stay up: its image needs a 'sleep' that takes 'infinity'. Remove it with: securebox rm {name}"

let private sessionless (needs: string) = $"{needs}, and there is no session here (XDG_RUNTIME_DIR is not set or cannot be used)"

/// What `--dbus` needs of the session before a filter can be started.
let private busUsable (ctx: Ctx) : result<unit, string> =
  // the address is one argument of the filter's, and systemd expands a $ in it
  if ctx.runtime = "" then Error (sessionless "--dbus needs xdg-dbus-proxy")
  else if ctx.busAddress = "" || String.startsWith "-" ctx.busAddress || String.contains "$" ctx.busAddress then
    Error "--dbus needs your session bus, and DBUS_SESSION_BUS_ADDRESS is not set or cannot be used"
  else Ok ()

/// What `--sound` needs of the session before a front-end can be started: PipeWire, and
/// the configuration of its PulseAudio server, which is given.
let private soundStock (ctx: Ctx) : result<string, string> =
  if ctx.runtime = "" then Error (sessionless "--sound needs pipewire-pulse")
  else if not (Host.pathExists (ctx.runtime + "/pipewire-0")) then
    Error $"--sound needs PipeWire, and there is no socket of it at {ctx.runtime}/pipewire-0"
  else
    match List.tryFind (fun f -> Host.pathExists f) soundConfigFiles with
    | None -> Error "--sound needs pipewire-pulse, whose configuration (pipewire-pulse.conf) was not found"
    | Some stock -> Ok stock

/// Makes sure a unit of the box's is running: started through the user's systemd, which
/// keeps it when securebox is gone. `prepare` is run only when it must be started, and
/// gives the arguments of `systemd-run`. A new box takes none over (`fresh`): one left under
/// its name was started for another box, with other grants.
let private served (ctx: Ctx) (fresh: bool) (unit: string) (socket: string) (needs: string) (prepare: unit -> result<list<string>, string>) : result<unit, string> =
  if ctx.runtime = "" then Error (sessionless needs)
  else
    if fresh then Host.tool ("systemctl", unitStopArgs unit) |> ignore
    if not fresh && Host.tool ("systemctl", unitActiveArgs unit) = 0 then Ok ()
    else
      match prepare () with
      | Error e -> Error e
      | Ok args ->
        Host.removeTree socket       // one that a unit that was killed left
        if Host.tool ("systemd-run", args) <> 0 then Error $"{needs}, through a systemd user session (systemd-run --user), and it could not be started"
        else if Host.awaitPath socket then Ok ()
        else Error $"{needs}, which was started but is not listening"

/// A `--dbus` box's filter. `names` is asked for only when it must be started.
let private filtered (ctx: Ctx) (fresh: bool) (name: string) (names: unit -> result<list<string>, string>) : result<unit, string> =
  served ctx fresh (busUnit name) (hostBusDir ctx name + "/bus") "--dbus needs xdg-dbus-proxy" (fun () ->
    match busUsable ctx with
    | Error e -> Error e
    | Ok () ->
      match (names (), Host.ensureDir (hostBusDir ctx name)) with
      | (Error e, _) -> Error e
      | (_, Error e) -> Error e
      | (Ok granted, Ok ()) -> Ok (proxyStartArgs ctx name granted))

/// A `--sound` box's front-end: the session's own pipewire-pulse configuration, with an
/// override that moves its socket into the box's directory and turns module loading off.
let private fronted (ctx: Ctx) (fresh: bool) (name: string) : result<unit, string> =
  served ctx fresh (soundUnit name) (hostSoundDir ctx name + "/native") "--sound needs pipewire-pulse" (fun () ->
    let conf = hostSoundConf ctx name
    match soundStock ctx with
    | Error e -> Error e
    | Ok stock ->
      let written =
        [ Host.ensureDir (hostSoundDir ctx name)
          Host.ensureDir (conf + "/pipewire-pulse.conf.d")
          Host.copyFile (stock, conf + "/pipewire-pulse.conf")
          Host.writeFile (conf + "/pipewire-pulse.conf.d/securebox.conf", soundOverride ctx name) ]
      match List.tryFind Result.isError written with
      | Some (Error e) -> Error $"--sound: {e}"
      | _ -> Ok (soundStartArgs ctx name))

/// Stops a box's units, and with `gone` clears their place in the runtime directory.
let private unserve (ctx: Ctx) (name: string) (bus: bool) (sound: bool) (gone: bool) =
  if bus then Host.tool ("systemctl", unitStopArgs (busUnit name)) |> ignore
  if sound then Host.tool ("systemctl", unitStopArgs (soundUnit name)) |> ignore
  if gone && ctx.runtime <> "" && (bus || sound) then Host.removeTree (hostBoxDir ctx name)

/// The names a `--dbus` box was created with, read back from its label and checked again.
let private busNames (name: string) () : result<list<string>, string> =
  match podman (busLabelArgs name) $"cannot read the D-Bus names of the box '{name}'" with
  | Error e -> Error e
  | Ok label ->
    let names = List.filter (fun n -> n <> "") (String.split "," (String.trim label))
    if names <> [] && List.forall (fun n -> Result.isOk (busName n)) names then Ok names
    else Error $"the box '{name}' has no usable list of D-Bus names; create it again with --dbus"

/// The compositor's socket for `--wayland`, from where `$WAYLAND_DISPLAY` says it is: it
/// must be a socket, and in the session's runtime directory, whatever that variable says.
let wayland (ctx: Ctx) (given: string) : result<string, string> =
  let resolved = Host.realPath given
  if resolved = "" || not (Host.isSocket resolved) then Error $"--wayland: there is no compositor socket at {given}"
  else if ctx.runtime = "" || not (under (Host.realPath ctx.runtime) resolved) || Host.realPath ctx.runtime = resolved then
    Error $"--wayland: {resolved} is not in your session's runtime directory"
  else
    match mountable resolved with
    | Error e -> Error $"--wayland: {e}"
    | Ok socket -> Ok socket

/// Whether a share is still the directory it was when the box was created. podman resolves
/// a mount's source again at every start, and a box with a read-write share that holds
/// another box's share can put a link there in the meantime.
let private unchanged (ctx: Ctx) (path: string) : result<unit, string> =
  let now = Host.realPath path
  if now = path && Result.isOk (sharePath ctx path) then Ok ()
  else Error $"the shared directory '{path}' is not what it was when the box was created (it is now '{now}'): the box is not started. Remove the box and create it again"

/// Whether the shares asked for are still the directories that were checked when the
/// command line was read. Between that and `podman create`, which resolves each path
/// again, a running box with a read-write share around one of them can put a link there:
/// `recreate` narrowing a box's share to a directory inside it is that case.
let private settled (ctx: Ctx) (shares: list<Share>) : result<unit, string> =
  let moved (s: Share) = Host.realPath s.path <> s.path || Result.isError (sharePath ctx s.path)
  match List.tryFind moved shares with
  | Some s -> Error $"the shared directory '{s.path}' changed while the box was being made (it is now '{Host.realPath s.path}'): it is not shared, and no box is created"
  | None -> Ok ()

/// Where securebox keeps a copy of each file it exported from a box, by kind. It is the
/// list of what the box has on the host, and what tells that a file there is still the
/// one securebox wrote: only such a file is replaced or removed. A symbolic link is never
/// such a file, whatever it leads to: `cmp` would follow it.
let private keptDir (ctx: Ctx) (name: string) (kind: string) = $"{boxDir ctx name}/exports/{kind}"
let private places (ctx: Ctx) = [ ("bin", ctx.binDir); ("applications", ctx.appsDir) ]
let private asWritten (kept: string) (path: string) =
  Host.pathExists kept && Host.isFile path && Host.tool ("cmp", [ "--silent"; "--"; kept; path ]) = 0

/// Puts a file on the host with the permission bits `mode`. It is always created anew:
/// securebox's own earlier file is removed first, and anything else at the path, a
/// dangling symbolic link included, is an error and stays as it is.
let private put (ctx: Ctx) (name: string) (kind: string) (dir: string) (file: string) (text: string) (mode: int) : result<unit, string> =
  let kept = keptDir ctx name kind + "/" + file
  let path = dir + "/" + file
  let there = Host.entryExists path
  if there && not (asWritten kept path) then
    Error $"{path} is there already, and securebox did not write it or it was changed since: it is left alone"
  else
    let made = [ Host.ensureDir (keptDir ctx name kind); Host.ensureDir dir; Host.writeFile (kept, text) ]
    match List.tryFind Result.isError made with
    | Some (Error e) -> Error $"cannot export: {e}"
    | _ ->
      // the earlier file goes only now, with the new one about to be there
      if there then Host.removeFile path
      Result.mapError (fun e -> $"cannot export: {e}") (Host.createFile (path, text, mode))

/// Removes an exported file from the host if it is still as securebox wrote it; whether
/// it was.
let private take (ctx: Ctx) (name: string) (kind: string) (dir: string) (file: string) : bool =
  let kept = keptDir ctx name kind + "/" + file
  let path = dir + "/" + file
  let mine = asWritten kept path
  if mine then Host.removeFile path
  Host.removeTree kept
  mine

/// Removes everything exported from a box.
let private unexport (ctx: Ctx) (name: string) =
  List.iter (fun (kind, dir) -> List.iter (fun file -> take ctx name kind dir file |> ignore) (Host.listDir (keptDir ctx name kind))) (places ctx)

/// What an earlier box of the name left on the host ran in that box: a new box under the
/// name does not take its scripts and launchers over. (`recreate` makes the same box again,
/// and keeps them.)
let private disown (ctx: Ctx) (name: string) =
  if List.exists (fun (kind, _) -> Host.listDir (keptDir ctx name kind) <> []) (places ctx) then
    unexport ctx name
    Host.say $"removed what an earlier box named '{name}' had exported; export from this one what it should have"

/// One securebox at a time for a box, from here until this one ends or becomes podman:
/// a launcher's `enter` waits while `recreate` has the box stopped, and does not start it
/// again under it. Where there is no data directory there is no box to wait for.
let private alone (ctx: Ctx) (name: string) : result<unit, string> =
  if Host.dirExists ctx.dataDir then Host.lock $"{ctx.dataDir}/.locks/{name}" else Ok ()

/// What the session must have for the grants asked for, as far as it can be told without
/// starting anything: `recreate` asks before the box it would replace is touched.
let private provided (ctx: Ctx) (spec: CreateSpec) : result<unit, string> =
  let _ = (if spec.dbus = [] then Ok () else busUsable ctx)?
  let _ = (if spec.sound then Result.map (fun _ -> ()) (soundStock ctx) else Ok ())?
  match spec.wayland with
  | Some socket when not (Host.isSocket socket) -> Error $"--wayland: there is no compositor socket at {socket}"
  | _ -> Ok ()

/// Starts a box that was just created, and looks at it. `recreate` (`again`) removes one
/// that does not come up: the box it replaced is gone by then, and what it tells the user
/// to do next starts from no container of the name.
let private begun (ctx: Ctx) (name: string) (again: bool) : result<unit, string> =
  let up =
    match podman (startArgs name) $"the box '{name}' was created but did not start" with
    | Error e -> Error e
    | Ok _ -> settle ctx name
  if again && Result.isError up then Host.capture (rmArgs name) |> ignore
  up

/// What is wrong with a set of grants whatever the host has: checked before anything is
/// touched.
let private coherent (spec: CreateSpec) : result<unit, string> =
  let session = Option.isSome spec.wayland || spec.sound || spec.dbus <> []
  let _ = (together spec.shares)?
  // with labelling off for a session grant, the host's network namespace would also put
  // the session's abstract sockets (X11's, for one) in the box's reach
  if session && spec.network = HostNetwork then Error "--network host cannot be combined with --wayland, --sound or --dbus" else Ok ()

/// `create`, and the second half of `recreate` (`again`), which keeps what the box had
/// exported and leaves no container behind when the new one does not come up.
let private make (ctx: Ctx) (spec: CreateSpec) (again: bool) : result<int, string> =
  let _ = (coherent spec)?
  let _ = (Host.lock $"{ctx.dataDir}/.locks/{spec.name}")?
  // the name must be free before anything is started under it
  let found = (look ctx spec.name)?
  match found with
  | Ours _ -> Error $"there is already a box named '{spec.name}'"
  | Foreign -> Error $"there is already a container named '{spec.name}', which is not a box of securebox's"
  | Missing ->
    if not again then disown ctx spec.name
    let home = boxHome ctx spec.name
    let kept = Host.dirExists home
    let _ = (Host.ensureDir home)?
    // the filter and the front-end first: their directories are what the box mounts
    let made =
      result {
        let! _ = if spec.dbus = [] then Ok () else filtered ctx true spec.name (fun () -> Ok spec.dbus)
        let! _ = if spec.sound then fronted ctx true spec.name else Ok ()
        // last, with no box of this name left to move a share: `recreate` has removed it
        let! _ = settled ctx spec.shares
        let! _ = podman (createArgs ctx spec) $"podman could not create the box '{spec.name}'"
        return! begun ctx spec.name again
      }
    match made with
    | Error e ->
      // nothing is left running under the name of a box that wasn't made
      unserve ctx spec.name (spec.dbus <> []) spec.sound true
      Error e
    | Ok () ->
      // what it was made with, for whoever makes it again once the container is gone
      Host.writeFile (boxDir ctx spec.name + "/created", createLine spec + "\n") |> ignore
      Host.say (if kept then $"created the box '{spec.name}', with the home directory an earlier box of that name left"
                else $"created the box '{spec.name}'")
      Host.say $"enter it with: securebox enter {spec.name}"
      Ok 0

let create (ctx: Ctx) (spec: CreateSpec) : result<int, string> = make ctx spec false

/// The box, running: started if it was stopped, with what its grants need from the session.
let private ready (ctx: Ctx) (name: string) : result<BoxState, string> =
  let state = (find ctx name)?
  // what the session must have for the box's grants: the filter and the front-end always,
  // the compositor's socket to start it
  let _ = (if hasBus ctx state then filtered ctx false name (busNames name) else Ok ())?
  let _ = (if hasSound ctx state then fronted ctx false name else Ok ())?
  let changed = if state.running then [] else List.filter Result.isError (List.map (unchanged ctx) (shares ctx state))
  let lacking = if state.running then [] else List.filter (fun (_, path) -> not (Host.isSocket path)) (sessionNeeds ctx state)
  let started =
    match (changed, lacking) with
    | (Error e :: _, _) -> Error e
    | (_, (what, path) :: _) -> Error $"the box '{name}' was created with {what}, and {path} is not there: start it from your graphical session"
    | _ -> if state.running then Ok "" else podman (startArgs name) $"the box '{name}' did not start"
  let _ = started?
  Ok state

let enter (ctx: Ctx) (name: string) (root: bool) (cmd: list<string>) : result<int, string> =
  let _ = (alone ctx name)?
  let state = (ready ctx name)?
  Ok (Host.exec (execArgs ctx name root (sessionEnv ctx state) (workdir ctx (shares ctx state)) cmd))

let private exportOne (ctx: Ctx) (name: string) (item: Exports.Item) : result<unit, string> =
  match item with
  | Exports.Bin command ->
    match Host.inBox (hasCommandArgs name command) with
    | Ok r when r.code = 0 ->
      let file = Exports.scriptName command
      let _ = (put ctx name "bin" ctx.binDir file (Exports.script ctx.self name command) 493)?
      Host.say $"{ctx.binDir}/{file} runs {command} in the box '{name}'"
      Ok ()
    | _ -> Error $"the box '{name}' has no command '{command}'"
  | Exports.App id ->
    match Host.inBox (desktopFileArgs ctx name id) with
    | Ok r when r.code = 0 ->
      let made = (Exports.launcher id r.output)?
      let file = Exports.launcherName name id
      let _ = (put ctx name "applications" ctx.appsDir file (Exports.desktopFile ctx.self name made) 420)?
      Host.say $"'{name}: {made.title}' is in your desktop's menu: {ctx.appsDir}/{file}"
      Ok ()
    | _ -> Error $"the box '{name}' has no application '{id}': no {id}.desktop in its /usr/share/applications, /usr/local/share/applications or ~/.local/share/applications"

let private removeOne (ctx: Ctx) (name: string) (item: Exports.Item) : result<unit, string> =
  let (kind, dir, file) =
    match item with
    | Exports.Bin command -> ("bin", ctx.binDir, Exports.scriptName command)
    | Exports.App id -> ("applications", ctx.appsDir, Exports.launcherName name id)
  if take ctx name kind dir file then Ok ()
  else Error $"{dir}/{file} was not exported from the box '{name}', or was changed since: it is left alone"

let rec private each (f: Exports.Item -> result<unit, string>) (items: list<Exports.Item>) : result<int, string> =
  match items with
  | [] -> Ok 0
  | item :: rest ->
    let _ = (f item)?
    each f rest

/// Puts commands and applications of a box on the host, as a script and a launcher that
/// enter the box; with `delete`, removes them, or all of the box's when none is named.
let export (ctx: Ctx) (name: string) (items: list<Exports.Item>) (delete: bool) : result<int, string> =
  let _ = (alone ctx name)?
  if delete then
    if items = [] then
      unexport ctx name
      Host.say $"removed what was exported from the box '{name}'"
      Ok 0
    else each (removeOne ctx name) items
  else if items = [] then Error "export needs --bin or --app (see securebox export --help)"
  else if ctx.self = "" then Error "securebox is at a path that cannot be written into a launcher (a space in it, or another character with a meaning to a shell): move it"
  else
    let state = (ready ctx name)?
    // a launcher runs securebox by its path, on the host, for good: not a file the box can write
    if List.exists (fun dir -> under dir ctx.self) (boxHome ctx name :: shares ctx state) then
      Error $"securebox itself ({ctx.self}) is in a directory the box '{name}' has: what is exported would run a file the box can replace. Put securebox outside what the box is given"
    else each (exportOne ctx name) items

let list (uid: int) : result<int, string> =
  let boxes = (podman listArgs "podman could not list the boxes")?
  let names = listed boxes
  // ps says where things are mounted; whether that is a grant takes the mounts themselves
  let mounts = if names = [] then "" else Result.defaultValue "" (podman (listMountsArgs names) "")
  let table = (listing (withBus uid mounts) boxes)?
  Host.out table
  Ok 0

let stop (ctx: Ctx) (name: string) : result<int, string> =
  let _ = (alone ctx name)?
  let state = (find ctx name)?
  let stopped = if state.running then podman (stopArgs name) $"the box '{name}' did not stop" else Ok ""
  unserve ctx name (hasBus ctx state) (hasSound ctx state) false
  Result.map (fun _ -> 0) stopped

let private purged (ctx: Ctx) (name: string) (failure: string) : result<int, string> =
  // the image `recreate` kept the box's files in goes too, if there is one
  Host.capture (snapshotRmArgs name) |> ignore
  match podman (purgeArgs ctx name) failure with
  | Error e -> Error e
  | Ok _ ->
    Host.say $"removed the box '{name}' and deleted {boxDir ctx name}"
    Ok 0

let rm (ctx: Ctx) (name: string) (purge: bool) : result<int, string> =
  let _ = (alone ctx name)?
  let dir = boxDir ctx name
  match look ctx name with
  | Error e -> Error e
  | Ok Foreign -> Error (foreign name)
  | Ok Missing ->
    // the container is gone already (removed with podman, say): nothing stays running
    // under its name, and what it left can still be purged, when it is a box's
    unexport ctx name
    if ctx.runtime <> "" && Host.pathExists (hostBoxDir ctx name) then unserve ctx name true true true
    if purge && Host.dirExists (boxHome ctx name) then purged ctx name $"could not delete {dir}" else Error (missing name)
  | Ok (Ours state) ->
    match podman (rmArgs name) $"the box '{name}' was not removed" with
    | Error e -> Error e
    | Ok _ ->
      unserve ctx name (hasBus ctx state) (hasSound ctx state) true
      unexport ctx name
      if purge then purged ctx name $"the box is removed, but {dir} could not be deleted"
      else
        if Host.dirExists dir then
          Host.say $"removed the box '{name}'; its home directory is kept in {dir}, with the command that created it in {dir}/created (rm --purge deletes both)"
        Ok 0

/// The box again, from its own files and with the grants now given: it is stopped, kept as
/// an image, removed, and created from that image. What was installed in it stays, and so
/// do its home directory and what was exported from it; its grants are `spec`'s alone.
let recreate (ctx: Ctx) (spec: CreateSpec) : result<int, string> =
  let name = spec.name
  let image = snapshotImage name
  let _ = (coherent spec)?
  let _ = (alone ctx name)?
  let state = (find ctx name)?
  // what the session lacks for the new grants is found while there is still a box to keep
  let _ = (provided ctx spec)?
  let _ = (if state.running then podman (stopArgs name) $"the box '{name}' did not stop" else Ok "")?
  // stopped as `stop` stops it: its filter and its front-end with it
  unserve ctx name (hasBus ctx state) (hasSound ctx state) false
  // the box could move a share until here; found now, it costs nothing: the box is as it
  // was, stopped. `create` looks once more, when the box is gone
  let _ = (settled ctx spec.shares)?
  // ponytail: each recreate adds a layer to the image; commit with --squash if a box is
  // ever recreated by the hundred
  let _ = (podman (commitArgs name) $"the files of the box '{name}' could not be kept as an image: the box is as it was, stopped")?
  let _ = (podman (rmArgs name) $"the box '{name}' was not removed")?
  unserve ctx name (hasBus ctx state) (hasSound ctx state) true
  let lost = $"There is no box '{name}' now. What was installed in it is in the image {image}, and its home directory is kept: 'securebox create {name} {image}' with its grants makes it again (what it had exported is then exported again)"
  Result.mapError (fun e -> e + "\n" + lost) (make ctx { spec with image = image } true)
