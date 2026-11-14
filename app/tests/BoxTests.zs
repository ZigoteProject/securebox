open Testing
open Box

let private ctx = Fixture.ctx

let private refused (r: result<string, string>) =
  match r with
  | Error e -> String.startsWith "refusing to share" e || String.contains "cannot be written" e
  | Ok _ -> false

// a test's name is one line
let private shown (s: string) = String.replace s "\n" "\\n"

let private goodNames = [ "dev"; "web-2"; "a.b_c"; "0x"; String.repeat 63 "a" ]
let private badNames = [ ""; "-x"; "--help"; "Dev"; "a/b"; ".."; ".x"; "a b"; "a\nb"; "é"; String.repeat 64 "a" ]

// sharePath gets paths with their links resolved: these are what it must refuse then
let private badShares =
  [ "/"; "/home"; "/home/ada"; "/var/home/ada"; "/var/home"
    "/home/ada/.ssh"; "/home/ada/.config/git"; "/var/home/ada/.ssh"; "/var/home/ada/.gnupg/x"
    "/home/ada/.local/share/securebox"; "/home/ada/.local/share/securebox/dev/home"
    "/etc"; "/etc/ssh"; "/usr/bin"; "/usr/lib"; "/boot"; "/dev/dri"; "/proc/1"; "/sys"; "/root"; "/root/x"
    "/var"; "/run"; "/tmp"; "/var/tmp"; "/var/lib/containers"; "/var/log"
    "/run/user"; "/run/user/1000"; "/run/user/1000/bus"; "/run/dbus"; "/run/systemd/private"; "/run/media"; "/run/mount"
    "/srv/a,b"; "/srv/a:b"; "/srv/a\nb" ]

let private badPorts =
  [ ""; "80"; "x:80"; "0:80"; "80:65536"; "8080:80/sctp"; "1.2.3:80:80"; "256.0.0.1:80:80"
    "::1:80:80"; "80:80,relabel"; "-1:80"; "80:+80" ]

