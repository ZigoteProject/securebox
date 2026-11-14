open Testing

// a test's name is one line
let private shown (s: string) = String.replace s "\n" "\\n"

let private self = "/usr/local/bin/securebox"
let private entry (lines: list<string>) = String.join "\n" ("[Desktop Entry]" :: "Type=Application" :: lines)
let private written (text: string) = Result.map (Exports.desktopFile self "dev") (Exports.launcher "app" text)
let private refused (lines: list<string>) = Result.isError (Exports.launcher "app" (entry lines))

// as a distribution ships it
let private firefox =
  String.join "\n" [
    "# a comment"
    "[Desktop Entry]"
    "Version=1.0"
    "Name=Firefox"
    "Name[de]=Feuerfuchs"
    "Exec=firefox --name firefox %u"
    "Icon=org.mozilla.firefox"
    "Terminal=false"
    "Type=Application"
    "MimeType=text/html;x-scheme-handler/https;"
    "Categories=Network;WebBrowser;"
    "StartupWMClass=firefox"
    "Actions=new-window;"
    ""
    "[Desktop Action new-window]"
    "Name=New Window"
    "Exec=firefox --new-window %u" ]

// command lines a launcher on the host is not made from
let private badExecs =
  [ ""; "%U"; "-rf /"; "sh -c \"id\""; "sh -c 'id'"; "app $(id)"; "app `id`"; "app;id"; "app && id"; "app | id"
    "app > /tmp/x"; "app $HOME"; "app\\ x"; "app\tx"; "app 100%"; "~/app"; "app *"; "app #x"; "app (x)" ]

