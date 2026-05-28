#!/usr/bin/env bash
#
# p0-deploy.sh — the akm P0 cloud spike, idempotently.
#
# Scaffolds (once) a generated app, installs deps, ensures a dedicated Neon spike
# branch, writes .prod.vars (once — preserving your edits + signing key), validates
# with `akm deploy --dry-run`, and — if Docker + wrangler login + Access config are
# ready — deploys for real. Safe to run repeatedly: every step is a no-op if already
# done, and nothing destructive happens without all prerequisites present.
#
# Usage:
#   scripts/p0-deploy.sh                 # full run (stops gracefully if not ready)
#   DRY_RUN_ONLY=1 scripts/p0-deploy.sh  # validate only, never deploy
#   FORCE_PRODVARS=1 scripts/p0-deploy.sh# regenerate .prod.vars from scratch
#
# Override any of these via the environment:
AKM_BIN="${AKM_BIN:-/Users/lf/Projects/akm/cli/zig-out/bin/akm}"
PROJECT_DIR="${PROJECT_DIR:-$HOME/akm-p0}"
APP_NAME="${APP_NAME:-Akm P0}"
NEON_PROJECT="${NEON_PROJECT:-sweet-forest-93715874}"
NEON_BRANCH="${NEON_BRANCH:-akm-p0}"
DRY_RUN_ONLY="${DRY_RUN_ONLY:-0}"
FORCE_PRODVARS="${FORCE_PRODVARS:-0}"
# Optional — if you already created the Cloudflare Access app, export these and
# they'll be baked into .prod.vars; otherwise placeholders are written.
CF_ACCESS_TEAM_DOMAIN="${CF_ACCESS_TEAM_DOMAIN:-}"
CF_ACCESS_AUD="${CF_ACCESS_AUD:-}"

set -euo pipefail

c_step=$'\033[1;36m'; c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_off=$'\033[0m'
step() { printf '\n%s== %s ==%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '%s✓ %s%s\n' "$c_ok" "$*" "$c_off"; }
warn() { printf '%s! %s%s\n' "$c_warn" "$*" "$c_off"; }
die()  { printf '%sERROR: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Rewrite a Neon postgres URL to the SQLAlchemy/psycopg driver form + ensure SSL.
to_psycopg() {
  local u="$1"
  u="${u/postgresql:\/\//postgresql+psycopg://}"
  u="${u/postgres:\/\//postgresql+psycopg://}"
  case "$u" in
    *sslmode=*) : ;;
    *\?*)       u="${u}&sslmode=require" ;;
    *)          u="${u}?sslmode=require" ;;
  esac
  printf '%s' "$u"
}

# ── 0. preflight (tools that every path needs) ──────────────────────────────
step "Preflight"
if [ ! -x "$AKM_BIN" ]; then
  have akm || die "akm not found at '$AKM_BIN' (build: cd cli && zig build), or set AKM_BIN"
  AKM_BIN="$(command -v akm)"
fi
for t in neonctl npm uv node python3 openssl; do have "$t" || die "missing required tool: $t"; done
ok "tools present; akm = $AKM_BIN"

# ── 1. scaffold (only if absent) ────────────────────────────────────────────
step "Scaffold project"
if [ ! -d "$PROJECT_DIR" ]; then
  "$AKM_BIN" init "$APP_NAME" "$PROJECT_DIR"
  ok "scaffolded $PROJECT_DIR"
else
  ok "project exists, reusing $PROJECT_DIR"
fi
cd "$PROJECT_DIR"

# ── 2. install deps (idempotent by nature) ──────────────────────────────────
step "Install dependencies"
uv sync >/dev/null && ok "uv sync"
npm install --silent >/dev/null && ok "npm install"

# ── DRY_RUN_ONLY short-circuit: validate WITHOUT touching the cloud ─────────
# `akm deploy --dry-run` only validates the wrangler config + bundle (no secrets,
# no DB), so a validate-only run must NOT create the Neon branch or write
# .prod.vars. Do that before the cloud-mutating sections below.
if [ "$DRY_RUN_ONLY" = 1 ]; then
  step "DRY_RUN_ONLY=1 — skipping Neon branch + .prod.vars (no cloud mutation)"
  "$AKM_BIN" deploy --dry-run
  ok "dry-run passed"
  step "Done (DRY_RUN_ONLY=1)"; exit 0
fi

