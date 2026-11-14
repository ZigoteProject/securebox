open Testing
open Box
open Podman

let private ctx = Fixture.ctx
let private lines (args: list<string>) = String.join "\n" args

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
        --passwd-entry
        ada:*:1000:1000::/home/ada:/bin/sh
        --security-opt
        no-new-privileges
        --mount
        type=bind,src=/home/ada/.local/share/securebox/dev/home,dst=/home/ada,relabel=private
        --workdir
        /home/ada
        fedora:45
        """)
    test "create, with every grant" (fun () ->
      expect (lines (createArgs ctx { name = "web"; image = "ubuntu:24.04"
                                      shares = [ { path = "/home/ada/Projects/web"; readOnly = false }
                                                 { path = "/srv/data"; readOnly = true } ]
                                      network = NoNetwork; publish = [ "127.0.0.1:8080:80" ]; gpu = true })) """
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
        --passwd-entry
        ada:*:1000:1000::/home/ada:/bin/sh
        --security-opt
        no-new-privileges
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
        /dev/dri
        ubuntu:24.04
        """)
    test "enter: a shell" (fun () -> expect (lines (execArgs ctx "dev" false "/home/ada" [])) """
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
      expect (lines (execArgs { ctx with tty = false; passEnv = [] } "dev" true "/srv/data" [ "dnf"; "install"; "-y"; "git" ])) """
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
    test "inspect's output" (fun () ->
      assert (parseInspect "1|running\n/home/ada/Projects/web\n/srv/data\n"
              = { ours = true; running = true; shares = [ "/home/ada/Projects/web"; "/srv/data" ] })
      assert (parseInspect "1|exited\n" = { ours = true; running = false; shares = [] })
      assert (parseInspect "<no value>|running\n" = { ours = false; running = true; shares = [] })
      assert (parseInspect "" = { ours = false; running = false; shares = [] }))
    test "the working directory maps only into a share" (fun () ->
      assert (workdir ctx [ "/home/ada/Projects/web" ] = "/home/ada/Projects/web/src")
      assert (workdir ctx [ "/home/ada/Projects/web/src" ] = "/home/ada/Projects/web/src")
      assert (workdir ctx [ "/home/ada/Projects/we" ] = "/home/ada")
      assert (workdir ctx [] = "/home/ada"))
    test "a box's directory" (fun () ->
      assert (boxHome ctx "dev" = "/home/ada/.local/share/securebox/dev/home")
      assert (purgeArgs ctx "dev" = [ "unshare"; "rm"; "-rf"; "--"; "/home/ada/.local/share/securebox/dev" ]))
  ]
