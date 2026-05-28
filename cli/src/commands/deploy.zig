//! `akm deploy` — drive `wrangler deploy` for container mode (goal.md §5).
//!
//! Pipeline: build artifacts → (optional) run migrations → (optional) push
//! secrets → `wrangler deploy`. The DO + `new_sqlite_classes` migration already
//! lives in `wrangler.jsonc`, so wrangler applies it; akm does not manage it.
//!
//! A real deploy needs a Workers **Paid** plan + Docker (for the container image);
//! `--dry-run` validates `wrangler.jsonc` and bundles the Worker without either,
//! and is the path verified locally. The account-dependent steps (secret upload,
//! real deploy, prod migrate) are skipped under `--dry-run`.

const std = @import("std");
const main = @import("../main.zig");
const project = @import("../project.zig");
const build = @import("build.zig");

const say = main.say;

const Options = struct {
    dir: []const u8 = ".",
    dry_run: bool = false,
    skip_build: bool = false,
    migrate: bool = false,
    env_name: ?[]const u8 = null,
    secrets_file: ?[]const u8 = null,
};

pub fn run(gpa: std.mem.Allocator, args: []const []const u8) !void {
    const io = main.io;
    const opts = parseArgs(args) catch {
        say("Usage: akm deploy [dir] [--dry-run] [--env NAME] [--secrets FILE] [--migrate] [--skip-build]\n");
        return error.BadArgs;
    };

    var proj = try project.openProject(io, opts.dir);
    defer proj.close(io);
    const pkg = try project.discoverPkg(gpa, io, proj);
    defer gpa.free(pkg);

    // 1. Build artifacts (wrangler deploy needs dist/ + a current typed client).
    if (!opts.skip_build) try build.buildArtifacts(gpa, io, proj, opts.dir, pkg, false);

    // Load the secrets/vars file once (used by migrate + secret upload).
    var secrets_bytes: ?[]u8 = null;
    defer if (secrets_bytes) |b| gpa.free(b);
    var vars: []project.Var = &.{};
    defer if (vars.len > 0) gpa.free(vars);
    if (opts.secrets_file) |sf| {
        // Resolve --secrets against the PROJECT dir, not the caller's cwd, so
        // `akm deploy apps/foo --secrets .prod.vars` reads apps/foo/.prod.vars
        // (matching where everything else for this project runs). Absolute
        // paths still work (openat ignores the base dir for them).
        secrets_bytes = proj.readFileAlloc(io, sf, gpa, .limited(1 << 20)) catch {
            say2("akm deploy: cannot read secrets file (relative to the project dir) '", sf);
            say("'\n");
            return error.SecretsFile;
        };
        vars = try project.parseVars(gpa, secrets_bytes.?);
    }

    // 2. Migrate (opt-in; never implicit; skipped on dry-run).
    if (opts.migrate) {
        if (opts.dry_run) {
            say("akm deploy: --dry-run, skipping alembic migrate\n");
        } else {
            const direct = lookup(vars, "DATABASE_URL_DIRECT") orelse
                main.environ_map.get("DATABASE_URL_DIRECT") orelse
                {
                    say("akm deploy: --migrate needs DATABASE_URL_DIRECT (in --secrets file or env).\n");
                    return error.NoDirectUrl;
                };
            try migrate(gpa, io, opts.dir, direct);
        }
    }

    // 3. Push secrets atomically (skipped on dry-run).
    if (vars.len > 0) {
        if (opts.dry_run) {
            say("akm deploy: --dry-run, skipping secret upload\n");
        } else {
            try pushSecrets(gpa, io, opts.dir, vars, opts.env_name);
        }
    }

    // 4. Deploy.
    try wranglerDeploy(gpa, io, opts.dir, opts.env_name, opts.dry_run);
    if (opts.dry_run) say("\nakm deploy: dry-run OK (config + bundle validated; nothing deployed).\n");
}

fn lookup(vars: []const project.Var, key: []const u8) ?[]const u8 {
    for (vars) |v| if (std.mem.eql(u8, v.key, key)) return v.value;
    return null;
}

