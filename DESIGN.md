# securebox — design

Status: 2026-11-14, released as 0.1.0. Implemented: the five commands and the `--share`,
`--share-ro`, `--network`, `--publish`, `--gpu`, `--wayland`, `--sound` and `--dbus` grants,
with 158 unit tests and an end-to-end script of 253 checks against real podman. The code has
had a correctness review and two independent security reviews; appendix D lists what they
found and what was done.

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
securebox create gui --wayland --sound    # GUI programs with sound; costs that box its SELinux confinement
securebox create app --dbus org.freedesktop.Notifications   # one name on the session bus, filtered
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
- The whole session bus, PipeWire's own socket, and portals. Section 3 says why.
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
what podman itself reports for each box, so the listing cannot drift from reality: its
mounts, networks and ports, and the names a `--dbus` box was granted).

| Flag | Grants |
|---|---|
| `--share PATH` (repeatable) | the directory, read-write, at the same path |
| `--share-ro PATH` (repeatable) | the directory, read-only |
| `--network none` / `host` | no network / the host's network namespace |
| `--publish [IP:]HOST:BOX[/udp]` (repeatable) | a port; bound to `127.0.0.1` unless an IP is given (podman's own default is all interfaces) |
| `--gpu` | the GPU's render devices, `/dev/dri/renderD*` (not the display's card nodes) |
| `--wayland` | the Wayland compositor's socket, for GUI programs; **turns SELinux confinement off for that box** |
| `--sound` | playing and recording, through a PulseAudio front-end of the box's own; **same cost** |
| `--dbus NAME` (repeatable) | calls to the interface of that name on the session bus, through a filter; **same cost** |

**What the session grants cost.** `--wayland`, `--sound` and `--dbus` each mean a socket
that a process of the user's session listens on, and all three cost the same thing; the
compositor is the example here. A GUI program has to connect to the compositor, a process
of the user's session. Tested on this machine: with the socket bind-mounted into a box,
`connect` fails under SELinux, with and without relabeling the socket file, and succeeds
with `--security-opt label=disable`. SELinux policy does not let `container_t` connect to
an unconfined process's socket, and there is no narrower switch. So a box created with
any of the three runs with SELinux labelling disabled (`spc_t`); a box created without
them never does. Everything else stays as in the table above, which the end-to-end script checks for
a `--wayland` box too: own home, no capabilities, no-new-privileges, seccomp, the private
network.

What the box gets is a runtime directory of its own, a tmpfs at `/run/user/UID` that is
yours and mode 0700, with one thing in it: the compositor's socket as `wayland-0`. The
session's other sockets (D-Bus, PipeWire, the podman socket, agents) are not there.
`enter` sets `XDG_RUNTIME_DIR` and `WAYLAND_DISPLAY` for such a box. Verified with a real
client: `wayland-info` in a Fedora box lists the compositor's interfaces.

Being a Wayland client is itself a grant: the box can open windows that look like any
other, and can use whatever protocols the compositor offers every client. GNOME and KDE
keep the dangerous ones to themselves. wlroots compositors (sway, Hyprland and others)
offer every client screen capture, a virtual keyboard and a virtual pointer: there a
Wayland client can type into other windows, and `--wayland` gives the box the desktop.
The fix would be to hand the box a socket made through `wp_security_context_v1` where the
compositor has it; that is not built. X11-only programs do not run.

A session grant cannot be combined with `--network host`: with labelling off, the host's
network namespace would put the session's abstract sockets (X11's, for one) in reach too.
The socket is mounted read-only, and must be a socket inside `$XDG_RUNTIME_DIR` whatever
`$WAYLAND_DISPLAY` says: `WAYLAND_DISPLAY=pulse` would otherwise have mounted the
session's sound directory.

**`--sound`** never gives the box the session's sound socket. The first version did, and
that was a way out of the box: the session's `pipewire-pulse` takes `load-module` from
whoever reaches its socket. Confirmed from inside a box: `module-pipe-sink` created a FIFO
at a host path of the box's choosing, `module-native-protocol-tcp` put the sound server
on a TCP port, and a module that loads a plugin by path would in all likelihood run it.

