# securebox — design

Status: 2026-11-14. Implemented: the five commands and the `--share`, `--share-ro`,
`--network`, `--publish`, `--gpu` and `--wayland` grants, with 125 unit tests and an
end-to-end script of 193 checks against real podman. The code has had a correctness review
and an independent security review; appendix D lists what they found and what was done.

securebox gives you a persistent, interactive Linux box from any container image, the way
distrobox does, but the box cannot see your home directory or your session unless you share
a path with it. One static binary written in Z# 0.7.1; podman is the only runtime dependency.

```sh
securebox create dev                      # a Fedora box with its own empty home
securebox create web ubuntu:24.04 --share ~/Projects/web
securebox enter web                       # a shell; cwd is kept when it is inside a share
securebox enter web -- npm test           # one command, exit code passed through
securebox enter web --root -- apt install -y nodejs
securebox create api --publish 8080:8080 --gpu
securebox create gui --wayland            # GUI programs; costs that box its SELinux confinement
securebox list
securebox stop web
securebox rm web                          # keeps the box's home; --purge deletes it too
```

## 1. Goals and non-goals

Goals:

- **As easy as distrobox.** `create`, `enter`, done. No config file, no daemon, no setup step.
- **Secure by default.** A new box gets nothing from the host: no home, no session sockets,
  no devices, no host network namespace. Every grant is an explicit flag at `create`.
- **Minimal.** Five commands. The tool only builds podman command lines; podman holds all state.
- **Fast.** Entering a running box costs two podman invocations and nothing else.
- **Single static binary**, rootless only.

Non-goals for v1:

- Docker, lilipod, remote podman, macOS, Windows. Podman on Linux only.
- Rootful boxes. securebox refuses to run as root. The request was "rootless by default";
  a rootful mode is deferred until someone needs it, because every default below would have
  to be re-argued for it.
- Exporting apps to the host desktop, `assemble`-style manifests, `upgrade`, `host-exec`.
  `securebox enter NAME -- cmd` is the primitive; a two-line wrapper script covers export.
- An escape hatch for arbitrary podman flags. It would void every guarantee in section 3;
  anyone who needs one can call podman directly.
- X11. An X11 socket lets the box log keystrokes and read other windows.
- An ssh-agent grant. Like Wayland it means a session socket, with the cost section 3
  describes, and unlike Wayland nobody has asked for it.
- Changing a box's grants after creation. Podman fixes mounts at create time; recreate the
  box (its home survives, packages installed into the image layer do not).

## 2. How it differs from distrobox

Distrobox column: read from the installed `distrobox-create` 1.8.2.5.

| | distrobox default | securebox default |
|---|---|---|
| Home | host `$HOME` mounted read-write | a private directory per box |
| Host filesystem | `/` at `/run/host`, `/dev`, `/sys`, `/tmp` | none |
| Session | `/run/user/UID` (D-Bus, Wayland, podman socket, agents) | none |
| Network / PID / IPC | host namespaces | private; outbound only |
| SELinux | `label=disable` | confined (`container_t`), per-box MCS category |
| Root inside | passwordless `sudo` | none; `--root` is granted from the host side |
| Setup inside the image | init script installs packages, creates the user | nothing is installed or modified |
| Implementation | POSIX shell | one native binary |

## 3. Security model

### Threat model

The adversary is **code running inside the box**: a package's install script, a build step,
a `curl | sh` installer, a coding agent, a compromised image. The asset is **everything on
the host outside what you shared**: SSH and GPG keys, browser profiles, tokens, dotfiles
(persistence through shell rc files), the session bus, host-local services.

Out of scope:

- Kernel and container-runtime escapes. The box shares the host kernel; this is not a VM.
- Exfiltration of what you did share. The network is on by default; use `--network none`.
- Resource exhaustion, beyond podman's default pids limit (2048).
- The user. Validation in section 5 guards against mistakes, not against the person at the
  keyboard, who can run podman directly.

One consequence worth stating in the README: a directory shared read-write is a channel
back to the host. The box can edit `.git/hooks`, a `Makefile` or `.envrc` in it, and that
code runs with full host privileges the next time you run it on the host. Use `--share-ro`
when the box only needs to read.

### Defaults

Each row was checked on this machine (podman 6.1.3, crun, pasta, SELinux enforcing,
Fedora 45 host) and is asserted by `tests/e2e.sh` on three images.

