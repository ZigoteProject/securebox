# Changelog

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