So, as with D-Bus, the box gets a socket of its own with something in between: a second
`pipewire-pulse`, run for that box as a unit of the user's systemd
(`securebox-sound-NAME`). It reads a copy of the system's `pipewire-pulse.conf` with one
override, through `PIPEWIRE_CONFIG_DIR` and `PULSE_RUNTIME_PATH`:

```text
pulse.properties = {
    server.address = [ { address = "unix:RUNTIME/securebox/NAME/pulse/native" client.access = "restricted" } ]
    pulse.allow-module-loading = false
}
```

The directory of that socket is mounted read-only at the box's `pulse/`, and
`PULSE_SERVER` points at it. Observed through it, from a box with `pactl`: the server
answers, sinks and sources are listed, and `load-module` of `module-null-sink`,
`module-pipe-sink`, `module-native-protocol-tcp` and `module-ladspa-sink` each fail with
"Access denied"; playing and recording work. With `client.access = "restricted"` the
box's clients also cannot change volumes or the default device (observed: "Access
denied"), though they can list the other programs using sound, by name. The session's
own socket is untouched (and still takes `load-module`, which the end-to-end script uses
as its control).

A PulseAudio client can play, and it can record: the microphone, and the monitor of what
other programs play. PipeWire's own socket is not shared: an unrestricted PipeWire client
also sees cameras and screen-sharing streams. This grant needs PipeWire on the host; with
the old PulseAudio daemon there is nothing to put in between, and `--sound` is refused.

**`--dbus NAME`** never gives the box the session bus. Whoever holds that bus can call
`org.freedesktop.systemd1` and have any command run as the user, or ask the secret service
for the keyring: the bus is a way out of every other restriction here. So the box gets a
socket of its own, and between it and the bus runs `xdg-dbus-proxy --filter`. Observed
through such a filter granted only `org.freedesktop.Notifications`: two names visible
(the bus itself and that one) of the 158 on the real bus; calls to systemd and to the
secret service fail with `ServiceUnknown`; owning a name is refused; so are the bus
driver's `UpdateActivationEnvironment`, `StartServiceByName` for another name and
`BecomeMonitor`. Verified with a real client too: `dbus-send` in a Fedora box gets the
notification server's answer, and is refused systemd.

- **A grant is the interface named like the bus name, not the name.** For each name the
  filter gets `--see=NAME --call=NAME=NAME.* --broadcast=NAME=NAME.*`. The first version
  used `--talk=NAME`, which lets through every call to whatever process owns the name, on
  any object and interface. On GNOME that process is often gnome-shell: granted
  `org.gtk.Notifications`, a box could introspect `/org/gnome/Mutter/RemoteDesktop`
  (keyboard and pointer injection) and `org.gnome.Shell` (confirmed). With the scoped rule
  both are "Access denied", as is `org.freedesktop.DBus.Properties` on the granted object.
  A service whose interface is not named like its bus name cannot be granted yet.
- A name must be written out (no wildcards). `org.freedesktop.systemd1` and
  `org.freedesktop.Flatpak`, which run commands on the host for whoever asks, are refused,
  **as a courtesy and not as a list of what is safe**: no such list can be complete.
  `org.freedesktop.secrets` (the keyring), `org.gnome.Shell`, `ca.desrt.dconf` (settings,
  custom key bindings included), a terminal's name and the portals all pass, and each
  gives away much of the session. Granting a name is the user's decision about that
  service.
- A new box never takes over a filter (or a sound front-end) left under its name: `create`
  checks that the name is free, stops what runs under it, starts its own, and stops it
  again if the box cannot be made. The first version reused whatever was running, so a
  failed `create --dbus A` followed by `create --dbus B` gave the second box A.
- The filter must outlive securebox, which is gone once it has exec'ed podman, so it runs
  as a transient unit of the user's systemd (`securebox-dbus-NAME`). `create` and `enter`
  start it when it is not running; `stop` and `rm` stop it. This grant therefore needs
  `xdg-dbus-proxy` and a systemd user session on the host.
