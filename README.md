# securebox

Persistent Linux boxes from any container image, as easy as distrobox, that cannot see
your home directory or your session unless you share a path with them.

```sh
securebox create dev                                   # a Fedora box with its own empty home
securebox create web docker.io/library/ubuntu:24.04 --share ~/Projects/web
securebox enter web                                    # a shell; the working directory is kept inside a share
securebox enter web -- npm test                        # one command; its exit code is securebox's
securebox enter web -e NODE_ENV=test -e API_KEY -- npm test   # with variables; API_KEY's value is the one here
securebox enter web --root -- apt install -y nodejs    # root, granted from the host side
securebox create gui --wayland --sound                 # GUI programs with sound (see what it costs, below)
securebox recreate web --share ~/Projects/web --network none   # other grants; what was installed stays
securebox export web --bin node --app org.example.Editor       # on the host: a command, a menu entry
securebox list
securebox stop web
securebox rm web                                       # keeps the box's home; --purge deletes it
```

One static binary of about 900 KB, written in [Z#](https://github.com/ZigoteProject/zsharp)
0.7.1. Podman is the only thing it needs at run time, and it is rootless only: securebox
refuses to run as root.

## Install

Each [release](https://github.com/ZigoteProject/securebox/releases) has a static binary
for x86-64 Linux:

```sh
v=0.2.0
curl -fsSLO "https://github.com/ZigoteProject/securebox/releases/download/v$v/securebox-$v-x86_64-linux.tar.gz"
curl -fsSLO "https://github.com/ZigoteProject/securebox/releases/download/v$v/SHA256SUMS"
sha256sum --check SHA256SUMS
tar xzf "securebox-$v-x86_64-linux.tar.gz"
install -Dm 755 "securebox-$v-x86_64-linux/securebox" ~/.local/bin/securebox
securebox --version
```

Releases after 0.2.0 are signed. `SHA256SUMS.sig` is an SSH signature of `SHA256SUMS`, made
with the key in [`release-signers`](release-signers); check it before the checksum, with
the `ssh-keygen` of OpenSSH 8.1 or later:

```sh
curl -fsSLO "https://github.com/ZigoteProject/securebox/releases/download/v$v/SHA256SUMS.sig"
curl -fsSLO "https://raw.githubusercontent.com/ZigoteProject/securebox/main/release-signers"
ssh-keygen -Y verify -f release-signers -I securebox-release -n securebox-release \
  -s SHA256SUMS.sig < SHA256SUMS
```

That says the files are the ones the holder of that key released, which a checksum
downloaded beside them does not. The key itself comes from the same repository: keep
`release-signers` from your first download, and a later release that does not verify
against it is one to ask about.

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
  included) unless you name it with `enter -e`, `/run/user` does not exist;
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

There is no flag for arbitrary podman options, on purpose: it would void every line above.

### Changing a box's grants: `recreate`

Grants are fixed when a box is created; `recreate` makes the box again. The usual reason is
a box that needs the network to be set up and should not have it afterwards:

```sh
securebox create dev --share ~/Projects/web             # with the network
securebox enter dev --root -- dnf install -y nodejs
securebox recreate dev --share ~/Projects/web --network none
```

`recreate` takes the grants `create` takes, and the box has those and no others: **a grant
you do not give again is gone**, which is the safe way round. What stays is everything in
the box: what was installed in it, its home directory, and what was exported from it.

It works by stopping the box (programs running in it end), saving its files as an image
(`localhost/securebox-snapshot:NAME`), removing it, and creating it from that image. Three
things follow:

- If the last step fails (a grant the host cannot give, say), the box is gone, and the
  message tells you the `create` that brings it back from the image; nothing is lost.
- `rm` keeps the image as it keeps the home directory; `rm --purge` deletes both.

The command that made a box, with its grants, is kept beside its home directory, in
`~/.local/share/securebox/NAME/created`. It outlives `rm`, so a box that is gone can be
made again as it was; copy those lines somewhere that outlives the machine.

- What an image keeps in a volume of its own (a database image's data directory) is not
  part of the box's files, and is not carried over.

## Exporting commands and applications: `export`

```sh
securebox export dev --bin rg                    # ~/.local/bin/rg runs rg in the box
securebox export dev --app org.gnome.TextEditor  # a launcher in your desktop's menu
securebox export dev --delete --bin rg           # removes it; --delete alone, all of the box's
```

`--bin` takes a command's name or its path in the box, and writes a three-line script that
runs `securebox enter dev -- rg "$@"`. `--app` takes the name of a `.desktop` file of the
box's (`securebox enter dev -- ls /usr/share/applications` lists them) and writes a
launcher called "*Name* (on dev)". A graphical application also needs the box to have
`--wayland`.

Both run in the box, with the box's grants and nothing more: a launcher is `securebox
enter`, started from somewhere else. What deserves care is the launcher itself, because it
is a file on the host made from what the box says:

- **Nothing of the box's `.desktop` file is copied.** securebox writes its own, with seven
  keys. From the box come the name (letters, digits and a little punctuation), the command
  line, the icon's *name*, whether it wants a terminal, its categories and its window
  class, each checked character by character. Its actions, MIME types, `TryExec` and
  D-Bus activation are not taken: an exported application never becomes the handler for
  your links or files.
- **The command line must be plain words** (letters, digits and `_@+=:,./-`). Some desktops
  hand that line to a shell, so anything quoted, and any `$`, `;` or backtick, is refused
  rather than escaped; export such an application's command with `--bin` and write the
  launcher yourself. The `%f` and `%U` a desktop replaces with file names are dropped: the
  host's paths mean nothing in the box.
- **Icons are your theme's.** The box names an icon and your desktop shows it if it has
  one; an image file of the box's is never put where your desktop would read it.
- **The name always ends in "(on NAME)"**, so an application of a box's cannot pass for
  one of the host's.
- **securebox only replaces and removes files it wrote.** It keeps a copy of each in the
  box's data directory, and a file on the host that differs from its copy (yours, or one
  you edited) is left alone, by `export`, by `--delete` and by `rm`.

`rm` removes a box's exports; `recreate` keeps them. A script in `~/.local/bin` named like
a command of the host's takes its place wherever that directory comes first in `PATH`:
that is the point of exporting it, and your choice each time.

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
zs test            # 220 unit tests: validation, the exact podman arguments, the command flows
tests/e2e.sh       # 312 checks with real podman, on Fedora, Ubuntu and Alpine images
```

The end-to-end script creates boxes named `sbx-e2e-<pid>-*`, keeps their data in a
temporary directory, probes each box from the inside for everything claimed above, tries
the refusals against a home directory it made for the purpose, and removes what it made.
The export checks write one script into `~/.local/bin` and one launcher into your
applications directory, named `sbx-e2e-<pid>-*`, and remove them. It needs python3 on the
host and pulls the images that aren't local.

## Where things are

```text
app/               the securebox binary: Cli, Box (validation), Podman (argument lists),
                   Exports (launchers), Effects (the outside world), Commands, main
packages/argz/     an Argu-style argument parser for Z#: a union is the command line
packages/posix/    exec, realpath, user ids, isatty, chmod, exclusive file creation: all of the project's C (100 lines)
tests/e2e.sh       the end-to-end tests
tools/release.sh   a release's files, built, tested and signed
release-signers    the key releases are signed with
DESIGN.md          the design: threat model, the podman command lines, what was verified
```

`SECUREBOX_DATA` moves the boxes' home directories somewhere else than
`$XDG_DATA_HOME/securebox`. It cannot be your home directory or hold it.

The code has had a correctness review and two independent security reviews, the second
of the desktop grants; DESIGN.md, appendix D, lists what they found and what was done
about each finding. `recreate` and `export` came after those reviews and have not had one
of their own.

## Limits

- Linux and rootless podman 5.3 or later, the local one only (not `CONTAINER_HOST`).
  Developed and tested on podman 6.1 with SELinux enforcing.
- No X11 (an X11 socket lets the box read your keystrokes), and no ssh-agent grant.
- An image needs `sh` and a `sleep` that takes `infinity`; distroless images won't work.
- Give `create` a full image name (`docker.io/library/ubuntu:24.04`); podman cannot ask
  which registry a short name means.
- An exported application keeps its unlocalized name, in ASCII, and its icon only when
  your theme has one of that name. No manifests.
- Z# is pre-1.0; this builds with 0.7.1.

[DESIGN.md](DESIGN.md) has the reasoning behind each of these.

## License

[MIT](LICENSE).
