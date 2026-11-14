// securebox: persistent boxes on rootless podman that see nothing of the host unless it is
// shared with them. DESIGN.md has the design.
open Argz
open Box

let private fail (msg: string) =
  eprintln $"securebox: {msg}"
  125

let private commandLine args : result<list<Cli.Command>, ArgError> = Argz.parse Cli.spec "securebox" args

let private env (name: string) = Option.defaultValue "" (Environment.getVariable name)

/// What the commands need from the environment, checked: the user's name and home go into
/// the box's passwd entry and its mounts. The name is the passwd database's, not `$USER`,
/// which may be stale or unset.
let private context () : result<Ctx, string> =
  let entry = Posix.userName ()
  let user = (Box.userName (if entry <> "" then entry else env "USER"))?
  let entryHome = Posix.userHome ()
  let asked = if env "HOME" <> "" then env "HOME" else entryHome
  let checked = (Result.mapError (fun e -> $"HOME: {e}") (Box.homePath asked))?
  let home = Path.getFullPath checked
  let named = List.filter (fun d -> d <> "") >> List.distinct
  let homes = named [ home; Posix.realPath home; entryHome; Posix.realPath entryHome ]
  // SECUREBOX_DATA, else securebox/ in the XDG data directory
  let data =
    match (Environment.getVariable "SECUREBOX_DATA", Environment.getVariable "XDG_DATA_HOME") with
    | (Some d, _) when Path.isAbsolute d -> d
    | (_, Some d) when Path.isAbsolute d -> d + "/securebox"
    | _ -> home + "/.local/share/securebox"
  let dataDir = (Result.mapError (fun e -> $"the data directory: {e}") (Box.dataPath homes (Path.getFullPath data)))?
  // and not through a link either, once it exists
  let resolved = Posix.realPath dataDir
  let _ = (Result.mapError (fun e -> $"the data directory: {e}") (if resolved = "" then Ok dataDir else Box.dataPath homes resolved))?
  let runtime = env "XDG_RUNTIME_DIR"
  let exe = Posix.realPath "/proc/self/exe"
  let apps =
    match Environment.getVariable "XDG_DATA_HOME" with
    | Some d when Path.isAbsolute d -> Path.getFullPath d + "/applications"
    | _ -> home + "/.local/share/applications"
  let shell = Path.getFileName (env "SHELL")
  let plain c = Char.isLetterOrDigit c || c = '-' || c = '_'
  Ok { user = user; uid = Posix.userId (); gid = Posix.groupId (); home = home; homes = homes
       dataDir = dataDir
       offLimits = named [ dataDir; Posix.realPath dataDir; (if Path.isAbsolute runtime then Path.getFullPath runtime else ""); Posix.realPath runtime ]
       runtime = (if Path.isAbsolute runtime && Result.isOk (Box.runtimePath (Path.getFullPath runtime)) then Path.getFullPath runtime else "")
       busAddress = env "DBUS_SESSION_BUS_ADDRESS"
       cwd = Environment.currentDirectory ()
       shell = if shell <> "" && List.forall plain (String.chars shell) then shell else "sh"
       tty = Posix.isTerminal 0 && Posix.isTerminal 1
       passEnv = List.filter (fun v -> Option.isSome (Environment.getVariable v)) [ "TERM"; "COLORTERM"; "LANG"; "LC_ALL" ]
       self = (if Exports.inertPath exe then exe else "")
       binDir = home + "/.local/bin"
       appsDir = apps }

/// The GPU's render nodes: what computing and rendering need, without the display's own.
let private renderDevices () : result<list<string>, string> =
  let nodes =
    match Directory.list "/dev/dri" with
    | Ok names -> List.filter (String.startsWith "renderD") names
    | Error _ -> []
  if nodes = [] then Error "--gpu: there is no render device in /dev/dri" else Ok (List.map (fun n -> "/dev/dri/" + n) nodes)

/// The compositor's socket: `$WAYLAND_DISPLAY`, in `$XDG_RUNTIME_DIR` unless it is a path.
let private waylandSocket () : result<string, string> =
  let display = if env "WAYLAND_DISPLAY" <> "" then env "WAYLAND_DISPLAY" else "wayland-0"
  let runtime = env "XDG_RUNTIME_DIR"
  if Path.isAbsolute display then Box.mountable (Path.getFullPath display)
  else if Path.isAbsolute runtime then Box.mountable (Path.getFullPath (runtime + "/" + display))
  else Error "--wayland: XDG_RUNTIME_DIR is not set, so the compositor's socket cannot be found"

