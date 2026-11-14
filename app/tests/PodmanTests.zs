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
    test "labelling is never off without --wayland" (fun () ->
      let every = createArgs ctx { name = "web"; image = "x"; shares = [ { path = "/srv/data"; readOnly = false } ]
                                   network = HostNetwork; publish = [ "127.0.0.1:1:1" ]; devices = [ "/dev/dri/renderD128" ] }
      assert (not (List.exists (String.startsWith "label=") every)))
    test "enter: a shell" (fun () -> expect (lines (execArgs ctx "dev" false false "/home/ada" [])) """
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
      expect (lines (execArgs { ctx with tty = false; passEnv = [] } "dev" true false "/srv/data" [ "dnf"; "install"; "-y"; "git" ])) """
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
    test "enter a --wayland box: where the socket is" (fun () ->
      let plain = execArgs ctx "gui" false false "/home/ada" [ "foot" ]
      let wayland = execArgs ctx "gui" false true "/home/ada" [ "foot" ]
      assert (List.filter (fun a -> not (List.contains a plain)) wayland = [ "XDG_RUNTIME_DIR=/run/user/1000"; "WAYLAND_DISPLAY=wayland-0" ]))
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
      assert (waylandSource ctx state = Some "/run/user/1000/wayland-1")
      assert (waylandSource ctx (parseInspect (Fixture.inspected "dev" "running" "\"1\"" [ dev ])) = None)
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
