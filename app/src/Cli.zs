// The command line: one union per command, and the commands themselves. DESIGN.md, section 3,
// has what each grant means.
open Argz

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

  let spec a =
    match a with
    | Name _ -> { help = "name of the new box"; kind = Positional }
    | Image _ -> { help = "image to create it from (default: Fedora)"; kind = Positional }
    | Share _ -> { help = "share a host directory read-write, at the same path (repeatable)"; short = Some 's' }
    | ShareRo _ -> { help = "share a host directory read-only (repeatable)" }
    | Network _ -> { help = "private (the default: outbound only), none or host" }
    | Publish _ -> { help = "publish a port, [IP:]HOST:BOX[/udp]; on 127.0.0.1 unless IP is given (repeatable)"; short = Some 'p' }
    | Gpu -> { help = "give the box the GPU's render devices (/dev/dri)" }

module Enter =
  [<Derive(Arg)>]
  type Arg =
    | Name of string
    | Root
    | Cmd of list<string>

  let spec a =
    match a with
    | Name _ -> { help = "name of the box"; kind = Positional }
    | Root -> { help = "enter as root, to install packages" }
    | Cmd _ -> { help = "command to run instead of a shell (after --)"; kind = Positional }

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

let spec a =
  match a with
  | Create _ -> Argz.command "create a box" Create.spec
  | Enter _ -> Argz.command "open a shell in a box, or run a command in it" Enter.spec
  | List -> { help = "list the boxes"; kind = Command }
  | Stop _ -> Argz.command "stop a box" Stop.spec
  | Rm _ -> Argz.command "remove a box; its home directory is kept" Rm.spec