let rec private createSpec (ctx: Ctx) (spec: CreateSpec) (args: list<Cli.Create.Arg>) : result<CreateSpec, string> =
  match args with
  | [] -> if spec.name = "" then Error "create needs a name for the box (see securebox create --help)" else Ok spec
  | Cli.Create.Name n :: rest ->
    let name = (Box.boxName n)?
    createSpec ctx { spec with name = name } rest
  | Cli.Create.Image i :: rest ->
    let image = (Box.image i)?
    createSpec ctx { spec with image = image } rest
  | Cli.Create.Share p :: rest ->
    let share = (Commands.share ctx p false)?
    createSpec ctx { spec with shares = List.append spec.shares [ share ] } rest
  | Cli.Create.ShareRo p :: rest ->
    let share = (Commands.share ctx p true)?
    createSpec ctx { spec with shares = List.append spec.shares [ share ] } rest
  | Cli.Create.Network n :: rest ->
    let net = (Box.network n)?
    createSpec ctx { spec with network = net } rest
  | Cli.Create.Publish p :: rest ->
    let port = (Box.publish p)?
    createSpec ctx { spec with publish = List.append spec.publish [ port ] } rest
  | Cli.Create.Gpu :: rest ->
    let devices = (renderDevices ())?
    createSpec ctx { spec with devices = devices } rest
  | Cli.Create.Wayland :: rest ->
    let named = (waylandSocket ())?
    let socket = (Commands.wayland ctx named)?
    createSpec ctx { spec with wayland = Some socket } rest
  | Cli.Create.Sound :: rest -> createSpec ctx { spec with sound = true } rest
  | Cli.Create.Dbus n :: rest ->
    let name = (Box.busName n)?
    createSpec ctx { spec with dbus = List.append spec.dbus [ name ] } rest

/// The variables `enter -e` sets. One given by name alone must be set here: podman takes
/// its value from the environment.
let rec private enterEnv (args: list<Cli.Enter.Arg>) : result<list<string>, string> =
  match args with
  | [] -> Ok []
  | Cli.Enter.Env given :: rest ->
    let checked = (Box.envVar given)?
    let _ = (if String.contains "=" checked || Option.isSome (Environment.getVariable checked) then Ok () else Error $"-e {checked}: {checked} is not set here")?
    let more = (enterEnv rest)?
    Ok (checked :: more)
  | _ :: rest -> enterEnv rest

let rec private exportItems (args: list<Cli.Export.Arg>) : result<list<Exports.Item>, string> =
  match args with
  | [] -> Ok []
  | Cli.Export.Bin given :: rest ->
    let program = (Exports.program given)?
    let more = (exportItems rest)?
    Ok (Exports.Bin program :: more)
  | Cli.Export.App given :: rest ->
    let application = (Exports.application given)?
    let more = (exportItems rest)?
    Ok (Exports.App application :: more)
  | _ :: rest -> exportItems rest

/// The box a command names, checked.
let private named (command: string) (names: list<string>) : result<string, string> =
  match names with
  | n :: _ -> Box.boxName n
  | [] -> Error $"{command} needs the name of a box (see securebox {command} --help)"

let private run (cmd: Cli.Command) : result<int, string> =
  match cmd with
  | Cli.Version ->
    println $"securebox {Cli.version}"
    Ok 0
  | Cli.List -> Commands.list (Posix.userId ())
  | Cli.Create args ->
    let ctx = (context ())?
    let spec = (createSpec ctx { name = ""; image = Box.defaultImage } args)?
    Commands.create ctx spec
  | Cli.Enter args ->
    let ctx = (context ())?
    let name = (named "enter" (List.choose (fun a -> match a with
                                                      | Cli.Enter.Name n -> Some n
                                                      | _ -> None) args))?
    let cmd = List.collect (fun a -> match a with
                                     | Cli.Enter.Cmd c -> c
                                     | _ -> []) args
    let vars = (enterEnv args)?
    Commands.enter { ctx with passEnv = List.append ctx.passEnv vars } name (List.contains Cli.Enter.Root args) cmd
  | Cli.Stop args ->
    let ctx = (context ())?
    let name = (named "stop" (List.map (fun (Cli.Stop.Name n) -> n) args))?
    Commands.stop ctx name
  | Cli.Rm args ->
    let ctx = (context ())?
    let name = (named "rm" (List.choose (fun a -> match a with
                                                   | Cli.Rm.Name n -> Some n
                                                   | _ -> None) args))?
    Commands.rm ctx name (List.contains Cli.Rm.Purge args)
  | Cli.Recreate args ->
    let ctx = (context ())?
    let name = (named "recreate" (List.choose (fun a -> match a with
                                                         | Cli.Recreate.Name n -> Some n
                                                         | _ -> None) args))?
    // the image is the box's own files: `recreate` names it
    let spec = (createSpec ctx { name = name; image = "" } (List.map Cli.Recreate.asCreate args))?
    Commands.recreate ctx spec
  | Cli.Export args ->
    let ctx = (context ())?
    let name = (named "export" (List.choose (fun a -> match a with
                                                       | Cli.Export.Name n -> Some n
                                                       | _ -> None) args))?
    let items = (exportItems args)?
    Commands.export ctx name items (List.contains Cli.Export.Delete args)

let main () =
  let args = Environment.args ()
  if Posix.effectiveUserId () = 0 then
    fail "refusing to run as root: boxes are rootless"
  else if env "CONTAINER_HOST" <> "" || env "CONTAINER_CONNECTION" <> "" then
    // podman would then talk to a service elsewhere, where these paths mean something else
    fail "CONTAINER_HOST or CONTAINER_CONNECTION is set: securebox works with the local podman only"
  else
    match commandLine (if args = [] then [ "--help" ] else args) with
    | Error (Help text) ->
      print text
      0
    | Error (Invalid msg) -> fail $"{msg} (see --help)"
    | Ok [ cmd ] ->
      match Effects.real (fun () -> run cmd) with
      | Ok code -> code
      | Error e -> fail e
    | Ok _ -> fail "one command at a time (see --help)"
