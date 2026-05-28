# akm — Adversarial Codex 5.5 audit (round 1)

Three parallel `codex exec` audits (gpt-5.5, xhigh reasoning, read-only sandbox):
auth chain, Zig core, command/template/script layer. Triaged below; **FIX** =
real, will address. Auth fundamentals verdict was SHIP (no signature bypass, no
alg confusion, header stripping clean) — findings are defense-in-depth.

## BLOCKER
- **B1 `--dry-run` mutates Neon** — `preview create --dry-run` calls `neon.ensure` (creates a real branch) before the dry-run check; `preview destroy --dry-run` calls `neon.delete` unconditionally (deletes a real branch); `DRY_RUN_ONLY=1 p0-deploy.sh` still creates the branch. **FIX** — gate all Neon create/delete behind `!dry_run`; dry-run prints intent only. (preview.zig:78/128, p0-deploy.sh)

## MAJOR — correctness / security (FIX)
- **M1 proxy duplicate Content-Length** (proxy.zig parseRequestHead) — last-wins CL with all headers forwarded → CL/CL request-smuggling differential. Reject conflicting duplicate CL.
- **M2 proxy tunnels failed WS upgrades** (proxy.zig ~273) — tunnels on `status==101 OR is_upgrade`; a non-101 upstream response to an Upgrade request is tunneled raw + skips `Connection: close` → hang. Tunnel only on `status==101`.
- **M3 neon pooled-URL string replace** (neon.zig parseCreate ~178) — replaces every occurrence of `host` in the URL → corrupts credentials/dbname/query if `host` appears there; `toPsycopgUrl` passes unknown schemes. Replace only the authority host; validate scheme.
- **M4 identity.py JWT lifetime unbounded** (identity.py:76) — verifier requires `exp` but accepts any far-future `exp`, missing `iat`. Trust boundary should enforce the ≤120s replay window itself. Require numeric `iat`/`exp`, bound `exp-iat`.
- **M5 dev signal-handler race** (dev.zig) — children spawned before SIGINT/SIGTERM handler installed → Ctrl-C in that window orphans uvicorn/Vite. Install handler before spawning.
- **M6 discoverPkg accepts non-identifier names** (project.zig:42) — also flows into `build`'s `python -c "from {pkg}…"` → injection + late failures. Validate as a Python identifier (match init's sanitizer).
- **M7 p0-deploy.sh Python injection** (scripts/p0-deploy.sh:77) — `NEON_BRANCH` spliced into `python3 -c` source. Pass via argv.
- **M8 components npm flag injection** (components.zig) — registry dep strings appended to `npm install`; a compromised registry could inject `--prefix` etc. Reject leading `-`; insert `--`.

## MAJOR — dev-only / localhost (mitigate + scope)
- **M9 proxy slowloris/thread-per-conn** (proxy.zig:70) — no read deadline / connection cap; localhost dev proxy only (attacker needs local code-exec), but add a bounded connection cap + cap chunk trailers.
- **M10 vite `allowedHosts: true`** (vite.config.ts.tmpl) — disables host allowlist (DNS-rebind on the dev server). Scope to localhost/proxy hosts.

## Resolution (round 1 fixes — all FIX items done)
B1 ✅ preview.zig gates Neon ensure/delete behind `!dry_run`; p0-deploy injection fixed.
M1 ✅ reject conflicting duplicate CL · M2 ✅ tunnel only on 101 · M3 ✅ neon swapHost (authority-host-only) + reject unknown scheme · M4 ✅ identity.py requires iat + bounds exp−iat ≤120+skew (verified 7/7) · M5 ✅ dev installs signal handler before spawning children · M6 ✅ discoverPkg validates Python identifier · M7 ✅ p0-deploy passes branch via argv · M8 ✅ components rejects non-package dep specs · M9 ✅ proxy concurrent-connection cap + trailer cap · M10 ✅ vite allowedHosts → localhost allowlist · N1 ✅ parseVars rejects NUL · N2 ✅ Dockerfile non-root USER · N3 ✅ min JWT key length.
N4 (proxy cfg lifetime on shutdown) — deferred: MINOR, tiny exit-only window, conflicts with the detached-handler design; not BLOCKER/MAJOR.
Tests: 53 unit (＋6) green; e2e 52/52; dev-smoke 10/10.

## MINOR (FIX cheap ones)
- **N1 `.dev.vars` NUL → panic** (project.zig parseVars) — invalid key/value bytes panic `Environ.Map.put`. Validate keys, reject NUL, error with line number.
- **N2 Dockerfile runs as root** — add a non-root `USER` before `CMD`.
- **N3 min JWT key length** — backend rejects only empty; require ≥32 bytes (defense-in-depth).
- **N4 proxy detached-handler cfg lifetime on shutdown** (proxy.zig:70) — tiny exit-window ownership issue; low priority.
