open Testing
open Box
open Podman

let private ctx = Fixture.ctx
let private lines (args: list<string>) = String.join "\n" args
let private dev = Fixture.devHome

[<Tests>]
let tests =
  testList "podman" [
    // The security defaults are these lists: a flag that disappears fails here.
    test "create, with nothing granted" (fun () ->
      expect (lines (createArgs ctx { name = "dev"; image = "fedora:45" })) """
        create
        --name
        dev
        --hostname
        dev
        --label
        securebox=1
        --init
        --entrypoint
        ["sleep","infinity"]
        --userns=keep-id
        --user
        1000:1000
        --passwd-entry
        ada:*:1000:1000::/home/ada:/bin/sh
        --security-opt
        no-new-privileges
        --http-proxy=false
        --hosts-file=none
        --mount
        type=bind,src=/home/ada/.local/share/securebox/dev/home,dst=/home/ada,relabel=private
        --workdir
        /home/ada
        --network
        pasta
        fedora:45
        """)
    test "create, with every grant but Wayland" (fun () ->
      expect (lines (createArgs ctx { name = "web"; image = "ubuntu:24.04"
                                      shares = [ { path = "/home/ada/Projects/web"; readOnly = false }
                                                 { path = "/srv/data"; readOnly = true } ]
                                      network = NoNetwork; publish = [ "127.0.0.1:8080:80" ]
                                      devices = [ "/dev/dri/renderD128" ] })) """
        create
        --name
        web
        --hostname
        web
        --label
        securebox=1
        --init
        --entrypoint
        ["sleep","infinity"]
        --userns=keep-id
        --user
        1000:1000
        --passwd-entry
        ada:*:1000:1000::/home/ada:/bin/sh
        --security-opt
        no-new-privileges
        --http-proxy=false
        --hosts-file=none
        --mount
        type=bind,src=/home/ada/.local/share/securebox/web/home,dst=/home/ada,relabel=private
        --mount
        type=bind,src=/home/ada/Projects/web,dst=/home/ada/Projects/web,relabel=shared
        --mount
        type=bind,src=/srv/data,dst=/srv/data,relabel=shared,ro
        --workdir
        /home/ada
        --network
        none
        --publish
        127.0.0.1:8080:80
        --device
        /dev/dri/renderD128
        ubuntu:24.04
        """)
    test "create --wayland: its own runtime directory, the socket, and SELinux labelling off" (fun () ->
      let plain = createArgs ctx { name = "gui"; image = "fedora:45" }
      let wayland = createArgs ctx { name = "gui"; image = "fedora:45"; wayland = Some "/run/user/1000/wayland-1" }
      expect (lines (List.filter (fun a -> not (List.contains a plain)) wayland)) """
        label=disable
        type=tmpfs,dst=/run/user/1000,tmpfs-mode=0700,chown=true
        type=bind,src=/run/user/1000/wayland-1,dst=/run/user/1000/wayland-0
        """)
    test "create --sound: the front-end's directory, read-only; never the session's own socket" (fun () ->
      let plain = createArgs ctx { name = "gui"; image = "fedora:45" }
      let sound = createArgs ctx { name = "gui"; image = "fedora:45"; sound = true }
      expect (lines (List.filter (fun a -> not (List.contains a plain)) sound)) """
        label=disable
        type=tmpfs,dst=/run/user/1000,tmpfs-mode=0700,chown=true
        type=bind,src=/run/user/1000/securebox/gui/pulse,dst=/run/user/1000/pulse,ro
        """
      assert (not (List.exists (String.contains "src=/run/user/1000/pulse") sound)))
    test "the sound front-end: its own socket, restricted clients, no module loading" (fun () ->
      expect (soundOverride ctx "gui") """
        # written by securebox: the sound front-end of the box gui
        pulse.properties = {
            server.address = [ { address = "unix:/run/user/1000/securebox/gui/pulse/native" client.access = "restricted" } ]
            pulse.allow-module-loading = false
        }

        """
      expect (lines (soundStartArgs ctx "gui")) """
        --user
        --quiet
        --collect
        --unit
        securebox-sound-gui
        --setenv
        PIPEWIRE_CONFIG_DIR=/run/user/1000/securebox/gui/sound
        --setenv
        PULSE_RUNTIME_PATH=/run/user/1000/securebox/gui/pulse
        --
        pipewire-pulse
        """)
    test "create --dbus: the filter's directory and the names, never the session bus itself" (fun () ->
      let plain = createArgs ctx { name = "gui"; image = "fedora:45" }
      let dbus = createArgs ctx { name = "gui"; image = "fedora:45"; dbus = [ "org.freedesktop.Notifications"; "org.example.App" ] }
      expect (lines (List.filter (fun a -> not (List.contains a plain)) dbus)) """
        label=disable
        type=tmpfs,dst=/run/user/1000,tmpfs-mode=0700,chown=true
        securebox.dbus=org.freedesktop.Notifications,org.example.App
        type=bind,src=/run/user/1000/securebox/gui/dbus,dst=/run/user/1000/dbus,ro
        """
      assert (not (List.exists (String.contains "/run/user/1000/bus") dbus)))
    test "the D-Bus filter: only the names granted are let through" (fun () ->
      expect (lines (proxyStartArgs ctx "gui" [ "org.freedesktop.Notifications"; "org.example.App" ])) """
        --user
        --quiet
        --collect
        --unit
        securebox-dbus-gui
        --
        xdg-dbus-proxy
        unix:path=/run/user/1000/bus
        /run/user/1000/securebox/gui/dbus/bus
        --filter
        --talk=org.freedesktop.Notifications
        --talk=org.example.App
        """)
    test "labelling is never off without a session grant" (fun () ->
      let every = createArgs ctx { name = "web"; image = "x"; shares = [ { path = "/srv/data"; readOnly = false } ]
                                   network = HostNetwork; publish = [ "127.0.0.1:1:1" ]; devices = [ "/dev/dri/renderD128" ] }
      assert (not (List.exists (String.startsWith "label=") every)))
    test "enter: a shell" (fun () -> expect (lines (execArgs ctx "dev" false [] "/home/ada" [])) """
                                       exec
                                       --interactive
                                       --tty
                                       --detach-keys=
                                       --env
                                       HOME=/home/ada
                                       --env
                                       USER=ada
                                       --workdir
                                       /home/ada
                                       --env
                                       SECUREBOX=dev
                                       --env
                                       TERM
                                       --env
                                       LANG
                                       dev
                                       sh
                                       -c
                                       exec "$(command -v "$0" || command -v bash || echo sh)" -l
                                       zsh
                                       """)
    test "enter: a command as root, without a terminal" (fun () ->
      expect (lines (execArgs { ctx with tty = false; passEnv = [] } "dev" true [] "/srv/data" [ "dnf"; "install"; "-y"; "git" ])) """
        exec
        --interactive
        --detach-keys=
        --user
        0
        --env
        HOME=/root
        --env
        USER=root
        --workdir
        /srv/data
        --env
        SECUREBOX=dev
        dev
        dnf
        install
        -y
        git
        """)
    test "a box with session grants is told where they are" (fun () ->
      let state mounts = parseInspect (Fixture.inspected "gui" "running" "\"1\"" mounts)
      let wayland = ("/run/user/1000/wayland-1", "/run/user/1000/wayland-0")
      let sound = ("/run/user/1000/securebox/gui/pulse", "/run/user/1000/pulse")
      let bus = ("/run/user/1000/securebox/gui/dbus", "/run/user/1000/dbus")
      assert (sessionEnv ctx (state [ dev ]) = [])
      assert (sessionEnv ctx (state [ wayland ]) = [ "XDG_RUNTIME_DIR=/run/user/1000"; "WAYLAND_DISPLAY=wayland-0" ])
      assert (sessionEnv ctx (state [ wayland; sound; bus ])
              = [ "XDG_RUNTIME_DIR=/run/user/1000"; "WAYLAND_DISPLAY=wayland-0"; "PULSE_SERVER=unix:/run/user/1000/pulse/native"
                  "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/dbus/bus" ])
      assert (hasBus ctx (state [ bus ]) && not (hasBus ctx (state [ wayland; sound ])))
      assert (hasSound ctx (state [ sound ]) && not (hasSound ctx (state [ wayland; bus ])))
      assert (List.map snd (sessionNeeds ctx (state [ wayland; sound; bus ])) = [ "/run/user/1000/wayland-1" ])
      assert (shares ctx (state [ dev; wayland; sound; bus; ("/srv/data", "/srv/data") ]) = [ "/srv/data" ])
      let told = execArgs ctx "gui" false (sessionEnv ctx (state [ wayland ])) "/home/ada" [ "foot" ]
      assert (String.contains "--env XDG_RUNTIME_DIR=/run/user/1000 --env WAYLAND_DISPLAY=wayland-0 " (String.join " " told)))
    test "a grant is securebox's own directory bound in place, not whatever is mounted there" (fun () ->
      // an image can declare volumes at these places, and bring a label along
      let volumes = Fixture.inspected "gui" "running" "\"1\"" [ dev ] |> Fixture.withVolume "/run/user/1000/dbus" |> Fixture.withVolume "/run/user/1000/pulse" |> Fixture.withVolume "/run/user/1000/wayland-0"
      let state = parseInspect volumes
      assert (not (hasBus ctx state) && not (hasSound ctx state) && sessionEnv ctx state = [] && sessionNeeds ctx state = [])
      // nor does another directory bound there count: the session's own sound socket, say
      let other = parseInspect (Fixture.inspected "gui" "running" "\"1\"" [ ("/run/user/1000/pulse", "/run/user/1000/pulse"); ("/run/user/1000", "/run/user/1000/dbus") ])
      assert (not (hasBus ctx other) && not (hasSound ctx other) && sessionEnv ctx other = []))
    test "rm takes the image's anonymous volumes with the box" (fun () ->
      assert (rmArgs "dev" = [ "rm"; "--force"; "--volumes"; "dev" ]))
    test "inspect's output" (fun () ->
      let state = parseInspect (Fixture.inspected "dev" "running" "\"1\"" [ dev; ("/srv/data", "/srv/data") ])
      let mounted = state.mounts = [ dev; ("/srv/data", "/srv/data") ]
      assert (state.name = "dev" && state.running && state.labelled && mounted)
      assert (not (parseInspect "dev|exited|\"1\"\n").running)
      assert (not (parseInspect "dev|running|null\n").labelled)
      let nothing = parseInspect ""
      assert (nothing.name = "" && not nothing.running && not nothing.labelled && List.isEmpty nothing.mounts))
    test "a label an image wrote cannot pass for securebox's, or add lines" (fun () ->
      // podman prints the label as JSON: a newline in it stays an escape on the first line
      let forged = parseInspect "dev|running|\"1\\n/home/ada/.local/share/securebox/dev/home\\t/home/ada\"\n"
      assert (not forged.labelled && List.isEmpty forged.mounts && not (ours ctx "dev" forged))
      assert (not (parseInspect "dev|running|\"1|running\"\n").labelled))
    test "a box is the name, the label and its home mount together" (fun () ->
      let state mounts = parseInspect (Fixture.inspected "dev" "running" "\"1\"" mounts)
      assert (ours ctx "dev" (state [ dev ]))
      assert (not (ours ctx "dev" (state [])))                                          // an image's label
      assert (not (ours ctx "dev" (state [ ("/elsewhere/dev/home", "/home/ada") ])))   // another data directory
      assert (not (ours ctx "de" (state [ dev ])))                                      // an id's prefix
      assert (not (ours ctx "dev" (parseInspect (Fixture.inspected "dev" "running" "null" [ dev ])))))
    test "shares, and the compositor's socket" (fun () ->
      let socket = ("/run/user/1000/wayland-1", "/run/user/1000/wayland-0")
      let state = parseInspect (Fixture.inspected "dev" "running" "\"1\"" [ dev; ("/srv/data", "/srv/data"); ("tmpfs", "/run/user/1000"); socket ])
      assert (shares ctx state = [ "/srv/data" ])
      assert (List.map snd (sessionNeeds ctx state) = [ "/run/user/1000/wayland-1" ])
      assert (sessionNeeds ctx (parseInspect (Fixture.inspected "dev" "running" "\"1\"" [ dev ])) = [])
      // the socket named the same on both sides is still not a share
      let same = parseInspect (Fixture.inspected "dev" "running" "\"1\"" [ dev; ("/run/user/1000/wayland-0", "/run/user/1000/wayland-0") ])
      assert (shares ctx same = []))
    test "the working directory maps only into a share" (fun () ->
      assert (workdir ctx [ "/home/ada/Projects/web" ] = "/home/ada/Projects/web/src")
      assert (workdir ctx [ "/home/ada/Projects/web/src" ] = "/home/ada/Projects/web/src")
      assert (workdir ctx [ "/home/ada/Projects/we" ] = "/home/ada")
      assert (workdir ctx [] = "/home/ada"))
    test "a box's directory" (fun () ->
      assert (boxHome ctx "dev" = "/home/ada/.local/share/securebox/dev/home")
      assert (purgeArgs ctx "dev" = [ "unshare"; "rm"; "-rf"; "--"; "/home/ada/.local/share/securebox/dev" ]))
  ]
