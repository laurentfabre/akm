//! `akm logs` — live log tail via `wrangler tail` (goal.md §5).
//!
//! Honest about the limits (§5): the source of truth for **container** (FastAPI)
//! stdout/stderr is the **Workers Observability dashboard** (`observability.enabled
//! = true` in wrangler.jsonc, already set by the template). `wrangler tail` is a
//! best-effort *live Worker* tail — whether it streams container output is a P0
//! verification item, not assumed. Durable export (Logs/Logpush) is paid/Enterprise.
//! So this command prints the caveat, then streams `wrangler tail`.

const std = @import("std");
const main = @import("../main.zig");
const project = @import("../project.zig");

const say = main.say;

const Options = struct {
    dir: []const u8 = ".",
    env_name: ?[]const u8 = null,
    format: ?[]const u8 = null, // pretty | json (wrangler default: pretty on a TTY)
};

pub fn run(gpa: std.mem.Allocator, args: []const []const u8) !void {
    const io = main.io;
    const opts = parseArgs(args) catch {
        say("Usage: akm logs [dir] [--env NAME] [--format pretty|json]\n");
        return error.BadArgs;
    };

    var proj = try project.openProject(io, opts.dir);
    defer proj.close(io);

    // §5: be explicit about what this does and does not show.
    say(
        \\akm logs: live Worker tail via `wrangler tail`.
        \\  Note: container (FastAPI) stdout/stderr is NOT guaranteed to appear here —
        \\  the source of truth for container logs is the Workers Observability dashboard
        \\  (observability.enabled=true). Durable export needs Logs/Logpush (paid tiers).
        \\  Ctrl-C to stop.
        \\
        \\
    );

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "npx", "wrangler", "tail" });
    if (opts.env_name) |e| try argv.appendSlice(gpa, &.{ "--env", e });
    if (opts.format) |f| try argv.appendSlice(gpa, &.{ "--format", f });

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .path = opts.dir },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        say2("akm logs: cannot run wrangler (is `npm install` done?): ", @errorName(err));
        say("\n");
        return err;
    };
    const term = try child.wait(io);
    // SIGINT (Ctrl-C) to stop the tail is the normal exit path; only a nonzero
    // *exit* code is a real failure (e.g. not logged in / no deployed Worker).
    if (term == .exited and term.exited != 0) {
        say("akm logs: wrangler tail failed (logged in? is the Worker deployed?).\n");
        return error.TailFailed;
    }
}

fn parseArgs(args: []const []const u8) !Options {
    var o = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eatValue(args, &i, arg, "--env")) |v| {
            o.env_name = v;
        } else if (eatValue(args, &i, arg, "--format")) |v| {
            o.format = v;
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
    // A value that looks like a flag means the real value was omitted — don't
    // swallow the next flag as the value (e.g. `--env --format`).
    if (i.* + 1 >= args.len or std.mem.startsWith(u8, args[i.* + 1], "-")) return null;
    i.* += 1;
    return args[i.*];
}

fn say2(a: []const u8, b: []const u8) void {
    say(a);
    say(b);
}

test "parseArgs logs flags" {
    const a = try parseArgs(&.{ "app", "--env", "production", "--format", "json" });
    try std.testing.expectEqualStrings("app", a.dir);
    try std.testing.expectEqualStrings("production", a.env_name.?);
    try std.testing.expectEqualStrings("json", a.format.?);
    try std.testing.expectError(error.UnknownFlag, parseArgs(&.{"--nope"}));
    try std.testing.expectEqualStrings(".", (try parseArgs(&.{})).dir);
}

test {
    std.testing.refAllDecls(@This());
}