| Property | How | Observed |
|---|---|---|
| Runs as you, not root | `--userns=keep-id --user UID:GID` | `uid=1000`, files in shares keep your ownership |
| No capabilities | non-root user | `CapEff` and `CapPrm` are 0 |
| No privilege gain | `--security-opt no-new-privileges` | `NoNewPrivs: 1`; `sudo` refuses to run |
| SELinux confinement kept | podman default, never `label=disable` (but see `--wayland`) | `container_t:s0:cNN,cNN` |
| seccomp filter kept | podman default | `Seccomp: 2` |
| Private home | bind mount of the box's own directory, `relabel=private` | host home not visible; the home starts empty |
| No session access | nothing mounted | `/run/user` and `/run/host` do not exist |
| No host environment | `podman exec` passes only what is named; `--http-proxy=false` | no host variable, proxy settings included |
| No host `/etc/hosts` | `--hosts-file=none` | only localhost, the box's name and `host.containers.internal` |
| Host loopback unreachable | `--network pasta`, stated rather than left to `containers.conf` | a host service on `127.0.0.1` cannot be reached as `127.0.0.1`, as `host.containers.internal` or through the gateway; with `--network host` the same probe reaches it |
| Root without setuid | `podman exec --user 0`, invoked from the host | root in the box can write `/usr`; it is an unprivileged subuid on the host |

Podman's default capability bounding set is deliberately kept rather than `--cap-drop=all`:
the user's processes hold no capabilities either way, and `--root` needs the default set
for package managers to work. Host services that listen on all interfaces remain reachable
from the box, as they are from any machine on your LAN.

Two podman defaults had to be turned off, both found in review: podman copies the host's
`http_proxy`-style variables into a container (observed: a proxy URL with its password),
and starts the container's `/etc/hosts` from the host's.

### Grants

