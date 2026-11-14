// What a box is made from, and the checks on everything the user types: these strings end up
// in podman's arguments and in host paths. DESIGN.md, section 5.

type Network =
  | Private
  | NoNetwork
  | HostNetwork

type Share = { path: string; readOnly: bool }

/// What `create` was asked for, validated.
type CreateSpec =
  { name: string
    image: string
    shares: list<Share> = []
    network: Network = Private
    publish: list<string> = []
    gpu: bool = false }

/// What securebox reads from its environment, once.
type Ctx =
  { user: string
    uid: int
    gid: int
    home: string
    /// Where the boxes' home directories are kept.
    dataDir: string
    cwd: string
    /// The name of the user's shell (`zsh`), looked for in the box.
    shell: string
    /// Whether standard input and output are a terminal.
    tty: bool
    /// The environment variables to pass into the box, of those that are set.
    passEnv: list<string> }

let defaultImage = "registry.fedoraproject.org/fedora:latest"

let private isControl (c: char) = int c < 32 || int c = 127

let private isNameChar (c: char) = Char.isLower c || Char.isDigit c || c = '_' || c = '.' || c = '-'

/// A box name: it is a container name, a host name and a directory name.
let boxName (s: string) : result<string, string> =
  let cs = String.chars s
  match cs with
  | first :: _ when (Char.isLower first || Char.isDigit first) && List.length cs <= 63 && List.forall isNameChar cs -> Ok s
  | _ -> Error $"'{s}' is not a box name: use lowercase letters, digits, '_', '.' and '-', starting with a letter or a digit, at most 63 characters"

/// An image reference: podman checks the rest, but it must not read as an option.
let image (s: string) : result<string, string> =
  if s = "" || String.startsWith "-" s || List.exists (fun c -> isControl c || c = ' ') (String.chars s) then
    Error $"'{s}' is not an image name"
  else
    Ok s

/// A user name, as it goes into the box's passwd entry.
let userName (s: string) : result<string, string> =
  let ok c = Char.isLetterOrDigit c || c = '_' || c = '.' || c = '-'
  if s <> "" && not (String.startsWith "-" s) && List.forall ok (String.chars s) then Ok s
  else Error $"the user name '{s}' cannot be used in a box"

/// A path that can be written into a `--mount` option and a passwd entry.
let mountable (path: string) : result<string, string> =
  if not (Path.isAbsolute path) then Error $"'{path}' is not an absolute path"
  else if List.exists (fun c -> isControl c || c = ',' || c = ':') (String.chars path) then
    Error $"'{path}' has a comma, a colon or a control character, which a mount cannot be written with"
  else Ok path

/// Whether `path` is `dir` or inside it.
let private under (dir: string) (path: string) = dir = "/" || path = dir || String.startsWith (dir + "/") path

/// A directory to share: made absolute, and refused where sharing it would hand over the
/// host (the home directory or what holds it, system directories, dot-directories of the
/// home). The check is on the text of the path: it stops mistakes, not symbolic links.
let sharePath (ctx: Ctx) (given: string) : result<string, string> =
  let path = Path.getFullPath (if Path.isAbsolute given then given else Path.combine ctx.cwd given)
  let refuse why = Error $"refusing to share '{path}': {why}"
  match mountable path with
  | Error e -> Error e
  | Ok _ ->
    if under path ctx.home then
      refuse "it is your home directory or contains it; share a directory inside it"
    else if List.exists (fun d -> under d path) [ "/etc"; "/usr"; "/boot"; "/dev"; "/proc"; "/sys" ] || path = "/var" || path = "/run" then
      refuse "it is a system directory"
    else if String.startsWith (ctx.home + "/.") path then
      refuse "dot-directories of your home hold credentials and host configuration"
    else
      Ok path

let network (s: string) : result<Network, string> =
  match s with
  | "private" -> Ok Private
  | "none" -> Ok NoNetwork
  | "host" -> Ok HostNetwork
  | _ -> Error $"'{s}' is not a network: use private, none or host"

let private port (s: string) =
  match String.parseInt s with
  | Some n when n >= 1 && n <= 65535 && List.forall Char.isDigit (String.chars s) -> true
  | _ -> false

let private ipv4 (s: string) =
  let parts = String.split "." s
  let octet p =
    match String.parseInt p with
    | Some n -> n >= 0 && n <= 255 && List.forall Char.isDigit (String.chars p)
    | None -> false
  List.length parts = 4 && List.forall octet parts

/// A published port, `[IP:]HOST:BOX[/tcp|/udp]`, as podman takes it. Without an address it
/// is bound to 127.0.0.1: podman's own default is every interface.
let publish (s: string) : result<string, string> =
  let bad = Error $"'{s}' is not a port to publish: write [IP:]HOST:BOX, with /udp for UDP"
  let (ports, proto) =
    match String.split "/" s with
    | [ p ] -> (p, Some "")
    | [ p; "tcp" ] -> (p, Some "/tcp")
    | [ p; "udp" ] -> (p, Some "/udp")
    | _ -> (s, None)
  match (String.split ":" ports, proto) with
  | ([ host; box ], Some suffix) when port host && port box -> Ok $"127.0.0.1:{host}:{box}{suffix}"
  | ([ ip; host; box ], Some suffix) when ipv4 ip && port host && port box -> Ok $"{ip}:{host}:{box}{suffix}"
  | _ -> bad