- The names are kept in the container's label `securebox.dbus`, read back only for a
  container already established as the box (section 4) and validated again before use. A
  label given at `create` wins over the same label in an image (checked).
- **A grant is recognised by securebox's own directory bound in place**, not by something
  being mounted where the grant goes. Only bind mounts are read from `inspect` at all: an
  image can declare volumes anywhere and carry any label, and the first version, which
  looked at the destination alone, started a filter with an image's names for a box
  created without `--dbus` (the box could not reach it; it should still never start).
- A program that only needs a bus to exist (to register itself, say) can run one inside
  the box with `dbus-run-session`; that needs no grant. There are no portals: they treat a
  caller that is not a Flatpak as a trusted host program.

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
  [--security-opt label=disable                             # with any session grant
   --mount type=tmpfs,dst=/run/user/UID,tmpfs-mode=0700,chown=true]
  [--mount type=bind,src=SOCKET,dst=/run/user/UID/wayland-0,ro]           # --wayland
  [--mount type=bind,src=RUNTIME/securebox/NAME/pulse,dst=/run/user/UID/pulse,ro]   # --sound
  [--label securebox.dbus=NAME,NAME                                                 # --dbus
   --mount type=bind,src=RUNTIME/securebox/NAME/dbus,dst=/run/user/UID/dbus,ro]
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
- Before any of it, `create` inspects the name: a container of that name, a box or not,
  stops it there.
- With `--dbus` or `--sound`, the filter and the front-end are started before
  `podman create`, so that their directories exist to be mounted:

  ```text
  systemctl --user stop securebox-dbus-NAME.service             # create: never reuse one
  systemctl --user is-active --quiet securebox-dbus-NAME.service  # enter: running already?
  systemd-run --user --quiet --collect --unit securebox-dbus-NAME.service --
    xdg-dbus-proxy BUS_ADDRESS RUNTIME/securebox/NAME/dbus/bus --filter
      --see=NAME --call=NAME=NAME.* --broadcast=NAME=NAME.* …

  systemd-run --user --quiet --collect --unit securebox-sound-NAME.service
    --setenv PIPEWIRE_CONFIG_DIR=RUNTIME/securebox/NAME/sound
    --setenv PULSE_RUNTIME_PATH=RUNTIME/securebox/NAME/pulse -- pipewire-pulse
  ```

### enter

```text
1. podman inspect --type container --format
     '{{.Name}}|{{.State.Status}}|{{json (index .Config.Labels "securebox")}}{{"\n"}}{{json .Mounts}}' NAME
2. podman start NAME                       # only when not running
3. podman exec --interactive [--tty] --detach-keys= [--user 0]
     --env HOME=HOME --env USER=USER --workdir W --env SECUREBOX=NAME
     [--env XDG_RUNTIME_DIR=/run/user/UID]                    # with any session grant
     [--env WAYLAND_DISPLAY=wayland-0]
     [--env PULSE_SERVER=unix:/run/user/UID/pulse/native]
     [--env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/UID/dbus/bus]
     --env TERM --env COLORTERM --env LANG --env LC_ALL
     NAME CMD...
```

- Step 1 answers in one call whether the container is the box, whether it runs, and what
  it has mounted. **A container is the box `NAME` only when three things hold:** its name
  is `NAME` (podman also accepts a name as the start of another container's id, so `db`
  or `fed` could otherwise land on a different box), it carries the label, and it has
  `DATA/NAME/home` mounted as the home. The label alone is not proof: a container made
  from an image with `LABEL securebox=1` carries it too, which is why the mount, which no
  image can bring along, is required. The label and the mounts are printed as JSON, so
  that nothing an image put in a label, or in the path of a volume it declares, can add a
  line that reads as a mount; of the mounts only the binds are used, which come from the
  command line that made the container. Every command that names a box goes through this check, so
  securebox never stops, removes or enters a container it did not create.