[<Tests>]
let tests =
  testList "box" [
    testList "name takes" [ for n in goodNames -> test n (fun () -> assert (Box.boxName n = Ok n)) ]
    testList "name refuses" [ for n in badNames -> test $"<{shown n}>" (fun () -> assert (Result.isError (Box.boxName n))) ]
    testProperty "a name is never an option or a path" (fun (s: string) ->
      match Box.boxName s with
      | Ok n -> not (String.startsWith "-" n) && not (String.contains "/" n)
      | Error _ -> true)
    testList "share" [
      test "a project directory, by either name of the home" (fun () ->
        assert (Box.sharePath ctx "/home/ada/Projects/web" = Ok "/home/ada/Projects/web")
        assert (Box.sharePath ctx "/var/home/ada/Projects/web" = Ok "/var/home/ada/Projects/web"))
      test "outside the home" (fun () ->
        assert (Box.sharePath ctx "/var/data" = Ok "/var/data")
        assert (Box.sharePath ctx "/run/media/ada/usb" = Ok "/run/media/ada/usb")
        assert (Box.sharePath ctx "/tmp/build" = Ok "/tmp/build")
        assert (Box.sharePath ctx "/home/adax" = Ok "/home/adax"))
      test "the data directory wherever it is, and what holds it" (fun () ->
        let moved = { ctx with dataDir = "/srv/boxes"; offLimits = [ "/srv/boxes" ] }
        assert (refused (Box.sharePath moved "/srv/boxes") && refused (Box.sharePath moved "/srv/boxes/dev/home"))
        assert (refused (Box.sharePath moved "/srv"))
        assert (Box.sharePath moved "/srv/boxes2" = Ok "/srv/boxes2"))
    ]
    testList "share refuses" [ for p in badShares -> test (shown p) (fun () -> assert (refused (Box.sharePath ctx p))) ]
    test "what was typed for a share is made absolute; nothing typed is a mistake" (fun () ->
      assert (Box.absolutePath ctx "../assets/" = Ok "/home/ada/Projects/web/assets")
      assert (Box.absolutePath ctx "/srv//data/./x/.." = Ok "/srv/data")
      assert (Box.absolutePath ctx "" = Error "an empty path cannot be shared")
      assert (Result.isError (Box.absolutePath { ctx with cwd = "." } "etc")))
    test "the data directory is not the home or what holds it" (fun () ->
      assert (Box.dataPath ctx.homes "/home/ada/.local/share/securebox" = Ok "/home/ada/.local/share/securebox")
      assert (Box.dataPath ctx.homes "/srv/boxes" = Ok "/srv/boxes")
      for d in [ "/"; "/home"; "/home/ada"; "/var/home/ada"; "/var"; "relative"; "/srv/a,b" ] do
        assert (Result.isError (Box.dataPath ctx.homes d)))
    test "a name on the session bus is written out, and is not one that runs commands on the host" (fun () ->
      for n in [ "org.freedesktop.Notifications"; "org.kde.StatusNotifierWatcher"; "com.example.my-app._1" ] do
        assert (Box.busName n = Ok n)
      for n in [ ""; "org"; "org."; ".org.x"; "org..x"; "org.freedesktop.*"; "*"; "org.1x"; "org.x y"; "--talk=org.x"; "org.x,org.y"
                 "org.freedesktop.systemd1"; "org.freedesktop.Flatpak"; "org.freedesktop.DBus"; ":1.42" ] do
        assert (Result.isError (Box.busName n)))
    test "shares of one box: none twice, none inside a read-write one" (fun () ->
      let rw path = { path = path; readOnly = false }
      let ro path = { path = path; readOnly = true }
      assert (Result.isOk (Box.together [ rw "/srv/a"; rw "/srv/b"; ro "/srv/c" ]) && Result.isOk (Box.together []))
      assert (Result.isOk (Box.together [ ro "/srv/a"; rw "/srv/a/build" ]))      // inside a read-only one: the box cannot replace it
      assert (Result.isOk (Box.together [ rw "/srv/a"; rw "/srv/ab" ]))           // a prefix of the name is not inside
      for shares in [ [ rw "/srv/a"; ro "/srv/a/.git" ]; [ ro "/srv/a/.git"; rw "/srv/a" ]; [ rw "/srv/a"; rw "/srv/a/x/y" ]; [ rw "/srv/a"; rw "/srv/a" ]; [ ro "/srv/a"; ro "/srv/a" ] ] do
        assert (Result.isError (Box.together shares)))
    test "the runtime directory can be written where securebox writes it" (fun () ->
      assert (Box.runtimePath "/run/user/1000" = Ok "/run/user/1000")
      for p in [ "run/user"; "/run/us er"; "/run/$HOME"; "/run/a\"b"; "/run/a,b"; "/run/a=b" ] do
        assert (Result.isError (Box.runtimePath p)))
    test "network" (fun () ->
      assert (Box.network "private" = Ok Private && Box.network "none" = Ok NoNetwork && Box.network "host" = Ok HostNetwork)
      assert (Result.isError (Box.network "bridge")))
    test "publish binds 127.0.0.1 unless told otherwise" (fun () ->
      assert (Box.publish "8080:80" = Ok "127.0.0.1:8080:80")
      assert (Box.publish "5353:53/udp" = Ok "127.0.0.1:5353:53/udp")
      assert (Box.publish "0.0.0.0:8080:80/tcp" = Ok "0.0.0.0:8080:80/tcp"))
    testList "publish refuses" [ for p in badPorts -> test $"<{p}>" (fun () -> assert (Result.isError (Box.publish p))) ]
    test "image" (fun () ->
      assert (Box.image "ubuntu:24.04" = Ok "ubuntu:24.04")
      assert (Result.isError (Box.image "--privileged") && Result.isError (Box.image "") && Result.isError (Box.image "a b")))
    test "user name, home and mountable paths" (fun () ->
      assert (Box.userName "ada" = Ok "ada" && Result.isError (Box.userName "a:b") && Result.isError (Box.userName ""))
      assert (Result.isError (Box.mountable "relative") && Result.isError (Box.mountable "/a:b"))
      assert (Box.homePath "/home/ada" = Ok "/home/ada")
      for h in [ "/home/a|b"; "/home/a&b"; "/home/a\\b"; "/home/a:b"; "home" ] do
        assert (Result.isError (Box.homePath h)))
  ]
