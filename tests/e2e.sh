#!/usr/bin/env bash
# End-to-end tests: the built securebox binary against real rootless podman. Each image gets
# a box, and the box is probed from the inside for what DESIGN.md, section 3, promises.
#
#   zs build && tests/e2e.sh                  # all default images
#   E2E_IMAGES="docker.io/library/alpine:latest" tests/e2e.sh
#   SECUREBOX=/path/to/securebox tests/e2e.sh
#
# Nothing of yours is touched: the boxes' data goes to a temporary directory, the boxes are
# named sbx-e2e-<pid>-*, the refusals are tried on a fake home directory, and everything is
# removed at the end. The export checks do write where exports go: a script named
# sbx-e2e-<pid>-* in ~/.local/bin and a launcher of that name in your applications
# directory, both removed. Needs podman and python3 (for a listener on the host's
# loopback); images that aren't local are pulled.
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
SB=${SECUREBOX:-$here/app/build/securebox}
IMAGES=${E2E_IMAGES:-registry.fedoraproject.org/fedora:45 docker.io/library/ubuntu:24.04 docker.io/library/alpine:latest}

[ -x "$SB" ] || { echo "no binary at $SB: run 'zs build' first, or set SECUREBOX" >&2; exit 2; }
command -v podman >/dev/null || { echo "podman is not installed" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is not installed" >&2; exit 2; }

tmp=$(mktemp -d) || exit 2
[ -d "$tmp" ] || exit 2
export SECUREBOX_DATA="$tmp/data"
export E2E_SECRET="must-not-reach-the-box"
prefix="sbx-e2e-$$"
bin="$HOME/.local/bin"
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
boxes=()
foreign=()
labelled=""
listener=""
pass=0
fail=0

cleanup() {
  for b in "${boxes[@]}"; do "$SB" rm "$b" --purge >/dev/null 2>&1; done
  for c in "${foreign[@]}"; do podman container rm --force "$c" >/dev/null 2>&1; done
  [ -n "$labelled" ] && podman image rm "$labelled" >/dev/null 2>&1
  [ -n "$listener" ] && kill "$listener" 2>/dev/null
  rm -f "$bin/$prefix-"* "$apps/securebox+$prefix-"*
  rm -rf "${tmp:?}"
}
trap cleanup EXIT

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n       %s\n' "$1" "$2"; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "no '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "found '$2' in: $3" ;; *) ok "$1" ;; esac; }

# Runs a shell script in the box, as the user or as root.
box() { "$SB" enter "$name" -- sh -c "$1" </dev/null 2>&1; }
rootbox() { "$SB" enter "$name" --root -- sh -c "$1" </dev/null 2>&1; }

uid=$(id -u)
user=$(id -un)

# A service on the host's loopback, which no box may reach. It serves an empty directory.
mkdir "$tmp/served"
port=$((20000 + $$ % 20000))
python3 -I -m http.server --bind 127.0.0.1 "$port" --directory "$tmp/served" >/dev/null 2>&1 &
listener=$!
up=no
for _ in $(seq 50); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then up=yes; break; fi
  sleep 0.1
done
[ "$up" = yes ] || { echo "the host's listener did not start on 127.0.0.1:$port" >&2; exit 2; }

# In the box: a TCP connection to $0:$1, with whatever the image has.
connect='if command -v bash >/dev/null; then bash -c "exec 3<>/dev/tcp/$0/$1" 2>/dev/null; else nc -w 2 "$0" "$1" </dev/null 2>/dev/null; fi && echo reached || echo unreachable'
# In the box: the same to the default gateway, where a mapping of the host's loopback shows.
gateway='gw=$(while read -r _ dest hex _; do [ "$dest" = 00000000 ] && echo "$hex" && break; done </proc/net/route)
[ -n "$gw" ] || { echo no-gateway; exit; }
ip=$(printf "%d.%d.%d.%d" "0x$(echo "$gw" | cut -c7-8)" "0x$(echo "$gw" | cut -c5-6)" "0x$(echo "$gw" | cut -c3-4)" "0x$(echo "$gw" | cut -c1-2)")
if command -v bash >/dev/null; then bash -c "exec 3<>/dev/tcp/$ip/$0" 2>/dev/null; else nc -w 2 "$ip" "$0" </dev/null 2>/dev/null; fi && echo reached || echo unreachable'
probe() { "$SB" enter "$name" -- sh -c "$connect" "$1" "$port" </dev/null 2>&1; }

