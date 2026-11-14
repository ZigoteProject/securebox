open Testing

[<Tests>]
let tests =
  testList "posix" [
    test "ids" (fun () ->
      assert (Posix.userId () > 0 && Posix.effectiveUserId () = Posix.userId () && Posix.groupId () > 0))
    test "a missing program is an error, and the process goes on" (fun () ->
      expect (Posix.exec "no-such-program-zz" [ "x" ]) "cannot run no-such-program-zz: No such file or directory")
    test "a NUL in an argument is refused" (fun () ->
      expect (Posix.exec "true" [ "a\0b" ]) "cannot run true: an argument contains a NUL byte")
  ]
