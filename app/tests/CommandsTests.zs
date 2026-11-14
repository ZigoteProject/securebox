open Testing
open Box
open Fixture

let private share = "/home/ada/Projects/web"
let private dir = "/home/ada/.local/share/securebox/dev"
let private ran (what: string) (calls: list<string>) = List.exists (String.startsWith what) calls
// the podman subcommand of each call, or the directory made
let private steps (calls: list<string>) = List.map (fun c -> List.item 1 (String.split " " c)) calls

let private dev (status: string) (mounts: list<string * string>) = box (inspected "dev" status "\"1\"" (devHome :: mounts))

// every command that names a box
let private commands =
  [ (fun () -> Commands.enter ctx "dev" false []); (fun () -> Commands.stop ctx "dev")
    (fun () -> Commands.rm ctx "dev" false); (fun () -> Commands.rm ctx "dev" true) ]

// containers named dev that are not the box dev
let private notBoxes =
  [ ("no label", inspected "dev" "running" "null" [ devHome ])
    ("an image's label, no home mount", inspected "dev" "running" "\"1\"" [])
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
    test "stop: only a running box is stopped" (fun () ->
      let (_, running) = record (dev "running" []) [] (fun () -> Commands.stop ctx "dev")
      let (_, stopped) = record (dev "exited" []) [] (fun () -> Commands.stop ctx "dev")
      assert (ran "podman stop dev" running && not (ran "podman stop" stopped)))
    test "rm keeps the home directory" (fun () ->
      let (r, calls) = record (dev "running" []) [ dir ] (fun () -> Commands.rm ctx "dev" false)
      assert (r = Ok 0 && ran "podman rm --force dev" calls && not (ran "podman unshare" calls)))
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
    test "create: home directory, create, start, and the passwd line checked as the user" (fun () ->
      let spec = { name = "dev"; image = "fedora:45"; shares = [ { path = share; readOnly = false } ] }
      let (r, calls) = record (box "") [ share ] (fun () -> Commands.create ctx spec)
      assert (r = Ok 0 && steps calls = [ $"{dir}/home"; "create"; "start"; "exec" ])
      assert (not (ran "podman exec --user 0" calls)))
    test "create: root rewrites the passwd line only where the image has its own" (fun () ->
      let clashing (args: list<string>) : ProcessResult =
        match args with
        | "exec" :: "dev" :: _ -> { code = 1; output = "" }          // the check, as the user
        | _ -> dev "running" [] args
      let (r, calls) = record clashing [] (fun () -> Commands.create ctx { name = "dev"; image = "ubuntu:24.04" })
      assert (r = Ok 0 && steps calls = [ $"{dir}/home"; "create"; "start"; "exec"; "inspect"; "exec" ])
      assert (String.startsWith "podman exec --user 0 dev sh -c sed " (List.last calls)))
    test "create: a box that didn't stay up is an error, not a success" (fun () ->
      let dead (args: list<string>) : ProcessResult =
        match args with
        | "exec" :: _ -> { code = 255; output = "" }
        | _ -> dev "exited" [] args
      let (r, calls) = record dead [] (fun () -> Commands.create ctx { name = "dev"; image = "scratch" })
      assert (Result.isError r && not (ran "podman exec --user 0" calls)))
    test "create --wayland without a compositor stops before podman" (fun () ->
      let spec = { name = "gui"; image = "fedora:45"; wayland = Some "/run/user/1000/wayland-0" }
      let (r, calls) = record (box "") [] (fun () -> Commands.create ctx spec)
      assert (r = Error "--wayland: there is no compositor socket at /run/user/1000/wayland-0" && calls = []))
    test "enter a --wayland box: the socket's place is told; a stopped one needs the compositor" (fun () ->
      let socket = ("/run/user/1000/wayland-1", "/run/user/1000/wayland-0")
      let (_, calls) = record (dev "running" [ socket ]) [] (fun () -> Commands.enter ctx "dev" false [ "foot" ])
      assert (String.contains "--env XDG_RUNTIME_DIR=/run/user/1000 --env WAYLAND_DISPLAY=wayland-0 " (List.last calls))
      let (stopped, stoppedCalls) = record (dev "exited" [ socket ]) [] (fun () -> Commands.enter ctx "dev" false [])
      assert (Result.isError stopped && steps stoppedCalls = [ "inspect" ])
      let (there, thereCalls) = record (dev "exited" [ socket ]) [ "/run/user/1000/wayland-1" ] (fun () -> Commands.enter ctx "dev" false [])
      assert (there = Ok 0 && steps thereCalls = [ "inspect"; "start"; "podman" ]))
    test "create --sound without a sound server stops before podman" (fun () ->
      let spec = { name = "gui"; image = "fedora:45"; sound = Some "/run/user/1000/pulse" }
      let (r, calls) = record (box "") [] (fun () -> Commands.create ctx spec)
      assert (r = Error "--sound: there is no sound server socket at /run/user/1000/pulse/native" && calls = []))
    test "create --dbus: the filter is running before the box is made" (fun () ->
      let spec = { name = "dev"; image = "fedora:45"; dbus = [ "org.freedesktop.Notifications" ] }
      let (r, calls) = record (box "") [] (fun () -> Commands.create ctx spec)
      assert (r = Ok 0)
      assert (steps calls = [ $"{dir}/home"; "--user"; "/run/user/1000/securebox/dev"; "/run/user/1000/securebox/dev/bus"; "--user"; "create"; "start"; "exec" ])
      assert (ran "systemctl --user is-active --quiet securebox-dbus-dev" calls)
      assert (List.exists (String.endsWith "--filter --talk=org.freedesktop.Notifications") calls))
    test "create --dbus without a session bus is refused" (fun () ->
      let spec = { name = "dev"; image = "fedora:45"; dbus = [ "org.freedesktop.Notifications" ] }
      let (r, calls) = record (box "") [] (fun () -> Commands.create { ctx with busAddress = "" } spec)
      assert (Result.isError r && not (ran "podman create" calls) && not (ran "systemd-run" calls)))
    test "enter a --dbus box: a running filter is left alone; a stopped one is started with the box's own names" (fun () ->
      let bus = ("/run/user/1000/securebox/dev", "/run/user/1000/dbus")
      let (_, calls) = record (dev "running" [ bus ]) [ "filter" ] (fun () -> Commands.enter ctx "dev" false [])
      assert (steps calls = [ "inspect"; "--user"; "podman" ] && not (ran "systemd-run" calls))
      let labelled (args: list<string>) : ProcessResult =
        if List.contains "{{index .Config.Labels \"securebox.dbus\"}}" args then { code = 0; output = "org.freedesktop.Notifications,org.example.App\n" }
        else dev "running" [ bus ] args
      let (r, started) = record labelled [] (fun () -> Commands.enter ctx "dev" false [])
      assert (r = Ok 0 && List.exists (String.endsWith "--filter --talk=org.freedesktop.Notifications --talk=org.example.App") started)
      assert (String.contains "--env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/dbus/bus " (List.last started)))
    test "a --dbus box whose label names what a box may not talk to is not entered" (fun () ->
      let bus = ("/run/user/1000/securebox/dev", "/run/user/1000/dbus")
      let forged (args: list<string>) : ProcessResult =
        if List.contains "{{index .Config.Labels \"securebox.dbus\"}}" args then { code = 0; output = "org.freedesktop.systemd1\n" }
        else dev "running" [ bus ] args
      let (r, calls) = record forged [] (fun () -> Commands.enter ctx "dev" false [])
      assert (Result.isError r && not (ran "systemd-run" calls) && not (ran "exec podman" calls)))
    test "stop and rm stop a --dbus box's filter; rm clears its place" (fun () ->
      let bus = ("/run/user/1000/securebox/dev", "/run/user/1000/dbus")
      let (_, stopped) = record (dev "running" [ bus ]) [ "filter" ] (fun () -> Commands.stop ctx "dev")
      assert (ran "systemctl --user stop securebox-dbus-dev" stopped && not (ran "remove" stopped))
      let (_, removed) = record (dev "running" [ bus ]) [ "filter" ] (fun () -> Commands.rm ctx "dev" false)
      assert (ran "systemctl --user stop securebox-dbus-dev" removed && ran "remove /run/user/1000/securebox/dev" removed)
      let (_, plain) = record (dev "running" []) [] (fun () -> Commands.stop ctx "dev")
      assert (not (ran "systemctl" plain)))
    test "a stopped --sound box needs the sound server to start" (fun () ->
      let sound = ("/run/user/1000/pulse", "/run/user/1000/pulse")
      let (r, calls) = record (dev "exited" [ sound ]) [] (fun () -> Commands.enter ctx "dev" false [])
      assert (Result.isError r && steps calls = [ "inspect" ])
      let (there, _) = record (dev "exited" [ sound ]) [ "/run/user/1000/pulse/native" ] (fun () -> Commands.enter ctx "dev" false [])
      assert (there = Ok 0))
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
