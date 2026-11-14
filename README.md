# securebox

Persistent Linux boxes from any container image, as easy as distrobox, that cannot see
your home directory or your session unless you share a path with them.

```sh
securebox create dev                                   # a Fedora box with its own empty home
securebox create web docker.io/library/ubuntu:24.04 --share ~/Projects/web
securebox enter web                                    # a shell; the working directory is kept inside a share
securebox enter web -- npm test                        # one command; its exit code is securebox's
securebox enter web --root -- apt install -y nodejs    # root, granted from the host side
securebox create gui --wayland --sound                 # GUI programs with sound (see what it costs, below)
securebox list
securebox stop web
securebox rm web                                       # keeps the box's home; --purge deletes it
```

One static binary of about 630 KB, written in [Z#](https://github.com/ZigoteProject/zsharp)
0.7.1. Podman is the only thing it needs at run time, and it is rootless only: securebox
refuses to run as root.

## Install

Each [release](https://github.com/ZigoteProject/securebox/releases) has a static binary
for x86-64 Linux:

```sh
v=0.1.1
curl -fsSLO "https://github.com/ZigoteProject/securebox/releases/download/v$v/securebox-$v-x86_64-linux.tar.gz"
curl -fsSLO "https://github.com/ZigoteProject/securebox/releases/download/v$v/SHA256SUMS"
sha256sum --check SHA256SUMS
tar xzf "securebox-$v-x86_64-linux.tar.gz"
install -Dm 755 "securebox-$v-x86_64-linux/securebox" ~/.local/bin/securebox
securebox --version
```

It needs rootless podman 5.3 or later. For arm64, or from source, see [Building](#building).
[CHANGELOG.md](CHANGELOG.md) has what each release changed.

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
- nothing of the host is mounted, no host environment variable is passed (proxy settings
  included), `/run/user` does not exist;
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
| `--gpu` | the GPU's render devices (`/dev/dri/renderD*`) |
| `--wayland` | the Wayland compositor's socket, for GUI programs (*) |
| `--sound` | playing and recording sound, through a front-end of the box's own (*) |
| `--dbus NAME` | calls to the interface of that name on your session bus, through a filter (repeatable) (*) |

(*) These three reach into your desktop session, and on an SELinux host a box with any of
them runs **without SELinux confinement**. They cannot be combined with `--network host`.
See below.

securebox refuses to share your home directory, anything that contains it, system
directories, your session's runtime directory (`/run/user/UID`), its own data, and
dot-directories of your home (`~/.ssh`, `~/.config`, …). A path is judged by what it leads
to, so a symbolic link to any of those is refused too. On an SELinux host, sharing a
directory relabels it for containers, permanently; that is harmless for a project
directory.

One box cannot have a share inside another of its read-write shares (the box could swap
the inner one for a link), and a stopped box is started only if each of its shares is
still the directory it was when the box was created.

### Desktop programs: `--wayland`, `--sound`, `--dbus`

A box created with any of these gets a private runtime directory (`XDG_RUNTIME_DIR`) that
holds only what was granted, and `enter` tells programs where each thing is.

- **`--wayland`**: the compositor's socket. Wayland programs open their windows on your
  desktop; add `--gpu` for accelerated rendering. A Wayland client can do what the
  compositor lets any client do. On GNOME and KDE that excludes capturing the screen and
  typing into other windows. **On wlroots compositors (sway, Hyprland, …) it includes
  both**: there, treat `--wayland` as giving the box your desktop.
- **`--sound`**: programs can play sound, and also **record**: the microphone, and what
  other programs are playing. The box does not get your sound server's socket: whoever has
  that can make the server load modules, which create files and open network ports on the
  host. It gets the socket of a second PulseAudio front-end that securebox runs for the box
  alone, with module loading turned off. Through it the box can also see which programs
  are using sound, but not change volumes or devices. PipeWire's own socket is not shared
  either, so cameras and screen sharing stay out of reach. Needs PipeWire on the host.
- **`--dbus NAME`**: the box may call the interface of that name on your session bus, for
  instance `--dbus org.freedesktop.Notifications`. It never gets the bus itself. Whoever
  holds the session bus can ask systemd to run any command as you, or ask the keyring for
  your passwords, so securebox runs a filter (`xdg-dbus-proxy`) between the bus and the
  box. The filter lets through calls to the interface named like the bus name, and
  nothing else the program behind that name offers (gnome-shell answers to notification
  names and to remote-desktop requests on the same connection). **Each name you grant is
  your decision about that service**: securebox refuses two names that plainly run
  commands on the host, and that is a courtesy, not a list of what is safe. Don't grant
  `org.freedesktop.secrets`, `org.gnome.Shell`, `ca.desrt.dconf` or a portal to a box you
  don't trust. A program that only needs *a* bus of its own can start
  one inside the box (`dbus-run-session`), which needs no grant.

The cost, on an SELinux host: SELinux does not let a confined container connect to a
socket of your session, and there is no narrower switch, so a box with any of these runs
with SELinux labelling disabled. Its other protections are unchanged (own home, no
capabilities, no-new-privileges, seccomp, private network, nothing else of the session),
and boxes created without these flags keep their confinement.

A `--wayland` box needs the compositor running to start, and after you log out and in
again it needs `securebox stop NAME` before the next `enter`. `--sound` and `--dbus` run
their front-end and filter as units of your systemd user session, started by `create` and
`enter` and stopped by `stop` and `rm`; `--dbus` needs `xdg-dbus-proxy` on the host.
There are no portals, and X11-only programs do not run.

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
zs test            # 158 unit tests: validation, the exact podman arguments, the command flows
tests/e2e.sh       # 254 checks with real podman, on Fedora, Ubuntu and Alpine images
```

The end-to-end script creates boxes named `sbx-e2e-<pid>-*`, keeps their data in a
temporary directory, probes each box from the inside for everything claimed above, tries
the refusals against a home directory it made for the purpose, and removes what it made. It needs python3 on the host and pulls the images that aren't local.

## Where things are

```text
app/               the securebox binary: Cli, Box (validation), Podman (argument lists),
                   Effects (the outside world), Commands, main
packages/argz/     an Argu-style argument parser for Z#: a union is the command line
packages/posix/    exec, realpath, user ids, isatty, chmod: all of the project's C (60 lines)
tests/e2e.sh       the end-to-end tests
DESIGN.md          the design: threat model, the podman command lines, what was verified
```

`SECUREBOX_DATA` moves the boxes' home directories somewhere else than
`$XDG_DATA_HOME/securebox`. It cannot be your home directory or hold it.

The code has had a correctness review and two independent security reviews, the second
of the desktop grants; DESIGN.md, appendix D, lists what they found and what was done
about each finding.

## Limits

- Linux and rootless podman 5.3 or later, the local one only (not `CONTAINER_HOST`).
  Developed and tested on podman 6.1 with SELinux enforcing.
- No X11 (an X11 socket lets the box read your keystrokes), and no ssh-agent grant.
- An image needs `sh` and a `sleep` that takes `infinity`; distroless images won't work.
- Give `create` a full image name (`docker.io/library/ubuntu:24.04`); podman cannot ask
  which registry a short name means.
- No export of apps to the host's desktop, and no manifests. `securebox enter NAME -- cmd`
  is the primitive to build those on.
- Z# is pre-1.0; this builds with 0.7.1.

[DESIGN.md](DESIGN.md) has the reasoning behind each of these.

## License

[MIT](LICENSE).
