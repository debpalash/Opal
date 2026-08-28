#!/usr/bin/env bash
# Boot and exercise a locally loaded Opal container image.
# Usage: scripts/docker-smoke.sh IMAGE EXPECTED_ARCH
set -euo pipefail
umask 077

if [[ $# -ne 2 ]]; then
  echo "usage: $0 IMAGE {amd64|arm64}" >&2
  exit 2
fi

image=$1
expected_arch=$2
case "$expected_arch" in
  amd64) expected_uname=x86_64 ;;
  arm64) expected_uname=aarch64 ;;
  *) echo "unsupported expected architecture: $expected_arch" >&2; exit 2 ;;
esac

container="opal-smoke-$$"
config_volume="opal-smoke-config-$$"
smoke_dir=$(mktemp -d "${TMPDIR:-/tmp}/opal-docker-smoke.XXXXXX")
base_url="http://127.0.0.1:${OPAL_SMOKE_PORT:-41595}"
setup_path=/config/opal/setup.token
setup_token=""

cleanup() {
  status=$?
  if [[ $status -ne 0 ]]; then
    echo "── container logs after smoke failure ──" >&2
    docker logs "$container" > "$smoke_dir/failure.log" 2>&1 || true
    # Never let a server regression copy a setup/API credential into CI logs,
    # even when the failure happened before this script could read the token.
    sed -E 's/[0-9a-f]{64}/[REDACTED-64-HEX]/g' "$smoke_dir/failure.log" >&2
  fi
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$config_volume" >/dev/null 2>&1 || true
  rm -rf "$smoke_dir"
  exit "$status"
}
trap cleanup EXIT

docker volume create "$config_volume" >/dev/null
docker run -d --name "$container" \
  -v "$config_volume:/config" \
  -p "127.0.0.1:${OPAL_SMOKE_PORT:-41595}:41595" "$image" >/dev/null

echo "── headless binary has no direct GUI dependencies ──"
docker cp "$container:/usr/local/bin/opal" "$smoke_dir/opal"
python3 scripts/elf-needed.py "$smoke_dir/opal" > "$smoke_dir/needed.txt"
cat "$smoke_dir/needed.txt"
if grep -Eiq 'sdl|libx11|libxext|libgl|libpulse|libasound' "$smoke_dir/needed.txt"; then
  echo "FAIL: GUI libraries crept back into the headless binary." >&2
  exit 1
fi

echo "── image architecture is $expected_arch ──"
got=$(docker exec "$container" uname -m)
if [[ "$got" != "$expected_uname" ]]; then
  echo "FAIL: expected $expected_arch ($expected_uname), container reports $got" >&2
  exit 1
fi

echo "── wait for /health ──"
healthy=0
for _ in $(seq 1 30); do
  if curl -fsS "$base_url/health" -o "$smoke_dir/health.json"; then
    healthy=1
    break
  fi
  sleep 2
done
if [[ $healthy -ne 1 ]]; then
  echo "FAIL: /health never came up" >&2
  exit 1
fi
grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' "$smoke_dir/health.json"

echo "── first-run registration and session auth ──"
curl -fsS "$base_url/api/auth/status" -o "$smoke_dir/auth-status.json"
grep -Eq '"needs_setup"[[:space:]]*:[[:space:]]*true' "$smoke_dir/auth-status.json"

# The first administrator is protected by a one-time credential in the
# persistent config volume. Operators can read this file with `docker exec`
# (or directly from a bind mount); the server logs its path, never its value.
setup_ready=0
for _ in $(seq 1 30); do
  if docker exec "$container" test -s "$setup_path"; then
    setup_ready=1
    break
  fi
  sleep 1
done
if [[ $setup_ready -ne 1 ]]; then
  echo "FAIL: first-admin credential was not created at $setup_path" >&2
  exit 1
fi
setup_mode=$(docker exec "$container" stat -c '%a' "$setup_path")
setup_owner=$(docker exec "$container" stat -c '%u' "$setup_path")
if [[ "$setup_mode" != 600 || "$setup_owner" != 10001 ]]; then
  echo "FAIL: $setup_path must be owned by uid 10001 with mode 600; got $setup_owner:$setup_mode" >&2
  exit 1
fi
setup_token=$(docker exec "$container" sh -c 'tr -d "\r\n" < /config/opal/setup.token')
if [[ ! "$setup_token" =~ ^[0-9a-f]{64}$ ]]; then
  echo "FAIL: $setup_path does not contain a 256-bit lowercase-hex credential" >&2
  exit 1
fi

onboarding_logged=0
for _ in $(seq 1 15); do
  docker logs "$container" > "$smoke_dir/onboarding.log" 2>&1
  if grep -Fq "$setup_path" "$smoke_dir/onboarding.log"; then
    onboarding_logged=1
    break
  fi
  sleep 1