/// `uv run alembic upgrade head` against the direct endpoint.
fn migrate(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, direct_url: []const u8) !void {
    say("akm deploy: alembic upgrade head (direct endpoint) …\n");
    var env = try project.baseChildEnv(gpa);
    defer env.deinit();
    try env.put("DATABASE_URL_DIRECT", direct_url);
    var child = std.process.spawn(io, .{
        .argv = &.{ "uv", "run", "alembic", "upgrade", "head" },
        .cwd = .{ .path = dir },
        .environ_map = &env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        say2("akm deploy: cannot run alembic: ", @errorName(err));
        say("\n");
        return err;
    };
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        say("akm deploy: migration failed — aborting before deploy.\n");
        return error.MigrateFailed;
    }
}

/// Upload all vars as Worker secrets in one atomic `wrangler secret bulk`,
/// feeding the JSON document on stdin so no secrets touch the disk.
fn pushSecrets(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, vars: []project.Var, env_name: ?[]const u8) !void {
    say("akm deploy: uploading secrets (wrangler secret bulk) …\n");

    var json: std.Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    try json.writer.writeByte('{');
    for (vars, 0..) |v, i| {
        if (i != 0) try json.writer.writeByte(',');
        try writeJsonString(&json.writer, v.key);
        try json.writer.writeByte(':');
        try writeJsonString(&json.writer, v.value);
    }
    try json.writer.writeByte('}');

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "npx", "wrangler", "secret", "bulk" });
    if (env_name) |e| try argv.appendSlice(gpa, &.{ "--env", e });

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .path = dir },
        .stdin = .pipe,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        say2("akm deploy: cannot run wrangler: ", @errorName(err));
        say("\n");
        return err;
    };
    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(io, json.written()) catch {};
        stdin.close(io);
        child.stdin = null;
    }
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        say("akm deploy: secret upload failed (is `wrangler` logged in?).\n");
        return error.SecretsFailed;
    }
}

fn wranglerDeploy(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, env_name: ?[]const u8, dry_run: bool) !void {
    say(if (dry_run) "akm deploy: wrangler deploy --dry-run …\n" else "akm deploy: wrangler deploy …\n");
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "npx", "wrangler", "deploy" });
    if (env_name) |e| try argv.appendSlice(gpa, &.{ "--env", e });
    if (dry_run) {
        // Containers need the Docker CLI to build the image even under --dry-run;
        // --containers-rollout=none skips that so config + Worker bundle still validate
        // on a machine without Docker.
        try argv.appendSlice(gpa, &.{ "--dry-run", "--containers-rollout=none" });
    }

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .path = dir },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        say2("akm deploy: cannot run wrangler (is `npm install` done?): ", @errorName(err));
        say("\n");
        return err;
    };
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.DeployFailed;
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
    var o = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            o.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--skip-build")) {
            o.skip_build = true;
        } else if (std.mem.eql(u8, arg, "--migrate")) {
            o.migrate = true;
        } else if (eatValue(args, &i, arg, "--env")) |v| {
            o.env_name = v;
        } else if (eatValue(args, &i, arg, "--secrets")) |v| {
            o.secrets_file = v;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownFlag;
        } else {
            o.dir = arg;
        }
    }
    return o;
}

fn eatValue(args: []const []const u8, i: *usize, arg: []const u8, flag: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, arg, flag)) return null;
    if (i.* + 1 >= args.len) return null;
    i.* += 1;
    return args[i.*];
}

fn say2(a: []const u8, b: []const u8) void {
    say(a);
    say(b);
}

test {
    std.testing.refAllDecls(@This());
}

test "parseArgs deploy flags" {
    const a = try parseArgs(&.{ "app", "--dry-run", "--env", "production", "--secrets", ".prod.vars", "--migrate" });
    try std.testing.expectEqualStrings("app", a.dir);
    try std.testing.expect(a.dry_run and a.migrate);
    try std.testing.expectEqualStrings("production", a.env_name.?);
    try std.testing.expectEqualStrings(".prod.vars", a.secrets_file.?);
    try std.testing.expectError(error.UnknownFlag, parseArgs(&.{"--nope"}));
}

test "lookup finds and misses" {
    const vars = [_]project.Var{ .{ .key = "A", .value = "1" }, .{ .key = "DATABASE_URL_DIRECT", .value = "x" } };
    try std.testing.expectEqualStrings("x", lookup(&vars, "DATABASE_URL_DIRECT").?);
    try std.testing.expect(lookup(&vars, "MISSING") == null);
}