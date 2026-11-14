#!/usr/bin/env bash
# Makes a release's files from the commit that is checked out, and signs them: tests, the
# static binary, the end-to-end script against that binary, then into build/release/
#
#   securebox-X.Y.Z-x86_64-linux.tar.gz   the binary, LICENSE, README.md
#   SHA256SUMS                            the archive's checksum
#   SHA256SUMS.sig                        an SSH signature of SHA256SUMS
#
#   SECUREBOX_SIGNING_KEY=~/.ssh/securebox-release tools/release.sh
#
# The key is a private key file, or a public key file whose private half is in ssh-agent
# (a hardware key, say). Its public half must be in release-signers, which is what a user
# verifies a download against: a release signed with any other key is not made. Nothing is
# tagged or uploaded; the last lines say what is left to do. DESIGN.md, section 8.
set -euo pipefail

cd "$(dirname "$0")/.."
target=x86_64-linux
identity=securebox-release
signers=release-signers
key=${SECUREBOX_SIGNING_KEY:-}

die() { echo "release: $*" >&2; exit 1; }

for tool in zs podman ssh-keygen sha256sum tar gzip git; do
  command -v "$tool" >/dev/null || die "$tool is not installed"
done

version=$(sed -n 's/^version = "\(.*\)"$/\1/p' app/zs.toml)
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "app/zs.toml has no version X.Y.Z"
grep -qxF "let version = \"$version\"" app/src/Cli.zs || die "Cli.version is not $version"
grep -qxF "v=$version" README.md || die "the README's install lines are not for $version"
grep -q "^## $version (" CHANGELOG.md || die "CHANGELOG.md has no section for $version"
[ -z "$(git status --porcelain)" ] || die "there are uncommitted changes: a release is made from a commit"

# The key, before the long steps: a signature made with it must verify against the signers file.
[ -n "$key" ] || die "set SECUREBOX_SIGNING_KEY to the release key (see the head of this script)"
[ -f "$key" ] || die "no key at $key"
[ -f "$signers" ] || die "$signers is not there: DESIGN.md, section 8, says how it is made"
sign() { ssh-keygen -Y sign -q -f "$key" -n "$identity" "$1"; }
verify() { ssh-keygen -Y verify -q -f "$signers" -I "$identity" -n "$identity" -s "$1.sig" <"$1"; }
probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT
echo probe >"$probe/probe"
sign "$probe/probe" || die "cannot sign with $key"
verify "$probe/probe" || die "$key is not a key of $signers"

zs test
(cd app && zs build --release --target "$target-musl")
binary=app/build/securebox
[ "$("$binary" --version)" = "securebox $version" ] || die "the binary built is not securebox $version"
SECUREBOX=$PWD/$binary tests/e2e.sh

name=securebox-$version-$target
out=build/release
rm -rf "$out"
mkdir -p "$out/$name"
install -m 755 "$binary" "$out/$name/securebox"
install -m 644 LICENSE README.md "$out/$name/"
# The same bytes from the same commit: fixed order, owner and times, no gzip timestamp.
tar --create --directory "$out" --sort=name --owner=0 --group=0 --numeric-owner \
  --mtime="@$(git log -1 --format=%ct)" "$name" | gzip --no-name --best >"$out/$name.tar.gz"
rm -rf "${out:?}/$name"
(cd "$out" && sha256sum "$name.tar.gz" >SHA256SUMS)
sign "$out/SHA256SUMS"
verify "$out/SHA256SUMS" || die "the signature just made does not verify"

echo
echo "release: $out/$name.tar.gz, SHA256SUMS and SHA256SUMS.sig are made and verified. Left to do:"
echo "  git tag -a v$version -m \"securebox $version\" && git push origin v$version"
echo "  attach the three files to the GitHub release of v$version"