[<Tests>]
let tests =
  testList "exports" [
    testList "a command takes" [
      for c in [ "rg"; "g++"; "python3.12"; "x86_64-linux-gnu-gcc"; "/opt/tool/bin/x_y" ] -> test c (fun () -> assert (Exports.program c = Ok c)) ]
    testList "a command refuses" [
      for c in [ ""; "-rf"; "a b"; "a;b"; "$(id)"; "../x"; "bin/x"; "/usr/bin/"; "/"; ".."; "/a/.."; "a\nb"; "x=y"; "a\"b"; "é" ] ->
        test $"<{shown c}>" (fun () -> assert (Result.isError (Exports.program c))) ]
    test "an application is named as its .desktop file is, with or without the ending" (fun () ->
      assert (Exports.application "org.mozilla.firefox" = Ok "org.mozilla.firefox")
      assert (Exports.application "foot.desktop" = Ok "foot")
      for a in [ ""; ".desktop"; "-x"; ".hidden"; "a/b"; "../x"; "a b"; "a+b"; "a\nb" ] do
        assert (Result.isError (Exports.application a)))
    test "the files on the host are named after the command, and after the box and the application" (fun () ->
      assert (Exports.scriptName "/opt/tool/bin/x_y" = "x_y" && Exports.scriptName "rg" = "rg")
      assert (Exports.launcherName "dev" "org.mozilla.firefox" = "securebox+dev+org.mozilla.firefox.desktop"))
    test "a launcher is written anew: the box's name in its title, securebox in its command, no other key" (fun () ->
      assert (written firefox
              = Ok (String.concat [
                      "[Desktop Entry]\n"
                      "Type=Application\n"
                      "Name=dev: Firefox\n"
                      "Exec=/usr/local/bin/securebox enter dev -- firefox --name firefox\n"
                      "Icon=org.mozilla.firefox\n"
                      "Terminal=false\n"
                      "Categories=Network;\n"
                      "StartupWMClass=app\n" ])))
    test "only [Desktop Entry] is read, and of a key its first line" (fun () ->
      let text = String.join "\n" [ "[Desktop Action x]"; "Exec=evil"; "Name=Evil"; entry [ " Name = Good "; "Exec=good"; "Exec=evil" ]; "[Other]"; "Terminal=true"; "Icon=evil" ]
      assert (Exports.launcher "app" text = Ok { title = "Good"; exec = [ "good" ]; icon = ""; terminal = false; categories = []; windowClass = "app" }))
    test "what a file says beyond its command is taken a character at a time, or not at all" (fun () ->
      let made = Exports.launcher "app" (entry [ "Name=Files\\n; `id` $(x) \t[31m"; "Exec=app"; "Icon=/usr/share/icons/x.svg"; "Terminal=true"
                                                 "Categories=Utility;Bad Cat;;$(id);X-Own"; "StartupWMClass=a b" ])
      assert (made = Ok { title = "Filesn id x 31m"; exec = [ "app" ]; icon = ""; terminal = true; categories = [ "Utility" ]; windowClass = "app" })
      // a name of nothing usable is the application's, and one that goes on is cut
      let long = Exports.launcher "app" (entry [ "Name=" + String.repeat 100 "a"; "Exec=app" ])
      assert (Result.map (fun (l: Exports.Launcher) -> String.length l.title) long = Ok 40)
      assert (Result.map (fun (l: Exports.Launcher) -> l.title) (Exports.launcher "app" (entry [ "Name=$$$"; "Exec=app" ])) = Ok "app"))
    test "a launcher cannot pass for an application of the host's" (fun () ->
      let made (lines: list<string>) = Exports.launcher "app" (entry ("Exec=app" :: lines))
      let title (lines: list<string>) = Result.map (fun (l: Exports.Launcher) -> l.title) (made lines)
      // the box's name comes first, so no name is long enough to hide it, and none ends in a "(on ...)" of its own
      assert (title [ "Name=Files (on host)" ] = Ok "Files on host")
      assert (title [ "Name=Files" + String.repeat 50 " " + "." ] = Ok "Files .")
      assert (Result.map (fun (l: Exports.Launcher) -> String.contains "\nName=dev: Files\n" (Exports.desktopFile self "dev" l)) (made [ "Name=Files" ]) = Ok true)
      // letters are ASCII's: none that only looks like one of them (the second letter here is Cyrillic)
      assert (title [ "Name=Fіles é" ] = Ok "Fles")
      // a carriage return does not start a line that a desktop might read as a key, and is not kept
      assert (title [ "Name=A\rB" ] = Ok "AB")
      assert (title [ "Name=A\r\nName=evil" ] = Ok "A")
      // the categories programs act on are not a box's to take: the host's terminal, for one
      assert (Result.map (fun (l: Exports.Launcher) -> l.categories) (made [ "Categories=System;TerminalEmulator;X-GNOME-Utilities;WebBrowser;" ]) = Ok [ "System" ])
      // nor another program's windows
      assert (Result.map (fun (l: Exports.Launcher) -> l.windowClass) (made [ "StartupWMClass=firefox" ]) = Ok "app"))
    test "the words the desktop would fill in with the host's files are dropped" (fun () ->
      assert (Result.map (fun (l: Exports.Launcher) -> l.exec) (Exports.launcher "app" (entry [ "Exec=env A=1 /opt/app/run  --open %F %i %c" ]))
              = Ok [ "env"; "A=1"; "/opt/app/run"; "--open" ]))
    testList "no launcher for the command line" [ for e in badExecs -> test $"<{shown e}>" (fun () -> assert (refused [ "Exec=" + e ])) ]
    test "no launcher for what is not an application, or has no command" (fun () ->
      assert (refused [ "Name=x" ])
      assert (Result.isError (Exports.launcher "app" "[Desktop Entry]\nType=Link\nExec=app"))
      assert (Result.isError (Exports.launcher "app" "Type=Application\nExec=app"))
      assert (Result.isError (Exports.launcher "app" "")))
    test "the script passes its arguments on, and quotes nothing else: there is nothing to quote" (fun () ->
      assert (Exports.script self "dev" "/opt/tool/bin/x_y"
              = "#!/bin/sh\n# Written by securebox: runs /opt/tool/bin/x_y in the box dev.\nexec /usr/local/bin/securebox enter dev -- /opt/tool/bin/x_y \"$@\"\n"))
    test "securebox's own path goes into a launcher only if it is inert" (fun () ->
      assert (Exports.inertPath "/home/ada/.local/bin/securebox")
      for p in [ ""; "securebox"; "/opt/my tools/securebox"; "/opt/$x/securebox"; "/opt/a;b/securebox" ] do
        assert (not (Exports.inertPath p)))
  ]
