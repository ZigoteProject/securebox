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
    /// The GPU's render devices (`--gpu`).
    devices: list<string> = []
    /// The compositor's socket on the host (`--wayland`).
    wayland: option<string> = None
    /// The directory of the sound server's PulseAudio socket on the host (`--sound`).
    sound: option<string> = None
    /// The names on the session bus the box may talk to (`--dbus`).
    dbus: list<string> = [] }

/// What securebox reads from its environment, once.
type Ctx =
  { user: string
    uid: int
    gid: int
    /// `$HOME`: where the box's own home directory is mounted.
    home: string
    /// Every way the home directory is named: `$HOME`, the passwd entry's, and both with
    /// their symbolic links resolved.
    homes: list<string>
    /// Where the boxes' home directories are kept.
    dataDir: string
    /// Directories no share may be, hold or be inside: securebox's data and the session's
    /// runtime directory.
    offLimits: list<string>
    /// The session's runtime directory on the host (`$XDG_RUNTIME_DIR`), "" when there is none.
    runtime: string
    /// The session bus's address (`$DBUS_SESSION_BUS_ADDRESS`), "" when there is none.
    busAddress: string
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

/// The home directory: it is also written into a sed script that fixes the box's passwd
/// entry, where `|`, `&` and `\` have a meaning.
let homePath (path: string) : result<string, string> =
  match mountable path with
  | Error e -> Error e
  | Ok _ ->
    if List.exists (fun c -> c = '|' || c = '&' || c = '\\') (String.chars path) then
      Error $"'{path}' has a '|', '&' or '\\', which the box's passwd entry cannot be written with"
    else Ok path

/// Whether `path` is `dir` or inside it.
let under (dir: string) (path: string) = dir = "/" || path = dir || String.startsWith (dir + "/") path

/// Where the boxes' data may be kept: not the home directory or what holds it, which
/// `rm --purge` would then be one mistyped name away from deleting.
let dataPath (homes: list<string>) (path: string) : result<string, string> =
  match mountable path with
  | Error e -> Error e
  | Ok _ ->
    if List.exists (fun h -> under path h) homes then
      Error $"'{path}' is your home directory or holds it: keep the boxes' data in a directory of its own"
    else Ok path

/// What the user typed for a share, made absolute. An empty path is a mistake (an unset
/// variable), not the working directory.
let absolutePath (ctx: Ctx) (given: string) : result<string, string> =
  if given = "" then Error "an empty path cannot be shared"
  else if Path.isAbsolute given then Ok (Path.getFullPath given)
  else if Path.isAbsolute ctx.cwd then Ok (Path.getFullPath (Path.combine ctx.cwd given))
  else Error $"cannot tell where '{given}' is: the working directory is gone"

/// Whether a directory may be shared. `path` is absolute with its symbolic links resolved,
/// so a link to the home directory is the home directory here. Refused: the home directory
/// and what holds it, system directories, securebox's data, the session's runtime
/// directory, and dot-directories of the home.
let sharePath (ctx: Ctx) (path: string) : result<string, string> =
  let refuse why = Error $"refusing to share '{path}': {why}"
  match mountable path with
  | Error e -> Error e
  | Ok _ ->
    if List.exists (fun h -> under path h) ctx.homes then
      refuse "it is your home directory or contains it; share a directory inside it"
    else if List.exists (fun d -> under d path) [ "/etc"; "/usr"; "/boot"; "/dev"; "/proc"; "/sys"; "/root"; "/run/user"; "/var/lib"; "/var/log" ]
            || List.contains path [ "/var"; "/run"; "/tmp"; "/var/tmp" ] then
      refuse "it is a system directory"
    else if List.exists (fun d -> under d path || under path d) ctx.offLimits then
      refuse "it is, holds or is inside securebox's data or your session's runtime directory"
    else if List.exists (fun h -> String.startsWith (h + "/.") path) ctx.homes then
      refuse "dot-directories of your home hold credentials and host configuration"
    else
      Ok path

/// A name on the session bus the box may talk to: a well-known name, written out (no
/// wildcard), and not one of those that run commands on the host for whoever asks.
let busName (s: string) : result<string, string> =
  let element (e: string) =
    match String.chars e with
    | first :: rest -> (Char.isLetter first || first = '_') && List.forall (fun c -> Char.isLetterOrDigit c || c = '_' || c = '-') rest
    | [] -> false
  let elements = String.split "." s
  if List.length elements < 2 || String.length s > 255 || not (List.forall element elements) then
    Error $"'{s}' is not a name on the session bus: write one out, as org.freedesktop.Notifications"
  else if List.contains s [ "org.freedesktop.systemd1"; "org.freedesktop.Flatpak"; "org.freedesktop.DBus" ] then
    Error $"refusing to let a box talk to {s}: it runs commands on the host for whoever asks"
  else Ok s

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
