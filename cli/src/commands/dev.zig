//! `akm dev` — the local dev loop orchestrator (goal.md §2 / §4 / §4.5).
//!
//! Brings up, on one origin, the full app for local development:
//!   - uvicorn running the generated FastAPI backend (`--reload`),
//!   - the Vite dev server for the React UI,
//!   - the akm reverse proxy (proxy.zig) that fronts both and mints the internal
//!     `X-Akm-Identity` assertion on `/api/*` — identical to the prod Worker.
//!
//! Optionally (`--neon-branch`) it creates an ephemeral Neon dev branch on start
//! and deletes it on exit, so the loop runs against an isolated database.
//!
//! Shutdown: SIGINT/SIGTERM set an atomic; a watcher thread wakes the proxy's
//! blocked accept with a self-connect; we then SIGTERM each child's *process
//! group* (uvicorn `--reload` and npm spawn grandchildren) and delete the branch.

const std = @import("std");
const main = @import("../main.zig");
const project = @import("../project.zig");
const proxy = @import("../proxy.zig");
const jwt = @import("../jwt.zig");
const neon = @import("../neon.zig");

const say = main.say;
const Environ = std.process.Environ;
const net = std.Io.net;

/// Set by the signal handler; read by the watcher and the proxy accept loop.
var should_stop = std.atomic.Value(bool).init(false);

const Options = struct {
    dir: []const u8 = ".",
    proxy_port: u16 = 8787,
    backend_port: u16 = 8000,
    vite_port: u16 = 5173,
    dev_user: []const u8 = "dev@akm.local",
    neon_branch: bool = false,
    neon_project: ?[]const u8 = null,
};

