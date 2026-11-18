#!/usr/bin/env bash
# Start the image with PostgreSQL the way futomaki runs it (no capabilities, no-new-privileges,
# read-only root, tmpfs /tmp, fresh /config volume), then check:
#   - it runs as uid 8888 with tini as PID 1, and reports the upstream version
#   - /healthz answers; a user can register (open registration on for the test), log in, and
#     /api/v0/me and /api/v0/record work with the session token
#   - after recreating it with ATUIN_OPEN_REGISTRATION=false (as on futomaki), the user can
#     still log in and a new registration is refused
#   - orphaned processes are reaped (no zombies, unlike upstream's image)
#
# Usage: scripts/smoke-test.sh <image>      (DOCKER=podman to use podman; needs curl + jq)
set -euo pipefail
trap 'echo "smoke: FAIL command failed at line $LINENO: $BASH_COMMAND" >&2' ERR

image="${1:?usage: smoke-test.sh <image>}"
docker="${DOCKER:-docker}"
root="$(cd "$(dirname "$0")/.." && pwd)"
want_version="$(tr -d '[:space:]v' < "$root/UPSTREAM_VERSION")"
tag="atuin-smoke-$$"
net="$tag-net"
port="${SMOKE_PORT:-18888}"
base="http://127.0.0.1:$port"
dbpass="db$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
password="pw$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"

cleanup() {
  rc=$?
  if [ $rc -ne 0 ]; then echo "--- logs ---"; $docker logs --tail 60 "$tag" 2>&1 || true; fi
  $docker rm -f "$tag" "$tag-db" >/dev/null 2>&1 || true
  $docker volume rm -f "$tag-config" >/dev/null 2>&1 || true
  $docker network rm "$net" >/dev/null 2>&1 || true
  exit $rc
}
trap cleanup EXIT

$docker network create "$net" >/dev/null
$docker run -d --name "$tag-db" --network "$net" --network-alias db \
  -e POSTGRES_USER=atuin -e POSTGRES_PASSWORD="$dbpass" -e POSTGRES_DB=atuin \
  docker.io/library/postgres:18 >/dev/null
for _ in $(seq 60); do $docker exec "$tag-db" pg_isready -U atuin -d atuin >/dev/null 2>&1 && break; sleep 1; done
sleep 2   # the image's init restarts postgres once after creating the database

start() {  # start <open_registration>
  $docker run -d --name "$tag" --network "$net" \
    --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp \
    -e ATUIN_HOST=0.0.0.0 -e ATUIN_OPEN_REGISTRATION="$1" \
    -e ATUIN_DB_URI="postgres://atuin:$dbpass@db/atuin" \
    -v "$tag-config:/config" -p "127.0.0.1:$port:8888" "$image" start >/dev/null
  for _ in $(seq 60); do curl -fsS -o /dev/null "$base/healthz" 2>/dev/null && return 0; sleep 1; done
  echo "smoke: FAIL /healthz not up"; return 1
}

start true

uid="$($docker exec "$tag" sh -c 'stat -c %u /proc/1')"
pid1="$($docker exec "$tag" sh -c 'tr "\0" " " < /proc/1/cmdline')"
[ "$uid" = 8888 ] || { echo "smoke: FAIL runs as uid $uid, expected 8888"; exit 1; }
case "$pid1" in tini*) ;; *) echo "smoke: FAIL PID 1 is '$pid1', expected tini"; exit 1 ;; esac
version="$($docker exec "$tag" atuin-server --version)"
grep -qF "$want_version" <<<"$version" || { echo "smoke: FAIL version '$version', expected $want_version"; exit 1; }
echo "smoke: $version, uid 8888, tini PID 1"

session="$(curl -fsS -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg p "$password" '{username:"smoke",email:"smoke@example.com",password:$p}')" "$base/register" | jq -r .session)"
[ -n "$session" ] && [ "$session" != null ] || { echo "smoke: FAIL register returned no session"; exit 1; }
curl -fsS -H "Authorization: Token $session" "$base/api/v0/me" | jq -e '.username == "smoke"' >/dev/null \
  || { echo "smoke: FAIL /api/v0/me"; exit 1; }
curl -fsS -o /dev/null -H "Authorization: Token $session" "$base/api/v0/record" \
  || { echo "smoke: FAIL /api/v0/record"; exit 1; }
echo "smoke: register, /api/v0/me and /api/v0/record OK"

# The image's health check command (bash /dev/tcp, no curl) must pass.
# (podman keeps HEALTHCHECK only in docker-format images: build with `--format docker`.)
hc="$($docker image inspect --format '{{json .Config.Healthcheck}}' "$image" | jq -r '.Test // empty | .[1:] | @sh')"
[ -n "$hc" ] || { echo "smoke: FAIL the image has no health check"; exit 1; }
eval "$docker exec \"$tag\" $hc" || { echo "smoke: FAIL the image's health check command fails"; exit 1; }
$docker exec "$tag" sh -c 'command -v curl' >/dev/null 2>&1 && { echo "smoke: FAIL curl is in the image"; exit 1; }
echo "smoke: health check command passes (no curl in the image)"

# Recreate with registration closed, as on futomaki.
$docker rm -f "$tag" >/dev/null
start false
session="$(curl -fsS -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg p "$password" '{username:"smoke",password:$p}')" "$base/login" | jq -r .session)"
curl -fsS -H "Authorization: Token $session" "$base/api/v0/me" | jq -e '.username == "smoke"' >/dev/null \
  || { echo "smoke: FAIL login after recreate"; exit 1; }
code="$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -d '{"username":"other","email":"other@example.com","password":"other-password"}' "$base/register")"
[ "$code" -ge 400 ] || { echo "smoke: FAIL registration with ATUIN_OPEN_REGISTRATION=false returned $code"; exit 1; }
echo "smoke: login after recreate OK; registration closed ($code)"

# An orphan must be reaped by PID 1.
$docker exec "$tag" sh -c 'sh -c "sleep 0.1 &" ; true'
sleep 2
zombies="$($docker exec "$tag" sh -c 'for s in /proc/[0-9]*/stat; do cut -d" " -f3 "$s" 2>/dev/null; done | grep -c "^Z$" || true')"
[ "$zombies" = 0 ] || { echo "smoke: FAIL $zombies zombie process(es)"; exit 1; }
echo "smoke: no zombies"

logs="$($docker logs "$tag" 2>&1)"
if grep -qiE 'panic|permission denied|read-only file system' <<<"$logs"; then
  grep -iE 'panic|permission denied|read-only file system' <<<"$logs" | head -5
  echo "smoke: FAIL panic or permission error in logs"; exit 1
fi
echo "smoke: PASS"
