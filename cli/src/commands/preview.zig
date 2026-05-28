//! `akm preview` — per-PR preview environments (goal.md §5/§6).
//!
//! A preview = an isolated Worker deployment **paired with a per-PR Neon branch**.
//! Container/DO Workers don't get native Wrangler preview URLs (§5), so each PR
//! gets a named Worker `{base}-pr-{id}` (deployed with `wrangler deploy --name`)
//! and a Neon branch `akm-pr-{id}`, torn down on `destroy`.
//!
//! akm provides `create`/`destroy` primitives for CI to call on PR open/close;
//! it embeds no git/webhook logic.
//!
//! The Neon-branch lifecycle is real and verified. The Cloudflare half is
//! write-now-verify-later (P0 cloud spike deferred): whether `--name` deploy /
//! secret / delete behaves for a DO/Container Worker is the open spike question,
//! surfaced here rather than hidden. `--dry-run` exercises everything but the
//! account-dependent wrangler calls.

const std = @import("std");
const main = @import("../main.zig");
const project = @import("../project.zig");
const build = @import("build.zig");
const neon = @import("../neon.zig");

const say = main.say;

const Options = struct {
    action: enum { create, destroy },
    pr: []const u8,
    dir: []const u8 = ".",
    neon_project: ?[]const u8 = null,
    secrets_file: ?[]const u8 = null,
    dry_run: bool = false,
    skip_build: bool = false,
};

pub fn run(gpa: std.mem.Allocator, args: []const []const u8) !void {
    const io = main.io;
    const opts = parseArgs(args) catch {
        usage();
        return error.BadArgs;
    };

    var proj = try project.openProject(io, opts.dir);
    defer proj.close(io);

    const base = try readWorkerName(gpa, io, proj);
    defer gpa.free(base);
    const worker = try std.fmt.allocPrint(gpa, "{s}-pr-{s}", .{ base, opts.pr });
    defer gpa.free(worker);
    const branch = try std.fmt.allocPrint(gpa, "akm-pr-{s}", .{opts.pr});
    defer gpa.free(branch);

    const neon_project = opts.neon_project orelse main.environ_map.get("NEON_PROJECT_ID") orelse {
        say("akm preview: needs --neon-project ID (or NEON_PROJECT_ID).\n");
        return error.MissingNeonProject;
    };

    switch (opts.action) {
        .create => try create(gpa, io, proj, opts, worker, branch, neon_project),
        .destroy => try destroy(gpa, io, opts, worker, branch, neon_project),
    }
}

fn create(
    gpa: std.mem.Allocator,
    io: std.Io,
    proj: std.Io.Dir,
    opts: Options,
    worker: []const u8,
    branch: []const u8,
    neon_project: []const u8,
) !void {
    say2("akm preview: creating preview for PR #", opts.pr);
    say("\n");

    // 1. Per-PR Neon branch (real, idempotent).
    say2("akm preview: ensuring Neon branch ", branch);
    say(" …\n");
    var br = try neon.ensure(gpa, io, neon_project, branch);
    defer br.deinit();

    // 2. Build artifacts.
    const pkg = try project.discoverPkg(gpa, io, proj);
    defer gpa.free(pkg);
    if (!opts.skip_build) try build.buildArtifacts(gpa, io, proj, opts.dir, pkg, false);

    // 3. Secrets = base file (AKM key + CF_ACCESS) + the PR branch's DB URLs.
    if (opts.dry_run) {
        say("akm preview: --dry-run, skipping secret upload\n");
    } else {
        try pushSecrets(gpa, io, opts, worker, br);
    }

    // 4. Deploy the named per-PR Worker.
    try wrangler(gpa, io, opts.dir, &.{ "deploy", "--name", worker }, opts.dry_run);

    say2("\nakm preview: PR #", opts.pr);
    say2(" → Worker ", worker);
    say2(", Neon branch ", branch);
    say("\n");
    if (opts.dry_run) {
        say("akm preview: dry-run OK (Neon branch made; wrangler deploy validated, not shipped).\n");
    } else {
        say2("akm preview: live at https://", worker);
        say(".<your-subdomain>.workers.dev (behind Cloudflare Access)\n");
    }
}

fn destroy(
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    worker: []const u8,
    branch: []const u8,
    neon_project: []const u8,
) !void {
    say2("akm preview: destroying preview for PR #", opts.pr);
    say("\n");
    if (opts.dry_run) {
        say2("akm preview: --dry-run, would `wrangler delete --name ", worker);
        say("`\n");
    } else {
        // Best-effort: tear down the Worker, then the branch, regardless of order outcome.
        wrangler(gpa, io, opts.dir, &.{ "delete", "--name", worker }, false) catch
            say("akm preview: wrangler delete failed (already gone?) — continuing\n");
    }
    say2("akm preview: deleting Neon branch ", branch);
    say(" …\n");
    neon.delete(gpa, io, neon_project, branch);
    say("akm preview: done.\n");
}

