#!/usr/bin/env bash
# dev-smoke.sh — end-to-end smoke test for `akm dev` (the local dev loop).
#
# Scaffolds an app, installs deps, starts `akm dev` on random ports, then proves
# the proxy's behavior over real HTTP and a clean shutdown:
#   1. /api/health      → 200 (proves /api/* routes to uvicorn)
#   2. /api/me          → 200 echoing the minted dev identity
#                         (proves mint → inject → backend-verify, one shared key)
#   3. /api/me + a forged client X-Akm-Identity → still the dev identity
#                         (proves the proxy STRIPS client identity, never trusts it)
#   4. /                → 200 HTML (proves /* routes to Vite)
#   5. SIGINT           → process exits and leaves no orphan uvicorn/vite
#
# Needs node/npm/uv. No network beyond npm/uv installs.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/cli/zig-out/bin/akm"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/akm-dev-smoke.XXXXXX")"
APP="$WORK/app"
# Random ports in a high range to avoid collisions with other runs.
base=$(( (RANDOM % 10000) + 24000 ))
PPORT=$base; BPORT=$((base+1)); VPORT=$((base+2))
DEV_PID=""
PASS=0; FAIL=0; FAILED=()

c_g="\033[32m"; c_r="\033[31m"; c_0="\033[0m"
ok()  { PASS=$((PASS+1)); printf "  ${c_g}✓${c_0} %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED+=("$1"); printf "  ${c_r}✗ %s${c_0}\n" "$1"; [ -n "${2:-}" ] && printf "      %s\n" "$2"; }

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  if [ -n "$DEV_PID" ] && kill -0 "$DEV_PID" 2>/dev/null; then
    kill -INT "$DEV_PID" 2>/dev/null
    for _ in $(seq 1 30); do kill -0 "$DEV_PID" 2>/dev/null || break; sleep 0.2; done
    kill -KILL "$DEV_PID" 2>/dev/null
  fi
  # belt-and-braces: kill anything still bound to our ports
  for p in "$PPORT" "$BPORT" "$VPORT"; do
    pids="$(lsof -ti tcp:"$p" 2>/dev/null || true)"
    # shellcheck disable=SC2086  # intentional word-split: lsof may return many PIDs
    [ -n "$pids" ] && kill -KILL $pids 2>/dev/null
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

step() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; exit 1; fi; }

printf "%b== setup ==%b\n" "$c_g" "$c_0"
[ -x "$BIN" ] || (cd "$ROOT/cli" && zig build) || { echo "build failed"; exit 1; }
step "init" "$BIN" init app "$APP"
# $1 is expanded by the inner `bash -c`, not here — single quotes are intentional.
# shellcheck disable=SC2016
step "uv sync" bash -c 'cd "$1" && uv sync' _ "$APP"
# shellcheck disable=SC2016
step "npm install" bash -c 'cd "$1" && npm install' _ "$APP"

printf "%b== start akm dev (ports %s/%s/%s) ==%b\n" "$c_g" "$PPORT" "$BPORT" "$VPORT" "$c_0"
( cd "$APP" && exec "$BIN" dev --port "$PPORT" --backend-port "$BPORT" --vite-port "$VPORT" ) \
  >"$WORK/dev.log" 2>&1 &
DEV_PID=$!

# Wait until the proxy serves a 200 from /api/health (uvicorn + proxy both up).
base_url="http://127.0.0.1:$PPORT"
up=0
for _ in $(seq 1 100); do  # up to ~50s
  if ! kill -0 "$DEV_PID" 2>/dev/null; then break; fi
  code="$(curl -s -o /dev/null -w '%{http_code}' "$base_url/api/health" 2>/dev/null || true)"
  [ "$code" = "200" ] && { up=1; break; }
  sleep 0.5
done
if [ "$up" = "1" ]; then ok "proxy up; /api/health → 200 (uvicorn routed)"; else
  bad "proxy/backend came up" "$(tail -5 "$WORK/dev.log" 2>/dev/null)"
  printf "%baborting probes%b\n" "$c_r" "$c_0"; exit 1
fi

printf "%b== probes ==%b\n" "$c_g" "$c_0"
# 2. /api/me echoes the minted dev identity
me="$(curl -s "$base_url/api/me" 2>/dev/null)"
if printf '%s' "$me" | grep -q '"email":"dev@akm.local"' && printf '%s' "$me" | grep -q '"kind":"user"'; then
  ok "/api/me returns minted identity (mint→inject→verify)"
else bad "/api/me identity" "got: $me"; fi

# 3. a forged client X-Akm-Identity must be stripped, not trusted
forged="$(curl -s -H 'X-Akm-Identity: forged.garbage.token' \
              -H 'Cf-Access-Jwt-Assertion: spoofed' "$base_url/api/me" 2>/dev/null)"
if printf '%s' "$forged" | grep -q '"email":"dev@akm.local"'; then
  ok "proxy strips client identity (forged header ignored)"
else bad "proxy strips client identity" "got: $forged"; fi

# 3b. a DB-backed route degrades gracefully without a database (503, not a crash)
db_code="$(curl -s -o /dev/null -w '%{http_code}' "$base_url/api/db-check" 2>/dev/null || true)"
if [ "$db_code" = "503" ]; then ok "/api/db-check → 503 (DB-less dev degrades gracefully)"; else
  bad "/api/db-check graceful 503" "got code=$db_code (expected 503)"; fi

# 4. / serves the Vite app (HTML)
root_code="$(curl -s -o "$WORK/root.html" -w '%{http_code}' "$base_url/" 2>/dev/null || true)"
if [ "$root_code" = "200" ] && grep -qi '<div id="root"\|<!doctype html\|<html' "$WORK/root.html" 2>/dev/null; then
  ok "/ serves Vite HTML (/* routed to Vite)"
else bad "/ serves Vite HTML" "code=$root_code"; fi

printf "%b== shutdown ==%b\n" "$c_g" "$c_0"
t0=$(date +%s)
kill -INT "$DEV_PID" 2>/dev/null
exited=0
for _ in $(seq 1 40); do kill -0 "$DEV_PID" 2>/dev/null || { exited=1; break; }; sleep 0.2; done
t1=$(date +%s)
if [ "$exited" = "1" ]; then ok "clean shutdown on SIGINT (~$((t1-t0))s)"; DEV_PID=""; else
  bad "clean shutdown on SIGINT" "still alive after 8s"; fi
sleep 0.5
orphans=0
for p in "$PPORT" "$BPORT" "$VPORT"; do
  [ -n "$(lsof -ti tcp:"$p" 2>/dev/null || true)" ] && orphans=$((orphans+1))
done
if [ "$orphans" = "0" ]; then ok "no orphan processes on any port"; else
  bad "no orphan processes" "$orphans port(s) still bound"; fi

printf "%b== summary ==%b\n" "$c_g" "$c_0"
printf "  %b%d passed%b, " "$c_g" "$PASS" "$c_0"
if [ "$FAIL" -eq 0 ]; then printf "%b0 failed%b\n" "$c_g" "$c_0"; exit 0; fi
printf "%b%d failed%b\n" "$c_r" "$FAIL" "$c_0"
for n in "${FAILED[@]}"; do printf "    ${c_r}- %s${c_0}\n" "$n"; done
exit 1
