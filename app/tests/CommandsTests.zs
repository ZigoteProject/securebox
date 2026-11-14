open Testing
open Box
open Fixture

let private share = "/home/ada/Projects/web"
let private dir = "/home/ada/.local/share/securebox/dev"
let private at = "/run/user/1000/securebox/dev"
let private ran (what: string) (calls: list<string>) = List.exists (String.startsWith what) calls
// the podman subcommand of each call, or the directory made
let private steps (calls: list<string>) = List.map (fun c -> List.item 1 (String.split " " c)) calls

let private dev (status: string) (mounts: list<string * string>) = box (inspected "dev" status "\"1\"" (devHome :: mounts))
let private bus = (at + "/dbus", "/run/user/1000/dbus")
let private sound = (at + "/pulse", "/run/user/1000/pulse")
let private socket = ("/run/user/1000/wayland-1", "/run/user/1000/wayland-0")

// every command that names a box
let private commands =
  [ (fun () -> Commands.enter ctx "dev" false []); (fun () -> Commands.stop ctx "dev")
    (fun () -> Commands.rm ctx "dev" false); (fun () -> Commands.rm ctx "dev" true)
    (fun () -> Commands.recreate ctx { name = "dev"; image = "" })
    (fun () -> Commands.export ctx "dev" [ Exports.Bin "rg" ] false) ]

let private snapshot = "localhost/securebox-snapshot:dev"
let private kept = dir + "/exports"
let private script = "/home/ada/.local/bin/rg"
let private launcher = "/home/ada/.local/share/applications/securebox+dev+app.desktop"

/// podman's answers around a `recreate` of `dev`: the box is there until it is removed,
/// and again once it is created; `failing` is the podman command that fails.
let private recreating (failing: string) : list<string> -> ProcessResult =
  let there = ref true
  fun args ->
    match args with
    | first :: _ when first = failing -> { code = 125; output = "" }
    | "rm" :: _ ->
      there.Value <- false
      { code = 0; output = "" }
    | "create" :: _ ->
      there.Value <- true
      { code = 0; output = "" }
    | "exec" :: _ -> { code = 0; output = "" }
    | _ -> box (if there.Value then inspected "dev" "running" "\"1\"" [ devHome ] else "") args

/// podman's answers for a running `dev` in which `exec` prints `output` and ends with `code`.
let private answering (code: int) (output: string) (args: list<string>) : ProcessResult =
  match args with
  | "exec" :: _ -> { code = code; output = output }
  | _ -> dev "running" [] args

// containers named dev that are not the box dev
let private notBoxes =
  [ ("no label", inspected "dev" "running" "null" [ devHome ])
    ("an image's label, no home mount", inspected "dev" "running" "\"1\"" [])
    ("an image's label, and a volume where the home goes", inspectedWith "dev" "running" "\"1\"" [] [ "/home/ada" ])
    ("another data directory's box", inspected "dev" "running" "\"1\"" [ ("/elsewhere/dev/home", "/home/ada") ]) ]

let private leftAlone (state: string) =
  for command in commands do
    let (r, calls) = record (box state) [ dir; dir + "/home" ] command
    assert (Result.isError r)
    assert (steps calls = [ "inspect" ])