pub fn run(gpa: std.mem.Allocator, args: []const []const u8) !void {
    const io = main.io;
    const opts = parseArgs(args) catch |err| {
        say("Usage: akm dev [dir] [--port N] [--backend-port N] [--vite-port N]\n" ++
            "               [--dev-user EMAIL] [--neon-branch] [--neon-project ID]\n");
        return err;
    };

    // ── locate & validate the project ────────────────────────────────────
    var proj = try project.openProject(io, opts.dir);
    defer proj.close(io);
    const pkg = try project.discoverPkg(gpa, io, proj);
    defer gpa.free(pkg);
    say2("akm dev: backend package = ", pkg);
    say("\n");

    // ── build the child environment (parent env + .dev.vars + overrides) ──
    var env = try project.baseChildEnv(gpa);
    defer env.deinit();
    loadDevVars(gpa, io, proj, &env) catch |err| switch (err) {
        error.FileNotFound => say("akm dev: no .dev.vars found — DB endpoints unset " ++
            "(copy .dev.vars.example to configure Neon/Postgres).\n"),
        else => return err,
    };

    // Install signal handlers BEFORE any cloud mutation (Neon branch) or child
    // spawn. The handler only sets `should_stop`; default disposition would kill
    // the process without running the teardown defers below (orphaning the
    // branch / children). After each mutation we re-check `should_stop` and
    // return through the defers if interrupted.
    installSignalHandlers();

    // ── optional ephemeral Neon branch ───────────────────────────────────
    var branch: ?neon.Branch = null;
    var neon_pid: ?[]u8 = null; // owned; kept alive for the teardown defer
    defer {
        if (branch) |*b| {
            if (neon_pid) |pid| {
                neon.delete(gpa, io, pid, b.id);
                say2("akm dev: deleted Neon branch ", b.id);
                say("\n");
            }
            b.deinit();
        }
        if (neon_pid) |pid| gpa.free(pid);
    }
    if (opts.neon_branch and !should_stop.load(.acquire)) {
        const project_id = opts.neon_project orelse env.get("NEON_PROJECT_ID") orelse {
            say("akm dev: --neon-branch needs --neon-project ID (or NEON_PROJECT_ID).\n");
            return error.MissingNeonProject;
        };
        neon_pid = try gpa.dupe(u8, project_id);
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "akm-dev-{d}", .{std.Io.Clock.now(.real, io).toSeconds()}) catch "akm-dev";
        say2("akm dev: creating Neon branch ", name);
        say(" …\n");
        branch = neon.create(gpa, io, neon_pid.?, name) catch |err| {
            say2("akm dev: Neon branch failed: ", @errorName(err));
            say(" (check neonctl auth / --neon-project)\n");
            return err;
        };
        try env.put("DATABASE_URL", branch.?.pooled_url);
        try env.put("DATABASE_URL_DIRECT", branch.?.direct_url);
        // Bring the fresh branch up to head (best-effort: a brand-new branch may
        // have no revisions yet, which is not an error worth aborting for).
        migrate(gpa, io, opts.dir, &env);
    }
    // Interrupted during branch creation/migration → return through the defer
    // above, which deletes the branch (no orphan).
    if (should_stop.load(.acquire)) return;

    // ── ensure a signing key shared by minter and backend ─────────────────
    const jwt_key = blk: {
        if (env.get("AKM_INTERNAL_JWT_KEY")) |k| if (k.len > 0) break :blk k;
        // No key configured: generate an ephemeral one and hand it to the backend.
        // Dev-only and process-local, so a clock+stack-seeded CSPRNG is sufficient.
        const hex = std.fmt.bytesToHex(devRandomBytes(io), .lower);
        try env.put("AKM_INTERNAL_JWT_KEY", &hex);
        say("akm dev: generated an ephemeral AKM_INTERNAL_JWT_KEY for this session.\n");
        break :blk env.get("AKM_INTERNAL_JWT_KEY").?;
    };
    // The proxy runs detached handler threads that may briefly outlive this
    // function (bounded drain in proxy.run) and read cfg.minter.key. The slice
    // above borrows from `env`, which `defer env.deinit()` frees on unwind — so
    // copy the key into process-lifetime memory (page_allocator, never freed;
    // reclaimed at exit) to rule out any use-after-free on shutdown.
    const jwt_key_owned = try std.heap.page_allocator.dupe(u8, jwt_key);

    // Mark this as a dev run so the backend may start without a database
    // (`akm dev` without --neon-branch / a DATABASE_URL in .dev.vars). In
    // production this marker is absent, so a missing DATABASE_URL fails fast.
    try env.put("AKM_DEV", "1");

    // ── spawn the backend (uvicorn) and the UI (Vite) ─────────────────────
    var bp_buf: [8]u8 = undefined;
    var vp_buf: [8]u8 = undefined;
    const bp = try std.fmt.bufPrint(&bp_buf, "{d}", .{opts.backend_port});
    const vp = try std.fmt.bufPrint(&vp_buf, "{d}", .{opts.vite_port});
    const app_target = try std.fmt.allocPrint(gpa, "{s}.backend.app:app", .{pkg});
    defer gpa.free(app_target);

    const backend_argv = [_][]const u8{
        "uv",         "run",         "uvicorn", app_target,
        "--host",     "127.0.0.1",   "--port",  bp,
        "--reload",   "--reload-dir", "src",
    };
    const vite_argv = [_][]const u8{ "npm", "run", "dev", "--", "--port", vp, "--strictPort" };

    // (Signal handlers were installed above, before the Neon branch / spawn.)
    var backend = spawnChild(io, opts.dir, &env, &backend_argv) catch |err| {
        say2("akm dev: failed to start uvicorn (is `uv` installed?): ", @errorName(err));
        say("\n");
        return err;
    };
    var vite = spawnChild(io, opts.dir, &env, &vite_argv) catch |err| {
        say2("akm dev: failed to start Vite (is `npm` installed + `npm install` run?): ", @errorName(err));
        say("\n");
        killChild(io, &backend);
        return err;
    };
    defer shutdownChildren(io, &backend, &vite);

    // ── watcher, then run the proxy (blocks) ──────────────────────────────
    // (signal handlers were installed before the children spawned, above)
    const watch = try std.Thread.spawn(.{}, watcher, .{ io, opts.proxy_port });

    printBanner(opts, pkg);
    const cfg = proxy.Config{
        .proxy_port = opts.proxy_port,
        .backend_port = opts.backend_port,
        .vite_port = opts.vite_port,
        .minter = .{ .key = jwt_key_owned },
        .dev_user = opts.dev_user,
    };
    proxy.run(io, cfg, &should_stop) catch |err| {
        should_stop.store(true, .release); // ensure the watcher exits
        watch.join();
        return err;
    };
    should_stop.store(true, .release);
    watch.join();
    say("\nakm dev: shutting down …\n");
}

