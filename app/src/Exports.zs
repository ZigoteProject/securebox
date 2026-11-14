// What `export` puts on the host: a script for a command of a box's, a launcher for an
// application of it. A box's .desktop file is the box's word, and a launcher runs on the
// host: nothing of the file is copied, and what is taken from it is checked character by
// character. DESIGN.md, section 3.

type Item =
  | Bin of string
  | App of string

/// What a launcher is made from.
type Launcher =
  { title: string
    exec: list<string>
    icon: string
    terminal: bool
    categories: list<string>
    windowClass: string }

/// Characters that mean nothing to a shell, nor in the Exec line of a .desktop file. Some
/// desktops hand that line to a shell, so a word of the box's is written only if it is
/// made of these.
let private inert (c: char) = Char.isLetterOrDigit c || List.contains c [ '_'; '@'; '+'; '='; ':'; ','; '.'; '/'; '-' ]
let private plain (c: char) = Char.isLetterOrDigit c || c = '_' || c = '.' || c = '-'
let private all (ok: char -> bool) (s: string) = s <> "" && List.forall ok (String.chars s)

/// Whether a path can be written into a launcher as it is. Asked of securebox's own.
let inertPath (path: string) = Path.isAbsolute path && all inert path

/// A command of the box's to export: its name, or its path in the box.
let program (s: string) : result<string, string> =
  let file = Path.getFileName s
  let spelled = all (fun c -> plain c || c = '+' || c = '/') s && not (String.startsWith "-" s) && not (String.endsWith "/" s)
  let placed = Path.isAbsolute s || not (String.contains "/" s)
  if spelled && placed && file <> "" && file <> "." && file <> ".." then Ok s
  else Error $"'{s}' is not a command to export: give its name, or its path in the box, in letters, digits and _.+-"

/// An application of the box's to export: the name of its .desktop file, with or without
/// the ending.
let application (s: string) : result<string, string> =
  let id = if String.endsWith ".desktop" s then String.sub s 0 (String.length s - 8) else s
  match String.chars id with
  | first :: _ when Char.isLetterOrDigit first && all plain id -> Ok id
  | _ -> Error $"'{s}' is not an application to export: give the name of its .desktop file, as org.mozilla.firefox"

/// The files on the host: the script is named as the command is, and a launcher after the
/// box and the application. No box name has a `+` in it, so no two boxes share a launcher.
let scriptName (command: string) = Path.getFileName command
let launcherName (box: string) (id: string) = $"securebox+{box}+{id}.desktop"

/// The launcher for a box's .desktop file. From its `[Desktop Entry]` come the name (some
/// punctuation and no more), the command (inert words only: anything quoted is refused,
/// and the %f and %U a desktop fills in with the host's files are dropped), the icon when
/// it is a name (the host's theme has it or not; a file of the box's is never read by the
/// desktop), whether it wants a terminal, its categories and its window class.
let launcher (id: string) (text: string) : result<Launcher, string> =
  let lines = List.map String.trim (String.splitLines text)
  let entry =
    match List.tryFindIndex (fun l -> l = "[Desktop Entry]") lines with
    | Some i -> List.takeWhile (fun l -> not (String.startsWith "[" l)) (List.skip (i + 1) lines)
    | None -> []
  let keyed (key: string) (l: string) =
    match String.indexOf "=" l with
    | Some i when String.trim (String.sub l 0 i) = key -> Some (String.trim (String.sub l (i + 1) (String.length l - i - 1)))
    | _ -> None
  let value (key: string) = Option.defaultValue "" (List.tryPick (keyed key) entry)
  let named (c: char) = Char.isLetterOrDigit c || List.contains c [ ' '; '.'; '-'; '_'; '+'; '('; ')'; ','; '&'; ':'; '/'; '!'; '#' ]
  let name = String.trim (String.ofChars (List.take 60 (List.filter named (String.chars (value "Name")))))
  let words = List.filter (fun w -> w <> "") (String.split " " (value "Exec"))
  let exec = List.filter (fun w -> not (String.startsWith "%" w && String.length w = 2)) words
  let orElse (fallback: string) (s: string) = if all plain s then s else fallback
  if value "Type" <> "Application" then Error $"{id}.desktop does not describe an application"
  else
    match exec with
    | first :: _ when not (String.startsWith "-" first) && List.forall (all inert) exec ->
      Ok { title = (if name = "" then id else name)
           exec = exec
           icon = orElse "" (value "Icon")
           terminal = value "Terminal" = "true"
           categories = List.filter (all (fun c -> Char.isLetterOrDigit c || c = '-')) (String.split ";" (value "Categories"))
           windowClass = orElse id (value "StartupWMClass") }
    | _ ->
      Error $"{id}.desktop starts its application with a command line securebox will not write on the host: it takes plain words only (letters, digits and _@+=:,./-), nothing quoted. Export the command with --bin, and write a launcher for it yourself"

/// The launcher, as a .desktop file. `self` is securebox, by its path. The name says which
/// box it is: an application of a box's cannot pass for one of the host's.
let desktopFile (self: string) (box: string) (l: Launcher) : string =
  String.concat [
    "[Desktop Entry]\n"
    "Type=Application\n"
    "Name=" + l.title + " (on " + box + ")\n"
    "Exec=" + self + " enter " + box + " -- " + String.join " " l.exec + "\n"
    (if l.icon = "" then "" else "Icon=" + l.icon + "\n")
    (if l.terminal then "Terminal=true\n" else "Terminal=false\n")
    (if l.categories = [] then "" else "Categories=" + String.join ";" l.categories + ";\n")
    "StartupWMClass=" + l.windowClass + "\n" ]

/// The script that runs a command of a box's: every string in it has been checked to be
/// inert, so none is quoted.
let script (self: string) (box: string) (command: string) : string =
  String.concat [
    "#!/bin/sh\n"
    "# Written by securebox: runs " + command + " in the box " + box + ".\n"
    "exec " + self + " enter " + box + " -- " + command + " \"$@\"\n" ]
