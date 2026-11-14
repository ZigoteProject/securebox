open Testing

[<Tests>]
let tests =
  testList "posix" [
    test "ids" (fun () ->
      assert (Posix.userId () > 0 && Posix.effectiveUserId () = Posix.userId () && Posix.groupId () > 0))
    test "a missing program is an error, and the process goes on" (fun () ->
      expect (Posix.exec "no-such-program-zz" [ "x" ]) "cannot run no-such-program-zz: No such file or directory")
    test "realPath resolves links and dots, and is empty for what isn't there" (fun () ->
      assert (Posix.realPath "/proc/self/../self/." = Posix.realPath "/proc/self")
      assert (String.startsWith "/proc/" (Posix.realPath "/proc/self") && Posix.realPath "/proc/self" <> "/proc/self")
      assert (Posix.realPath "/no/such/path" = "" && Posix.realPath "" = ""))
    test "isSocket" (fun () -> assert (not (Posix.isSocket "/proc/self") && not (Posix.isSocket "/no/such/path")))
    test "exists" (fun () -> assert (Posix.exists "/proc/self" && Posix.exists "/" && not (Posix.exists "/no/such/path")))
    test "the passwd entry" (fun () -> assert (Posix.userName () <> "" && String.startsWith "/" (Posix.userHome ())))
    test "a NUL in an argument is refused" (fun () ->
      expect (Posix.exec "true" [ "a\0b" ]) "cannot run true: an argument contains a NUL byte")
  ]