[<Tests>]
let tests =
  testList "commands" [
    test "enter a running box: inspect, then exec in the shared working directory" (fun () ->
      let (r, calls) = record (dev "running" [ (share, share) ]) [] (fun () -> Commands.enter ctx "dev" false [ "make" ])
      assert (r = Ok 0 && List.length calls = 2)
      assert (ran "podman inspect " calls && ran "exec podman exec " calls)
      assert (String.contains $"--workdir {share}/src " (List.last calls))
      assert (String.endsWith " dev make" (List.last calls)))
    test "enter a stopped box: it is started first" (fun () ->
      let (r, calls) = record (dev "exited" []) [] (fun () -> Commands.enter ctx "dev" false [])
      assert (r = Ok 0 && steps calls = [ "inspect"; "start"; "podman" ]))
    test "a stopped box is started only if its shares are still what they were" (fun () ->
      // podman resolves a mount's source again at each start
      let (same, _) = record (dev "exited" [ (share, share) ]) [ share ] (fun () -> Commands.enter ctx "dev" false [])
      assert (same = Ok 0)
      // /srv/to-ssh was a directory when the box was made; it is a link to ~/.ssh now
      let (r, calls) = record (dev "exited" [ ("/srv/to-ssh", "/srv/to-ssh") ]) [ "/var/home/ada/.ssh" ] (fun () -> Commands.enter ctx "dev" false [])
      assert (Result.isError r && steps calls = [ "inspect" ])
      let (gone, goneCalls) = record (dev "exited" [ (share, share) ]) [] (fun () -> Commands.enter ctx "dev" false [])
      assert (Result.isError gone && not (ran "podman start" goneCalls))
      // a running box has them mounted already
      let (running, _) = record (dev "running" [ ("/srv/to-ssh", "/srv/to-ssh") ]) [] (fun () -> Commands.enter ctx "dev" false [])
      assert (running = Ok 0))
    testList "a container that isn't the box is left alone" [ for (why, state) in notBoxes -> test why (fun () -> leftAlone state) ]
    test "a name podman takes for another container's id is no box" (fun () ->
      // `podman inspect de` answers with the container whose id starts with de
      let other = box (inspected "web" "running" "\"1\"" [ ("/home/ada/.local/share/securebox/web/home", "/home/ada") ])
      for command in [ (fun () -> Commands.enter ctx "de" false []); (fun () -> Commands.stop ctx "de"); (fun () -> Commands.rm ctx "de" false) ] do
        let (r, calls) = record other [] command
        assert (r = Error "no box named 'de'; create it with: securebox create de")
        assert (steps calls = [ "inspect" ]))
    test "a box that doesn't exist" (fun () ->
      let (r, calls) = record (box "") [] (fun () -> Commands.enter ctx "dev" false [])
      assert (r = Error "no box named 'dev'; create it with: securebox create dev")
      assert (steps calls = [ "inspect"; "container" ]))
    test "a podman that fails is not a box that is gone: nothing is purged" (fun () ->
      let broken (args: list<string>) : ProcessResult = { code = 125; output = "" }
      let (r, calls) = record broken [ dir; dir + "/home" ] (fun () -> Commands.rm ctx "dev" true)
      assert (r = Error "podman could not inspect 'dev'")
      assert (not (ran "podman unshare" calls) && not (ran "podman rm" calls)))
    test "list prints the table, to standard output" (fun () ->
      let boxes (args: list<string>) : ProcessResult = { code = 0; output = "[{\"Names\":[\"dev\"],\"State\":\"running\",\"Image\":\"fedora:45\",\"Mounts\":[\"/home/ada\"]}]" }
      let (r, calls) = record boxes [] (fun () -> Commands.list 1000)
      assert (r = Ok 0 && steps calls = [ "ps"; "container"; "NAME" ])
      assert (List.item 1 calls = "podman container inspect --format {{.Name}}|{{json .Mounts}} dev")
      assert (String.contains "\ndev   running  fedora:45  /home/ada\n" (List.last calls))
      let failing (args: list<string>) : ProcessResult = { code = 125; output = "" }
      assert (Result.isError (fst (record failing [] (fun () -> Commands.list 1000)))))
    test "stop: only a running box is stopped" (fun () ->
      let (_, running) = record (dev "running" []) [] (fun () -> Commands.stop ctx "dev")
      let (_, stopped) = record (dev "exited" []) [] (fun () -> Commands.stop ctx "dev")
      assert (ran "podman stop dev" running && not (ran "podman stop" stopped)))
    test "rm keeps the home directory" (fun () ->
      let (r, calls) = record (dev "running" []) [ dir ] (fun () -> Commands.rm ctx "dev" false)
      assert (r = Ok 0 && ran "podman rm --force --volumes dev" calls && not (ran "podman unshare" calls)))
    test "rm --purge deletes it, inside podman's user namespace" (fun () ->
      let (r, calls) = record (dev "exited" []) [ dir ] (fun () -> Commands.rm ctx "dev" true)
      assert (r = Ok 0 && List.last calls = $"podman unshare rm -rf -- {dir}"))
    test "rm --purge after the container is gone deletes what is a box's directory, and nothing else" (fun () ->
      let (r, calls) = record (box "") [ dir; dir + "/home" ] (fun () -> Commands.rm ctx "dev" true)
      assert (r = Ok 0 && List.last calls = $"podman unshare rm -rf -- {dir}")
      // a directory of that name without a home in it was never a box
      let (stray, strayCalls) = record (box "") [ dir ] (fun () -> Commands.rm ctx "dev" true)
      assert (Result.isError stray && not (ran "podman unshare" strayCalls))
      let (gone, _) = record (box "") [] (fun () -> Commands.rm ctx "dev" true)
      assert (Result.isError gone))
    test "rm of a box removed behind securebox's back stops what ran under its name" (fun () ->
      let (_, calls) = record (box "") [ at ] (fun () -> Commands.rm ctx "dev" false)
      assert (ran "systemctl --user stop securebox-dbus-dev.service" calls && ran "systemctl --user stop securebox-sound-dev.service" calls)
      assert (ran $"remove {at}" calls))
    test "create: the name is free, then home directory, create, start, and the passwd line checked as the user" (fun () ->
      let spec = { name = "dev"; image = "fedora:45"; shares = [ { path = share; readOnly = false } ] }
      let (r, calls) = record (box "") [ share ] (fun () -> Commands.create ctx spec)
      assert (r = Ok 0 && steps calls = [ "inspect"; "container"; $"{dir}/home"; "create"; "start"; "exec"; $"{dir}/created" ])
      assert (not (ran "podman exec --user 0" calls)))
    test "create: a name that is taken is refused before anything is touched" (fun () ->
      let spec = { name = "dev"; image = "fedora:45"; dbus = [ "org.example.App" ]; sound = true }
      let (r, calls) = record (dev "exited" [ bus ]) pipewire (fun () -> Commands.create ctx spec)
      assert (r = Error "there is already a box named 'dev'" && steps calls = [ "inspect" ])
      let (f, _) = record (box (inspected "dev" "running" "null" [])) [] (fun () -> Commands.create ctx spec)
      assert (Result.isError f))
    test "create: root rewrites the passwd line only where the image has its own" (fun () ->
      let (r, calls) = record (creating (inspected "dev" "running" "\"1\"" [ devHome ]) 1) [] (fun () -> Commands.create ctx { name = "dev"; image = "ubuntu:24.04" })
      assert (r = Ok 0 && steps calls = [ "inspect"; "container"; $"{dir}/home"; "create"; "start"; "exec"; "inspect"; "exec"; $"{dir}/created" ])
      assert (String.startsWith "podman exec --user 0 dev sh -c sed " (List.item 7 calls)))
    test "create: a box that didn't stay up is an error, not a success" (fun () ->
      let (r, calls) = record (creating (inspected "dev" "exited" "\"1\"" [ devHome ]) 255) [] (fun () -> Commands.create ctx { name = "dev"; image = "scratch" })
      assert (Result.isError r && not (ran "podman exec --user 0" calls) && not (List.exists (String.startsWith "write") calls)))
    test "enter passes on the variables it was given, after its own" (fun () ->
      let (_, calls) = record (dev "running" [ socket ]) [] (fun () -> Commands.enter { ctx with passEnv = [ "TERM"; "API_KEY"; "MODE=fast and loose" ] } "dev" false [ "make" ])
      assert (String.endsWith "--env WAYLAND_DISPLAY=wayland-0 --env TERM --env API_KEY --env MODE=fast and loose dev make" (List.last calls)))
    test "create: shares that one could replace, and a session grant with the host's network, are refused" (fun () ->
      let nested = { name = "dev"; image = "x"; shares = [ { path = "/srv/a"; readOnly = false }; { path = "/srv/a/.git"; readOnly = true } ] }
      let (r, calls) = record (box "") [] (fun () -> Commands.create ctx nested)
      assert (Result.isError r && calls = [])
      for spec in [ { name = "dev"; image = "x"; network = HostNetwork; sound = true }
                    { name = "dev"; image = "x"; network = HostNetwork; dbus = [ "org.example.App" ] }
                    { name = "dev"; image = "x"; network = HostNetwork; wayland = Some "/run/user/1000/wayland-0" } ] do
        let (h, hostCalls) = record (box "") pipewire (fun () -> Commands.create ctx spec)
        assert (h = Error "--network host cannot be combined with --wayland, --sound or --dbus" && hostCalls = []))
    test "--wayland takes a socket in the session's runtime directory, whatever WAYLAND_DISPLAY says" (fun () ->
      let asked path present = fst (record (box "") present (fun () -> Commands.wayland ctx path))
      let runtime = "/run/user/1000"
      assert (asked "/run/user/1000/wayland-0" [ runtime; "/run/user/1000/wayland-0" ] = Ok "/run/user/1000/wayland-0")
      assert (Result.isError (asked "/run/user/1000/wayland-0" [ runtime ]))                 // no such socket
      assert (Result.isError (asked "/srv/socket" [ runtime; "/srv/socket" ]))               // a socket, elsewhere
      assert (Result.isError (asked "/run/user/1000" [ runtime ]))                           // the directory itself
      // a link in the runtime directory that leads out of it
      assert (Result.isError (asked "/srv/to-ssh" [ runtime; "/var/home/ada/.ssh" ])))
    test "create --sound: a front-end of the box's own is configured and running before the box is made" (fun () ->
      let spec = { name = "dev"; image = "fedora:45"; sound = true }
      let (r, calls) = record (box "") pipewire (fun () -> Commands.create ctx spec)
      assert (r = Ok 0)
      assert (calls |> List.skip 2 |> List.take 8
              = [ $"mkdir {dir}/home"; "systemctl --user stop securebox-sound-dev.service"
                  $"mkdir {at}/pulse"; $"mkdir {at}/sound/pipewire-pulse.conf.d"
                  $"copy /usr/share/pipewire/pipewire-pulse.conf {at}/sound/pipewire-pulse.conf"
                  $"write {at}/sound/pipewire-pulse.conf.d/securebox.conf"; $"remove {at}/pulse/native"
                  $"systemd-run --user --quiet --collect --unit securebox-sound-dev.service --setenv PIPEWIRE_CONFIG_DIR={at}/sound --setenv PULSE_RUNTIME_PATH={at}/pulse -- pipewire-pulse" ])
      assert (steps (List.skip 10 calls) = [ "create"; "start"; "exec"; $"{dir}/created" ]))
    test "create --sound without PipeWire stops before podman" (fun () ->
      let spec = { name = "dev"; image = "fedora:45"; sound = true }
      let (r, calls) = record (box "") [] (fun () -> Commands.create ctx spec)
      assert (r = Error "--sound needs PipeWire, and there is no socket of it at /run/user/1000/pipewire-0")
      assert (not (ran "podman create" calls) && not (ran "systemd-run" calls)))
    test "create --dbus: a filter of its own, whatever ran under the name before, and before the box is made" (fun () ->
      let spec = { name = "dev"; image = "fedora:45"; dbus = [ "org.freedesktop.Notifications" ] }
      // "units": one is running under that name already, left by a box removed with podman
      let (r, calls) = record (box "") [ "units" ] (fun () -> Commands.create ctx spec)
      assert (r = Ok 0)
      assert (steps calls = [ "inspect"; "container"; $"{dir}/home"; "--user"; $"{at}/dbus"; $"{at}/dbus/bus"; "--user"; "create"; "start"; "exec"; $"{dir}/created" ])
      assert (List.item 3 calls = "systemctl --user stop securebox-dbus-dev.service" && not (ran "systemctl --user is-active" calls))
      assert (List.exists (String.endsWith "--filter --see=org.freedesktop.Notifications --call=org.freedesktop.Notifications=org.freedesktop.Notifications.* --broadcast=org.freedesktop.Notifications=org.freedesktop.Notifications.*") calls))
    test "create that fails leaves nothing running under the name" (fun () ->
      let failing (args: list<string>) : ProcessResult =
        match args with
        | "create" :: _ -> { code = 125; output = "" }
        | _ -> box "" args
      let spec = { name = "dev"; image = "fedorra"; dbus = [ "org.freedesktop.secrets" ]; sound = true }
      let (r, calls) = record failing pipewire (fun () -> Commands.create ctx spec)
      assert (Result.isError r)
      let created = Option.defaultValue 0 (List.tryFindIndex (String.startsWith "podman create") calls)
      let after = List.skip created calls
      assert (ran "systemctl --user stop securebox-dbus-dev.service" after && ran "systemctl --user stop securebox-sound-dev.service" after && ran $"remove {at}" after))
    test "create --dbus without a session bus is refused" (fun () ->
      let spec = { name = "dev"; image = "fedora:45"; dbus = [ "org.freedesktop.Notifications" ] }
      for address in [ ""; "-x"; "unix:path=/run/$HOME/bus" ] do
        let (r, calls) = record (box "") [] (fun () -> Commands.create { ctx with busAddress = address } spec)
        assert (Result.isError r && not (ran "podman create" calls) && not (ran "systemd-run" calls)))
    test "enter a --dbus box: a running filter is left alone; a stopped one is started with the box's own names" (fun () ->
      let (_, calls) = record (dev "running" [ bus ]) [ "units" ] (fun () -> Commands.enter ctx "dev" false [])
      assert (steps calls = [ "inspect"; "--user"; "podman" ] && not (ran "systemd-run" calls))
      let labelled (args: list<string>) : ProcessResult =
        if List.contains "{{index .Config.Labels \"securebox.dbus\"}}" args then { code = 0; output = "org.freedesktop.Notifications,org.example.App\n" }
        else dev "running" [ bus ] args
      let (r, started) = record labelled [] (fun () -> Commands.enter ctx "dev" false [])
      assert (r = Ok 0 && List.exists (String.endsWith " --see=org.example.App --call=org.example.App=org.example.App.* --broadcast=org.example.App=org.example.App.*") started)
      assert (String.contains "--env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/dbus/bus " (List.last started)))
    test "a --dbus box whose label names what a box may not talk to is not entered" (fun () ->
      let forged (args: list<string>) : ProcessResult =
        if List.contains "{{index .Config.Labels \"securebox.dbus\"}}" args then { code = 0; output = "org.freedesktop.systemd1\n" }
        else dev "running" [ bus ] args
      let (r, calls) = record forged [] (fun () -> Commands.enter ctx "dev" false [])
      assert (Result.isError r && not (ran "systemd-run" calls) && not (ran "exec podman" calls)))
    test "an image's volume and label start no filter" (fun () ->
      // a box created without --dbus, from an image that declares a volume where the bus goes
      let state = inspectedWith "dev" "running" "\"1\"" [ devHome ] [ "/run/user/1000/dbus"; "/run/user/1000/pulse" ]
      let (r, calls) = record (box state) [] (fun () -> Commands.enter ctx "dev" false [])
      assert (r = Ok 0 && steps calls = [ "inspect"; "podman" ])
      assert (not (String.contains "DBUS_SESSION_BUS_ADDRESS" (List.last calls)) && not (String.contains "PULSE_SERVER" (List.last calls))))
    test "stop and rm stop a box's filter and front-end; rm clears their place" (fun () ->
      let (_, stopped) = record (dev "running" [ bus; sound ]) [ "units" ] (fun () -> Commands.stop ctx "dev")
      assert (ran "systemctl --user stop securebox-dbus-dev.service" stopped && ran "systemctl --user stop securebox-sound-dev.service" stopped)
      assert (not (ran "remove" stopped))
      let (_, removed) = record (dev "running" [ bus ]) [ "units" ] (fun () -> Commands.rm ctx "dev" false)
      assert (ran "systemctl --user stop securebox-dbus-dev.service" removed && ran $"remove {at}" removed)
      let (_, plain) = record (dev "running" []) [] (fun () -> Commands.stop ctx "dev")
      assert (not (ran "systemctl" plain)))
    test "enter a --sound box: its front-end is started when it is not running" (fun () ->
      let (r, calls) = record (dev "exited" [ sound ]) pipewire (fun () -> Commands.enter ctx "dev" false [])
      assert (r = Ok 0 && ran "systemd-run --user --quiet --collect --unit securebox-sound-dev.service " calls)
      assert (String.contains "--env PULSE_SERVER=unix:/run/user/1000/pulse/native " (List.last calls))
      let (_, running) = record (dev "running" [ sound ]) [ "units" ] (fun () -> Commands.enter ctx "dev" false [])
      assert (not (ran "systemd-run" running)))
    test "enter a --wayland box: the socket's place is told; a stopped one needs the compositor" (fun () ->
      let (_, calls) = record (dev "running" [ socket ]) [] (fun () -> Commands.enter ctx "dev" false [ "foot" ])
      assert (String.contains "--env XDG_RUNTIME_DIR=/run/user/1000 --env WAYLAND_DISPLAY=wayland-0 " (List.last calls))
      let (stopped, stoppedCalls) = record (dev "exited" [ socket ]) [] (fun () -> Commands.enter ctx "dev" false [])
      assert (Result.isError stopped && steps stoppedCalls = [ "inspect" ])
      let (there, thereCalls) = record (dev "exited" [ socket ]) [ "/run/user/1000/wayland-1" ] (fun () -> Commands.enter ctx "dev" false [])
      assert (there = Ok 0 && steps thereCalls = [ "inspect"; "start"; "podman" ]))
    test "recreate: the box is stopped, kept as an image, removed, and created from that image with the grants given" (fun () ->
      let spec = { name = "dev"; image = ""; network = NoNetwork; shares = [ { path = share; readOnly = true } ] }
      let (r, calls) = record (recreating "") [ share ] (fun () -> Commands.recreate ctx spec)
      assert (r = Ok 0)
      assert (steps calls = [ "inspect"; "stop"; "commit"; "rm"; "inspect"; "container"; $"{dir}/home"; "create"; "start"; "exec"; $"{dir}/created" ])
      assert (List.item 2 calls = $"podman commit --quiet dev {snapshot}")
      assert (List.exists (String.endsWith $",ro --workdir /home/ada --network none {snapshot}") calls))
    test "recreate: a share the box turned into a link while it ran is not mounted, and the box is kept" (fun () ->
      // to-web is a link: what main resolved to a directory no longer is one
      let spec = { name = "dev"; image = ""; shares = [ { path = "/srv/to-web"; readOnly = true } ] }
      let (r, calls) = record (recreating "") [ share ] (fun () -> Commands.recreate ctx spec)
      assert (Result.isError r && steps calls = [ "inspect"; "stop" ]))
    test "create: a share that is no longer the directory it was is not mounted" (fun () ->
      let spec = { name = "dev"; image = "fedora:45"; shares = [ { path = "/srv/to-web"; readOnly = false } ] }
      let (r, calls) = record (box "") [ share ] (fun () -> Commands.create ctx spec)
      assert (Result.isError r && not (ran "podman create" calls)))
    test "recreate: grants that cannot go together, and a box that isn't there, touch nothing" (fun () ->
      let (r, calls) = record (recreating "") pipewire (fun () -> Commands.recreate ctx { name = "dev"; image = ""; network = HostNetwork; sound = true })
      assert (Result.isError r && calls = [])
      let (gone, goneCalls) = record (box "") [] (fun () -> Commands.recreate ctx { name = "dev"; image = "" })
      assert (gone = Error "no box named 'dev'; create it with: securebox create dev" && steps goneCalls = [ "inspect"; "container" ]))
    test "recreate: a box whose files could not be kept is not removed" (fun () ->
      let (r, calls) = record (recreating "commit") [] (fun () -> Commands.recreate ctx { name = "dev"; image = "" })
      assert (Result.isError r && not (ran "podman rm" calls) && not (ran "podman create" calls)))
    test "recreate that fails once the box is removed says where its files are" (fun () ->
      let (r, _) = record (recreating "create") [] (fun () -> Commands.recreate ctx { name = "dev"; image = "" })
      assert (match r with
              | Error e -> String.contains $"securebox create dev {snapshot}" e
              | Ok _ -> false))
    test "export --bin: the command is looked for in the box; the copy is written, then the script is created anew, executable" (fun () ->
      let (r, calls) = record (answering 0 "") [] (fun () -> Commands.export ctx "dev" [ Exports.Bin "rg" ] false)
      assert (r = Ok 0)
      assert (List.item 1 calls = "podman exec dev sh -c command -v \"$1\" >/dev/null 2>&1 sh rg")
      assert (List.skip 2 calls
              = [ $"mkdir {kept}/bin"; "mkdir /home/ada/.local/bin"; $"write {kept}/bin/rg"; $"create {script} 493" ]))
    test "export: a stopped box is started, as enter starts it" (fun () ->
      let stopped (args: list<string>) : ProcessResult =
        match args with
        | "exec" :: _ -> { code = 0; output = "" }
        | _ -> dev "exited" [] args
      let (r, calls) = record stopped [] (fun () -> Commands.export ctx "dev" [ Exports.Bin "rg" ] false)
      assert (r = Ok 0 && List.take 3 (steps calls) = [ "inspect"; "start"; "exec" ]))
    test "export: what the box doesn't have is not exported" (fun () ->
      for item in [ Exports.Bin "rg"; Exports.App "app" ] do
        let (r, calls) = record (answering 1 "") [] (fun () -> Commands.export ctx "dev" [ item ] false)
        assert (Result.isError r && not (List.exists (String.startsWith "write") calls)))
    test "export --app: the box's .desktop file is read as the user, and a launcher of securebox's own is written" (fun () ->
      let (r, calls) = record (answering 0 "[Desktop Entry]\nType=Application\nName=App\nExec=app %U\n") [] (fun () -> Commands.export ctx "dev" [ Exports.App "app" ] false)
      assert (r = Ok 0 && String.startsWith "podman exec --env HOME=/home/ada dev sh -c " (List.item 1 calls) && String.endsWith " sh app" (List.item 1 calls))
      assert (List.skip 4 calls = [ $"write {kept}/applications/securebox+dev+app.desktop"; $"create {launcher} 420" ])
      // a command line of the box's that is not inert words
      let (bad, badCalls) = record (answering 0 "[Desktop Entry]\nType=Application\nExec=sh -c \"id\"\n") [] (fun () -> Commands.export ctx "dev" [ Exports.App "app" ] false)
      assert (Result.isError bad && not (List.exists (String.startsWith "write") badCalls)))
    test "export writes over a file only if it is the one securebox wrote" (fun () ->
      let (r, calls) = record (answering 0 "") [ script ] (fun () -> Commands.export ctx "dev" [ Exports.Bin "rg" ] false)
      assert (Result.isError r && not (List.exists (String.startsWith "write") calls) && not (List.exists (String.startsWith "create") calls))
      // its own file is removed, and created again: never written into
      let (again, againCalls) = record (answering 0 "") [ script; kept + "/bin/rg" ] (fun () -> Commands.export ctx "dev" [ Exports.Bin "rg" ] false)
      assert (again = Ok 0 && List.skip 2 againCalls
              = [ $"cmp --silent -- {kept}/bin/rg {script}"; $"unlink {script}"; $"mkdir {kept}/bin"; "mkdir /home/ada/.local/bin"
                  $"write {kept}/bin/rg"; $"create {script} 493" ]))
    test "export does not write through a symbolic link, dangling or not, and does not remove one" (fun () ->
      let linked = "/home/ada/.local/bin/linked"
      let touched (calls: list<string>) = List.exists (fun c -> String.startsWith "write" c || String.startsWith "create" c || String.startsWith "unlink" c) calls
      let (r, calls) = record (answering 0 "") [] (fun () -> Commands.export ctx "dev" [ Exports.Bin "linked" ] false)
      assert (r = Error $"{linked} is there already, and securebox did not write it or it was changed since: it is left alone" && not (touched calls))
      // a link to a file that reads as securebox's copy does is still not securebox's file
      let (same, sameCalls) = record (answering 0 "") [ linked; kept + "/bin/linked" ] (fun () -> Commands.export ctx "dev" [ Exports.Bin "linked" ] false)
      assert (Result.isError same && not (touched sameCalls))
      let (gone, goneCalls) = record (box "") [ linked; kept + "/bin/linked" ] (fun () -> Commands.export ctx "dev" [ Exports.Bin "linked" ] true)
      assert (Result.isError gone && not (ran $"unlink {linked}" goneCalls)))
    test "export needs something to export, and a path of securebox's that a launcher can be written with" (fun () ->
      let (r, calls) = record (answering 0 "") [] (fun () -> Commands.export ctx "dev" [] false)
      assert (Result.isError r && calls = [])
      let (s, sCalls) = record (answering 0 "") [] (fun () -> Commands.export { ctx with self = "" } "dev" [ Exports.Bin "rg" ] false)
      assert (Result.isError s && sCalls = []))
    test "export --delete removes what securebox wrote, and leaves what it did not" (fun () ->
      let (r, calls) = record (box "") [ script; kept + "/bin/rg" ] (fun () -> Commands.export ctx "dev" [ Exports.Bin "rg" ] true)
      assert (r = Ok 0 && calls = [ $"cmp --silent -- {kept}/bin/rg {script}"; $"unlink {script}"; $"remove {kept}/bin/rg" ])
      let (other, otherCalls) = record (box "") [ script ] (fun () -> Commands.export ctx "dev" [ Exports.Bin "rg" ] true)
      assert (Result.isError other && not (ran $"unlink {script}" otherCalls))
      // without a name: all of the box's, of both kinds
      let (all, allCalls) = record (box "") [ script; kept + "/bin/rg"; launcher; kept + "/applications/securebox+dev+app.desktop" ] (fun () -> Commands.export ctx "dev" [] true)
      assert (all = Ok 0 && ran $"unlink {script}" allCalls && ran $"unlink {launcher}" allCalls))
    test "rm removes what was exported from the box; rm --purge the image recreate made too" (fun () ->
      let (_, calls) = record (dev "running" []) [ dir; script; kept + "/bin/rg" ] (fun () -> Commands.rm ctx "dev" false)
      assert (ran $"unlink {script}" calls && not (ran "podman image rm" calls))
      let (_, purged) = record (dev "running" []) [ dir ] (fun () -> Commands.rm ctx "dev" true)
      assert (ran $"podman image rm --ignore {snapshot}" purged)
      // a box removed behind securebox's back leaves nothing on the host either
      let (_, gone) = record (box "") [ script; kept + "/bin/rg" ] (fun () -> Commands.rm ctx "dev" false)
      assert (ran $"unlink {script}" gone))
    test "a share is what the path leads to" (fun () ->
      let asked given present = fst (record (box "") present (fun () -> Commands.share ctx given false))
      assert (asked share [ share ] = Ok { path = share; readOnly = false })
      // a link into a project is the project; a link to ~/.ssh is ~/.ssh
      assert (asked "/srv/to-web" [ share ] = Ok { path = share; readOnly = false })
      assert (asked "/srv/to-ssh" [ "/var/home/ada/.ssh" ]
              = Error "refusing to share '/var/home/ada/.ssh': dot-directories of your home hold credentials and host configuration")
      assert (asked share [] = Error $"cannot share '{share}': no such directory")
      assert (asked "" [ "/home/ada/Projects/web/src" ] = Error "an empty path cannot be shared"))
  ]
