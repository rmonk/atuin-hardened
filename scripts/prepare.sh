#!/usr/bin/env bash
# Set up the hardened build context for the atuin server at the pinned upstream version.
# Result: build/src (Docker context: upstream source) with build/src/Dockerfile.hardened, and
# build/build-args (KEY=VALUE lines for --build-arg).
#
# Our Dockerfile replaces upstream's, so it depends on how upstream builds and lays out its
# image. The anchors below are read from upstream's tree at the same tag; if any is missing,
# upstream changed its image and overlay/Dockerfile must be reviewed before the build can go on.
#
# Usage: scripts/prepare.sh [upstream-version]   (default: contents of UPSTREAM_VERSION)
# Needs: git, curl, jq.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ref="${1:-$(tr -d '[:space:]' < "$root/UPSTREAM_VERSION")}"
src="$root/build/src"
upstream_repo="${UPSTREAM_REPO:-https://github.com/atuinsh/atuin.git}"

rm -rf "$root/build"
mkdir -p "$root/build"
git clone --quiet --depth 1 --branch "$ref" "$upstream_repo" "$src" 2>/dev/null
sha="$(git -C "$src" rev-parse HEAD)"
echo "prepare: upstream $ref @ ${sha:0:12}"
rm -rf "$src/.git" "$src/.github"

fail() { echo "prepare: $*" >&2; echo "prepare: upstream changed its image; review overlay/Dockerfile." >&2; exit 1; }
need() {  # need <description> <file> <extended regex>: must occur exactly once
  local n
  [ -f "$src/$2" ] || fail "anchor '$1': $2 is missing"
  n="$(grep -cE "$3" "$src/$2" || true)"
  [ "$n" = 1 ] || fail "anchor '$1' matched $n times in $2 (expected 1)"
}

need "server binary build"       Dockerfile '^RUN cargo build --release --bin atuin-server$'
need "build packages"            Dockerfile 'apt install build-essential libssl-dev pkg-config -y'
need "runtime on Debian slim"    Dockerfile '^FROM debian:[a-z]+-[0-9]+-slim AS runtime$'
need "runtime packages"          Dockerfile 'apt install --no-install-recommends ca-certificates curl libssl3 -y'
need "atuin user and /config"    Dockerfile "useradd -c 'atuin user' atuin && mkdir /config && chown atuin:atuin /config"
need "config dir env"            Dockerfile '^ENV ATUIN_CONFIG_DIR=/config$'
need "log level env"             Dockerfile '^ENV RUST_LOG=atuin_server=info$'
need "health check"              Dockerfile 'localhost:\$\{ATUIN_PORT:-8888\}/healthz'
need "entrypoint"                Dockerfile '^ENTRYPOINT \["/usr/local/bin/atuin-server"\]$'
need "toolchain pin"             rust-toolchain.toml '^channel = "[0-9]+\.[0-9]+\.[0-9]+"$'

toolchain="$(sed -nE 's/^channel = "([0-9.]+)"$/\1/p' "$src/rust-toolchain.toml")"
[ -n "$toolchain" ] || { echo "prepare: could not read the Rust toolchain" >&2; exit 1; }
echo "prepare: rust $toolchain"

cp "$root/overlay/Dockerfile" "$src/Dockerfile.hardened"

cat > "$root/build/build-args" <<EOF
RUST_IMAGE=docker.io/library/rust:$toolchain-trixie
RUNTIME_IMAGE=docker.io/library/debian:trixie-slim
UPSTREAM_VERSION=$ref
UPSTREAM_SHA=$sha
EOF
echo "prepare: build context ready at $src"
