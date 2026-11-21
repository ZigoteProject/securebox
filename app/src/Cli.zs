// The command line: one union per command, and the commands themselves. DESIGN.md, section 3,
// has what each grant means.
open Argz

/// The release this is; app/zs.toml says the same (tests/e2e.sh checks that it does).
let version = "0.2.0"

module Create =
  [<Derive(Arg)>]
  type Arg =
    | Name of string
    | Image of string
    | Share of string
    | ShareRo of string
    | Network of string
    | Publish of string
    | Gpu
    | Kvm
    | Wayland
    | Sound
    | Dbus of string
    | PidsLimit of int
    | ShmSize of string

  let spec a =
    match a with
    | Name _ -> { help = "name of the new box"; kind = Positional }
    | Image _ -> { help = "image to create it from (default: Fedora)"; kind = Positional }
    | Share _ -> { help = "share a host directory read-write, at the same path (repeatable)"; short = Some 's' }
    | ShareRo _ -> { help = "share a host directory read-only (repeatable)" }
    | Network _ -> { help = "private (the default: outbound only), none or host" }
    | Publish _ -> { help = "publish a port, [IP:]HOST:BOX[/udp]; on 127.0.0.1 unless IP is given (repeatable)"; short = Some 'p' }
    | Gpu -> { help = "give the box the GPU's render devices (/dev/dri/renderD*)" }
    | Kvm -> { help = "give the box /dev/kvm, for virtual machines and the Android emulator" }
    | Wayland -> { help = "let GUI programs reach the Wayland compositor; SELinux confinement is off for such a box" }
    | Sound -> { help = "let programs play and record sound (PulseAudio socket); SELinux confinement off, as for --wayland" }
    | Dbus _ -> { help = "let the box talk to this session-bus name, through a filter (repeatable); SELinux confinement off" }
    | PidsLimit _ -> { help = "how many processes and threads the box may have at once (podman's default: 2048)" }
    | ShmSize _ -> { help = "the size of the box's /dev/shm, as 512m or 4g (podman's default: 64m)" }

module Recreate =
  [<Derive(Arg)>]
  type Arg =
    | Name of string
    | Share of string
    | ShareRo of string
    | Network of string
    | Publish of string
    | Gpu
    | Kvm
    | Wayland
    | Sound
    | Dbus of string
    | PidsLimit of int
    | ShmSize of string

  /// The grants are `create`'s, and so is what is said about them.
  let asCreate a =
    match a with
    | Name n -> Create.Name n
    | Share p -> Create.Share p
    | ShareRo p -> Create.ShareRo p
    | Network n -> Create.Network n
    | Publish p -> Create.Publish p
    | Gpu -> Create.Gpu
    | Kvm -> Create.Kvm
    | Wayland -> Create.Wayland
    | Sound -> Create.Sound
    | Dbus n -> Create.Dbus n
    | PidsLimit n -> Create.PidsLimit n
    | ShmSize s -> Create.ShmSize s

  let spec a =
    match a with
    | Name _ -> { help = "name of the box"; kind = Positional }
    | _ -> Create.spec (asCreate a)

module Enter =
  [<Derive(Arg)>]
  type Arg =
    | Name of string
    | Root
    | Env of string
    | Cmd of list<string>

  let spec a =
    match a with
    | Name _ -> { help = "name of the box"; kind = Positional }
    | Root -> { help = "enter as root, to install packages" }
    | Env _ -> { help = "set a variable in the box: NAME=VALUE, or NAME for the value it has here (repeatable)"; short = Some 'e' }
    | Cmd _ -> { help = "command to run instead of a shell (after --)"; kind = Positional }

module Export =
  [<Derive(Arg)>]
  type Arg =
    | Name of string
    | Bin of string
    | App of string
    | Delete

  let spec a =
    match a with
    | Name _ -> { help = "name of the box"; kind = Positional }
    | Bin _ -> { help = "a command of the box's, by name or path: a script in ~/.local/bin runs it in the box (repeatable)" }
    | App _ -> { help = "an application of the box's, by the name of its .desktop file: a launcher in your desktop's menu (repeatable)" }
    | Delete -> { help = "remove what was exported: the ones named, or all of the box's" }

module Stop =
  [<Derive(Arg)>]
  type Arg =
    | Name of string

  let spec a =
    match a with
    | Name _ -> { help = "name of the box"; kind = Positional }

module Rm =
  [<Derive(Arg)>]
  type Arg =
    | Name of string
    | Purge

  let spec a =
    match a with
    | Name _ -> { help = "name of the box"; kind = Positional }
    | Purge -> { help = "delete the box's home directory too" }

[<Derive(Arg)>]
type Command =
  | Create of list<Create.Arg>
  | Enter of list<Enter.Arg>
  | List
  | Stop of list<Stop.Arg>
  | Rm of list<Rm.Arg>
  | Recreate of list<Recreate.Arg>
  | Export of list<Export.Arg>
  | Version

let spec a =
  match a with
  | Create _ -> Argz.command "create a box" Create.spec
  | Enter _ -> Argz.command "open a shell in a box, or run a command in it" Enter.spec
  | List -> { help = "list the boxes"; kind = Command }
  | Stop _ -> Argz.command "stop a box" Stop.spec
  | Rm _ -> Argz.command "remove a box; its home directory is kept" Rm.spec
  | Recreate _ -> Argz.command "make a box again with other grants; what was installed in it is kept" Recreate.spec
  | Export _ -> Argz.command "put a box's commands and applications on the host, as launchers" Export.spec
  | Version -> { help = "show the version" }