n=0
for image in $IMAGES; do
  n=$((n + 1))
  name="$prefix-$n"
  t="[$image]"
  proj="$tmp/proj-$n"
  ro="$tmp/ro-$n"
  mkdir -p "$proj/sub" "$ro"
  echo "from the host" >"$ro/readme"
  ln -s "$proj" "$tmp/link-$n"
  hostport=$((port + n))

  boxes+=("$name")
  out=$("$SB" create "$name" "$image" --share "$tmp/link-$n" --share-ro "$ro" --publish "$hostport:8080" 2>&1)
  is "$t create" 0 $?
  has "$t create says how to enter" "securebox enter $name" "$out"
  is "$t the home starts empty" "0" "$(box 'ls -A "$HOME" | wc -l | tr -d " "')"

  # who the box runs as
  is "$t the user's uid" "$uid" "$(box 'id -u')"
  is "$t HOME is the host's path" "$HOME" "$(box 'echo $HOME')"
  is "$t the passwd entry has the user's name and home" "$user:$HOME" "$(box "grep '^[^:]*:[^:]*:$uid:' /etc/passwd | cut -d: -f1,6")"
  is "$t SECUREBOX names the box" "$name" "$(box 'echo $SECUREBOX')"

  # no privileges, and no way to gain them
  status=$(box 'cat /proc/self/status')
  has "$t no effective capabilities" "CapEff:	0000000000000000" "$status"
  has "$t no permitted capabilities" "CapPrm:	0000000000000000" "$status"
  has "$t no-new-privileges" "NoNewPrivs:	1" "$status"
  has "$t seccomp filter" "Seccomp:	2" "$status"
  if [ "$(getenforce 2>/dev/null)" = Enforcing ]; then
    has "$t SELinux confinement" ":container_t:" "$(box 'tr -d "\000" </proc/self/attr/current')"
  fi
  has "$t the user cannot write /usr" "denied" "$(box 'touch /usr/e2e 2>&1 || echo denied')"

  # nothing of the host
  is "$t no /run/user, no /run/host" "absent" "$(box 'ls -d /run/user/* /run/host 2>/dev/null || echo absent')"
  hasnt "$t the host's environment stays out" "$E2E_SECRET" "$(box 'env')"
  is "$t no XDG_RUNTIME_DIR or WAYLAND_DISPLAY" "unset" "$(box 'echo "${XDG_RUNTIME_DIR-unset}${WAYLAND_DISPLAY+set}"')"
  is "$t the home is the box's own, and writable" "kept" "$(box 'echo kept > ~/e2e && cat ~/e2e')"
  is "$t the box's home is under the data directory" "kept" "$(cat "$SECUREBOX_DATA/$name/home/e2e" 2>/dev/null)"
  is "$t the box's directory is private" "700" "$(stat -c %a "$SECUREBOX_DATA/$name")"

  # the network
  is "$t the host's loopback is unreachable as 127.0.0.1" "unreachable" "$(probe 127.0.0.1)"
  is "$t ... as host.containers.internal" "unreachable" "$(probe host.containers.internal)"
  is "$t ... and through the gateway" "unreachable" "$("$SB" enter "$name" -- sh -c "$gateway" "$port" </dev/null 2>&1)"
  has "$t a published port is bound to 127.0.0.1" "127.0.0.1:$hostport" "$(podman port "$name" 2>&1)"

  # shares: given through a symbolic link, mounted at what the link leads to
  is "$t a share is writable" "ok" "$(box "echo from-the-box > '$proj/made' && echo ok")"
  is "$t ... and the file is the user's on the host" "$uid from-the-box" "$(stat -c %u "$proj/made" 2>/dev/null) $(cat "$proj/made" 2>/dev/null)"
  is "$t a read-only share can be read" "from the host" "$(box "cat '$ro/readme'")"
  has "$t ... and not written" "denied" "$(box "touch '$ro/x' 2>/dev/null || echo denied")"
  is "$t the working directory is kept inside a share" "$proj/sub" "$(cd "$proj/sub" && box 'pwd')"
  is "$t ... and is the home outside one" "$HOME" "$(cd "$tmp" && box 'pwd')"

  # root comes from the host side
  is "$t --root is uid 0" "0" "$(rootbox 'id -u')"
  is "$t --root can install into the image" "ok" "$(rootbox 'touch /usr/e2e && echo ok')"

  # exit codes and standard input
  box 'exit 42' >/dev/null
  is "$t the command's exit code is passed on" 42 $?
  echo 'exit 5' | "$SB" enter "$name" >/dev/null 2>&1
  is "$t a shell reads standard input" 5 $?
  is "$t output is the command's alone" "plain" "$("$SB" enter "$name" -- echo plain </dev/null 2>/dev/null)"
  is "$t -e sets a variable, by value or from here" "one two|$E2E_SECRET" "$("$SB" enter "$name" -e "E2E_A=one two" -e E2E_SECRET -- sh -c 'echo "$E2E_A|$E2E_SECRET"' </dev/null 2>/dev/null)"
  "$SB" enter "$name" -e HOME=/root -- true >/dev/null 2>&1
  is "$t ... and not one of securebox's own" 125 $?

  # lifecycle
  has "$t list shows the box" "$name" "$("$SB" list 2>&1)"
  "$SB" stop "$name" >/dev/null 2>&1
  is "$t stop" "exited" "$(podman inspect --type container --format '{{.State.Status}}' "$name")"
  is "$t enter starts a stopped box" "up" "$(box 'echo up')"
  is "$t what root installed is still there" "ok" "$(box 'test -e /usr/e2e && echo ok')"

  # recreate: the box again from its own files, with the grants given now and no others
  snapshot="localhost/securebox-snapshot:$name"
  out=$("$SB" recreate "$name" --share-ro "$ro" --network none 2>&1)
  is "$t recreate" 0 $?
  is "$t ... the box is made from its own files" "$snapshot" "$(podman inspect --type container --format '{{.ImageName}}' "$name")"
  is "$t ... what root installed is kept" "ok" "$(box 'test -e /usr/e2e && echo ok')"
  is "$t ... and the home" "kept" "$(box 'cat ~/e2e')"
  is "$t ... the passwd entry is still the user's" "$user:$HOME" "$(box "grep '^[^:]*:[^:]*:$uid:' /etc/passwd | cut -d: -f1,6")"
  is "$t ... the network is the one asked for now: none" "lo" "$(box 'echo $(ls /sys/class/net)')"
  is "$t ... a share that was not given again is gone" "absent" "$(box "ls '$proj/made' 2>/dev/null || echo absent")"
  is "$t ... the one given again is there" "from the host" "$(box "cat '$ro/readme'")"
  has "$t ... still no capabilities" "CapEff:	0000000000000000" "$(box 'cat /proc/self/status')"
  is "$t ... and nothing of the session" "absent" "$(box 'ls -d /run/user/* /run/host 2>/dev/null || echo absent')"
  "$SB" recreate "$name" --network host --sound >/dev/null 2>&1
  is "$t recreate with grants that cannot go together is refused" 125 $?
  is "$t ... and the box is left as it was" "running" "$(podman inspect --type container --format '{{.State.Status}}' "$name")"

  # removal: the home is kept until --purge, which also deletes what the box's root made
  rootbox "touch $HOME/made-by-root" >/dev/null
  out=$("$SB" rm "$name" 2>&1)
  is "$t rm" 0 $?
  has "$t rm says where the home is" "$SECUREBOX_DATA/$name" "$out"
  is "$t the command that made the box is kept with it" "securebox create $name $snapshot --share-ro $ro --network none" "$(cat "$SECUREBOX_DATA/$name/created" 2>&1)"
  is "$t rm keeps the home" "kept" "$(cat "$SECUREBOX_DATA/$name/home/e2e" 2>/dev/null)"
  "$SB" enter "$name" -- true >/dev/null 2>&1
  is "$t a removed box cannot be entered" 125 $?
  "$SB" rm "$name" --purge >/dev/null 2>&1
  is "$t rm --purge after the box is gone" 0 $?
  is "$t ... deletes its directory" "gone" "$([ -e "$SECUREBOX_DATA/$name" ] && echo there || echo gone)"
  podman image exists "$snapshot"
  is "$t ... and the image recreate kept its files in" 1 $?
