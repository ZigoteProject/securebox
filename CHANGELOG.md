# Changelog

## Unreleased

- `recreate` (and `create`) check each share again just before the box is made. A box
  with a read-write share could replace a directory inside it with a link while
  `recreate` was narrowing the share to that directory, and the link's target was
  mounted. Found by the review of `recreate` and `export`.
- Releases are signed: `SHA256SUMS.sig` is an SSH signature of `SHA256SUMS`, verified
  against `release-signers` with `ssh-keygen -Y verify`. `tools/release.sh` makes a
  release's files, and refuses a key that is not in that file.
- `export` no longer writes through a symbolic link where a script or a launcher goes. A
  file is created anew (`O_EXCL`, `O_NOFOLLOW`), anything else at the path is left alone
  and reported, and a link is never taken for a file securebox wrote, by `export`,
  `export --delete` or `rm`.

## 0.2.0 (2026-11-14)

- `securebox recreate NAME [grants]`: the box again, with the grants given now and what
  was installed in it kept. For a box that needs the network only while it is set up:
  `securebox recreate dev --network none`.
- `securebox export NAME --bin COMMAND --app APPLICATION`: a script in `~/.local/bin` and
  a launcher in the desktop's menu that run in the box; `--delete` removes them. A
  launcher is written by securebox from checked parts of the box's `.desktop` file, never
  copied.
- `rm` removes what was exported from the box; `rm --purge` also the image `recreate` made.
- `securebox enter NAME -e NAME=VALUE` sets a variable in the box, and `-e NAME` passes the
  host's value without putting it on a command line.
- The `securebox create` line a box was made with is kept in `DATA/NAME/created`, where it
  outlives `rm`.

## 0.1.1 (2026-11-14)

- `securebox --version`.
- The install instructions download with `curl`: the repository is public.

## 0.1.0 (2026-11-14)

The first release.

- `create`, `enter`, `list`, `stop` and `rm`: persistent boxes on rootless podman, from any
  image that has `sh` and `sleep infinity`. A box has its own home directory, no
  capabilities, `no-new-privileges`, a private network, and keeps SELinux and seccomp
  confinement. Nothing of the host is mounted and no host environment variable is passed.
- `enter --root` for installing packages; `enter NAME -- cmd` passes the exit code through.
- Grants, all off by default and fixed at `create`: `--share`, `--share-ro`, `--network
  none|host`, `--publish`, `--gpu`, and the three that reach into the desktop session,
  `--wayland`, `--sound` and `--dbus NAME`. A box with a session grant runs without SELinux
  confinement; the README says what each one costs.
- Refusals: the home directory and what holds it, system directories, `/run`, the data
  directory, dot-directories of the home, links to any of those, running as root, and a
  remote podman.
- A static x86-64 binary. arm64 builds from source and has not been run on one.

Needs podman 5.3 or later. Tested on podman 6.1 with SELinux enforcing, on Fedora, Ubuntu
and Alpine images. The limits are in the README; [DESIGN.md](DESIGN.md), appendix D, has
what the reviews found.
