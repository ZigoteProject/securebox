open Testing
open Argz

[<Derive(Arg)>]
type CreateArg =
  | Name of string
  | Image of string
  | Share of string
  | ShareRo of string
  | Jobs of int
  | Verbose

let createSpec a =
  match a with
  | Name _ -> { help = "name of the box"; kind = Positional }
  | Image _ -> { help = "image to create it from"; kind = Positional }
  | Share _ -> { help = "share a directory read-write"; short = Some 's' }
  | ShareRo _ -> { help = "share a directory read-only" }
  | Jobs _ -> { help = "how many jobs" }
  | Verbose -> { help = "say more"; short = Some 'v' }

[<Derive(Arg)>]
type EnterArg =
  | Box of string
  | Root
  | Cmd of list<string>

let enterSpec a =
  match a with
  | Box _ -> { help = "name of the box"; kind = Positional }
  | Root -> { help = "enter as root" }
  | Cmd _ -> { help = "command to run instead of a shell"; kind = Positional }

[<Derive(Arg)>]
type Command =
  | Create of list<CreateArg>
  | Enter of list<EnterArg>
  | List

let commandSpec a =
  match a with
  | Create _ -> Argz.command "create a box" createSpec
  | Enter _ -> Argz.command "enter a box" enterSpec
  | List -> { help = "list boxes"; kind = Command }

module Inner =
  [<Derive(Arg)>]
  type Arg =
    | DeepDown of string

  let spec a =
    match a with
    | DeepDown _ -> { help = "a case in a nested module" }

let inner (args: list<string>) : result<list<Inner.Arg>, ArgError> = Argz.parse Inner.spec "prog" args

let create (args: list<string>) : result<list<CreateArg>, ArgError> = Argz.parse createSpec "prog" args
let top (args: list<string>) : result<list<Command>, ArgError> = Argz.parse commandSpec "prog" args

[<Tests>]
let tests =
  testList "argz" [
    test "kebab" (fun () -> assert (Argz.kebab "ShareRo" = "share-ro" && Argz.kebab "Name" = "name"))
    test "flags, positionals, short, inline value" (fun () ->
      assert (create [ "dev"; "--share"; "/a"; "-s"; "/b"; "--share-ro=/c"; "fedora"; "-v"; "--jobs"; "4" ]
              = Ok [ Name "dev"; Share "/a"; Share "/b"; ShareRo "/c"; Image "fedora"; Verbose; Jobs 4 ]))
    test "a union in another module" (fun () ->
      assert (inner [ "--deep-down"; "x" ] = Ok [ Inner.DeepDown "x" ]))
    test "empty" (fun () -> assert (create [] = Ok []))
    test "unknown option" (fun () -> assert (create [ "--nope" ] = Error (Invalid "unknown option --nope")))
    test "missing value" (fun () -> assert (create [ "--share" ] = Error (Invalid "--share: missing value")))
    test "not a number" (fun () ->
      assert (create [ "--jobs"; "x" ] = Error (Invalid "--jobs: expected a number, got 'x'")))
    test "switch with a value" (fun () ->
      assert (create [ "--verbose=1" ] = Error (Invalid "--verbose takes no value")))
    test "too many positionals" (fun () ->
      assert (create [ "a"; "b"; "c" ] = Error (Invalid "unexpected argument 'c'")))
    test "after -- everything is positional" (fun () ->
      assert (create [ "--"; "--share" ] = Ok [ Name "--share" ]))
    test "subcommand" (fun () ->
      assert (top [ "create"; "dev"; "-s"; "/a" ] = Ok [ Create [ Name "dev"; Share "/a" ] ]))
    test "subcommand without arguments" (fun () -> assert (top [ "list" ] = Ok [ List ]))
    test "unknown subcommand" (fun () ->
      assert (top [ "nope" ] = Error (Invalid "unexpected argument 'nope'")))
    test "a list positional takes the rest, options included" (fun () ->
      assert (top [ "enter"; "web"; "--root"; "--"; "npm"; "test"; "--watch" ]
              = Ok [ Enter [ Box "web"; Root; Cmd [ "npm"; "test"; "--watch" ] ] ])
      assert (top [ "enter"; "web"; "ls"; "-la" ] = Ok [ Enter [ Box "web"; Cmd [ "ls"; "-la" ] ] ]))
    test "help at the top" (fun () ->
      match top [ "--help" ] with
      | Error (Help text) -> expect text """
                               usage: prog <command> [options]

                               commands:
                                 create      create a box
                                 enter       enter a box
                                 list        list boxes

                               options:
                                 -h, --help  show this help

                               """
      | _ -> assert false)
    test "help of a subcommand" (fun () ->
      match top [ "create"; "--help" ] with
      | Error (Help text) -> expect text """
                               usage: prog create [options] NAME IMAGE

                               arguments:
                                 NAME                   name of the box
                                 IMAGE                  image to create it from

                               options:
                                 -s, --share <text>     share a directory read-write
                                     --share-ro <text>  share a directory read-only
                                     --jobs <n>         how many jobs
                                 -v, --verbose          say more
                                 -h, --help             show this help

                               """
      | _ -> assert false)
  ]