done

# Once, on the first image: grants and refusals that don't depend on the image.
image=${IMAGES%% *}
t="[grants]"

# The control for the network checks above: with the host's network, the same probe reaches
# the listener, so "unreachable" there was the isolation and not a probe that cannot work.
name="$prefix-host"
boxes+=("$name")
"$SB" create "$name" "$image" --network host >/dev/null 2>&1
is "$t --network host: the same probe reaches the host's loopback" "reached" "$(probe 127.0.0.1)"
"$SB" rm "$name" --purge >/dev/null 2>&1

name="$prefix-none"
boxes+=("$name")
http_proxy="http://user:secret@proxy.invalid:3128" HTTPS_PROXY="http://user:secret@proxy.invalid:3128" \
  "$SB" create "$name" "$image" --network none >/dev/null 2>&1
is "$t --network none: only loopback" "lo" "$(box 'ls /sys/class/net | tr "\n" " " | sed "s/ $//"')"
hasnt "$t the host's proxy settings stay out" "secret" "$(box 'env')"
"$SB" rm "$name" --purge >/dev/null 2>&1

if ls /dev/dri/renderD* >/dev/null 2>&1; then
  name="$prefix-gpu"
  boxes+=("$name")
  "$SB" create "$name" "$image" --gpu >/dev/null 2>&1
  is "$t --gpu: a render device can be opened" "ok" "$(box 'for d in /dev/dri/renderD*; do : <>"$d" && echo ok; break; done')"
  is "$t --gpu: render devices only" "" "$(box 'ls /dev/dri | grep -v "^renderD" | tr "\n" " "')"
  "$SB" rm "$name" --purge >/dev/null 2>&1
  name="$prefix-nogpu"
  boxes+=("$name")
  "$SB" create "$name" "$image" >/dev/null 2>&1
  is "$t without --gpu there is no /dev/dri" "absent" "$(box 'ls -d /dev/dri 2>/dev/null || echo absent')"
  "$SB" rm "$name" --purge >/dev/null 2>&1
fi

# The limits, and a box with neither as their control. /dev/shm is measured in kilobytes and
# held to a range: podman's default is written "65536k" and comes out as 64000k, so whether
# its "m" is 1000 or 1024 kilobytes is left open here.
shm_kb='sed -n "s|.* /dev/shm .*size=\([0-9]*\)k.*|\1|p" /proc/mounts'
about_128m() { [ "${1:-0}" -ge 120000 ] && [ "${1:-0}" -le 135000 ] && echo yes || echo "no: ${1:-nothing}k"; }
name="$prefix-limits"
boxes+=("$name")
"$SB" create "$name" "$image" --pids-limit 4321 --shm-size 128m >/dev/null 2>&1
is "$t --pids-limit: the box's limit on processes and threads" "4321" "$(box 'cat /sys/fs/cgroup/pids.max')"
is "$t --shm-size: /dev/shm is that size" "yes" "$(about_128m "$(box "$shm_kb")")"
has "$t the limits are in the record of what made the box" "--pids-limit 4321 --shm-size 128m" "$(cat "$SECUREBOX_DATA/$name/created" 2>&1)"
"$SB" recreate "$name" --shm-size 128m >/dev/null 2>&1
hasnt "$t recreate: a limit not given again is gone" "4321" "$(box 'cat /sys/fs/cgroup/pids.max')"
is "$t recreate: a limit given again stays" "yes" "$(about_128m "$(box "$shm_kb")")"
"$SB" rm "$name" --purge >/dev/null 2>&1

