// Argz: an Argu-style command-line parser. A union is the command line: each case is an
// argument, a function with an exhaustive `match` describes the cases, and `[<Derive(Arg)>]`
// writes the parser and the usage text.
//
//   [<Derive(Arg)>]
//   type CreateArg =
//     | Name of string
//     | Share of string
//     | Verbose
//
//   let createSpec a =
//     match a with
//     | Name _ -> { help = "name of the box"; kind = Positional }
//     | Share _ -> { help = "share a directory"; short = Some 's' }
//     | Verbose -> { help = "say more" }
//
//   Argz.parse createSpec "prog" args : result<list<CreateArg>, ArgError>
//
// A subcommand is a case holding the list of its own arguments, described with its own
// function:
//
//   [<Derive(Arg)>]
//   type Command =
//     | Create of list<CreateArg>
//     | List
//
//   let commandSpec a =
//     match a with
//     | Create _ -> Argz.command "create a box" createSpec
//     | List -> { help = "list boxes"; kind = Command }
//
// The descriptions are functions, not a trait: a derive is expanded where its type is
// declared, before an impl for that type can be written.

/// How a case is written on the command line.
type Kind =
  /// `--kebab-name`, with a value when the case has a field.
  | Flag
  /// A bare token; positional cases are filled in declaration order.
  | Positional
  /// A bare word, the case's name in kebab-case; its field parses what follows.
  | Command

/// A command's own cases.
type Sub =
  | Sub of list<Info>

/// A case as the parser sees it: its name on the command line, what its description said,
/// how its value is shown in usage, how many fields it has, and a command's own cases.
and Info =
  { flag: string
    help: string
    short: option<char>
    kind: Kind
    hint: string
    count: int
    sub: Sub }

/// What a description says about a case. `sub` is a command's own arguments
/// (`Argz.command` fills it).
type Spec = { help: string; short: option<char> = None; kind: Kind = Flag; sub: Sub = Sub [] }

/// Why parsing stopped: help was asked for (the usage text), or the arguments are wrong.
type ArgError =
  | Help of string
  | Invalid of string

/// The tokens still to read, and where the parse is.
type Cursor =
  { rest: ref<list<string>>
    /// The program name and the commands entered so far, for usage text.
    path: ref<list<string>>
    /// Set by `--`: every later token is a positional.
    literal: ref<bool>
    /// The cases of the union about to be read.
    infos: ref<list<Info>> }

/// What a token turned out to be.
type Match = { index: int; info: Info; consumed: bool; inlineValue: option<string> }

