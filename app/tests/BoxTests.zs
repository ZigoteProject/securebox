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

let private badShares =
  [ "/"; "/home"; "/home/ada"; "/home/ada/"; "/home/ada/Projects/.."
    "/home/ada/.ssh"; "/home/ada/.config/git"; "/home/ada/Projects/../.gnupg"
    "/home/ada/.local/share/securebox/dev/home"
    "/etc"; "/etc/ssh"; "/usr/lib"; "/boot"; "/dev/dri"; "/proc/1"; "/sys"; "/var"; "/run"
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
      test "a project directory" (fun () ->
        assert (Box.sharePath ctx "/home/ada/Projects/web" = Ok "/home/ada/Projects/web"))
      test "relative to the working directory, and normalized" (fun () ->
        assert (Box.sharePath ctx "../assets/" = Ok "/home/ada/Projects/web/assets")
        assert (Box.sharePath ctx "/srv//data/./x/.." = Ok "/srv/data"))
      test "outside the home" (fun () ->
        assert (Box.sharePath ctx "/var/data" = Ok "/var/data")
        assert (Box.sharePath ctx "/run/media/ada/usb" = Ok "/run/media/ada/usb")
        assert (Box.sharePath ctx "/home/adax" = Ok "/home/adax"))
    ]
    testList "share refuses" [ for p in badShares -> test (shown p) (fun () -> assert (refused (Box.sharePath ctx p))) ]
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
    test "user name and mountable paths" (fun () ->
      assert (Box.userName "ada" = Ok "ada" && Result.isError (Box.userName "a:b") && Result.isError (Box.userName ""))
      assert (Result.isError (Box.mountable "relative") && Result.isError (Box.mountable "/a:b")))
  ]
