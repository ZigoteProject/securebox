# securebox

Persistent Linux boxes from any container image, as easy as distrobox, that cannot see
your home directory or your session unless you share a path with them.

```sh
securebox create dev                                   # a Fedora box with its own empty home
securebox create web docker.io/library/ubuntu:24.04 --share ~/Projects/web
securebox enter web                                    # a shell; the working directory is kept inside a share
securebox enter web -- npm test                        # one command; its exit code is securebox's
securebox enter web --root -- apt install -y nodejs    # root, granted from the host side
securebox list
securebox stop web
securebox rm web                                       # keeps the box's home; --purge deletes it
```

One static binary of about 260 KB, written in [Z#](https://github.com/ZigoteProject/zsharp)
0.7.1. Podman is the only thing it needs at run time, and it is rootless only: securebox
refuses to run as root.

## Why

distrobox makes a container feel like your machine by giving it your machine: your home
directory read-write, `/` under `/run/host`, your session's sockets, the host's network,
and SELinux confinement off. That is the right trade for a trusted toolbox and the wrong
one for running a package's install script, a `curl | sh` installer, a build you don't
know, or a coding agent.

securebox starts from the other end. A new box has nothing of the host, and every grant
is a flag you pass at `create`.

| | distrobox default | securebox default |
|---|---|---|
| Home | host `$HOME`, read-write | a private directory per box |
| Host filesystem | `/` at `/run/host`, `/dev`, `/sys`, `/tmp` | none |
| Session (D-Bus, Wayland, podman socket, agents) | shared | none |
| Network, PID, IPC | the host's | private; outbound only |
| SELinux | disabled for the box | confined, per-box category |
| Root inside | passwordless `sudo` | none; `enter --root` from the host |
| Changes to the image | installs packages, creates a user | none beyond one passwd line |

## What a box can and cannot do

Inside a box, by default:

- you are yourself (same uid, same user name, `HOME` at the same path), with **no
  capabilities** and **no way to gain them**: `no-new-privileges` is set, so `sudo` and
  every other setuid program refuse to work;
- the home directory is the box's own, kept in `~/.local/share/securebox/NAME/home`;
- nothing of the host is mounted, no host environment variable is passed, `/run/user` does
  not exist;
- the network is podman's private rootless one: outbound works, services listening on the
  host's `127.0.0.1` are unreachable;
- SELinux (where the host has it) and seccomp confinement stay on.

To install software, enter as root from the outside: `securebox enter NAME --root`. Root in
the box is an unprivileged subordinate uid on the host.

What this does **not** protect against: kernel or container-runtime escapes (a box shares
the host's kernel; it is not a VM), exfiltration of what you did share (use
`--network none`), and resource exhaustion.

A directory shared read-write is a way back to the host: the box can edit `.git/hooks`, a
`Makefile` or `.envrc` in it, and that runs with your full privileges the next time you
run it on the host. Use `--share-ro` when the box only needs to read.

## Grants

All off by default, all given to `create`, all visible in `securebox list`.

| Flag | Grants |
|---|---|
| `-s`, `--share PATH` | the directory, read-write, at the same path (repeatable) |
| `--share-ro PATH` | the directory, read-only (repeatable) |
| `--network none` | no network at all |
| `--network host` | the host's network namespace, loopback included |
| `-p`, `--publish [IP:]HOST:BOX[/udp]` | a port, bound to `127.0.0.1` unless you give an address (repeatable) |
| `--gpu` | the GPU's render devices (`/dev/dri`) |

securebox refuses to share your home directory, anything that contains it, system
directories, and dot-directories of your home (`~/.ssh`, `~/.config`, …). On an SELinux
host, sharing a directory relabels it for containers, permanently; that is harmless for a
project directory.

Grants are fixed when the box is created. To change them, remove the box and create it
again: its home directory survives (`rm` keeps it, and `create` picks it up), packages
installed into the image do not.

There is no flag for arbitrary podman options, on purpose: it would void every line above.

## Building

Needs the Z# 0.7.1 toolchain, clang 23 or later, and zig (for the static build).

```sh
# the compiler: unpack zs-0.7.1-linux-x86_64.tar.gz from
# https://github.com/ZigoteProject/zsharp/releases/tag/v0.7.1 into .toolchain/
export PATH="$PWD/.toolchain/zs-0.7.1-linux-x86_64:$PATH"
zs doctor                                                # what a build needs, found or missing

zs build                                                 # app/build/securebox, a debug build
cd app && zs build --release --target x86_64-linux-musl  # the static binary, app/build/securebox
cp build/securebox ~/.local/bin/
```

`--target aarch64-linux-musl` builds for arm64 (built, never run on one).

## Testing

```sh
zs test            # 93 unit tests: validation, the exact podman arguments, the command flows
tests/e2e.sh       # 153 checks with real podman, on Fedora, Ubuntu and Alpine images
```

The end-to-end script creates boxes named `sbx-e2e-<pid>-*`, keeps their data in a
temporary directory, probes each box from the inside for everything claimed above, and
removes what it made. It needs python3 on the host and pulls the images that aren't local.

## Where things are

```text
app/               the securebox binary: Cli, Box (validation), Podman (argument lists),
                   Effects (the outside world), Commands, main
packages/argz/     an Argu-style argument parser for Z#: a union is the command line
packages/posix/    exec, user ids, isatty, chmod: all of the project's C (40 lines)
tests/e2e.sh       the end-to-end tests
DESIGN.md          the design: threat model, the podman command lines, what was verified
```

`SECUREBOX_DATA` moves the boxes' home directories somewhere else than
`$XDG_DATA_HOME/securebox`.

## Limits

- Linux and rootless podman only. Developed and tested on podman 6.1 with SELinux enforcing.
- **No graphical programs.** Wayland and ssh-agent grants were tested and left out: SELinux
  does not let a confined box connect to a socket of your session, and the only way around
  that is to turn the confinement off. X11 is left out because an X11 socket lets the box
  read your keystrokes.
- An image needs `sh` and a `sleep` that takes `infinity`; distroless images won't work.
- Give `create` a full image name (`docker.io/library/ubuntu:24.04`); podman cannot ask
  which registry a short name means.
- No export of apps to the host's desktop, and no manifests. `securebox enter NAME -- cmd`
  is the primitive to build those on.
- Z# is pre-1.0; this builds with 0.7.1.

[DESIGN.md](DESIGN.md) has the reasoning behind each of these.