- When `inspect` fails, `podman container exists NAME` says whether that is "no such
  container" (exit 1) or podman failing; only the first is treated as a box that is gone.
- Before a stopped box is started, each of its shares must still resolve to itself and
  still pass the share check. podman resolves a mount's source again at every start, so a
  directory that has become a link (put there by another box with a read-write share
  around it, say) would otherwise be followed.
- `W` is the host's working directory when it lies inside a share, otherwise `HOME`.
- `--tty` only when stdin and stdout are terminals. `--detach-keys=` stops podman from
  swallowing Ctrl-P.
- Without `CMD`, the box's shell is found in the box, preferring the host's `$SHELL` name:
  `sh -c 'exec "$(command -v "$0" || command -v bash || echo sh)" -l' zsh`.
- `HOME` and `USER` are always passed explicitly.
- A stopped `--wayland` box is started only when the compositor's socket is there;
  otherwise `enter` says so instead of letting podman fail on the missing mount source.
- For a `--dbus` or `--sound` box, `enter` first makes sure the filter or the front-end is
  running, starting it (the filter with the names from the box's label) when it is not.
- The exit code is the command's. securebox's own failures exit 125, as podman's do.

### list, stop, rm

```text
podman ps --all --filter label=securebox=1 --format json
podman container inspect --format '{{.Name}}|{{json .Mounts}}' NAME…     # list: what is mounted
podman stop NAME
podman rm --force --volumes NAME          # with the anonymous volumes its image declared
podman unshare rm -rf -- DATA/NAME        # with --purge only
```

`list` reads that JSON and prints its own table: NAME, STATE, IMAGE, MOUNTS, NETWORKS,
PORTS and DBUS. (podman's table format cannot print a label, which is where a `--dbus`
box's names are.) The names are shown only for a box that has securebox's directory bound
where the bus goes. `ps` reports where things are mounted and not what they are, and the
first version went by that: a box from an image declaring a volume there, with the label,
was listed with the image's names. So `list` asks for the mounts themselves, in one more
call. Control characters are replaced, so a name or a label cannot write escape sequences
to the terminal. It needs nothing from the environment but the uid. `rm` keeps the home directory and prints its path; deleting user
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
  - `/etc`, `/usr`, `/boot`, `/dev`, `/proc`, `/sys`, `/root`, `/var/lib`, `/var/log` and
    anything under them; all of `/run` (the system's sockets: its bus, systemd's) except
    what is under `/run/media` and `/run/mount`; `/var`, `/tmp` and `/var/tmp` themselves
    (homes and build directories live under those);
  - `DATA` and `$XDG_RUNTIME_DIR`: themselves, what holds them, and anything inside;
  - any dot-entry directly under the home (`~/.ssh`, `~/.gnupg`, `~/.config`, `~/.local`…),
    which is where credentials and host configuration live.
- **Shares of one box:** none twice, and none inside another that is read-write: the box
  could replace the inner one with a link, which podman follows at the next start.
- **User and home:** the name comes from the passwd database (`$USER` only when it has no
  entry) and the home from `$HOME` (the passwd entry's when unset). Both go into the
  passwd entry and the mounts, so neither may contain `:` or `,`; the home also may not
  contain `|`, `&` or `\`, which the `sed` of section 4 would read as syntax.
- **Data directory:** absolute, and not the home directory or what holds it, by its text
  or through a link: `rm --purge` deletes `DATA/NAME`.
- **Runtime directory and bus address:** `$XDG_RUNTIME_DIR` is written into mounts, a
  configuration file and a unit's command line, so it may hold no comma, colon, quote,
  backslash, space, `=` or `$`; `$DBUS_SESSION_BUS_ADDRESS` no `$` (systemd expands one).
- **Wayland socket:** `$WAYLAND_DISPLAY` is resolved, and must be a socket inside
  `$XDG_RUNTIME_DIR`.
- **Bus name (`--dbus`):** a well-known name written out: at least two elements of
  letters, digits, `_` and `-`, none starting with a digit; no wildcard. Refused:
  `org.freedesktop.systemd1`, `org.freedesktop.Flatpak`, `org.freedesktop.DBus`.
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
  abstract pathExists : string -> bool
  abstract isSocket   : string -> bool
  abstract realPath   : string -> string                               // "" when it isn't there
  abstract ensureDir  : string -> result<unit, string>                 // with parents, mode 0700
  abstract tool       : string * list<string> -> int                   // systemctl, systemd-run
  abstract removeTree : string -> unit                                 // a stale socket; a box's session directory
  abstract writeFile  : string * string -> result<unit, string>        // the sound front-end's
  abstract copyFile   : string * string -> result<unit, string>        //   configuration
  abstract awaitPath  : string -> bool                                 // a unit's socket
  abstract say        : string -> unit                                 // a line for the user, on stderr
  abstract out        : string -> unit                                 // list's table, on stdout
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
reach the terminal. The last call of `enter` is an `execvp`: securebox is
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
Posix.exists          : string -> bool                     // access(2)
Posix.isSocket        : string -> bool
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

- The release build is a static binary cross-linked through `zig cc`: 626 KB for x86-64,
  618 KB for arm64 (`aarch64-linux-musl`), C shim included. A run that only parses its
  arguments takes about half a millisecond. Two builds of one commit are the same bytes.
- A release is made by hand, there is no CI: set the version in `app/zs.toml` and
  `CHANGELOG.md`, run `zs test`, build the static binary, run `tests/e2e.sh` with
  `SECUREBOX` set to it, tag `vX.Y.Z`, and attach
  `securebox-X.Y.Z-x86_64-linux.tar.gz` (the binary, `LICENSE`, `README.md`) and
  `SHA256SUMS` to the GitHub release. arm64 is not shipped until it has been run on one.
- Build needs: Z# 0.7.1 (`.toolchain/`, not committed), clang 23+, zig.
- Runtime needs: podman 5.3 or later (`--hosts-file`), with pasta, its rootless network
  since 5.0. Developed and tested on 6.1 only. No version probe at run time.
- Z# is pre-1.0 and may break source between releases. Pin 0.7.1 in CI and upgrade
  deliberately using its CHANGELOG's "to rewrite" notes.

## 9. Testing

- **Unit (`zs test`, 158 tests):** validation tables and a property test (no accepted name
  starts with `-` or contains `/`); `expect` tests of `createArgs` and `execArgs`, which
  pin the security flags, and a test that labelling is never off without a session grant; the
  ownership check against an image's label, another data directory and an id prefix; the
  command flows under the recording `Host` handler; argz parse tables and `expect` tests
  of usage text; the posix functions.
- **End to end (`tests/e2e.sh`, 253 checks):** the built binary against real podman, on
  Fedora, Ubuntu and Alpine images: every row of section 3's table probed from inside the
  box, shares, exit codes, the lifecycle, the grants (the session grants included, where
  the session has a compositor, a sound server and a bus), refusals, and containers that are not securebox's. It keeps its
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
| M2 ✅ | `--publish`, `--gpu`, `--wayland`, `--sound`, `--dbus`; the passwd fix-up for images with a clashing uid | done; the session grants at the cost section 3 states, `--ssh-agent` not built |
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
7. **`list` trusts the label for its rows.** It is `podman ps` filtered by label, so a
   container made from an image that carries `LABEL securebox=1` shows up in it. No
   command acts on one, and no D-Bus names are shown for it.
8. **No portals** in any box, and no bus name can be owned on the session bus.
9. **A filter's names are fixed at create,** like every grant.

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
session with PipeWire), images `fedora:45`, `ubuntu:24.04` and `alpine:latest`: 253 passed,
0 failed.

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
no-new-privileges unchanged); a `--sound` box (its front-end running as a user unit, the
session's own socket not mounted, the server answering through it, three `load-module`
requests refused where the session's own socket accepts one, the front-end stopped by
`stop`, restarted by `enter`, gone after `rm`); a box from an image that declares volumes
where the grants go and carries the `--dbus` label (no filter, no front-end, and its
anonymous volumes removed with it); a `--dbus` box (the filter running as a user unit, only the granted
names visible through it, systemd and the secret service refused, another interface of
the granted object and gnome-shell's remote-desktop object refused, the filter stopped by
`stop`, restarted by `enter`, gone after `rm`); a box whose share became a link while it
was stopped (not started); a failed `create --dbus` (no filter left); twenty-nine refusals, those about the home against a fake one (the home under each
name, links to it, the runtime and data directories, an empty path, a remote podman, …);
two foreign containers, one from an image carrying the label, left alone by `enter`,
`stop`, `rm` and `rm --purge` together with the directories of their names; a directory
that was never a box not purged.

Separately, by hand, with clients installed in a Fedora box: `wayland-info` lists the
compositor's interfaces; `pactl info` names the host's sound server; `dbus-send` gets an
answer from the granted name and `ServiceUnknown` from systemd.

Entering a running box, median of 15 runs on this machine before the review changes:
`podman exec NAME true` takes 227 ms and `securebox enter NAME -- true` 268 ms. The 40 ms
are the one `podman inspect`; securebox's own start-up is under a millisecond.

## Appendix D: the reviews

Two reviews of commit `c943898`: a correctness review, and a security review by a reader
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

A second pass, on the session grants, before they had an independent review of their own:

| Finding | Severity | What was done |
|---|---|---|
| `--sound` gave the box the session's PulseAudio socket, and the session's sound server takes `load-module` from it (confirmed: a FIFO created at a host path, a TCP listener opened) | high | the box gets a front-end of its own with module loading off; the session's socket is never mounted |
| Grants were recognised by mount destination, so an image declaring a volume there, with a `securebox.dbus` label, had a filter started with its names (confirmed; the box could not reach it) | low | a grant is securebox's own directory bound in place; only bind mounts are read |
| `rm` left an image's anonymous volumes behind | bug | `rm --force --volumes` |

Checked and found sound in that pass: the D-Bus filter refuses the bus driver's
`UpdateActivationEnvironment`, `StartServiceByName` for a name not granted, and
`BecomeMonitor`; other connections cannot be introspected through it.

The second independent review, of the session grants and of the fixes above:

| Finding | Severity | What was done |
|---|---|---|
| `--sound`: beyond the FIFO and the TCP listener, `module-alsa-sink device=file:…` very likely writes host files and runs host commands | high | already closed by the front-end, which takes no `load-module` at all |
| `--dbus NAME` used `--talk`, which grants everything the owning process exports (confirmed: gnome-shell's remote-desktop and shell interfaces through `org.gtk.Notifications`) | medium | `--see` plus `--call` and `--broadcast` scoped to the interface named like the bus name |
| A running filter was reused whatever names it had been started with: a failed `create`, or a box removed with podman, left one for the next box of that name | medium | `create` requires a free name, stops what runs under it, and stops its own units when it fails; `rm` of a missing box stops them too |
| The mounts in `inspect` output were printed raw, so a volume path with a line break could have written itself in as other mounts (not confirmed that podman accepts such a path) | low | the mounts are printed and read as JSON |
| podman resolves share sources again at every start: a box with a read-write share around another share could swap it for a link | low | shares are re-checked before a start; nested shares of one box are refused |
| A session grant with `--network host` put the host's abstract sockets in reach | low | the combination is refused |
| The design said too little about `--wayland` on wlroots compositors | low | said plainly: there it gives the box the desktop |
| `WAYLAND_DISPLAY` could name anything (`pulse`, `../../../etc`), mounted read-write | hardening | it must resolve to a socket in the runtime directory; mounted read-only |
| systemd expands `$` in a unit's command line; boxes `x` and `x.service` shared a unit; the data directory could be a link to the home; `/run/dbus` and `/run/systemd` could be shared | hardening | `$` refused where it would be expanded; units named in full; the resolved data directory is checked; all of `/run` but removable media refused |
| The denylist of bus names suggested the others were safe | design | kept as a courtesy, and said to be one, in the message, the README and section 3 |

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
