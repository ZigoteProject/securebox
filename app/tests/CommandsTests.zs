open Testing
open Box
open Fixture

let private share = "/home/ada/Projects/web"
let private dir = "/home/ada/.local/share/securebox/dev"
let private ran (what: string) (calls: list<string>) = List.exists (String.startsWith what) calls

[<Tests>]
let tests =
  testList "commands" [
    test "enter a running box: inspect, then exec in the shared working directory" (fun () ->
      let (r, calls) = record (box $"1|running\n{share}\n") [] (fun () -> Commands.enter ctx "dev" false [ "make" ])
      assert (r = Ok 0 && List.length calls = 2)
      assert (ran "podman inspect " calls && ran "exec podman exec " calls)
      assert (String.contains $"--workdir {share}/src " (List.last calls))
      assert (String.endsWith " dev make" (List.last calls)))
    test "enter a stopped box: it is started first" (fun () ->
      let (r, calls) = record (box "1|exited\n") [] (fun () -> Commands.enter ctx "dev" false [])
      assert (r = Ok 0)
      assert (List.map (fun c -> List.item 1 (String.split " " c)) calls = [ "inspect"; "start"; "podman" ]))
    test "a container that isn't securebox's is left alone" (fun () ->
      for command in [ (fun () -> Commands.enter ctx "dev" false []); (fun () -> Commands.stop "dev")
                       (fun () -> Commands.rm ctx "dev" false); (fun () -> Commands.rm ctx "dev" true) ] do
        let (r, calls) = record (box "<no value>|running\n") [ dir ] command
        assert (Result.isError r)
        assert (List.length calls = 1 && ran "podman inspect " calls))
    test "a box that doesn't exist" (fun () ->
      let (r, calls) = record (box "") [] (fun () -> Commands.enter ctx "dev" false [])
      assert (r = Error "no box named 'dev'; create it with: securebox create dev")
      assert (List.length calls = 1))
    test "stop: only a running box is stopped" (fun () ->
      let (_, running) = record (box "1|running\n") [] (fun () -> Commands.stop "dev")
      let (_, stopped) = record (box "1|exited\n") [] (fun () -> Commands.stop "dev")
      assert (ran "podman stop dev" running && not (ran "podman stop" stopped)))
    test "rm keeps the home directory" (fun () ->
      let (r, calls) = record (box "1|running\n") [ dir ] (fun () -> Commands.rm ctx "dev" false)
      assert (r = Ok 0 && ran "podman rm --force dev" calls && not (ran "podman unshare" calls)))
    test "rm --purge deletes it, inside podman's user namespace" (fun () ->
      let (r, calls) = record (box "1|exited\n") [ dir ] (fun () -> Commands.rm ctx "dev" true)
      assert (r = Ok 0 && List.last calls = $"podman unshare rm -rf -- {dir}"))
    test "rm --purge after the container is gone still deletes the directory" (fun () ->
      let (r, calls) = record (box "") [ dir ] (fun () -> Commands.rm ctx "dev" true)
      assert (r = Ok 0 && List.last calls = $"podman unshare rm -rf -- {dir}")
      let (gone, _) = record (box "") [] (fun () -> Commands.rm ctx "dev" true)
      assert (Result.isError gone))
    test "create: home directory, create, start, passwd" (fun () ->
      let spec = { name = "dev"; image = "fedora:45"; shares = [ { path = share; readOnly = false } ] }
      let (r, calls) = record (box "") [ share ] (fun () -> Commands.create ctx spec)
      assert (r = Ok 0)
      assert (List.map (fun c -> List.item 1 (String.split " " c)) calls = [ $"{dir}/home"; "create"; "start"; "exec" ]))
    test "create: a share that isn't there stops it before podman" (fun () ->
      let spec = { name = "dev"; image = "fedora:45"; shares = [ { path = share; readOnly = false } ] }
      let (r, calls) = record (box "") [] (fun () -> Commands.create ctx spec)
      assert (r = Error $"cannot share '{share}': no such directory" && calls = []))
  ]
