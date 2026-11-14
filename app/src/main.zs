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
/// the box's passwd entry and its mounts.
let private context () : result<Ctx, string> =
  let user = (Box.userName (env "USER"))?
  let home = (Result.mapError (fun e -> $"HOME: {e}") (Box.mountable (env "HOME")))?
  // SECUREBOX_DATA, else securebox/ in the XDG data directory
  let data =
    match (Environment.getVariable "SECUREBOX_DATA", Environment.getVariable "XDG_DATA_HOME") with
    | (Some d, _) when Path.isAbsolute d -> d
    | (_, Some d) when Path.isAbsolute d -> d + "/securebox"
    | _ -> home + "/.local/share/securebox"
  let dataDir = (Result.mapError (fun e -> $"the data directory: {e}") (Box.mountable (Path.getFullPath data)))?
  let shell = Path.getFileName (env "SHELL")
  let plain c = Char.isLetterOrDigit c || c = '-' || c = '_'
  Ok { user = user; uid = Posix.userId (); gid = Posix.groupId (); home = Path.getFullPath home
       dataDir = dataDir; cwd = Environment.currentDirectory ()
       shell = if shell <> "" && List.forall plain (String.chars shell) then shell else "sh"
       tty = Posix.isTerminal 0 && Posix.isTerminal 1
       passEnv = List.filter (fun v -> Option.isSome (Environment.getVariable v)) [ "TERM"; "COLORTERM"; "LANG"; "LC_ALL" ] }

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
    let path = (Box.sharePath ctx p)?
    createSpec ctx { spec with shares = List.append spec.shares [ { path = path; readOnly = false } ] } rest
  | Cli.Create.ShareRo p :: rest ->
    let path = (Box.sharePath ctx p)?
    createSpec ctx { spec with shares = List.append spec.shares [ { path = path; readOnly = true } ] } rest
  | Cli.Create.Network n :: rest ->
    let net = (Box.network n)?
    createSpec ctx { spec with network = net } rest
  | Cli.Create.Publish p :: rest ->
    let port = (Box.publish p)?
    createSpec ctx { spec with publish = List.append spec.publish [ port ] } rest
  | Cli.Create.Gpu :: rest -> createSpec ctx { spec with gpu = true } rest

/// The box a command names, checked.
let private named (command: string) (names: list<string>) : result<string, string> =
  match names with
  | n :: _ -> Box.boxName n
  | [] -> Error $"{command} needs the name of a box (see securebox {command} --help)"

let private run (ctx: Ctx) (cmd: Cli.Command) : result<int, string> =
  match cmd with
  | Cli.Create args ->
    let spec = (createSpec ctx { name = ""; image = Box.defaultImage } args)?
    Commands.create ctx spec
  | Cli.Enter args ->
    let name = (named "enter" (List.choose (fun a -> match a with
                                                      | Cli.Enter.Name n -> Some n
                                                      | _ -> None) args))?
    let cmd = List.collect (fun a -> match a with
                                     | Cli.Enter.Cmd c -> c
                                     | _ -> []) args
    Commands.enter ctx name (List.contains Cli.Enter.Root args) cmd
  | Cli.List -> Commands.list ()
  | Cli.Stop args ->
    let name = (named "stop" (List.map (fun (Cli.Stop.Name n) -> n) args))?
    Commands.stop name
  | Cli.Rm args ->
    let name = (named "rm" (List.choose (fun a -> match a with
                                                   | Cli.Rm.Name n -> Some n
                                                   | _ -> None) args))?
    Commands.rm ctx name (List.contains Cli.Rm.Purge args)

let main () =
  let args = Environment.args ()
  if Posix.effectiveUserId () = 0 then
    fail "refusing to run as root: boxes are rootless"
  else
    match commandLine (if args = [] then [ "--help" ] else args) with
    | Error (Help text) ->
      print text
      0
    | Error (Invalid msg) -> fail $"{msg} (see --help)"
    | Ok [ cmd ] ->
      match context () with
      | Error e -> fail e
      | Ok ctx ->
        match Effects.real (fun () -> run ctx cmd) with
        | Ok code -> code
        | Error e -> fail e
    | Ok _ -> fail "one command at a time (see --help)"
