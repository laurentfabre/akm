//! `akm build` — assemble the deployable artifacts (goal.md §4 #1, §5).
//!
//! For container mode this generates the two *derived* artifacts:
//!   1. the typed API client — import the FastAPI app under AKM_OPENAPI_BUILD=1,
//!      emit `openapi.json`, then run `openapi-typescript` → `ui/api/schema.ts`,
//!   2. the built UI in `dist/` (via `vite build`), served by the Worker as assets.
//!
//! The Dockerfile, Worker entry, Container DO class, and `wrangler.jsonc` are
//! static templates emitted by `init`; `build` only sanity-checks they exist.
//! No Docker is needed here — the image is built by `wrangler deploy`.

const std = @import("std");
const main = @import("../main.zig");
const project = @import("../project.zig");

const say = main.say;

const Options = struct {
    dir: []const u8 = ".",
    skip_codegen: bool = false,
};

pub fn run(gpa: std.mem.Allocator, args: []const []const u8) !void {
    const io = main.io;
    const opts = parseArgs(args) catch {
        say("Usage: akm build [dir] [--skip-codegen]\n");
        return error.BadArgs;
    };

    var proj = try project.openProject(io, opts.dir);
    defer proj.close(io);
    const pkg = try project.discoverPkg(gpa, io, proj);
    defer gpa.free(pkg);

    try buildArtifacts(gpa, io, proj, opts.dir, pkg, opts.skip_codegen);
    reportArtifacts(io, proj, opts.skip_codegen);
}

/// Run the artifact pipeline: emit openapi.json + typed client (unless skipped),
/// then `vite build` → `dist/`. Shared with `akm deploy`.
pub fn buildArtifacts(
    gpa: std.mem.Allocator,
    io: std.Io,
    proj: std.Io.Dir,
    dir: []const u8,
    pkg: []const u8,
    skip_codegen: bool,
) !void {
    if (!skip_codegen) {
        try emitOpenapi(gpa, io, dir, pkg);
        try proj.createDirPath(io, "ui/api"); // openapi-typescript won't make parents
        try runStep(io, dir, &.{ "npm", "run", "codegen" }, "openapi-typescript (typed client)");
    }
    try runStep(io, dir, &.{ "npm", "run", "build" }, "vite build (UI → dist/)");
}

/// Import the FastAPI app under the build-mode flag and write `openapi.json`.
/// The import must be side-effect-light (no DB/network) — `create_app` honors
/// AKM_OPENAPI_BUILD and skips the lifespan (goal.md §4 codegen contract).
fn emitOpenapi(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, pkg: []const u8) !void {
    say("akm build: generating openapi.json …\n");
    var env = try project.baseChildEnv(gpa);
    defer env.deinit();
    try env.put("AKM_OPENAPI_BUILD", "1");

    const script = try std.fmt.allocPrint(
        gpa,
        "import json\nfrom {s}.backend.app import app\nopen('openapi.json','w').write(json.dumps(app.openapi()))\n",
        .{pkg},
    );
    defer gpa.free(script);

    const argv = [_][]const u8{ "uv", "run", "python", "-c", script };
    const res = std.process.run(gpa, io, .{
        .argv = &argv,
        .cwd = .{ .path = dir },
        .environ_map = &env,
    }) catch |err| {
        say2("akm build: cannot run uv (is `uv` installed?): ", @errorName(err));
        say("\n");
        return err;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        say("akm build: openapi generation failed:\n");
        say(std.mem.trim(u8, res.stderr, " \t\r\n"));
        say("\n");
        return error.OpenApiFailed;
    }
}

/// Spawn a build step with inherited stdio (so the tool's own progress shows).
fn runStep(io: std.Io, dir: []const u8, argv: []const []const u8, label: []const u8) !void {
    say2("akm build: ", label);
    say(" …\n");
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = dir },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        say2("akm build: cannot spawn ", argv[0]);
        say2(": ", @errorName(err));
        say("\n");
        return err;
    };
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        say2("akm build: step failed: ", label);
        say(" (have you run `npm install`?)\n");
        return error.StepFailed;
    }
}

/// Print a checklist of the artifacts the deploy step will consume.
fn reportArtifacts(io: std.Io, proj: std.Io.Dir, skipped_codegen: bool) void {
    say("\nakm build: artifacts\n");
    if (!skipped_codegen) {
        check(io, proj, "openapi.json", true);
        check(io, proj, "ui/api/schema.ts", true);
    }
    check(io, proj, "dist/index.html", true);
    // Static artifacts produced by `init` — warn (don't fail) if missing.
    check(io, proj, "src/worker/index.ts", false);
    check(io, proj, "Dockerfile", false);
    check(io, proj, "wrangler.jsonc", false);
    say("\nReady for: akm deploy  (or `wrangler deploy`)\n");
}

fn check(io: std.Io, proj: std.Io.Dir, path: []const u8, generated: bool) void {
    if (proj.access(io, path, .{})) |_| {
        say2("  ✓ ", path);
        say("\n");
    } else |_| {
        say2(if (generated) "  ✗ missing (build did not produce): " else "  ! missing (run akm init?): ", path);
        say("\n");
    }
}

fn parseArgs(args: []const []const u8) !Options {
    var o = Options{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--skip-codegen")) {
            o.skip_codegen = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownFlag;
        } else {
            o.dir = arg;
        }
    }
    return o;
}

fn say2(a: []const u8, b: []const u8) void {
    say(a);
    say(b);
}

test {
    std.testing.refAllDecls(@This());
}

test "parseArgs" {
    try std.testing.expectEqualStrings(".", (try parseArgs(&.{})).dir);
    const a = try parseArgs(&.{ "myapp", "--skip-codegen" });
    try std.testing.expectEqualStrings("myapp", a.dir);
    try std.testing.expect(a.skip_codegen);
    try std.testing.expectError(error.UnknownFlag, parseArgs(&.{"--nope"}));
}
