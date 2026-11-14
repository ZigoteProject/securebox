#!/usr/bin/env bash
# End-to-end tests: the built securebox binary against real rootless podman. Each image gets
# a box, and the box is probed from the inside for what DESIGN.md, section 3, promises.
#
#   zs build && tests/e2e.sh                  # all default images
#   E2E_IMAGES="docker.io/library/alpine:latest" tests/e2e.sh
#   SECUREBOX=/path/to/securebox tests/e2e.sh
#
# Nothing of yours is touched: the boxes' data goes to a temporary directory, the boxes are
# named sbx-e2e-<pid>-*, and everything is removed at the end. Needs podman and python3 (for
# a listener on the host's loopback); images that aren't local are pulled.
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
SB=${SECUREBOX:-$here/app/build/securebox}
IMAGES=${E2E_IMAGES:-registry.fedoraproject.org/fedora:45 docker.io/library/ubuntu:24.04 docker.io/library/alpine:latest}

[ -x "$SB" ] || { echo "no binary at $SB: run 'zs build' first, or set SECUREBOX" >&2; exit 2; }
command -v podman >/dev/null || { echo "podman is not installed" >&2; exit 2; }

tmp=$(mktemp -d)
export SECUREBOX_DATA="$tmp/data"
export E2E_SECRET="must-not-reach-the-box"
prefix="sbx-e2e-$$"
boxes=()
foreign=""
listener=""
pass=0
fail=0

cleanup() {
  for b in "${boxes[@]}"; do "$SB" rm "$b" --purge >/dev/null 2>&1; done
  [ -n "$foreign" ] && podman container rm --force "$foreign" >/dev/null 2>&1
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

# A service on the host's loopback, which no box may reach.
port=$((20000 + $$ % 20000))
python3 -I -m http.server --bind 127.0.0.1 "$port" --directory "$tmp" >/dev/null 2>&1 &
listener=$!
for _ in $(seq 50); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.1; done
# Tries a TCP connection from inside the box, with whatever the image has.
connect='if command -v bash >/dev/null; then bash -c "exec 3<>/dev/tcp/$0/$1" 2>/dev/null; else nc -w 2 "$0" "$1" </dev/null 2>/dev/null; fi && echo reached || echo unreachable'

n=0
for image in $IMAGES; do
  n=$((n + 1))
  name="$prefix-$n"
  t="[$image]"
  proj="$tmp/proj-$n"
  ro="$tmp/ro-$n"
  mkdir -p "$proj/sub" "$ro"
  echo "from the host" >"$ro/readme"
  hostport=$((port + n))

  boxes+=("$name")
  out=$("$SB" create "$name" "$image" --share "$proj" --share-ro "$ro" --publish "$hostport:8080" 2>&1)
  is "$t create" 0 $?
  has "$t create says how to enter" "securebox enter $name" "$out"

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
  first=$(ls -A "$HOME" | head -1)
  is "$t the host's home is not there ($first)" "absent" "$(box "ls -d \"\$HOME/$first\" 2>/dev/null || echo absent")"
  is "$t the home is the box's own, and writable" "kept" "$(box 'echo kept > ~/e2e && cat ~/e2e')"
  is "$t the box's home is under the data directory" "kept" "$(cat "$SECUREBOX_DATA/$name/home/e2e" 2>/dev/null)"
  is "$t the box's directory is private" "700" "$(stat -c %a "$SECUREBOX_DATA/$name")"

  # the network
  is "$t the host's loopback is unreachable" "unreachable" "$("$SB" enter "$name" -- sh -c "$connect" 127.0.0.1 "$port" </dev/null 2>&1)"
  is "$t ... also as host.containers.internal" "unreachable" "$("$SB" enter "$name" -- sh -c "$connect" host.containers.internal "$port" </dev/null 2>&1)"
  has "$t a published port is bound to 127.0.0.1" "127.0.0.1:$hostport" "$(podman port "$name" 2>&1)"

  # shares
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

name="$prefix-none"
boxes+=("$name")
"$SB" create "$name" "$image" --network none >/dev/null 2>&1
is "$t --network none: only loopback" "lo" "$(box 'ls /sys/class/net | tr "\n" " " | sed "s/ $//"')"
"$SB" rm "$name" --purge >/dev/null 2>&1

if ls /dev/dri/renderD* >/dev/null 2>&1; then
  name="$prefix-gpu"
  boxes+=("$name")
  "$SB" create "$name" "$image" --gpu >/dev/null 2>&1
  is "$t --gpu: the render device can be opened" "ok" "$(box 'for d in /dev/dri/renderD*; do : <>"$d" && echo ok; break; done')"
  "$SB" rm "$name" --purge >/dev/null 2>&1
  name="$prefix-nogpu"
  boxes+=("$name")
  "$SB" create "$name" "$image" >/dev/null 2>&1
  is "$t without --gpu there is no /dev/dri" "absent" "$(box 'ls -d /dev/dri 2>/dev/null || echo absent')"
  "$SB" rm "$name" --purge >/dev/null 2>&1
fi

t="[refusals]"
name="$prefix-refused"
refused() { # refused "what" args...: create must fail with 125 and make no container
  local what=$1
  shift
  "$SB" create "$name" "$image" "$@" >/dev/null 2>&1
  is "$t $what" 125 $?
}
refused "sharing the home directory" --share "$HOME"
refused "sharing what holds the home directory" --share "$(dirname "$HOME")"
refused "sharing a dot-directory of the home" --share "$HOME/.ssh"
refused "sharing /" --share /
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

t="[foreign]"
foreign="$prefix-foreign"
podman create --name "$foreign" "$image" true >/dev/null 2>&1
for command in "enter $foreign -- true" "stop $foreign" "rm $foreign" "rm $foreign --purge"; do
  # shellcheck disable=SC2086
  out=$("$SB" $command 2>&1)
  is "$t '$command' is refused" 125 $?
  has "$t ... and says why" "not created by securebox" "$out"
done
is "$t the container is still there" "yes" "$(podman container exists "$foreign" && echo yes || echo no)"

t="[cli]"
has "$t --help lists the commands" "create" "$("$SB" --help)"
has "$t a command's --help lists its options" "--share-ro" "$("$SB" create --help)"
"$SB" frobnicate >/dev/null 2>&1
is "$t an unknown command" 125 $?

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
