#!/usr/bin/env bash
# e2e-test.sh — repeatable end-to-end test harness for the akm CLI.
#
# Scaffolds a throwaway app and exercises every command against the real
# toolchain (node/npm/uv/npx/wrangler), asserting concrete outcomes. Each check
# bumps a PASS/FAIL counter; the script exits nonzero if any check fails.
#
# Out of local scope (no Docker / no Workers-Paid / no psql here): a real
# container build, a real `wrangler deploy`, and live SQL. Those are covered by
# build-mode import + `--dry-run`. Live Neon preview is opt-in (RUN_NEON=1 with
# a NEON_PROJECT_ID); otherwise preview is tested via its arg-validation paths.
#
# Usage:
#   scripts/e2e-test.sh                 # full local run
#   FAST=1 scripts/e2e-test.sh          # skip slow npm/uv/build/components blocks
#   RUN_NEON=1 NEON_PROJECT_ID=<id> scripts/e2e-test.sh   # also test live preview
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_DIR="$ROOT/cli"
BIN="$CLI_DIR/zig-out/bin/akm"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/akm-e2e.XXXXXX")"
APP="$WORK/app"
PKG="app"            # akm slugifies the app name into the python package name
PASS=0
FAIL=0
FAILED_NAMES=()

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

c_g="\033[32m"; c_r="\033[31m"; c_y="\033[33m"; c_0="\033[0m"
ok()   { PASS=$((PASS+1)); printf "  ${c_g}✓${c_0} %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf "  ${c_r}✗ %s${c_0}\n" "$1"; [ -n "${2:-}" ] && printf "      %s\n" "$2"; }
skip() { printf "  ${c_y}- skip${c_0} %s\n" "$1"; }
hdr()  { printf "\n${c_y}== %s ==${c_0}\n" "$1"; }

# expect_ok "name" cmd...    — command must exit 0
expect_ok() { local n="$1"; shift; local out; if out="$("$@" 2>&1)"; then ok "$n"; else bad "$n" "exit $? :: $(printf '%s' "$out" | tail -1)"; fi; }
# expect_fail "name" cmd...  — command must exit nonzero
expect_fail() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n" "expected nonzero exit, got 0"; else ok "$n"; fi; }
# expect_fail_in DIR "name" cmd... — run in DIR (subshell, args quoted), must exit nonzero
expect_fail_in() { local d="$1" n="$2"; shift 2; if ( cd "$d" && "$@" ) >/dev/null 2>&1; then bad "$n" "expected nonzero exit, got 0"; else ok "$n"; fi; }
# in_app "name" cmd...       — run inside $APP, must exit 0
in_app() { local n="$1"; shift; local out; if out="$(cd "$APP" && "$@" 2>&1)"; then ok "$n"; else bad "$n" "exit $? :: $(printf '%s' "$out" | tail -1)"; fi; }
assert_file() { if [ -e "$1" ]; then ok "file: ${1#"$APP"/}"; else bad "file missing: ${1#"$APP"/}"; fi; }
assert_grep() { if grep -q "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3" "pattern '$2' not in ${1#"$APP"/}"; fi; }

# ---------------------------------------------------------------------------
hdr "build the binary"
if (cd "$CLI_DIR" && zig build >/dev/null 2>&1); then ok "zig build"; else bad "zig build" "fix compile errors first"; exit 1; fi
[ -x "$BIN" ] || { bad "binary present"; exit 1; }

# ---------------------------------------------------------------------------
hdr "init"
expect_ok "akm init app" "$BIN" init "$PKG" "$APP"
for f in package.json pyproject.toml wrangler.jsonc Dockerfile vite.config.ts tsconfig.json alembic.ini \
         ".gitignore" "src/$PKG/backend/app.py" "src/worker/index.ts" ui/main.tsx; do
  assert_file "$APP/$f"
done
# No leftover *akm* template tokens. Matches the render grammar (a bare
# identifier, or a #if/#unless/`/`close directive) — NOT JSX object literals
# like `style={{ fontFamily: ... }}`, which are valid in static .tsx files.
# (render.zig hard-errors on unknown vars, so this mainly guards static files.)
TOKEN_RE='\{\{[[:space:]]*[#/]?[a-zA-Z_][a-zA-Z0-9_]*([[:space:]]+[a-zA-Z_][a-zA-Z0-9_.]*)?[[:space:]]*\}\}'
if grep -rIlE "$TOKEN_RE" "$APP" >/dev/null 2>&1; then
  bad "no leftover akm template tokens" "$(grep -rIlE "$TOKEN_RE" "$APP" | sed "s#$APP/##" | tr '\n' ' ')"
else ok "no leftover akm template tokens"; fi
# no unresolved path tokens
if find "$APP" -path '*__pkg__*' -o -path '*__slug__*' 2>/dev/null | grep -q .; then
  bad "no leftover __pkg__/__slug__ path tokens"; else ok "no leftover __pkg__/__slug__ path tokens"; fi
# package.json valid JSON
expect_ok "package.json is valid JSON" node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$APP/package.json"
assert_grep "$APP/src/$PKG/backend/app.py" "AKM_OPENAPI_BUILD" "app.py honors AKM_OPENAPI_BUILD"

if [ "${FAST:-0}" = "1" ]; then hdr "FAST mode: skipping dep-install / build / components / deploy blocks"; else

# ---------------------------------------------------------------------------
hdr "install deps (uv sync + npm install)"
in_app "uv sync" uv sync
in_app "npm install" npm install

# ---------------------------------------------------------------------------
hdr "build (openapi -> codegen -> vite)"
in_app "akm build" "$BIN" build
assert_file "$APP/openapi.json"
assert_file "$APP/ui/api/schema.ts"
assert_file "$APP/dist/index.html"
# build-mode import must be side-effect-light: openapi.json holds real paths
assert_grep "$APP/openapi.json" '"paths"' "openapi.json has paths"
in_app "akm build --skip-codegen (rebuild dist only)" "$BIN" build --skip-codegen

# ---------------------------------------------------------------------------
hdr "frontend"
in_app "frontend typecheck" "$BIN" frontend typecheck
in_app "frontend build (vite only)" "$BIN" frontend build
in_app "frontend add clsx --dev" "$BIN" frontend add clsx --dev
assert_grep "$APP/package.json" '"clsx"' "clsx in package.json"
# the dev-failure fix: no `dev` script => nonzero exit (not silent success)
node -e 'const f=process.argv[1],p=require(f);delete p.scripts.dev;require("fs").writeFileSync(f,JSON.stringify(p,null,2))' "$APP/package.json"
( cd "$APP" && "$BIN" frontend dev >/dev/null 2>&1 ); rc=$?
if [ "$rc" -ne 0 ]; then ok "frontend dev surfaces failure (rc=$rc)"; else bad "frontend dev surfaces failure" "got rc=0 on missing dev script"; fi
# restore dev script for later
node -e 'const f=process.argv[1],p=require(f);p.scripts.dev="vite";require("fs").writeFileSync(f,JSON.stringify(p,null,2))' "$APP/package.json"

# ---------------------------------------------------------------------------
hdr "components (shadcn over HTTPS)"
in_app "components init" "$BIN" components init
assert_file "$APP/components.json"
assert_file "$APP/ui/lib/utils.ts"
assert_file "$APP/ui/globals.css"
in_app "components init (idempotent re-run)" "$BIN" components init
in_app "components add button card" "$BIN" components add button card
assert_file "$APP/ui/components/ui/button.tsx"
assert_file "$APP/ui/components/ui/card.tsx"
in_app "vite build resolves @/ after components" "$BIN" build --skip-codegen

# ---------------------------------------------------------------------------
hdr "deploy (--dry-run, no Docker)"
in_app "deploy --dry-run --skip-build" "$BIN" deploy --dry-run --skip-build
in_app "deploy --dry-run --env staging --skip-build" "$BIN" deploy --dry-run --env staging --skip-build

fi  # end non-FAST

# ---------------------------------------------------------------------------
hdr "negative / arg-validation paths"
expect_fail_in "$APP"  "frontend (no subcommand)"        "$BIN" frontend
expect_fail_in "$APP"  "frontend bogus (unknown subcmd)" "$BIN" frontend bogus
expect_fail_in "$APP"  "frontend add (no packages)"      "$BIN" frontend add --dev
expect_fail_in "$WORK" "frontend build (not in project)" "$BIN" frontend build
expect_fail_in "$WORK" "build (not in project)"          "$BIN" build
expect_fail_in "$WORK" "deploy (not in project)"         "$BIN" deploy --dry-run
expect_fail_in "$APP"  "preview create (no --pr)"        "$BIN" preview create
expect_fail "unknown top-level command"                  "$BIN" frobnicate
expect_ok   "akm help"                        "$BIN" help
expect_ok   "akm version"                     "$BIN" version
# logs prints the §5 caveat before attempting wrangler (assert the caveat text)
logs_out="$(cd "$APP" && timeout 20 "$BIN" logs 2>&1)";
if printf '%s' "$logs_out" | grep -q "Observability"; then ok "logs prints §5 container-log caveat"; else bad "logs prints §5 caveat" "caveat text not found"; fi

# ---------------------------------------------------------------------------
hdr "preview dry-run must NOT mutate Neon (B1 regression, opt-in)"
if [ "${RUN_NEON:-0}" = "1" ] && [ -n "${NEON_PROJECT_ID:-}" ]; then
  PRID="e2e$$"; BR="akm-pr-$PRID"
  in_app "preview create --dry-run runs" "$BIN" preview create --pr "$PRID" --neon-project "$NEON_PROJECT_ID" --dry-run
  if neonctl branches list --project-id "$NEON_PROJECT_ID" --output json 2>/dev/null | grep -q "\"name\": \"$BR\""; then
    bad "dry-run created NO Neon branch" "branch $BR exists — dry-run mutated Neon!"
    neonctl branches delete "$BR" --project-id "$NEON_PROJECT_ID" 2>/dev/null || true
  else ok "dry-run created NO Neon branch ($BR absent)"; fi
  in_app "preview destroy --dry-run runs (no delete)" "$BIN" preview destroy --pr "$PRID" --neon-project "$NEON_PROJECT_ID" --dry-run
else
  skip "live preview (set RUN_NEON=1 NEON_PROJECT_ID=<id>)"
fi

# ---------------------------------------------------------------------------
hdr "summary"
printf "  %b%d passed%b, " "$c_g" "$PASS" "$c_0"
if [ "$FAIL" -eq 0 ]; then printf "%b0 failed%b\n" "$c_g" "$c_0"; exit 0; fi
printf "%b%d failed%b\n" "$c_r" "$FAIL" "$c_0"
for n in "${FAILED_NAMES[@]}"; do printf "    ${c_r}- %s${c_0}\n" "$n"; done
exit 1