name="$prefix-nokvm"
boxes+=("$name")
"$SB" create "$name" "$image" >/dev/null 2>&1
is "$t without --kvm there is no /dev/kvm" "absent" "$(box 'ls /dev/kvm 2>/dev/null || echo absent')"
hasnt "$t without --shm-size, /dev/shm is podman's size" "yes" "$(about_128m "$(box "$shm_kb")")"
"$SB" rm "$name" --purge >/dev/null 2>&1
if [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  name="$prefix-kvm"
  boxes+=("$name")
  "$SB" create "$name" "$image" --kvm >/dev/null 2>&1
  # opened for reading and writing by a confined box: SELinux policy has to allow it
  is "$t --kvm: /dev/kvm can be opened" "ok" "$(box ': <>/dev/kvm && echo ok')"
  hasnt "$t --kvm: SELinux confinement stays on" "spc_t" "$(box 'cat /proc/self/attr/current 2>/dev/null')"
  is "$t --kvm: no other device comes with it" "absent" "$(box 'ls -d /dev/dri 2>/dev/null || echo absent')"
  "$SB" rm "$name" --purge >/dev/null 2>&1
fi

socket="${XDG_RUNTIME_DIR:-}/${WAYLAND_DISPLAY:-wayland-0}"
if [ -S "$socket" ]; then
  name="$prefix-wayland"
  boxes+=("$name")
  "$SB" create "$name" "$image" --wayland >/dev/null 2>&1
  is "$t --wayland: create" 0 $?
  is "$t --wayland: the socket is in the box's own runtime directory" "socket" "$(box 'test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" && echo socket')"
  is "$t --wayland: that directory is the user's, private, and holds nothing else" "700 $uid wayland-0" "$(box 'echo "$(stat -c "%a %u" "$XDG_RUNTIME_DIR")" $(ls -A "$XDG_RUNTIME_DIR")')"
  if [ "$(box 'command -v curl >/dev/null && echo yes')" = yes ]; then
    # curl exits 7 when it cannot connect; anything else means the compositor answered
    box 'curl -s -m 3 --unix-socket "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" http://x/ >/dev/null 2>&1; [ $? -ne 7 ]'
    is "$t --wayland: the compositor can be connected to" 0 $?
  fi
  # the rest of the box is as any other
  status=$(box 'cat /proc/self/status')
  has "$t --wayland: still no capabilities" "CapEff:	0000000000000000" "$status"
  has "$t --wayland: still no-new-privileges" "NoNewPrivs:	1" "$status"
  is "$t --wayland: still none of the session's other sockets" "wayland-0" "$(box 'ls -A /run/user/*')"
  "$SB" rm "$name" --purge >/dev/null 2>&1
fi

if [ -S "${XDG_RUNTIME_DIR:-}/pipewire-0" ] && command -v pipewire-pulse >/dev/null; then
  name="$prefix-sound"
  boxes+=("$name")
  unit="securebox-sound-$name"
  front="$XDG_RUNTIME_DIR/securebox/$name/pulse/native"
  "$SB" create "$name" "$image" --sound >/dev/null 2>&1
  is "$t --sound: create" 0 $?
  is "$t --sound: the box's front-end runs as a unit of the user's" "active" "$(systemctl --user is-active "$unit" 2>&1)"
  is "$t --sound: PULSE_SERVER is a socket in the box's own runtime directory" "socket" "$(box 'test -S "${PULSE_SERVER#unix:}" && echo socket')"
  is "$t --sound: that directory holds nothing else of the session" "pulse" "$(box 'ls -A "$XDG_RUNTIME_DIR" | tr "\n" " " | sed "s/ $//"')"
  has "$t --sound: the socket's directory is read-only" "denied" "$(box 'touch "$XDG_RUNTIME_DIR/pulse/x" 2>/dev/null || echo denied')"
  hasnt "$t --sound: the session's own sound socket is not what is mounted" " $XDG_RUNTIME_DIR/pulse " "$(podman inspect --type container --format '{{range .Mounts}} {{.Source}} {{end}}' "$name")"
  if [ "$(box 'command -v curl >/dev/null && echo yes')" = yes ]; then
    box 'curl -s -m 3 --unix-socket "${PULSE_SERVER#unix:}" http://x/ >/dev/null 2>&1; [ $? -ne 7 ]'
    is "$t --sound: the front-end can be connected to" 0 $?
  fi
  if command -v pactl >/dev/null; then
    # From the host, through the same socket the box has: what the front-end takes.
    PULSE_SERVER="unix:$front" pactl info >/dev/null 2>&1
    is "$t --sound: the sound server answers through the front-end" 0 $?
    for module in "module-null-sink" "module-pipe-sink file=$tmp/fifo-from-the-box" "module-native-protocol-tcp port=45713 listen=127.0.0.1"; do
      # shellcheck disable=SC2086
      has "$t --sound: load-module ${module%% *} is refused" "denied" "$(PULSE_SERVER="unix:$front" pactl load-module $module 2>&1)"
    done
    is "$t --sound: ... and nothing was made on the host" "no" "$([ -e "$tmp/fifo-from-the-box" ] && echo yes || echo no)"
    # the control: the session's own socket does take them, which is why the box doesn't get it
    if id=$(pactl load-module module-null-sink sink_name=sbx_e2e_control 2>/dev/null); then
      pactl unload-module "$id" >/dev/null 2>&1
      ok "$t --sound: (control) the session's own socket accepts load-module"
    fi
  fi
  has "$t --sound: still no capabilities" "CapEff:	0000000000000000" "$(box 'cat /proc/self/status')"
  "$SB" stop "$name" >/dev/null 2>&1
  is "$t --sound: stop stops the front-end" "inactive" "$(systemctl --user is-active "$unit" 2>&1)"
  is "$t --sound: enter starts it again" "active" "$(box 'true'; systemctl --user is-active "$unit" 2>&1)"
  "$SB" rm "$name" --purge >/dev/null 2>&1
  is "$t --sound: rm stops it and clears its place" "inactive gone" "$(systemctl --user is-active "$unit" 2>&1) $([ -e "$XDG_RUNTIME_DIR/securebox/$name" ] && echo there || echo gone)"
fi

if command -v xdg-dbus-proxy >/dev/null && command -v busctl >/dev/null && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  name="$prefix-dbus"
  boxes+=("$name")
  unit="securebox-dbus-$name"
  "$SB" create "$name" "$image" --dbus org.freedesktop.Notifications --dbus org.gtk.Notifications >/dev/null 2>&1
  is "$t --dbus: create" 0 $?
  is "$t --dbus: the filter runs as a unit of the user's" "active" "$(systemctl --user is-active "$unit" 2>&1)"
  is "$t --dbus: the box is told where the filtered bus is" "socket" "$(box 'test -S "${DBUS_SESSION_BUS_ADDRESS#unix:path=}" && echo socket')"
  has "$t --dbus: list shows the names granted" "org.freedesktop.Notifications,org.gtk.Notifications" "$("$SB" list 2>/dev/null | grep "^$name ")"
  is "$t --dbus: the session bus itself is not in the box" "absent" "$(box 'ls -d /run/user/*/bus 2>/dev/null || echo absent')"
  if [ "$(box 'command -v curl >/dev/null && echo yes')" = yes ]; then
    box 'curl -s -m 3 --unix-socket "${DBUS_SESSION_BUS_ADDRESS#unix:path=}" http://x/ >/dev/null 2>&1; [ $? -ne 7 ]'
    is "$t --dbus: the filter can be connected to" 0 $?
  fi
  # From the host, through the same socket the box has: what the filter lets through.
  filter="unix:path=$XDG_RUNTIME_DIR/securebox/$name/dbus/bus"
  names=$(busctl --address="$filter" list --no-legend 2>/dev/null | awk '{print $1}' | grep -v '^:' | sort | tr '\n' ' ')
  has "$t --dbus: the bus is reachable through the filter" "org.freedesktop.DBus " "$names"
  hasnt "$t --dbus: systemd is not visible through it" "org.freedesktop.systemd1" "$names"
  is "$t --dbus: nothing is visible but the bus and the names granted" "none" "$(echo "$names" | tr ' ' '\n' | grep -v -x -e org.freedesktop.DBus -e org.freedesktop.Notifications -e org.gtk.Notifications -e '' || echo none)"
  # A grant is the interface named like the bus name, not everything its owner exports.
  if busctl --user status org.freedesktop.Notifications >/dev/null 2>&1; then
    has "$t --dbus: the granted name's own interface answers" "s " "$(busctl --address="$filter" call org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications GetServerInformation 2>&1)"
    has "$t --dbus: another interface of the same object is refused" "denied" "$(busctl --address="$filter" call org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.DBus.Properties GetAll s org.freedesktop.Notifications 2>&1)"
  fi
  if busctl --user introspect org.gtk.Notifications /org/gnome/Mutter/RemoteDesktop 2>/dev/null | grep -q CreateSession; then
    # gnome-shell owns this name, and has its remote-desktop interface on the same connection
    has "$t --dbus: the owner's other objects are refused (gnome-shell's remote desktop)" "denied" "$(busctl --address="$filter" introspect org.gtk.Notifications /org/gnome/Mutter/RemoteDesktop 2>&1)"
  fi
  has "$t --dbus: a call to systemd is refused" "ServiceUnknown" "$(busctl --address="$filter" call org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.DBus.Peer Ping 2>&1)"
  has "$t --dbus: so is a call to the secret service" "ServiceUnknown" "$(busctl --address="$filter" call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.DBus.Peer Ping 2>&1)"
  "$SB" stop "$name" >/dev/null 2>&1
  is "$t --dbus: stop stops the filter" "inactive" "$(systemctl --user is-active "$unit" 2>&1)"
  is "$t --dbus: enter starts it again" "active" "$(box 'true'; systemctl --user is-active "$unit" 2>&1)"
  "$SB" rm "$name" --purge >/dev/null 2>&1
  is "$t --dbus: rm stops it and clears its place" "inactive gone" "$(systemctl --user is-active "$unit" 2>&1) $([ -e "$XDG_RUNTIME_DIR/securebox/$name" ] && echo there || echo gone)"
fi

# Refusals. They are tried against a home directory made for the test, so that a check that
# stopped working cannot share (and relabel) the real one.
t="[refusals]"
name="$prefix-refused"
boxes+=("$name")
fake="$tmp/fake-home"
mkdir -p "$fake/.ssh" "$fake/Projects/inner" "$tmp/runtime" "$tmp/elsewhere"
ln -s "$fake/.ssh" "$tmp/to-ssh"
ln -s "$fake" "$tmp/to-home"
refused() { # refused "what" args...: create must fail with 125
  local what=$1
  shift
  HOME="$fake" XDG_RUNTIME_DIR="$tmp/runtime" "$SB" create "$name" "$image" "$@" >/dev/null 2>&1
  is "$t $what" 125 $?
}
refused "sharing the home directory" --share "$fake"
refused "sharing what holds the home directory" --share "$tmp"
refused "sharing a dot-directory of the home" --share "$fake/.ssh"
refused "sharing a symbolic link to a dot-directory of the home" --share "$tmp/to-ssh"
refused "sharing a symbolic link to the home directory" --share "$tmp/to-home"
refused "sharing through a link to the home directory" --share "$tmp/to-home/.ssh"
refused "sharing the session's runtime directory" --share "$tmp/runtime"
refused "sharing securebox's data directory" --share "$SECUREBOX_DATA"
refused "sharing a box's home directory" --share "$SECUREBOX_DATA/$name/home"
refused "sharing nothing (an unset variable)" --share ""
refused "sharing /etc" --share /etc
refused "sharing a directory that isn't there" --share "$tmp/nope"
refused "a share inside a read-write share of the same box" --share "$fake/Projects" --share-ro "$fake/Projects/inner"
refused "the same share twice" --share "$fake/Projects" --share "$fake/Projects"
refused "the system's sockets under /run" --share /run/systemd
refused "a session grant with the host's network" --network host --sound
refused "talking to systemd on the session bus" --dbus org.freedesktop.systemd1
refused "a wildcard of names on the session bus" --dbus 'org.freedesktop.*'
refused "an unknown network" --network bridge
refused "a port that isn't one" --publish 80
refused "an option podman would take" --privileged
refused "no limit on processes" --pids-limit 0
refused "a limit on processes that isn't a number" --pids-limit max
refused "a size for /dev/shm without its unit" --shm-size 64
refused "a size for /dev/shm with more to it" --shm-size '64m,exec'
is "$t none of those made a container" "no" "$(podman container exists "$name" && echo yes || echo no)"
"$SB" create "Not_A_Name" "$image" >/dev/null 2>&1
is "$t a name that isn't one" 125 $?
"$SB" create "--name" "$image" >/dev/null 2>&1
is "$t a name that is an option" 125 $?
SECUREBOX_DATA="$fake" HOME="$fake" "$SB" create "$name" "$image" >/dev/null 2>&1
is "$t a data directory that is the home directory" 125 $?
CONTAINER_HOST="unix:///nowhere" "$SB" list >/dev/null 2>&1
is "$t a remote podman" 125 $?
# --wayland takes a socket in the runtime directory, whatever WAYLAND_DISPLAY says
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  for display in pulse ../../../etc /etc/passwd "$tmp/elsewhere"; do
    WAYLAND_DISPLAY="$display" "$SB" create "$name" "$image" --wayland >/dev/null 2>&1
    is "$t --wayland with WAYLAND_DISPLAY=$display" 125 $?
  done
fi
is "$t ... and still no container" "no" "$(podman container exists "$name" && echo yes || echo no)"

# What happens around a box, rather than in it.
t="[lifecycle]"
name="$prefix-swap"
boxes+=("$name")
mkdir -p "$tmp/swap/inner"
"$SB" create "$name" "$image" --share "$tmp/swap/inner" >/dev/null 2>&1
out=$("$SB" create "$name" "$image" 2>&1)
is "$t a name that is taken" 125 $?
has "$t ... is said to be taken" "already a box named" "$out"
# A share replaced by a link while the box is stopped: podman would follow it at the start.
"$SB" stop "$name" >/dev/null 2>&1
rmdir "$tmp/swap/inner" && ln -s "$tmp/elsewhere" "$tmp/swap/inner"
out=$("$SB" enter "$name" -- true 2>&1)
is "$t a box whose share became a link is not started" 125 $?
has "$t ... and securebox says why" "is not what it was" "$out"
is "$t ... and it stays stopped" "exited" "$(podman inspect --type container --format '{{.State.Status}}' "$name")"
"$SB" rm "$name" --purge >/dev/null 2>&1

if command -v xdg-dbus-proxy >/dev/null && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  # A create that fails must not leave a filter for the next box of that name.
  name="$prefix-failed"
  boxes+=("$name")
  "$SB" create "$name" "localhost/$prefix-no-such-image" --dbus org.freedesktop.secrets >/dev/null 2>&1
  is "$t a create that fails" 125 $?
  is "$t ... leaves no filter running under the name" "inactive" "$(systemctl --user is-active "securebox-dbus-$name.service" 2>&1)"
  is "$t ... and nothing in the runtime directory" "gone" "$([ -e "$XDG_RUNTIME_DIR/securebox/$name" ] && echo there || echo gone)"
fi

# Containers that are not securebox's: a plain one, and one whose image carries the label.
t="[foreign]"
plain="$prefix-foreign"
foreign+=("$plain")
podman create --name "$plain" "$image" true >/dev/null 2>&1
labelled="localhost/$prefix-labelled"
podman commit --quiet --change 'LABEL securebox=1' "$plain" "$labelled" >/dev/null 2>&1
imposter="$prefix-imposter"
foreign+=("$imposter")
podman create --name "$imposter" "$labelled" true >/dev/null 2>&1
is "$t (the second one does carry the label)" "1" "$(podman inspect --type container --format '{{index .Config.Labels "securebox"}}' "$imposter" 2>&1)"
for c in "$plain" "$imposter"; do
  mkdir -p "$SECUREBOX_DATA/$c/home"   # as if a box of that name had been here before
  for command in "enter $c -- true" "stop $c" "rm $c" "rm $c --purge"; do
    # shellcheck disable=SC2086
    out=$("$SB" $command 2>&1)
    is "$t '$command' is refused" 125 $?
    has "$t ... and says why" "is not a box of securebox's" "$out"
  done
  is "$t $c is still there" "yes" "$(podman container exists "$c" && echo yes || echo no)"
  is "$t ... and so is the directory of that name" "yes" "$([ -d "$SECUREBOX_DATA/$c/home" ] && echo yes || echo no)"
done

# A box from an image that declares volumes where the session grants go, and carries the
# label a --dbus box has: created without those grants, it gets none of them.
t="[hostile image]"
hostile="localhost/$prefix-hostile"
podman commit --quiet --change 'LABEL securebox.dbus=org.freedesktop.secrets' --change "VOLUME /run/user/$uid/dbus" --change "VOLUME /run/user/$uid/pulse" "$plain" "$hostile" >/dev/null 2>&1
volumes=$(podman volume ls --quiet | wc -l)
name="$prefix-volumes"
boxes+=("$name")
"$SB" create "$name" "$hostile" >/dev/null 2>&1
is "$t create" 0 $?
is "$t the box is told of no bus and no sound server" "unset" "$(box 'echo "${DBUS_SESSION_BUS_ADDRESS-unset}${PULSE_SERVER+set}${XDG_RUNTIME_DIR+set}"')"
hasnt "$t list shows no D-Bus names for it" "org.freedesktop.secrets" "$("$SB" list 2>/dev/null)"
is "$t no filter was started for it" "inactive" "$(systemctl --user is-active "securebox-dbus-$name" 2>&1)"
is "$t no sound front-end was started for it" "inactive" "$(systemctl --user is-active "securebox-sound-$name" 2>&1)"
"$SB" rm "$name" --purge >/dev/null 2>&1
is "$t rm takes the image's anonymous volumes with the box" "$volumes" "$(podman volume ls --quiet | wc -l)"
podman image rm "$hostile" >/dev/null 2>&1

# export: a command and an application of a box's on the host. The .desktop file is the
# box's word, and this one tries what a hostile box would.
t="[export]"
name="$prefix-export"
boxes+=("$name")
cmd="$prefix-hello"
app="$prefix-app"
self=$(realpath "$SB")
script="$bin/$cmd"
launcher="$apps/securebox+$name+$app.desktop"
"$SB" create "$name" "$image" >/dev/null 2>&1
# Writes standard input to a file in the box, as root.
inbox() { "$SB" enter "$name" --root -- sh -c 'mkdir -p "$(dirname "$0")" && cat >"$0" && chmod 755 "$0"' "$1" 2>/dev/null; }
inbox "/usr/local/bin/$cmd" <<'END'
#!/bin/sh
echo "hello from $SECUREBOX:" "$@"
END
inbox "/usr/share/applications/$app.desktop" <<END
[Desktop Action evil]
Exec=sh -c "touch ~/pwned"
[Desktop Entry]
Type=Application
Name=Hello; \`touch /tmp/pwned\` \$(id)
Name[de]=Hallo
Exec=/usr/local/bin/$cmd --flag=1 %U
Icon=/usr/share/icons/evil.svg
Categories=Utility;Bad Cat;TerminalEmulator;
StartupWMClass=firefox
DBusActivatable=true
MimeType=text/html;
TryExec=/bin/sh
END
inbox "/usr/share/applications/$app-quoted.desktop" <<'END'
[Desktop Entry]
Type=Application
Name=Quoted
Exec=sh -c "echo $HOME; id"
END
out=$("$SB" export "$name" --bin "$cmd" --app "$app" 2>&1)
is "$t export" 0 $?
is "$t the script on the host runs the command in the box" "hello from $name: a b c" "$("$script" a "b c" </dev/null 2>/dev/null)"
is "$t the launcher is securebox's own text, with the box's words checked" "[Desktop Entry]
Type=Application
Name=$name: Hello touch /tmp/pwned id
Exec=$self enter $name -- /usr/local/bin/$cmd --flag=1
Terminal=false
Categories=Utility;
StartupWMClass=$app" "$(cat "$launcher" 2>&1)"
"$SB" export "$name" --app "$app-quoted" >/dev/null 2>&1
is "$t a command line with quoting in it is not exported" "125 absent" "$? $([ -e "$apps/securebox+$name+$app-quoted.desktop" ] && echo there || echo absent)"
"$SB" export "$name" --bin "$prefix-nothing" >/dev/null 2>&1
is "$t a command the box doesn't have is not exported" "125 absent" "$? $([ -e "$bin/$prefix-nothing" ] && echo there || echo absent)"
"$SB" export "$name" --delete --bin "$cmd" >/dev/null 2>&1
is "$t export --delete removes the script" "0 gone" "$? $([ -e "$script" ] && echo there || echo gone)"
"$SB" export "$name" --bin "$cmd" >/dev/null 2>&1
echo "# mine now" >>"$script"
"$SB" export "$name" --bin "$cmd" >/dev/null 2>&1
is "$t a file that was changed since is not written over" "125 # mine now" "$? $(tail -1 "$script")"
# A link where a script would go, to a file that is not there: nothing is written through it.
inbox "/usr/local/bin/$cmd-linked" <<'END'
#!/bin/sh
END
ln -s "$tmp/through-a-link" "$bin/$cmd-linked"
"$SB" export "$name" --bin "$cmd-linked" >/dev/null 2>&1
is "$t a dangling link is not written through" "125 absent link" "$? $([ -e "$tmp/through-a-link" ] && echo there || echo absent) $([ -L "$bin/$cmd-linked" ] && echo link || echo replaced)"
# ... nor is a link to a copy of what securebox would write taken for its own file.
rm -f "$bin/$cmd-linked"
"$SB" export "$name" --bin "$cmd-linked" >/dev/null 2>&1
is "$t the script is created with the mode of a command" "755" "$(stat -c %a "$bin/$cmd-linked" 2>&1)"
cp "$bin/$cmd-linked" "$tmp/same-text"
rm -f "$bin/$cmd-linked"
ln -s "$tmp/same-text" "$bin/$cmd-linked"
"$SB" export "$name" --bin "$cmd-linked" >/dev/null 2>&1
is "$t a link to the same text is not written over" "125 link" "$? $([ -L "$bin/$cmd-linked" ] && echo link || echo replaced)"
"$SB" export "$name" --delete --bin "$cmd-linked" >/dev/null 2>&1
is "$t ... and not removed" "125 link" "$? $([ -L "$bin/$cmd-linked" ] && echo link || echo replaced)"
rm -f "$bin/$cmd-linked"
# The box's own head decides how much securebox is sent: more than it will take, on both streams.
inbox "/usr/local/bin/head" <<'END'
#!/bin/sh
yes ESCAPE >&2 | yes
END
out=$(timeout 60 "$SB" export "$name" --app "$app" 2>&1)
is "$t a box that prints without end is not read without end, and not onto the terminal" "125 0" "$? $(printf '%s' "$out" | grep -c ESCAPE)"
"$SB" enter "$name" --root -- rm -f /usr/local/bin/head 2>/dev/null
"$SB" recreate "$name" >/dev/null 2>&1
is "$t recreate keeps what was exported" "there" "$([ -e "$launcher" ] && echo there || echo gone)"
"$SB" rm "$name" --purge >/dev/null 2>&1
is "$t rm removes the launcher" "gone" "$([ -e "$launcher" ] && echo there || echo gone)"
is "$t ... and leaves the file that is no longer securebox's" "# mine now" "$(tail -1 "$script" 2>&1)"
rm -f "$script"
# A box removed behind securebox's back leaves its exports; a new box of the name does not get them.
"$SB" create "$name" "$image" >/dev/null 2>&1
inbox "/usr/local/bin/$cmd" <<'END'
#!/bin/sh
END
"$SB" export "$name" --bin "$cmd" >/dev/null 2>&1
podman rm --force "$name" >/dev/null 2>&1
"$SB" create "$name" "$image" >/dev/null 2>&1
is "$t a new box does not take over what an earlier one of its name exported" "gone" "$([ -e "$script" ] && echo there || echo gone)"
"$SB" rm "$name" --purge >/dev/null 2>&1

# rm --purge without a box deletes only what is a box's directory.
t="[purge]"
mkdir -p "$SECUREBOX_DATA/stray"
"$SB" rm stray --purge >/dev/null 2>&1
is "$t a directory that was never a box is not purged" "125 yes" "$? $([ -d "$SECUREBOX_DATA/stray" ] && echo yes || echo no)"

t="[cli]"
has "$t list has a column for D-Bus names" "DBUS" "$("$SB" list 2>/dev/null | head -1)"
has "$t --help lists the commands" "create" "$("$SB" --help)"
is "$t --version is the manifest's" "securebox $(sed -n 's/^version = "\(.*\)"/\1/p' "$here/app/zs.toml")" "$("$SB" --version)"
has "$t a command's --help lists its options" "--share-ro" "$("$SB" create --help)"
is "$t a command without arguments has its own help" "usage: securebox list [options]" "$("$SB" list --help | head -1)"
"$SB" list stop x >/dev/null 2>&1
is "$t ... and takes none" 125 $?
"$SB" frobnicate >/dev/null 2>&1
is "$t an unknown command" 125 $?
env -u USER "$SB" list >/dev/null 2>&1
is "$t list works without USER" 0 $?

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