done
if [[ $onboarding_logged -ne 1 ]]; then
  echo "FAIL: container logs do not tell the operator where to find the setup credential" >&2
  exit 1
fi
if grep -Fq "$setup_token" "$smoke_dir/onboarding.log"; then
  echo "FAIL: first-admin credential leaked to container logs" >&2
  exit 1
fi
printf 'X-Opal-Setup-Token: %s\n' "$setup_token" > "$smoke_dir/setup-header"

code=$(curl -sS -o "$smoke_dir/register-without-setup.json" -w '%{http_code}' \
  -X POST --data 'username=ci-admin&password=ci-smoke-pass' \
  "$base_url/api/auth/register")
if [[ "$code" != 403 ]]; then
  echo "FAIL: first-admin registration without setup credential returned $code, expected 403" >&2
  exit 1
fi

# The capability must not bypass the local-authority checks used to keep a
# fresh server from being claimed through a public reverse proxy or hostile
# browser Origin. Rejections must leave the one-time file intact.
code=$(curl -sS -o "$smoke_dir/register-cross-origin.json" -w '%{http_code}' \
  -X POST -H "@$smoke_dir/setup-header" -H 'Origin: https://attacker.example' \
  --data 'username=ci-evil-origin&password=ci-smoke-pass' \
  "$base_url/api/auth/register")
if [[ "$code" != 403 ]]; then
  echo "FAIL: cross-origin first-admin registration returned $code, expected 403" >&2
  exit 1
fi
code=$(curl -sS -o "$smoke_dir/register-dns-host.json" -w '%{http_code}' \
  -X POST -H "@$smoke_dir/setup-header" -H 'Host: opal.example' \
  --data 'username=ci-dns-host&password=ci-smoke-pass' \
  "$base_url/api/auth/register")
if [[ "$code" != 403 ]]; then
  echo "FAIL: DNS-Host first-admin registration returned $code, expected 403" >&2
  exit 1
fi
if ! docker exec "$container" test -s "$setup_path"; then
  echo "FAIL: rejected registration consumed the one-time setup credential" >&2
  exit 1
fi

curl -fsS -X POST \
  -H "@$smoke_dir/setup-header" \
  -c "$smoke_dir/session.cookies" \
  --data 'username=ci-admin' \
  --data 'password=ci-smoke-pass' \
  "$base_url/api/auth/register" -o "$smoke_dir/register.json"
if ! python3 -c 'import json,sys; assert json.load(open(sys.argv[1], encoding="utf-8")) == {"ok": True}' "$smoke_dir/register.json"; then
  echo "FAIL: registration did not return the cookie-session success contract" >&2
  exit 1
fi
if ! grep -q 'opal_session' "$smoke_dir/session.cookies"; then
  echo "FAIL: registration did not issue a browser session cookie" >&2
  exit 1
fi
if docker exec "$container" test -e "$setup_path"; then
  echo "FAIL: one-time setup credential still exists after successful registration" >&2
  exit 1
fi
code=$(curl -sS -o "$smoke_dir/register-replay.json" -w '%{http_code}' \
  -X POST -H "@$smoke_dir/setup-header" \
  --data 'username=ci-replay&password=ci-smoke-pass' \
  "$base_url/api/auth/register")
if [[ "$code" != 403 ]]; then
  echo "FAIL: replayed first-admin credential returned $code, expected 403" >&2
  exit 1
fi
curl -fsS -b "$smoke_dir/session.cookies" \
  "$base_url/api/status" -o "$smoke_dir/api-status.json"
code=$(curl -sS -o /dev/null -w '%{http_code}' "$base_url/api/status")
if [[ "$code" != 401 ]]; then
  echo "FAIL: expected 401 without a token, got $code" >&2
  exit 1
fi

echo "── logs route and web UI ──"
curl -fsS -b "$smoke_dir/session.cookies" \
  "$base_url/api/logs?limit=5" -o "$smoke_dir/logs.json"
grep -q '"entries"' "$smoke_dir/logs.json"
curl -fsS "$base_url/" -o "$smoke_dir/index.html"
# Always grep downloaded files. `curl | grep -q` fails intermittently under
# pipefail when grep finds an early match and closes curl's pipe (curl exit 23).
grep -qiE 'opal|<!doctype' "$smoke_dir/index.html"

docker logs "$container" > "$smoke_dir/container.log" 2>&1
if grep -Fq "$setup_token" "$smoke_dir/container.log"; then
  echo "FAIL: first-admin credential leaked to container logs" >&2
  exit 1
fi
tail -20 "$smoke_dir/container.log"
echo "SMOKE OK ($expected_arch)"