// ── child process helpers ───────────────────────────────────────────────────

fn spawnChild(
    io: std.Io,
    dir: []const u8,
    env: *const Environ.Map,
    argv: []const []const u8,
) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = dir },
        .environ_map = env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .pgid = 0, // new process group so we can signal the whole tree
    });
}

/// Grace period between SIGTERM and SIGKILL during shutdown.
const shutdown_grace_ms = 800;

/// Signal a child's whole process group (negative pid catches uvicorn's reloader
/// + worker and npm's vite child), falling back to the bare pid.
fn signalGroup(pid: std.posix.pid_t, sig: std.posix.SIG) void {
    std.posix.kill(-pid, sig) catch {
        std.posix.kill(pid, sig) catch {};
    };
}

/// Terminate a single child and its group, then reap it (used on the spawn-error
/// path before the proxy starts).
fn killChild(io: std.Io, child: *std.process.Child) void {
    if (child.id) |pid| {
        signalGroup(pid, .TERM);
        io.sleep(std.Io.Duration.fromMilliseconds(shutdown_grace_ms), .awake) catch {};
        signalGroup(pid, .KILL);
        _ = child.wait(io) catch {};
    }
}

/// Stop both children: SIGTERM both, one shared grace period, then SIGKILL any
/// stragglers (uvicorn's `--reload` supervisor can be slow) and reap. Bounded so
/// Ctrl-C returns promptly even if a child ignores SIGTERM.
fn shutdownChildren(io: std.Io, backend: *std.process.Child, vite: *std.process.Child) void {
    if (backend.id) |p| signalGroup(p, .TERM);
    if (vite.id) |p| signalGroup(p, .TERM);
    io.sleep(std.Io.Duration.fromMilliseconds(shutdown_grace_ms), .awake) catch {};
    if (backend.id) |p| signalGroup(p, .KILL);
    if (vite.id) |p| signalGroup(p, .KILL);
    if (backend.id != null) _ = backend.wait(io) catch {};
    if (vite.id != null) _ = vite.wait(io) catch {};
}

/// 32 random bytes for the ephemeral dev signing key, from the OS CSPRNG
/// (`io.random`, seeded by OS entropy). Dev-only and process-local.
fn devRandomBytes(io: std.Io) [32]u8 {
    var out: [32]u8 = undefined;
    io.random(&out);
    return out;
}

// ── environment ─────────────────────────────────────────────────────────────

