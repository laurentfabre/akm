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

## Round 2 (re-audit of the fixed code) — new findings, all fixed
- **R2-B1 (BLOCKER)** p0-deploy.sh `DRY_RUN_ONLY=1` still ensured a real Neon branch (round-1 fix was preview.zig only). ✅ early DRY_RUN_ONLY exit before any Neon/`.prod.vars` mutation.
- **R2-M1 (MAJOR, auth)** NaN/Infinity NumericDate bypass: `json.loads` accepts `NaN`; every comparison with NaN is False, so `iat:NaN`/`exp:NaN` slipped past expiry + the M4 window cap. ✅ `_loads_strict` (parse_constant rejects non-finite) + `_numeric_date` (isfinite, non-bool) + `nbf` now mandatory. Verified 7/7 (NaN/Infinity/missing-nbf rejected).
- **R2-M2 (MAJOR, regression from N3)** `.dev.vars.example` key was shorter than the new 32-char minimum → `cp … && akm dev` would 500. ✅ example key now ≥32 chars + a generate hint.
- **R2-m1 (MINOR)** proxy: only `chunked` TE was rejected with CL; `Transfer-Encoding: gzip`+CL slipped. ✅ reject ANY TE+CL.
- **R2-m2 (MINOR, = N4)** proxy detached handlers could outlive `cfg.minter.key` on shutdown. ✅ bounded (~1s) connection drain before `proxy.run` returns.
- **R2-m3 (MINOR, latent)** render `skipBlock` only tracked one block kind → cross-kind mis-nesting in a skipped branch went unreported. ✅ LIFO stack across all kinds.
Round-2 audit otherwise verified every round-1 fix present and correct. Tests: 54 unit green.

## Round 3 (re-audit) — auth SHIP/clean; core+cmds edge cases, all fixed
- **R3-1 (MAJOR)** proxy shutdown UAF not fully closed by the 1s drain (a withholding client outlasts it, then reads freed `cfg.minter.key`). ✅ key copied into process-lifetime memory (page_allocator, never freed) so handlers can't read freed bytes; drain kept as courtesy.
- **R3-2 (MAJOR)** proxy `Content-Length` via `parseInt` accepted `+5`/`-0` (parser differential). ✅ require `1*DIGIT` (`isAllDigits`) before parse.
- **R3-3 (MAJOR)** `--secrets FILE` read from cwd, not the project dir → wrong DB/secrets when `dir != "."`. ✅ deploy.zig + preview.zig read it via the project Dir (absolute paths still work).
- **R3-4 (MAJOR)** dev `--neon-branch`: signal handler installed after branch creation → Ctrl-C orphaned the branch. ✅ install handler before any cloud mutation + `should_stop` check after branch/migrate (returns through the delete defer).
- **R3-5 (MAJOR)** p0-deploy `FORCE_PRODVARS` rewrite kept an existing file's mode (umask only affects new files) → world-readable secrets. ✅ explicit `chmod 600`.
- **R3-6 (MINOR)** proxy head bounded by count, not bytes. ✅ aggregate 64KiB request-head cap.
Round-3 auth verdict: SHIP, fully clean. Tests after fixes: 54 unit green.

## Round 4 (re-audit) — auth SHIP/clean; remaining edge cases, all fixed
- **R4-1 (MAJOR)** `eatValue` swallowed a flag-looking value: `preview create --pr --dry-run` (empty `$PR` in CI) set `pr="--dry-run"`, left `dry_run=false`, and did a REAL deploy. ✅ all 4 `eatValue` copies reject a value starting with `-`.
- **R4-2 (MAJOR)** p0-deploy chmod only ran on the write path; a pre-existing 0644 `.prod.vars` stayed world-readable. ✅ `chmod 600` after the if/else (always).
- **R4-3 (MAJOR)** `parseVars` accepted duplicate keys → migrate (first) vs `secret bulk` (last-wins) could target different DBs. ✅ reject duplicate keys.
- **R4-4 (MAJOR/MINOR)** dev `--neon-branch` partial-create: an interrupt/parse-error after the remote branch was made left `branch=null` → no cleanup. ✅ best-effort delete-by-name in the create catch path.
- **R4-5 (MINOR)** components fetch followed redirects + unbounded body (SSRF/OOM). ✅ pin `https://ui.shadcn.com/`, `redirect_behavior=.not_allowed`, 2MiB cap.
- **R4-6 (MINOR)** proxy accepted non-chunked TE (e.g. `gzip`) → possible deadlock. ✅ reject any request TE that isn't `chunked`.
- **R4-7 (MINOR)** test scripts spliced `$APP`/`$WORK` into `bash -c`/`node -e`. ✅ pass paths via argv (`expect_fail_in`, `process.argv`, `bash -c '… "$1"' _ "$APP"`).
Round-4 auth verdict: SHIP, clean. Tests after fixes: 55 unit green.

## Round 5 (re-audit) — auth + cmds SHIP; 1 MAJOR + repeated MINORs, all fixed
- **R5-1 (MAJOR, regression from R4-4)** dev `--neon-branch` name `akm-dev-{seconds}` could collide between two same-second runs; the loser's create fails on conflict and the by-name cleanup then deletes the WINNER's live branch. ✅ collision-resistant name (`akm-dev-{seconds}-{random hex}`) → no clash + by-name delete only targets our own.
- **R5-2 (MINOR)** proxy TE used substring match (`xchunked`, `chunked, gzip` slipped). ✅ accept only an exact sole `chunked`; reject multiple TE headers.
- **R5-3 (MINOR)** components size cap was post-hoc. ✅ stream into a fixed pre-capped 2MiB buffer (overflow → fetch error).
- **R5-4 (MINOR)** p0-deploy rewrite had a brief mode window. ✅ mktemp (0600) + atomic mv.
Round-5 verdict: auth SHIP, cmds SHIP, core SHIP-with-fixes (no BLOCKER). Tests after fixes: 55 unit / 52 e2e / 10 dev-smoke.

## MINOR (FIX cheap ones)
- **N1 `.dev.vars` NUL → panic** (project.zig parseVars) — invalid key/value bytes panic `Environ.Map.put`. Validate keys, reject NUL, error with line number.
- **N2 Dockerfile runs as root** — add a non-root `USER` before `CMD`.
- **N3 min JWT key length** — backend rejects only empty; require ≥32 bytes (defense-in-depth).
- **N4 proxy detached-handler cfg lifetime on shutdown** (proxy.zig:70) — tiny exit-window ownership issue; low priority.
