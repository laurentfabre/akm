const std = @import("std");
const init_cmd = @import("commands/init.zig");
const dev_cmd = @import("commands/dev.zig");
const build_cmd = @import("commands/build.zig");
const deploy_cmd = @import("commands/deploy.zig");
const components_cmd = @import("commands/components.zig");
const logs_cmd = @import("commands/logs.zig");
const preview_cmd = @import("commands/preview.zig");
const frontend_cmd = @import("commands/frontend.zig");

pub const version = "0.0.1";

/// The process-wide Io (Zig 0.16). Set once at startup; used by `say` and the
/// commands for filesystem access. A CLI is single-threaded enough for this.
pub var io: std.Io = undefined;

/// The parent process environment (Zig 0.16). `akm dev` clones this to build the
/// child environment for uvicorn/Vite. Set once at startup; read on the main thread.
pub var environ_map: *std.process.Environ.Map = undefined;

const usage =
    \\akm — Cloudflare + Neon full-stack app toolkit (Zig orchestrator)
    \\
    \\Usage: akm <command> [args]
    \\
    \\Commands:
    \\  init <name>     Scaffold a new Cloudflare + Neon app
    \\  dev [dir]       Run the local dev loop (proxy + uvicorn + Vite)
    \\  build [dir]     Codegen typed client + build UI/Worker artifacts
    \\  deploy [dir]    Build + push secrets + wrangler deploy (--dry-run to validate)
    \\  logs [dir]      Live Worker tail (wrangler tail; Observability for container logs)
    \\  components      Add shadcn/ui components (init | add <name…>)
    \\  frontend        UI-only toolchain (install | add | dev | build | typecheck)
    \\  preview         Per-PR preview env (create | destroy --pr <id>)
    \\  version         Print version
    \\  help            Show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    io = init.io;
    environ_map = init.environ_map;
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
    } else if (eql(cmd, "dev")) {
        try dev_cmd.run(gpa, args[2..]);
    } else if (eql(cmd, "build")) {
        try build_cmd.run(gpa, args[2..]);
    } else if (eql(cmd, "deploy")) {
        try deploy_cmd.run(gpa, args[2..]);
    } else if (eql(cmd, "components")) {
        try components_cmd.run(gpa, args[2..]);
    } else if (eql(cmd, "logs")) {
        try logs_cmd.run(gpa, args[2..]);
    } else if (eql(cmd, "preview")) {
        try preview_cmd.run(gpa, args[2..]);
    } else if (eql(cmd, "frontend")) {
        try frontend_cmd.run(gpa, args[2..]);
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
    std.testing.refAllDecls(dev_cmd);
    std.testing.refAllDecls(build_cmd);
    std.testing.refAllDecls(deploy_cmd);
    std.testing.refAllDecls(components_cmd);
    std.testing.refAllDecls(logs_cmd);
    std.testing.refAllDecls(preview_cmd);
    std.testing.refAllDecls(frontend_cmd);
    std.testing.refAllDecls(@import("project.zig"));
    std.testing.refAllDecls(@import("proxy.zig"));
    std.testing.refAllDecls(@import("jwt.zig"));
    std.testing.refAllDecls(@import("neon.zig"));
}