/// A type that can be read from the command line.
trait Arg<'a> =
  /// Reads one value.
  abstract take : Cursor -> result<'a, ArgError>
  /// Reads values until no tokens are left.
  abstract takeAll : Cursor -> result<list<'a>, ArgError>
  /// Any value of the type: the derive builds a case from samples to ask for its `Spec`.
  abstract sample : unit -> 'a
  /// How the value is shown in usage text.
  abstract hint : 'a -> string
  /// A union's cases, as its description gives them; nothing for other types.
  abstract describe : ('a -> Spec) -> list<Info>

/// `ShareRo` is `share-ro`.
let kebab (name: string) =
  let mutable out = []
  for ch in String.chars name do
    if Char.isUpper ch then
      if out <> [] then out <- '-' :: out
      out <- Char.toLower ch :: out
    else
      out <- ch :: out
  String.ofChars (List.rev out)

/// A case's name on the command line. A derive gets the name qualified by its module when
/// the union is declared in another one (`Cli.ShareRo`): only the last part counts.
let flagOf (caseName: string) =
  match String.lastIndexOf "." caseName with
  | Some i -> kebab (String.sub caseName (i + 1) (String.length caseName - i - 1))
  | None -> kebab caseName

let private next (c: Cursor) : result<string, ArgError> =
  match c.rest.Value with
  | x :: rest ->
    c.rest.Value <- rest
    Ok x
  | [] -> Error (Invalid "missing value")

let private each (one: Cursor -> result<'a, ArgError>) (c: Cursor) : result<list<'a>, ArgError> =
  let rec go acc =
    if c.rest.Value = [] then Ok (List.rev acc)
    else
      match one c with
      | Ok v -> go (v :: acc)
      | Error e -> Error e
  go []

impl Arg<string> =
  let take c = next c
  let takeAll c = each next c
  let sample () = ""
  let hint _ = "<text>"
  let describe _ = []

let private nextInt (c: Cursor) : result<int, ArgError> =
  match next c with
  | Error e -> Error e
  | Ok s ->
    match String.parseInt s with
    | Some n -> Ok n
    | None -> Error (Invalid $"expected a number, got '{s}'")

impl Arg<int> =
  let take c = nextInt c
  let takeAll c = each nextInt c
  let sample () = 0
  let hint _ = "<n>"
  let describe _ = []

/// A list takes every token that is left: the tail of a command line (`list<string>`), or a
/// subcommand's own arguments (`list<CreateArg>`).
impl Arg<list<'a>> =
  let take (c: Cursor) : result<list<'a>, ArgError> = takeAll c
  let takeAll (c: Cursor) : result<list<list<'a>>, ArgError> =
    match takeAll c with
    | Ok xs -> Ok [ xs ]
    | Error e -> Error e
  let sample () = []
  let hint _ = "..."
  let describe _ = []

/// Which case a token names. `positionals` is how many positional tokens came before it.
let resolve (infos: list<Info>) (literal: bool) (positionals: int) (tok: string) : result<Match, string> =
  let indexed = List.mapi (fun i info -> (i, info)) infos
  let find pred = List.tryFind (fun (_, info) -> pred info) indexed
  let found (i, info) value = Ok { index = i; info = info; consumed = true; inlineValue = value }
  if literal || not (String.startsWith "-" tok) || tok = "-" then
    match (if literal then None else find (fun info -> info.kind = Command && info.flag = tok)) with
    | Some hit -> found hit None
    | None ->
      let ps = List.filter (fun (_, info) -> info.kind = Positional) indexed
      if positionals < List.length ps then
        let (i, info) = List.item positionals ps
        Ok { index = i; info = info; consumed = false; inlineValue = None }
      else
        Error $"unexpected argument '{tok}'"
  else if String.startsWith "--" tok then
    let body = String.sub tok 2 (String.length tok - 2)
    let eq = String.indexOf "=" body
    let name = match eq with
               | Some i -> String.sub body 0 i
               | None -> body
    let value = Option.map (fun i -> String.sub body (i + 1) (String.length body - i - 1)) eq
    match find (fun info -> info.kind = Flag && info.flag = name) with
    | Some (i, info) ->
      if info.count = 0 && Option.isSome value then Error $"--{name} takes no value"
      else found (i, info) value
    | None -> Error $"unknown option --{name}"
  else
    match find (fun info -> info.kind = Flag && Option.map (fun ch -> $"-{ch}") info.short = Some tok) with
    | Some hit -> found hit None
    | None -> Error $"unknown option {tok}"

/// The usage text of one level: its commands, positional arguments and options.
let render (path: list<string>) (infos: list<Info>) =
  let ofKind k = List.filter (fun (info: Info) -> info.kind = k) infos
  let commands = ofKind Command
  let flags = ofKind Flag
  let positionals = ofKind Positional
  let upper (info: Info) = String.toUpper info.flag + (if info.hint = "..." then "..." else "")
  let left (info: Info) =
    match info.kind with
    | Command -> info.flag
    | Positional -> upper info
    | Flag ->
      let short = match info.short with
                  | Some ch -> $"-{ch}, "
                  | None -> "    "
      short + "--" + info.flag + (if info.count > 0 then " " + info.hint else "")
  let helpRow = ("-h, --help", "show this help")
  let rows = List.map (fun (info: Info) -> (left info, info.help))
  let width = List.fold (fun w (l, _) -> max w (String.length l)) 0 (helpRow :: rows infos)
  let section title rs =
    if rs = [] then ""
    else $"\n{title}:\n" + String.concat (List.map (fun (l, h) -> $"  {String.padRight width l}  {h}\n") rs)
  String.concat [
    "usage: " + String.join " " path
    (if commands <> [] then " <command>" else "")
    " [options]"
    String.concat (List.map (fun info -> " " + upper info) positionals)
    "\n"
    section "commands" (rows commands)
    section "arguments" (rows positionals)
    section "options" (List.append (rows flags) [ helpRow ]) ]

/// Writes `Arg` for a union: `takeAll` reads its cases from the tokens, in command-line order.
derive Arg =
  let sample () : 'self =
    let first = List.head Shape.cases
    match Shape.buildCase first.name (fun f -> Ok (sample ())) with
    | Some (Ok v) -> v
    | _ -> panic "argz: a union without cases"

  let hint (x: 'self) = "<args>"

  let take (c: Cursor) : result<'self, ArgError> =
    Error (Invalid "argz: a union field must be a list (a subcommand's arguments)")

  let describe (spec: 'self -> Spec) : list<Info> =
    List.map (fun case ->
      let mutable h = ""
      let built : option<result<'self, ArgError>> =
        Shape.buildCase case.name (fun f ->
          let s = sample ()
          h <- hint s
          Ok s)
      match built with
      | Some (Ok v) ->
        let s = spec v
        { flag = flagOf case.name; help = s.help; short = s.short; kind = s.kind; hint = h
          count = case.count; sub = s.sub }
      | _ -> panic "argz: a case from Shape.cases") Shape.cases

  let takeAll (c: Cursor) : result<list<'self>, ArgError> =
    let infos = c.infos.Value
    let names = List.map (fun case -> case.name) Shape.cases
    let mutable acc = []
    let mutable positionals = 0
    let mutable err =
      if List.map (fun (info: Info) -> info.flag) infos = List.map flagOf names then None
      else Some (Invalid "argz: the description given is another union's")
    while Option.isNone err && c.rest.Value <> [] do
      let tok = List.head c.rest.Value
      c.rest.Value <- List.tail c.rest.Value
      let literal = c.literal.Value
      if not literal && tok = "--" then
        c.literal.Value <- true
      else if not literal && (tok = "--help" || tok = "-h") then
        err <- Some (Help (render c.path.Value infos))
      else
        match resolve infos literal positionals tok with
        | Error m -> err <- Some (Invalid m)
        | Ok m ->
          if not m.consumed then
            positionals <- positionals + 1
            c.rest.Value <- tok :: c.rest.Value
          match m.inlineValue with
          | Some v -> c.rest.Value <- v :: c.rest.Value
          | None -> ()
          if m.info.kind = Command && m.info.count > 0 then
            c.path.Value <- List.append c.path.Value [ tok ]
            let (Sub sub) = m.info.sub
            c.infos.Value <- sub
          match Shape.buildCase (List.item m.index names) (fun f -> take c) with
          | Some (Ok v) ->
            acc <- v :: acc
            // a command without a field takes nothing: what follows it is help or a mistake
            if m.info.kind = Command && m.info.count = 0 then
              match c.rest.Value with
              | [] -> ()
              | next :: _ ->
                if next = "--help" || next = "-h" then
                  err <- Some (Help (render (List.append c.path.Value [ tok ]) []))
                else
                  err <- Some (Invalid $"unexpected argument '{next}'")
          | Some (Error (Invalid e)) ->
            err <- Some (Invalid (if m.info.kind = Flag then $"{tok}: {e}" else e))
          | Some (Error e) -> err <- Some e
          | None -> err <- Some (Invalid "argz: a case from Shape.cases")
    match err with
    | Some e -> Error e
    | None -> Ok (List.rev acc)

/// A command's description: its help, and the description of its own arguments.
let command (help: string) (spec: 'a -> Spec) : Spec =
  { help = help; kind = Command; sub = Sub (describe spec) }

/// Parses a command line: `spec` describes the union's cases, `program` is the name usage
/// text shows, `args` the arguments after it.
let parse (spec: 'a -> Spec) (program: string) (args: list<string>) : result<list<'a>, ArgError> =
  takeAll { rest = ref args; path = ref [ program ]; literal = ref false; infos = ref (describe spec) }