/// Upload base secrets + the PR branch DB URLs via `wrangler secret bulk --name`.
fn pushSecrets(gpa: std.mem.Allocator, io: std.Io, opts: Options, worker: []const u8, br: neon.Branch) !void {
    var bytes: ?[]u8 = null;
    defer if (bytes) |b| gpa.free(b);
    var vars: []project.Var = &.{};
    defer if (vars.len > 0) gpa.free(vars);
    if (opts.secrets_file) |sf| {
        bytes = std.Io.Dir.cwd().readFileAlloc(io, sf, gpa, .limited(1 << 20)) catch {
            say2("akm preview: cannot read secrets file '", sf);
            say("'\n");
            return error.SecretsFile;
        };
        vars = try project.parseVars(gpa, bytes.?);
    }

    var json: std.Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    try json.writer.writeByte('{');
    var first = true;
    for (vars) |v| {
        // The PR branch owns the DB URLs; ignore any DB entries in the base file.
        if (std.mem.eql(u8, v.key, "DATABASE_URL") or std.mem.eql(u8, v.key, "DATABASE_URL_DIRECT")) continue;
        try writePair(&json.writer, &first, v.key, v.value);
    }
    try writePair(&json.writer, &first, "DATABASE_URL", br.pooled_url);
    try writePair(&json.writer, &first, "DATABASE_URL_DIRECT", br.direct_url);
    try json.writer.writeByte('}');

    say("akm preview: uploading secrets (wrangler secret bulk) …\n");
    var child = std.process.spawn(io, .{
        .argv = &.{ "npx", "wrangler", "secret", "bulk", "--name", worker },
        .cwd = .{ .path = opts.dir },
        .stdin = .pipe,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        say2("akm preview: cannot run wrangler: ", @errorName(err));
        say("\n");
        return err;
    };
    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(io, json.written()) catch {};
        stdin.close(io);
        child.stdin = null;
    }
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.SecretsFailed;
}

fn wrangler(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, sub: []const []const u8, dry_run: bool) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "npx", "wrangler" });
    try argv.appendSlice(gpa, sub);
    if (dry_run) try argv.appendSlice(gpa, &.{ "--dry-run", "--containers-rollout=none" });

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .path = dir },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        say2("akm preview: cannot run wrangler (is `npm install` done?): ", @errorName(err));
        say("\n");
        return err;
    };
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.WranglerFailed;
}

/// Read the top-level `"name"` from wrangler.jsonc (tolerant of // comments).
fn readWorkerName(gpa: std.mem.Allocator, io: std.Io, proj: std.Io.Dir) ![]u8 {
    const bytes = proj.readFileAlloc(io, "wrangler.jsonc", gpa, .limited(1 << 20)) catch {
        say("akm preview: cannot read wrangler.jsonc\n");
        return error.NoProject;
    };
    defer gpa.free(bytes);
    // Find the first `"name"` key and read its string value — robust to JSONC comments.
    const key = std.mem.indexOf(u8, bytes, "\"name\"") orelse {
        say("akm preview: no \"name\" in wrangler.jsonc\n");
        return error.NoProject;
    };
    const colon = std.mem.indexOfScalarPos(u8, bytes, key, ':') orelse return error.NoProject;
    const q1 = std.mem.indexOfScalarPos(u8, bytes, colon, '"') orelse return error.NoProject;
    const q2 = std.mem.indexOfScalarPos(u8, bytes, q1 + 1, '"') orelse return error.NoProject;
    return gpa.dupe(u8, bytes[q1 + 1 .. q2]);
}

fn writePair(w: *std.Io.Writer, first: *bool, key: []const u8, value: []const u8) !void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try writeJsonString(w, key);
    try w.writeByte(':');
    try writeJsonString(w, value);
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn parseArgs(args: []const []const u8) !Options {
    if (args.len == 0) return error.BadArgs;
    const action: @FieldType(Options, "action") = if (std.mem.eql(u8, args[0], "create"))
        .create
    else if (std.mem.eql(u8, args[0], "destroy"))
        .destroy
    else
        return error.BadArgs;

    var pr: ?[]const u8 = null;
    var o = Options{ .action = action, .pr = "" };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            o.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--skip-build")) {
            o.skip_build = true;
        } else if (eatValue(args, &i, arg, "--pr")) |v| {
            pr = v;
        } else if (eatValue(args, &i, arg, "--neon-project")) |v| {
            o.neon_project = v;
        } else if (eatValue(args, &i, arg, "--secrets")) |v| {
            o.secrets_file = v;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownFlag;
        } else {
            o.dir = arg;
        }
    }
    o.pr = pr orelse return error.MissingPr;
    return o;
}

fn eatValue(args: []const []const u8, i: *usize, arg: []const u8, flag: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, arg, flag)) return null;
    if (i.* + 1 >= args.len) return null;
    i.* += 1;
    return args[i.*];
}

fn usage() void {
    say(
        \\Usage:
        \\  akm preview create  --pr <id> [dir] [--neon-project ID] [--secrets FILE] [--dry-run] [--skip-build]
        \\  akm preview destroy --pr <id> [dir] [--neon-project ID] [--dry-run]
        \\
    );
}

fn say2(a: []const u8, b: []const u8) void {
    say(a);
    say(b);
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseArgs requires action + pr" {
    try testing.expectError(error.BadArgs, parseArgs(&.{}));
    try testing.expectError(error.BadArgs, parseArgs(&.{"nope"}));
    try testing.expectError(error.MissingPr, parseArgs(&.{"create"}));

    const a = try parseArgs(&.{ "create", "--pr", "123", "app", "--dry-run", "--neon-project", "p1" });
    try testing.expectEqual(@as(@TypeOf(a.action), .create), a.action);
    try testing.expectEqualStrings("123", a.pr);
    try testing.expectEqualStrings("app", a.dir);
    try testing.expect(a.dry_run);
    try testing.expectEqualStrings("p1", a.neon_project.?);

    const d = try parseArgs(&.{ "destroy", "--pr", "9" });
    try testing.expectEqual(@as(@TypeOf(d.action), .destroy), d.action);
    try testing.expectError(error.UnknownFlag, parseArgs(&.{ "create", "--pr", "1", "--bogus" }));
}

test {
    std.testing.refAllDecls(@This());
}