/// Load `.dev.vars` (`KEY=value` / `KEY="value"`, `#` comments) into `env`.
fn loadDevVars(gpa: std.mem.Allocator, io: std.Io, proj: std.Io.Dir, env: *Environ.Map) !void {
    const bytes = try proj.readFileAlloc(io, ".dev.vars", gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    const vars = try project.parseVars(gpa, bytes);
    defer gpa.free(vars);
    for (vars) |v| try env.put(v.key, v.value);
}

/// `uv run alembic upgrade head` over the direct endpoint. Best-effort.
fn migrate(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, env: *const Environ.Map) void {
    const argv = [_][]const u8{ "uv", "run", "alembic", "upgrade", "head" };
    const res = std.process.run(gpa, io, .{
        .argv = &argv,
        .cwd = .{ .path = dir },
        .environ_map = env,
    }) catch |err| {
        say2("akm dev: alembic skipped (", @errorName(err));
        say(")\n");
        return;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (res.term == .exited and res.term.exited == 0) {
        say("akm dev: alembic upgrade head ok\n");
    } else {
        // Best-effort (a brand-new branch may have no revisions yet), but surface
        // the actual stderr so a genuinely broken migration isn't opaque.
        say("akm dev: alembic upgrade head reported issues (continuing):\n");
        const e = std.mem.trim(u8, res.stderr, " \t\r\n");
        if (e.len > 0) {
            say(e);
            say("\n");
        }
    }
}

// ── signals & shutdown wakeup ───────────────────────────────────────────────

fn handleSignal(_: std.posix.SIG) callconv(.c) void {
    should_stop.store(true, .release);
}

fn installSignalHandlers() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

/// Poll the stop flag; once set, wake the proxy's blocked `accept` with a
/// throwaway local connection. Retries the connect: a single failed self-connect
/// must not leave `accept` blocked forever (that would deadlock shutdown).
fn watcher(io: std.Io, proxy_port: u16) void {
    while (!should_stop.load(.acquire)) {
        io.sleep(std.Io.Duration.fromMilliseconds(200), .awake) catch {};
    }
    const addr = net.IpAddress.parse("127.0.0.1", proxy_port) catch return;
    var attempt: usize = 0;
    while (attempt < 50) : (attempt += 1) {
        if (addr.connect(io, .{ .mode = .stream })) |s| {
            s.close(io);
            return; // accept woke; it will observe should_stop and break
        } else |_| {
            io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};
        }
    }
    std.log.warn("akm dev: could not wake the proxy accept loop to shut down", .{});
}

// ── arg parsing & banner ─────────────────────────────────────────────────────

fn parseArgs(args: []const []const u8) !Options {
    var o = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--neon-branch")) {
            o.neon_branch = true;
        } else if (eatValue(args, &i, arg, "--port")) |v| {
            o.proxy_port = std.fmt.parseInt(u16, v, 10) catch return error.BadPort;
        } else if (eatValue(args, &i, arg, "--backend-port")) |v| {
            o.backend_port = std.fmt.parseInt(u16, v, 10) catch return error.BadPort;
        } else if (eatValue(args, &i, arg, "--vite-port")) |v| {
            o.vite_port = std.fmt.parseInt(u16, v, 10) catch return error.BadPort;
        } else if (eatValue(args, &i, arg, "--dev-user")) |v| {
            o.dev_user = v;
        } else if (eatValue(args, &i, arg, "--neon-project")) |v| {
            o.neon_project = v;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownFlag;
        } else {
            o.dir = arg; // positional: project dir
        }
    }
    return o;
}

/// If `arg == flag`, consume and return the next arg as its value.
fn eatValue(args: []const []const u8, i: *usize, arg: []const u8, flag: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, arg, flag)) return null;
    if (i.* + 1 >= args.len) return null;
    i.* += 1;
    return args[i.*];
}

fn printBanner(o: Options, pkg: []const u8) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf,
        \\
        \\  akm dev — http://localhost:{d}
        \\    /api/*  → uvicorn  :{d}   ({s}.backend.app:app, identity injected)
        \\    /*      → vite      :{d}
        \\    dev identity: {s}   ·   Ctrl-C to stop
        \\
        \\
    , .{ o.proxy_port, o.backend_port, pkg, o.vite_port, o.dev_user }) catch return;
    say(msg);
}

fn say2(a: []const u8, b: []const u8) void {
    say(a);
    say(b);
}

test {
    std.testing.refAllDecls(@This());
}

test "parseArgs defaults and overrides" {
    const a = try parseArgs(&.{});
    try std.testing.expectEqual(@as(u16, 8787), a.proxy_port);
    try std.testing.expectEqualStrings(".", a.dir);

    const b = try parseArgs(&.{ "myapp", "--port", "9000", "--neon-branch", "--dev-user", "x@y.z" });
    try std.testing.expectEqualStrings("myapp", b.dir);
    try std.testing.expectEqual(@as(u16, 9000), b.proxy_port);
    try std.testing.expect(b.neon_branch);
    try std.testing.expectEqualStrings("x@y.z", b.dev_user);

    try std.testing.expectError(error.UnknownFlag, parseArgs(&.{"--nope"}));
    try std.testing.expectError(error.BadPort, parseArgs(&.{ "--port", "abc" }));
}