# ── 3. ensure a dedicated Neon spike branch + fetch connection strings ──────
step "Neon branch '$NEON_BRANCH' on project $NEON_PROJECT"
# Pass the branch name as argv (NOT spliced into the source) — a name with a
# quote would otherwise inject arbitrary Python.
if neonctl branches list --project-id "$NEON_PROJECT" -o json \
   | python3 -c "import sys,json; t=sys.argv[1]; sys.exit(0 if any(b.get('name')==t for b in json.load(sys.stdin)) else 1)" "$NEON_BRANCH"; then
  ok "branch exists, reusing"
else
  neonctl branches create --project-id "$NEON_PROJECT" --name "$NEON_BRANCH" >/dev/null
  ok "branch created"
fi
POOLED_RAW="$(neonctl connection-string --project-id "$NEON_PROJECT" --branch "$NEON_BRANCH" --pooled | tr -d '[:space:]')"
DIRECT_RAW="$(neonctl connection-string --project-id "$NEON_PROJECT" --branch "$NEON_BRANCH"          | tr -d '[:space:]')"
[ -n "$POOLED_RAW" ] && [ -n "$DIRECT_RAW" ] || die "could not fetch Neon connection strings (neonctl auth expired? run: neonctl auth)"
POOLED="$(to_psycopg "$POOLED_RAW")"; DIRECT="$(to_psycopg "$DIRECT_RAW")"
ok "connection strings resolved (pooled + direct)"

# ── 4. .prod.vars (create once; preserve key + your Access edits) ───────────
step "Secrets file (.prod.vars)"
if [ -f .prod.vars ] && [ "$FORCE_PRODVARS" != 1 ]; then
  ok ".prod.vars exists, leaving it untouched (FORCE_PRODVARS=1 to regenerate)"
else
  KEY="$(openssl rand -hex 32)"
  umask 077
  cat > .prod.vars <<EOF
# akm P0 secrets — gitignored. Generated $(date -u +%FT%TZ).
AKM_INTERNAL_JWT_KEY="$KEY"
DATABASE_URL="$POOLED"
DATABASE_URL_DIRECT="$DIRECT"
CF_ACCESS_TEAM_DOMAIN="${CF_ACCESS_TEAM_DOMAIN:-CHANGEME-your-team}"
CF_ACCESS_AUD="${CF_ACCESS_AUD:-CHANGEME-access-app-aud-tag}"
EOF
  ok "wrote .prod.vars"
fi
# Always tighten the mode — `umask` only covers newly-created files, so a
# pre-existing .prod.vars (left untouched above, or from an older run) could
# otherwise stay world-readable with secrets in it.
chmod 600 .prod.vars
if grep -q CHANGEME .prod.vars 2>/dev/null; then
  warn "CF_ACCESS_* are placeholders — create the Cloudflare Access app/policy and fill them,"
  warn "  else the Worker rejects every /api/* request with 403 (goal.md §4.5)."
fi

# ── 5. validate (no account / Docker needed) ────────────────────────────────
# (DRY_RUN_ONLY already exited above, before any cloud mutation.)
step "Validate (akm deploy --dry-run)"
"$AKM_BIN" deploy --dry-run
ok "dry-run passed"

# ── 6. real-deploy preflight (stop gracefully, don't error, if not ready) ───
step "Real-deploy preflight"
not_ready=0
if ! docker info >/dev/null 2>&1; then warn "Docker not running — start Docker Desktop"; not_ready=1; fi
if ! ./node_modules/.bin/wrangler whoami >/dev/null 2>&1; then warn "wrangler not logged in — run: cd '$PROJECT_DIR' && npx wrangler login"; not_ready=1; fi
if grep -q CHANGEME .prod.vars 2>/dev/null; then warn "CF_ACCESS_* still placeholders — fill them in .prod.vars"; not_ready=1; fi
if [ "$not_ready" = 1 ]; then
  step "Prerequisites incomplete — fix the warnings above and re-run this script"
  warn "Everything up to deploy is done and idempotent; re-running resumes from here."
  exit 0
fi
ok "Docker up, wrangler logged in, Access configured"

# ── 7. deploy for real (idempotent: wrangler updates the existing Worker) ───
step "Deploy (akm deploy --secrets .prod.vars --migrate)"
"$AKM_BIN" deploy --secrets .prod.vars --migrate
ok "deploy finished"

step "Next: verify the spike"
cat <<'EOF'
  - Open the Worker URL in a browser → Access login → app should load.
  - curl needs a service token:  -H 'Cf-Access-Client-Id: …' -H 'Cf-Access-Client-Secret: …'
  - Container logs:  npx wrangler tail   (P0 question: does it stream container stdout?)
  - Measure cold start: first request after the container has slept.
EOF