All off by default, all given at `create`, all visible in `securebox list` (which prints
podman's own mount and network columns, so the listing cannot drift from reality).

| Flag | Grants |
|---|---|
| `--share PATH` (repeatable) | the directory, read-write, at the same path |
| `--share-ro PATH` (repeatable) | the directory, read-only |
| `--network none` / `host` | no network / the host's network namespace |
| `--publish [IP:]HOST:BOX[/udp]` (repeatable) | a port; bound to `127.0.0.1` unless an IP is given (podman's own default is all interfaces) |
| `--gpu` | the GPU's render devices, `/dev/dri/renderD*` (not the display's card nodes) |
| `--wayland` | the Wayland compositor's socket, for GUI programs; **turns SELinux confinement off for that box** |

**What `--wayland` costs.** A GUI program has to connect to the compositor, a process of
the user's session. Tested on this machine: with the socket bind-mounted into a box,
`connect` fails under SELinux, with and without relabeling the socket file, and succeeds
with `--security-opt label=disable`. SELinux policy does not let `container_t` connect to
an unconfined process's socket, and there is no narrower switch. So a box created with
`--wayland` runs with SELinux labelling disabled (`spc_t`); a box created without it never
does. Everything else stays as in the table above, which the end-to-end script checks for
a `--wayland` box too: own home, no capabilities, no-new-privileges, seccomp, the private
network.

What the box gets is a runtime directory of its own, a tmpfs at `/run/user/UID` that is
yours and mode 0700, with one thing in it: the compositor's socket as `wayland-0`. The
session's other sockets (D-Bus, PipeWire, the podman socket, agents) are not there.
`enter` sets `XDG_RUNTIME_DIR` and `WAYLAND_DISPLAY` for such a box. Verified with a real
client: `wayland-info` in a Fedora box lists the compositor's interfaces.

Being a Wayland client is itself a grant: the box can open windows that look like any
other, and can use whatever protocols the compositor offers every client (on wlroots
compositors that may include screen capture and clipboard managers; GNOME and KDE restrict
those). There is no sound, no D-Bus and no portals, and X11-only programs do not run.

The GPU needs no such trade because policy allows it (`container_use_dri_devices` is on by
default).

## 4. What securebox runs

No shell is ever involved on the host; every podman call is an argv list.

### create

```text
podman create
  --name NAME --hostname NAME
  --label securebox=1
  --init --entrypoint ["sleep","infinity"]
  --userns=keep-id --user UID:GID
  --passwd-entry USER:*:UID:GID::HOME:/bin/sh
  --security-opt no-new-privileges
  --http-proxy=false --hosts-file=none
  --mount type=bind,src=DATA/NAME/home,dst=HOME,relabel=private
  --mount type=bind,src=P,dst=P,relabel=shared[,ro]        # one per share
  --workdir HOME
  --network pasta | none | host
  [--publish IP:HOST:BOX]                                   # one per port
  [--device /dev/dri/renderDnnn]                            # one per render node, with --gpu
  [--security-opt label=disable                             # with --wayland
   --mount type=tmpfs,dst=/run/user/UID,tmpfs-mode=0700,chown=true
   --mount type=bind,src=SOCKET,dst=/run/user/UID/wayland-0]
  IMAGE
podman start NAME
podman exec NAME sh -c '…read /etc/passwd…' sh UID USER HOME              # as the user
podman exec --user 0 NAME sh -c 'sed -i … /etc/passwd' sh UID USER HOME   # only if that failed
```

- `DATA` is `$SECUREBOX_DATA` when set, else `$XDG_DATA_HOME/securebox`, else
  `~/.local/share/securebox`. `DATA/NAME` is created with mode 0700 before the call.
  (`SECUREBOX_DATA` exists because `XDG_DATA_HOME` also moves podman's own image store,
  which the end-to-end tests must not do.) `DATA` may not be the home directory or hold it.
- `HOME` inside the box is the same path as on the host, and shares mount at their host
  path, with symbolic links resolved. Paths in build output, editor configs and git
  worktrees then mean the same thing on both sides.
- The default image is one constant, `registry.fedoraproject.org/fedora:latest`, fully
  qualified so short-name resolution cannot pick another registry.
- podman's errors and pull progress go to the terminal as they are.
- PID 1 is podman's init running `sleep infinity`. For images without `sleep`,
  `--entrypoint ["/run/podman-init","-P"]` also works (checked), but it relies on an
  internal podman path, so it stays a fallback that is not implemented.
- The box is started and checked, as the user: is it up, and does its passwd line have
  your name and home? It does when podman wrote the entry. An image that already has a
  user with your uid (ubuntu:24.04 ships `ubuntu` as 1000) keeps its own line; only then
  is one `sed` run as root in the box to rewrite that line's name and home, so that
  programs reading the home from passwd (OpenSSH) find the box's. A box that did not stay
  up makes `create` fail, and say that the image needs a `sleep`.
- A home directory left by an earlier box of the same name is reused, and `create` says so.

### enter

```text
1. podman inspect --type container --format
     '{{.Name}}|{{.State.Status}}|{{json (index .Config.Labels "securebox")}}{{range .Mounts}}{{"\n"}}{{.Source}}{{"\t"}}{{.Destination}}{{end}}' NAME
2. podman start NAME                       # only when not running
3. podman exec --interactive [--tty] --detach-keys= [--user 0]
     --env HOME=HOME --env USER=USER --workdir W --env SECUREBOX=NAME
     [--env XDG_RUNTIME_DIR=/run/user/UID --env WAYLAND_DISPLAY=wayland-0]
     --env TERM --env COLORTERM --env LANG --env LC_ALL
     NAME CMD...
```

- Step 1 answers in one call whether the container is the box, whether it runs, and what
  it has mounted. **A container is the box `NAME` only when three things hold:** its name
  is `NAME` (podman also accepts a name as the start of another container's id, so `db`
  or `fed` could otherwise land on a different box), it carries the label, and it has
  `DATA/NAME/home` mounted as the home. The label alone is not proof: a container made
  from an image with `LABEL securebox=1` carries it too, which is why the mount, which no
  image can bring along, is required. The label is printed as JSON so that nothing an image
  put in it can add lines. Every command that names a box goes through this check, so
  securebox never stops, removes or enters a container it did not create.
- When `inspect` fails, `podman container exists NAME` says whether that is "no such
  container" (exit 1) or podman failing; only the first is treated as a box that is gone.
- `W` is the host's working directory when it lies inside a share, otherwise `HOME`.
- `--tty` only when stdin and stdout are terminals. `--detach-keys=` stops podman from
  swallowing Ctrl-P.
- Without `CMD`, the box's shell is found in the box, preferring the host's `$SHELL` name:
  `sh -c 'exec "$(command -v "$0" || command -v bash || echo sh)" -l' zsh`.
- `HOME` and `USER` are always passed explicitly.
- A stopped `--wayland` box is started only when the compositor's socket is there;
  otherwise `enter` says so instead of letting podman fail on the missing mount source.
- The exit code is the command's. securebox's own failures exit 125, as podman's do.

### list, stop, rm

```text
podman ps --all --filter label=securebox=1 --format 'table {{.Names}}\t{{.State}}\t{{.Image}}\t{{.Mounts}}\t{{.Networks}}\t{{.Ports}}'
podman stop NAME
podman rm --force NAME
podman unshare rm -rf -- DATA/NAME        # with --purge only
```

`list` is an `exec` of `podman ps`, so there is no output parsing at all; it needs nothing
from the environment. `rm` keeps the home directory and prints its path; deleting user
data takes the explicit `--purge`. The purge runs inside podman's user namespace because
files the box's root made in the home belong to a subordinate uid, which the user alone
cannot delete. `rm NAME --purge` also works after the container is gone, but only when
`DATA/NAME/home` exists, so a directory that was never a box is never deleted, and never
when `NAME` is someone else's container or podman itself failed.

### State

There is no state file. A box is a podman container with the label `securebox=1` and its
home directory under `DATA` mounted as the home. Podman is the only source of truth.

## 5. Input validation

Arguments and the environment are the trust boundary: they end up in podman's argv and in
host paths.

- **Box name:** `[a-z0-9][a-z0-9_.-]{0,62}`. Cannot start with `-` (option injection) or
  contain `/` (path traversal under `DATA`).
- **Image:** must not start with `-`; otherwise podman validates it.
- **Share path:** must not be empty (an unset variable is a mistake, not the working
  directory), must exist and be a directory, and is **resolved with `realpath` before it
  is checked and mounted**. A symbolic link to `~/.ssh`, `/bin` (a link into `/usr`), or a
  home reached as `/home/you` where `/home` is a link to `/var/home`, is therefore judged
  as what it leads to. It must not contain `,`, `:` or control characters (`--mount` is
  comma-separated). Refused outright:
  - the home directory and everything that holds it, under each of its names: `$HOME`,
    the passwd entry's home, and both resolved;
  - `/etc`, `/usr`, `/boot`, `/dev`, `/proc`, `/sys`, `/root`, `/run/user`, `/var/lib`,
    `/var/log` and anything under them; `/var`, `/run`, `/tmp` and `/var/tmp` themselves
    (homes, removable media and build directories live under those);
  - `DATA` and `$XDG_RUNTIME_DIR`: themselves, what holds them, and anything inside;
  - any dot-entry directly under the home (`~/.ssh`, `~/.gnupg`, `~/.config`, `~/.local`…),
    which is where credentials and host configuration live.
- **User and home:** the name comes from the passwd database (`$USER` only when it has no
  entry) and the home from `$HOME` (the passwd entry's when unset). Both go into the
  passwd entry and the mounts, so neither may contain `:` or `,`; the home also may not
  contain `|`, `&` or `\`, which the `sed` of section 4 would read as syntax.
- **Data directory:** absolute, and not the home directory or what holds it: `rm --purge`
  deletes `DATA/NAME`.
- **Network:** one of three words. **Publish:** `[IP:]PORT:PORT[/tcp|/udp]`, IPv4 only.
- **Remote podman:** with `CONTAINER_HOST` or `CONTAINER_CONNECTION` set, podman talks to a
  service elsewhere, where these paths mean something else; securebox refuses to run.

Resolving links closes the mistakes that matter (and one attack: a box with a read-write
share could plant a link there for a later `--share` to follow). It matters for a second
reason: `relabel=shared` permanently changes the SELinux label of the shared tree on the
host (observed: `container_file_t:s0`). That is harmless for a project directory and
breaks things for `~/.ssh` (sshd stops reading it).

## 6. Architecture

```text
zs.toml                        [workspace] members = ["app", "packages/*"]
app/                           the securebox binary
  zs.toml                      depends on argz and posix by path
  src/main.zs                  parse, refuse root, read the environment, dispatch
  src/Cli.zs                   one argument union per command, and Command
  src/Box.zs                   Share, Network, CreateSpec, Ctx; all validation
  src/Podman.zs                pure functions: spec -> argv; parsing of inspect's output
  src/Effects.zs               the Host effect and its real handler
  src/Commands.zs              create, enter, list, stop, rm
  tests/                       unit tests, and Fixture.zs: a Host that records
packages/argz/                 the argument parser (section 7)
packages/posix/                exec and the other libc calls, with their C
tests/e2e.sh                   the end-to-end script (section 9)
```

`zs build` and `zs test` at the root cover every member. A `zs.toml` cannot be both a
workspace and a package (the root package is then not built), which is why the binary lives
in `app/`.

**Pure core.** `Podman.createArgs : Ctx -> CreateSpec -> list<string>` and
`Podman.execArgs` are pure. The security properties of section 3 are exactly the contents
of those lists, so they are pinned with `expect` tests: a flag cannot disappear without a
test diff.

**One effect for the outside world.** Z#'s effect handlers are its dependency-injection
mechanism (the compiler's own `logstat` example swaps real disk for memory this way).

```fsharp
effect Host =
  abstract capture    : list<string> -> result<ProcessResult, string>  // podman, waited for
  abstract exec       : list<string> -> int                            // podman replaces securebox
  abstract dirExists  : string -> bool
  abstract pathExists : string -> bool                                 // a socket, for one
  abstract realPath   : string -> string                               // "" when it isn't there
  abstract ensureDir  : string -> result<unit, string>                 // with parents, mode 0700
  abstract say        : string -> unit                                 // a line for the user
```

Tests handle `Host` with a recorder (`app/tests/Fixture.zs`), which makes the flows
checkable without podman: `rm` refuses a container without the label, `enter` starts a
stopped box, the working directory maps only into shares. Everything read from the
environment (user, uid, gid, home, data directory, cwd, shell name, tty) is gathered once
in `main` into a `Ctx` record and passed as a value. (The effect is in `Effects.zs`: in a
file named `Host.zs`, `Host.capture` would name a function of the module, not the
effect's operation.)

**Running podman.** Calls that are followed by more work (`inspect`, `create`, `start`,
`stop`, `rm`) go through `Process.run`: standard output is captured, so podman's chatter
(the container's id or name) never mixes into a command's output, and its errors still
reach the terminal. The last call of `enter` and of `list` is an `execvp`: securebox is
replaced by podman, so there is no parent process left to forward signals, relay the
terminal or pass the exit code on. In the real handler `Host.exec` returns only when
podman could not be started.

**The `posix` package.** Z# 0.7.1 has no `exec`, and Std has no user ids or `isatty`, so
all of the project's C and every `extern` live in one small package:

```fsharp
Posix.exec            : string -> list<string> -> string   // returns only on failure, with the reason
Posix.effectiveUserId : unit -> int                        // 0: securebox refuses to run
Posix.userId, Posix.groupId : unit -> int
Posix.isTerminal      : int -> bool
Posix.setMode         : string -> int -> bool              // chmod
Posix.realPath        : string -> string                   // "" when the path isn't there
Posix.exists          : string -> bool                     // access(2): sockets too
Posix.userName, Posix.userHome : unit -> string            // the passwd entry, "" without one
```

`exec` packs the argv into one buffer and hands it to one short C function
(`packages/posix/c/posix.c`) that checks the packing, then calls `execvp`. Two things it
does first, both found by testing: it flushes C's `stdout`, because the runtime prints
through it and the buffer would die with the process image (text printed before the exec
was lost), and it restores `SIGPIPE` to its default, because the runtime ignores it and an
ignored signal survives `exec`. An argument containing a NUL byte is refused in Z# before
the call. No `unsafe` block is needed anywhere.

**Errors.** Validation and flows use `result` and `?`; `main` prints
`securebox: <message>` to stderr and exits 125. Messages say what to do next
(`no box named 'web'; create it with: securebox create web`).

## 7. argz: an Argu-style argument parser for Z#

A separate package in the workspace (`packages/argz`, 16 tests), with no
dependency on securebox, extractable to its own repository when someone else wants it.

Argu's idea is that a union is the command line: each case is an argument, an exhaustive
`match` supplies its help text, and parsing and usage output are generated. argz keeps
that shape. This is securebox's real definition (`app/src/Cli.zs`, abridged):

```fsharp
open Argz

module Create =
  [<Derive(Arg)>]
  type Arg =
    | Name of string
    | Image of string
    | Share of string
    | ShareRo of string
    | Network of string

  let spec a =
    match a with
    | Name _    -> { help = "name of the new box"; kind = Positional }
    | Image _   -> { help = "image to create it from (default: Fedora)"; kind = Positional }
    | Share _   -> { help = "share a host directory read-write (repeatable)"; short = Some 's' }
    | ShareRo _ -> { help = "share a host directory read-only (repeatable)" }
    | Network _ -> { help = "private (the default), none or host" }

module Enter =
  [<Derive(Arg)>]
  type Arg =
    | Name of string
    | Root
    | Cmd of list<string>
  // spec likewise

[<Derive(Arg)>]
type Command =
  | Create of list<Create.Arg>
  | Enter of list<Enter.Arg>
  | List

let spec a =
  match a with
  | Create _ -> Argz.command "create a box" Create.spec
  | Enter _  -> Argz.command "open a shell in a box, or run a command in it" Enter.spec
  | List     -> { help = "list the boxes"; kind = Command }

// in main:  Argz.parse Cli.spec "securebox" args : result<list<Cli.Command>, ArgError>
```

Adding a case without describing it is a compile error, which is the property that makes
Argu pleasant.

- **Result:** the cases in command-line order, as a list. `securebox create dev -s /a`
  parses to `[ Create [ Name "dev"; Share "/a" ] ]`. The consumer folds the list into its
  own record, so "repeatable", "last one wins" and "required" are the consumer's two-line
  choices and argz needs no `GetResult`/`GetResults` family.
- **Kinds:** a case is a `Flag` (the default: `ShareRo` is `--share-ro`, a case without a
  field is a switch), a `Positional` (filled in declaration order) or a `Command` (a bare
  word, the case's name).
- **Subcommands:** a `Command` case holds the list of its own argument union, and
  `Argz.command help childSpec` wires the child's description in. Commands nest to any
  depth. A `Command` case without a field (`List`) takes no arguments: what follows it is
  its own `--help` or an error.
- **Grammar:** `--flag value`, `--flag=value`, `-s value`; `--` makes every later token a
  positional; a positional whose field is `list<string>` takes everything that is left,
  options included (`enter web -- npm test --watch`).
- **Help:** `--help` or `-h` at any level returns `Error (Help text)` with that level's
  usage, so `securebox --help` lists the commands and `securebox create --help` the
  arguments of `create`. Everything else wrong is `Error (Invalid message)`.
- **Field types:** `string`, `int`, `list<_>`. A new one is an `impl Arg<T>`.

Where it differs from Argu, and why:

- **Descriptions are functions, not an interface on the union.** A Z# derive is expanded
  where its type is declared, so it cannot call a trait impl for that type, which can only
  be written after the declaration (`Derive(Arg) on CreateArg: … does not implement
  ArgSpec`, and an impl before the type is `unknown type`). The description is therefore
  passed in: to `Argz.parse` at the top, and through `Argz.command` for a subcommand. A
  description wired to the wrong union is caught at parse time
  (`the description given is another union's`), not by the type checker.
- **Metadata is in the `match`, not in attributes** (`short = Some 's'`,
  `kind = Positional`): a derive cannot read custom attributes yet (ROADMAP: "field
  attributes for derives").
- **Constructors are unique per module** in Z#, so each command's union sits in its own
  nested module (`Create.Name`, `Enter.Name`). A derive then sees the case name qualified
  (`Cli.Create.Name`); argz uses the last part.

Left out of argz 0.1: cases with more than one field, environment-variable fallbacks,
combined short flags (`-it`), "did you mean". Z#'s ROADMAP lists a first-party `cli`
package ("argument parsing derived from a record") after 0.7; argz stays small so that
moving to it later is cheap.

## 8. Build and distribution

```sh
export PATH="$PWD/.toolchain/zs-0.7.1-linux-x86_64:$PATH"   # the 0.7.1 release, unpacked
zs build                                                    # app/build/securebox (debug)
zs test                                                     # every member's tests
cd app && zs build --release --target x86_64-linux-musl     # the static binary
```

- The release build is a static binary cross-linked through `zig cc`: 340 KB for x86-64,
  354 KB for arm64 (`aarch64-linux-musl`), C shim included. A run that only parses its
  arguments takes about half a millisecond.
- Build needs: Z# 0.7.1 (`.toolchain/`, not committed), clang 23+, zig.
- Runtime needs: podman 5.3 or later (`--hosts-file`), with pasta, its rootless network
  since 5.0. Developed and tested on 6.1 only. No version probe at run time.
- Z# is pre-1.0 and may break source between releases. Pin 0.7.1 in CI and upgrade
  deliberately using its CHANGELOG's "to rewrite" notes.

## 9. Testing

- **Unit (`zs test`, 125 tests):** validation tables and a property test (no accepted name
  starts with `-` or contains `/`); `expect` tests of `createArgs` and `execArgs`, which
  pin the security flags, and a test that labelling is never off without `--wayland`; the
  ownership check against an image's label, another data directory and an id prefix; the
  command flows under the recording `Host` handler; argz parse tables and `expect` tests
  of usage text; the posix functions.
- **End to end (`tests/e2e.sh`, 193 checks):** the built binary against real podman, on
  Fedora, Ubuntu and Alpine images: every row of section 3's table probed from inside the
  box, shares, exit codes, the lifecycle, the grants (a `--wayland` box included, where a
  compositor is running), refusals, and containers that are not securebox's. It keeps its
  boxes' data in a temporary `SECUREBOX_DATA`, tries the refusals against a home directory
  it made, and removes everything. This script is the acceptance test for "secure by
  default".

The network check has a control: a box with `--network host` runs the same probe and
reaches the host's listener, so "unreachable" elsewhere is the isolation and not a probe
that cannot work. The first version of the script had no such control and could not fail.

## 10. Milestones

| | Scope | Done when |
|---|---|---|
| M0 ✅ | Spikes: the argz derive with subcommands; `exec` of `podman exec -it` through the C shim; a static musl build | done 2026-11-14, appendix B |
| M1 ✅ | `create`, `enter`, `list`, `stop`, `rm`; `--share`, `--share-ro`, `--network`; tests | done: the end-to-end script passes on three images |
| M2 ✅ | `--publish`, `--gpu`, `--wayland`; the passwd fix-up for images with a clashing uid | done; `--wayland` at the cost section 3 states, `--ssh-agent` not built |
| Review ✅ | a correctness review and an independent security review | done 2026-11-14; appendix D |

## 11. Open questions and known limits

1. **Relabel cost.** `relabel=shared` on a very large tree may be slow at container start.
   Measure on a large checkout before adding any knob.
2. **Empty home.** A new box home has no dotfiles, so shells start with the distribution's
   defaults. Copying `/etc/skel` on first enter is a few lines if it turns out to be missed.
3. **Images without `sleep` or `sh`.** A box needs both (PID 1, and the shell lookup and
   passwd fix-up). Distroless images are out.
4. **Short image names.** podman may want to ask which registry a short name means, and
   `create` does not give it a terminal to ask on. Use a full name
   (`docker.io/library/ubuntu:24.04`) or configure short-name aliases.
5. **A renamed passwd line keeps its old group names.** On ubuntu the user is `ada` but
   its group is still called `ubuntu`; only the name is cosmetic, the ids are right.
6. **`--wayland` boxes and the compositor.** The socket is mounted when the box starts.
   Such a box cannot be started without a compositor running (`enter` says so), and after
   logging out and in it has the old socket until `securebox stop NAME` and a new `enter`.
7. **`list` trusts the label.** It is `podman ps` filtered by label, so a container made
   from an image that carries `LABEL securebox=1` shows up in it. No command acts on one.
8. **No sound, D-Bus or portals** in any box.

## Appendix A: what was verified, and how

Throwaway containers on podman 6.1.3 (rootless, crun, pasta, SELinux enforcing), images
`fedora:45` and `ubuntu:24.04`, created with the argv of section 4 and removed afterwards.

| Probe | Result |
|---|---|
| `id`, `$HOME`, `getent passwd` (fedora) | uid 1000, host username, home at the host path |
| `env` | `HOME`, `HOSTNAME`, `PATH` only |
| `/proc/self/status` as user | `CapPrm` 0, `CapEff` 0, `NoNewPrivs` 1, `Seccomp` 2 |
| `/proc/self/attr/current` | `system_u:system_r:container_t:s0:c51,c284` |
| `ls /run/user /run/host` | no such file or directory |
| `touch /usr/x` as user | permission denied |
| `sudo -n id` | refused: the "no new privileges" flag is set |
| `podman exec --user 0`: `touch /usr/x` | succeeds |
| write to a `--share`; write to a `ro` share | succeeds; read-only file system |
| host listener on `127.0.0.1`, from the box via `127.0.0.1`, `169.254.1.2`, `host.containers.internal` | cannot connect on any of the three (curl exit 7) |
| outbound HTTPS | 200 |
| `podman exec … sh -c 'exit 42'` | exit code 42 |
| shell fallback with `zsh` missing | bash login shell, `TERM` and `SECUREBOX` set, cwd correct |
| step 1's `inspect` format; `list`'s `ps` format | print as described |
| ubuntu: `$HOME` without and with `-e HOME` | `/home/ubuntu`; the host path |

Not verified: podman versions other than 6.1.3, hosts without SELinux, and arm64 (the
binary is built for it, never run).

## Appendix B: stage 0 results

Toolchain: the `zs-0.7.1-linux-x86_64` release archive (sha256 `15c03d3a…04a1a6`, as GitHub
lists it), with the host's clang 23.1.5 and zig 0.16.0; `zs doctor` reports everything
needed as found.

| Spike | Result |
|---|---|
| argz derive, with subcommands | works; 16 tests pass, two of them `expect` tests of usage text |
| `Posix.exec "podman" ["exec"; "-i"; "-t"; …]` under a pseudo-terminal | the box sees `/dev/pts/0`; exit code 42 comes back as securebox's |
| the same without a terminal | `-t` left out (`isTerminal`), exit code passed through |
| output printed before `exec` | lost at first; kept after the shim's `fflush` |
| signals in the exec-ed program | `SigIgn` and `SigBlk` both 0 after the shim's `SIGPIPE` reset |
| file descriptors across `exec` | only 0, 1 and 2 are inherited |
| `Process.run "podman" ["inspect"; …]` | output and exit code captured (`1\|running`; 125 for a missing container) |
| static build, x86-64 and arm64 | `statically linked, stripped`; the x86-64 one runs; 122 KB and 139 KB for the stage 0 skeleton |
| whole workspace | `zs test`: 19 passed, 0 failed |

What Z# 0.7.1 does that the design had to follow, for whoever writes M1:

- There is no `elif` (write `else if`), and an expression cannot continue on a line that
  starts with an operator.
- A record cannot contain itself; recursion goes through a union declared with `and`.
- A derive is expanded at the type's declaration (section 7), and `Shape.cases` gives
  module-qualified names for a union declared outside the main file.
- A library's main file must be named after the package (`src/Argz.zs` with
  `main = "src/Argz.zs"`) for its module to be `Argz` in its own tests.
- `String.indexOf` and `lastIndexOf` return an `option`; a C string becomes a Z# string
  with `String.ofCStr`; `String.bytes` gives the `span<u8>` an `extern` takes as pointer
  and length.
- `zs test --update` rewrites one failing `expect` per run.
- **A name from an opened module wins over a later definition of the same name in the
  opening file.** `open Argz` followed by `let parse …` and a call of `parse` calls
  `Argz.parse`. Reproduced with two plain files and no packages. This looks like a
  compiler bug; until it is settled, do not reuse an opened module's names.

## Appendix C: end-to-end results

`tests/e2e.sh` on podman 6.1.3 (rootless, crun, pasta, SELinux enforcing, a GNOME Wayland
session), images `fedora:45`, `ubuntu:24.04` and `alpine:latest`: 193 passed, 0 failed.

Per image: the home starts empty; the uid, `HOME` and passwd entry; zero capabilities,
no-new-privileges, seccomp and `container_t`; no `/run/user` or `/run/host`, no host
environment, no `XDG_RUNTIME_DIR`; the host's loopback unreachable three ways and a
published port bound to `127.0.0.1`; a read-write share given through a symbolic link, a
read-only share, the working directory; `--root`; exit codes and standard input; `list`,
`stop`, restart on `enter`; `rm` keeping the home and `--purge` deleting it, root-made
files included.

Once: `--network host` as the control for the network checks; `--network none`; the
host's proxy variables kept out; `--gpu` with render nodes only; a `--wayland` box (the
socket alone in a private runtime directory, the compositor answering, capabilities and
no-new-privileges unchanged); nineteen refusals, those about the home against a fake one (the home under each
name, links to it, the runtime and data directories, an empty path, a remote podman, …);
two foreign containers, one from an image carrying the label, left alone by `enter`,
`stop`, `rm` and `rm --purge` together with the directories of their names; a directory
that was never a box not purged.

Separately, by hand: `wayland-info` installed in a Fedora `--wayland` box lists the
compositor's interfaces.

Entering a running box, median of 15 runs on this machine before the review changes:
`podman exec NAME true` takes 227 ms and `securebox enter NAME -- true` 268 ms. The 40 ms
are the one `podman inspect`; securebox's own start-up is under a millisecond.

## Appendix D: the reviews

Two reviews of commit `1d03749`: a correctness review, and a security review by a reader
who had not seen the design discussion. Every finding below was reproduced or confirmed in
the code before it was fixed, and each fix has a unit or end-to-end test.

| Finding | Severity | What was done |
|---|---|---|
| A box could plant a symbolic link in a read-write share for a later `--share` to follow to `~/.ssh` or the home; `/bin`, `/lib` and a home behind `/home -> /var/home` passed the same way | medium | shares are resolved with `realpath` before they are checked and mounted |
| `--share ""` (an unset variable) shared the working directory | medium | an empty path is refused |
| `/run/user/UID` could be shared: the session bus, the podman socket, the agents | medium | `/run/user`, `$XDG_RUNTIME_DIR`, `/root`, `/tmp`, `/var/lib`, `/var/log` refused |
| The data directory was only protected where it sat under a dot-directory | low | `DATA` is refused as a share, with what holds it and what is in it |
| A box name was also matched as the start of another container's id, so `rm db` could remove a different box | low | the inspected container's name must equal the name asked for |
| The label was the only proof of ownership, and an image can carry it (confirmed: `securebox stop` acted on such a container) | low | the box's home mount is required too; the label is read as JSON |
| `rm --purge` treated any podman failure as "gone" and deleted `DATA/NAME` whatever it was | low | "gone" is `podman container exists` saying so; only a directory with `home` in it is purged; `DATA` may not be the home or hold it |
| podman's defaults copied the host's proxy variables (with credentials) and `/etc/hosts` into the box | low | `--http-proxy=false --hosts-file=none` |
| `create` reported success for a box that had not stayed up, and blamed a missing `sleep` for any failure | low | a box that is not running fails `create`; the passwd step reports for itself |
| `create` always ran one command as root in the box, and `HOME` reached `sed` unescaped | low | the check runs as the user, root only for images with a clashing uid; `|`, `&`, `\` refused in `HOME` |
| The network, the user and the podman in use depended on configuration | hardening | `--network pasta` and `--user UID:GID` are stated; `CONTAINER_HOST` is refused; `--gpu` passes render nodes only |
| `securebox list --help` printed the top-level usage; `list create x` parsed as two commands | bug | a command without a field takes nothing, and has its own help |
| `list` and `stop` failed when `$USER` was unset | bug | the name comes from the passwd database; `list` reads no environment |
| The end-to-end loopback check could not fail, and the refusals were tried on the real home | tests | a `--network host` control and a gateway probe; refusals against a fake home |

Reviewed and found sound: no user-controlled string becomes a podman option or an extra
field of `--mount` or `--passwd-entry`; values reach the in-box shell scripts as positional
parameters, never as script text; the C shim's bounds; the argument parser.

Left as it is, knowingly: the share check cannot stop a user who shares a directory and
then replaces part of its path with a link while the box exists (the mount is fixed at
create); `list` shows a container whose image carries the label.

## Sources

- Z# 0.7.1: <https://github.com/ZigoteProject/zsharp/releases/tag/v0.7.1>; at that tag,
  `README.md`, `ROADMAP.md`, `docs/guide/06-traits.md`, `08-programs.md`,
  `09-c-interop.md`, `docs/spec/07-traits.md`, `docs/reference/Diagnostics.Process.md`,
  `lib/std/Diagnostics/Process.zs`, `examples/logstat`.
- distrobox 1.8.2.5: the installed `distrobox-create` script.
- podman 6.1.3: `podman run --help`, `podman exec --help`, and the probes above.
