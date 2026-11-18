# atuin-hardened

Rebuilds the [atuin](https://github.com/atuinsh/atuin) sync server (`atuin-server`) from upstream release tags with
upstream's pinned Rust toolchain and locked dependencies, on Debian 13 with current packages, running as a fixed
non-1000 uid with tini as PID 1. Each build is gated on a Trivy scan and a smoke test, and the result is published to
`ghcr.io/rmonk/atuin`. It is a drop-in replacement for `ghcr.io/atuinsh/atuin`: same binary, `ATUIN_*` settings,
`/config`, port 8888, health check semantics and entrypoint.

No fork: each build clones upstream at the tag in `UPSTREAM_VERSION` and builds it with `overlay/Dockerfile`.

## Why

- **Upstream's `latest` tag doesn't follow releases.** atuin's image workflow publishes `18.24.8` and so on with
  `latest=false`, so anything on `ghcr.io/atuinsh/atuin:latest` silently stays on an old version (18.24.2 on
  futomaki in November 2026, six releases behind). Here `latest-hardened` always tracks `UPSTREAM_VERSION`, and
  `watch-upstream.yml` opens a PR for each release.
- **Debian packages:** upstream's runtime is a dated `debian:bookworm-*-slim` without `apt-get upgrade`. At 18.24.2
  Arcane reported 4 critical / 8 high there (perl, brotli, OpenSSL, apt), all fixable.
- **uid 1000:** upstream's `useradd` gives the `atuin` user uid 1000, which is a real account on many hosts.
- **Zombies:** upstream's PID 1 is the server, so the health check's `curl` processes are never reaped.

At 18.24.8 (tested 2026-11-18): no critical findings and no fixable high ones. What remains (46 high) is Debian 13
base packages with no fix released yet (util-linux, login, sqlite, perl-base, ...). Dropping curl removed 60 more
(curl's Kerberos/libssh2 dependency tree).

## What gets changed

| | Upstream image | Hardened |
|---|---|---|
| Base | `debian:bookworm-<date>-slim`, no upgrade | `debian:trixie-slim` + `apt-get upgrade`, rebuilt weekly |
| Binary | built on bookworm | same source, toolchain (`rust-toolchain.toml`) and `Cargo.lock` (`--locked`), built on trixie |
| User | `atuin`, uid 1000 | `atuin`, uid/gid **8888** |
| PID 1 | `atuin-server` | `tini`, which reaps orphans |
| Health check | `curl -fsS http://localhost:${ATUIN_PORT:-8888}/healthz` | the same request with bash `/dev/tcp`; curl is not installed |
| Default command | none (`start` given at run time) | `start` |

## Running it

```yaml
image: ghcr.io/rmonk/atuin:latest-hardened
command: start
cap_drop: [ALL]
security_opt: [no-new-privileges:true]
read_only: true
tmpfs: [/tmp]
volumes:
  - config:/config      # must be owned by 8888:8888
```

Moving from upstream's image, once, with the container stopped: `chown -R 8888:8888 <config volume>` on the host. The
database needs nothing (it lives in PostgreSQL), but back it up before moving to a newer atuin release: the server
migrates the schema on start.

## Tags

- `latest-hardened`: newest successful build of the current `UPSTREAM_VERSION`
- `<upstream>-hardened`, e.g. `v18.24.8-hardened`
- `<upstream>-hardened-<YYYYMMDD>`: immutable, use this to pin or roll back

amd64 only.

## Automation

- `build.yml`: runs on push/PR, manually, and weekly (Mon 06:27 UTC). It runs prepare, then build, then the Trivy
  gate (fixable CRITICAL/HIGH fail the build; exceptions go in `.trivyignore.yaml`, scoped to a package URL with a
  reason and an expiry date), then the smoke test, then pushes (on main only). The Trivy JSON/table output is kept as
  a build artifact. If the `HC_PING_URL` secret is set, a successful run pings it.
- `watch-upstream.yml`: runs daily. When atuin publishes a new (non-prerelease) release, it opens a PR that bumps
  `UPSTREAM_VERSION` and dispatches the build on that branch. Merge it when it is green.

## Keeping in step with upstream

Our Dockerfile replaces upstream's, so `scripts/prepare.sh` checks anchors in upstream's tree at the tag (the build
command and packages, the runtime base and packages, the user and `/config`, env defaults, the health check, the
entrypoint, and the toolchain pin, from which the Rust image tag is taken). If one is missing, the build fails
instead of shipping something that only looks right. Then compare upstream's `Dockerfile` with `overlay/Dockerfile`.

## Smoke test

`scripts/smoke-test.sh` starts the image with PostgreSQL 18 the way futomaki runs it (no capabilities,
`no-new-privileges`, read-only root, tmpfs `/tmp`, a fresh `/config` volume) and checks:
- uid 8888, tini as PID 1, and the upstream version
- `/healthz`; register (registration open for the test), `/api/v0/me` and `/api/v0/record` with the session token
- the image's own health check command passes, and curl is not in the image
- after recreating it with `ATUIN_OPEN_REGISTRATION=false`: login still works and a new registration is refused
- an orphaned process is reaped (no zombies), and the logs have no panics or permission errors

## Local build

```bash
scripts/prepare.sh
podman build --format docker -f build/src/Dockerfile.hardened $(sed 's/^/--build-arg /' build/build-args) \
  -t atuin:hardened build/src      # --format docker: OCI images drop HEALTHCHECK
DOCKER=podman scripts/smoke-test.sh atuin:hardened
```
