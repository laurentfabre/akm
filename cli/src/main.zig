const std = @import("std");
const init_cmd = @import("commands/init.zig");

pub const version = "0.0.1";

/// The process-wide Io (Zig 0.16). Set once at startup; used by `say` and the
/// commands for filesystem access. A CLI is single-threaded enough for this.
pub var io: std.Io = undefined;

const usage =
    \\akm — Cloudflare + Neon full-stack app toolkit (Zig orchestrator)
    \\
    \\Usage: akm <command> [args]
    \\
    \\Commands:
    \\  init <name>     Scaffold a new Cloudflare + Neon app
    \\  dev             Run the local dev orchestrator              (P2, not yet implemented)
    \\  build           Build Worker + Container artifacts          (P3, not yet implemented)
    \\  deploy          Deploy via wrangler                         (P3, not yet implemented)
    \\  logs            Tail logs (wrangler tail / Observability)   (P3, not yet implemented)
    \\  version         Print version
    \\  help            Show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    io = init.io;
    const gpa = init.gpa;

    // Zig 0.16 delivers argv through the process Init; materialize as slices.
    const argz = try init.minimal.args.toSlice(init.arena.allocator());
    if (argz.len < 2) {
        say(usage);
        return;
    }
    const args = try gpa.alloc([]const u8, argz.len);
    defer gpa.free(args);
    for (argz, 0..) |a, i| args[i] = a;

    const cmd = args[1];
    if (eql(cmd, "version") or eql(cmd, "--version") or eql(cmd, "-v")) {
        say("akm " ++ version ++ "\n");
    } else if (eql(cmd, "help") or eql(cmd, "--help") or eql(cmd, "-h")) {
        say(usage);
    } else if (eql(cmd, "init")) {
        try init_cmd.run(gpa, args[2..]);
    } else if (eql(cmd, "dev") or eql(cmd, "build") or eql(cmd, "deploy") or eql(cmd, "logs")) {
        say2("akm: '", cmd);
        say("' is not yet implemented (see goal.md phases P2/P3).\n");
        return error.NotImplemented;
    } else {
        say2("akm: unknown command '", cmd);
        say("'\n\n");
        say(usage);
        return error.UnknownCommand;
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Write to stdout (best-effort; a broken pipe is not fatal for a CLI).
pub fn say(s: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, s) catch {};
}
fn say2(a: []const u8, b: []const u8) void {
    say(a);
    say(b);
}

test {
    std.testing.refAllDecls(@import("render.zig"));
    std.testing.refAllDecls(init_cmd);
}
