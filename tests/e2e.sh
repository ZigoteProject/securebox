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
# removed at the end. Needs podman and python3 (for a listener on the host's loopback);
# images that aren't local are pulled.
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

  # lifecycle
  has "$t list shows the box" "$name" "$("$SB" list 2>&1)"
  "$SB" stop "$name" >/dev/null 2>&1
  is "$t stop" "exited" "$(podman inspect --type container --format '{{.State.Status}}' "$name")"
  is "$t enter starts a stopped box" "up" "$(box 'echo up')"
  is "$t what root installed is still there" "ok" "$(box 'test -e /usr/e2e && echo ok')"

  # removal: the home is kept until --purge, which also deletes what the box's root made
  rootbox "touch $HOME/made-by-root" >/dev/null
  out=$("$SB" rm "$name" 2>&1)
  is "$t rm" 0 $?
  has "$t rm says where the home is" "$SECUREBOX_DATA/$name" "$out"
  is "$t rm keeps the home" "kept" "$(cat "$SECUREBOX_DATA/$name/home/e2e" 2>/dev/null)"
  "$SB" enter "$name" -- true >/dev/null 2>&1
  is "$t a removed box cannot be entered" 125 $?
  "$SB" rm "$name" --purge >/dev/null 2>&1
  is "$t rm --purge after the box is gone" 0 $?
  is "$t ... deletes its directory" "gone" "$([ -e "$SECUREBOX_DATA/$name" ] && echo there || echo gone)"
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

# Refusals. They are tried against a home directory made for the test, so that a check that
# stopped working cannot share (and relabel) the real one.
t="[refusals]"
name="$prefix-refused"
boxes+=("$name")
fake="$tmp/fake-home"
mkdir -p "$fake/.ssh" "$fake/Projects" "$tmp/runtime" "$tmp/elsewhere"
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
refused "an unknown network" --network bridge
refused "a port that isn't one" --publish 80
refused "an option podman would take" --privileged
is "$t none of those made a container" "no" "$(podman container exists "$name" && echo yes || echo no)"
"$SB" create "Not_A_Name" "$image" >/dev/null 2>&1
is "$t a name that isn't one" 125 $?
"$SB" create "--name" "$image" >/dev/null 2>&1
is "$t a name that is an option" 125 $?
SECUREBOX_DATA="$fake" HOME="$fake" "$SB" create "$name" "$image" >/dev/null 2>&1
is "$t a data directory that is the home directory" 125 $?
CONTAINER_HOST="unix:///nowhere" "$SB" list >/dev/null 2>&1
is "$t a remote podman" 125 $?

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

# rm --purge without a box deletes only what is a box's directory.
t="[purge]"
mkdir -p "$SECUREBOX_DATA/stray"
"$SB" rm stray --purge >/dev/null 2>&1
is "$t a directory that was never a box is not purged" "125 yes" "$? $([ -d "$SECUREBOX_DATA/stray" ] && echo yes || echo no)"

t="[cli]"
has "$t --help lists the commands" "create" "$("$SB" --help)"
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
