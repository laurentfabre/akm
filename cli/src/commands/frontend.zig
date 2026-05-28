//! `akm frontend` — a thin, honest wrapper over the npm/Vite frontend toolchain
//! (goal.md §4: "thin wrapper over Bun/Vite/npm").
//!
//! This is the **UI-only escape hatch**: it lets you work on the React/Vite app
//! in isolation, without spinning up the full `akm dev` loop (reverse proxy +
//! `X-Akm-Identity` minting + uvicorn + ephemeral Neon branch). It does NOT
//! reimplement any of those tools — every subcommand just sequences npm in the
//! project directory after a minimal "is this an akm project?" guard.
//!
//! Subcommands:
//!   install [dir]            npm install            (fetch frontend deps)
//!   add <pkg…> [--dev]       npm install [-D] <pkg> (add a dependency)
//!   dev [dir]                npm run dev            (Vite only — no API proxy)
//!   build [dir]              npm run build          (Vite build only — no codegen)
//!   typecheck [dir]          npm run typecheck      (tsc --noEmit)
//!
//! Honest boundaries vs the full commands:
//!   • `frontend dev` runs Vite alone — `/api/*` is NOT proxied to a backend and
//!     no identity header is injected. For the real local loop use `akm dev`.
//!   • `frontend build` is `vite build` only — it does NOT regenerate the typed
//!     client from openapi.json. For the full artifact pipeline use `akm build`.

const std = @import("std");
const main = @import("../main.zig");
const project = @import("../project.zig");

const say = main.say;

const usage =
    \\Usage: akm frontend <subcommand>
    \\
    \\  install [dir]          npm install (fetch frontend deps)
    \\  add <pkg…> [--dev]     npm install [-D] <pkg…> (add a dependency; --dir PATH to target)
    \\  dev [dir]              npm run dev — Vite only (no API proxy; use `akm dev` for the full loop)
    \\  build [dir]            npm run build — Vite build only (no codegen; use `akm build` for the full pipeline)
    \\  typecheck [dir]        npm run typecheck (tsc --noEmit)
    \\
;

pub fn run(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        say(usage);
        return error.BadArgs;
    }
    const sub = args[0];
    const rest = args[1..];

    if (eql(sub, "install")) {
        try runScripted(rest, &.{ "npm", "install" }, "install", false);
    } else if (eql(sub, "dev")) {
        // Interrupting the dev server (Ctrl-C) is the normal way to stop it.
        try runScripted(rest, &.{ "npm", "run", "dev" }, "dev", true);
    } else if (eql(sub, "build")) {
        try runScripted(rest, &.{ "npm", "run", "build" }, "build", false);
    } else if (eql(sub, "typecheck")) {
        try runScripted(rest, &.{ "npm", "run", "typecheck" }, "typecheck", false);
    } else if (eql(sub, "add")) {
        try runAdd(gpa, rest);
    } else {
        say2("akm frontend: unknown subcommand '", sub);
        say("'\n\n");
        say(usage);
        return error.BadArgs;
    }
}

/// Subcommands whose only positional is an optional `[dir]` (install/dev/build/
/// typecheck): parse the dir, validate the project, then spawn the fixed argv.
fn runScripted(
    args: []const []const u8,
    argv: []const []const u8,
    label: []const u8,
    interruptible: bool,
) !void {
    const io = main.io;
    const dir = parseDirOnly(args) catch {
        say2("Usage: akm frontend ", label);
        say(" [dir]\n");
        return error.BadArgs;
    };

    var proj = try project.openProject(io, dir);
    defer proj.close(io);

    try spawnNpm(io, dir, argv, interruptible);
}

/// `add <pkg…> [--dev] [--dir PATH]`: positionals are package specs (so the
/// project dir must be given via `--dir`, default ".").
fn runAdd(gpa: std.mem.Allocator, args: []const []const u8) !void {
    const io = main.io;

    var pkgs: std.ArrayList([]const u8) = .empty;
    defer pkgs.deinit(gpa);
    var dir: []const u8 = ".";
    var dev = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--dev") or eql(arg, "-D")) {
            dev = true;
        } else if (eql(arg, "--dir")) {
            if (i + 1 >= args.len) {
                say("akm frontend add: --dir needs a path\n");
                return error.BadArgs;
            }
            i += 1;
            dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            say2("akm frontend add: unknown flag ", arg);
            say("\n");
            return error.BadArgs;
        } else {
            try pkgs.append(gpa, arg);
        }
    }

    if (pkgs.items.len == 0) {
        say("Usage: akm frontend add <pkg…> [--dev] [--dir PATH]\n");
        return error.BadArgs;
    }

    var proj = try project.openProject(io, dir);
    defer proj.close(io);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "npm", "install" });
    if (dev) try argv.append(gpa, "--save-dev");
    try argv.appendSlice(gpa, pkgs.items);

    try spawnNpm(io, dir, argv.items, false);
}

/// Spawn npm with inherited stdio in `dir`. `interruptible` = a long-running
/// server (`dev`) the user stops with Ctrl-C: a *signal* termination, or npm's
/// 130/143 (128+SIGINT/SIGTERM) exit, is then the normal stop — but a plain
/// nonzero exit (e.g. no `dev` script, Vite crashed at startup) is still a real
/// failure, so we don't blanket-ignore it the way a bare early return would.
fn spawnNpm(io: std.Io, dir: []const u8, argv: []const []const u8, interruptible: bool) !void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = dir },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        say2("akm frontend: cannot run npm (is Node installed?): ", @errorName(err));
        say("\n");
        return err;
    };
    const term = try child.wait(io);
    const ok = switch (term) {
        .exited => |code| code == 0 or (interruptible and (code == 130 or code == 143)),
        else => interruptible, // killed by a signal: normal only when stopping `dev`
    };
    if (!ok) {
        say("akm frontend: command failed (have you run `akm frontend install`?).\n");
        return error.FrontendFailed;
    }
}

/// Parse the at-most-one optional positional `[dir]` (default "."); reject flags.
fn parseDirOnly(args: []const []const u8) ![]const u8 {
    var dir: []const u8 = ".";
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownFlag;
        dir = arg;
    }
    return dir;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn say2(a: []const u8, b: []const u8) void {
    say(a);
    say(b);
}

test "parseDirOnly: default and override" {
    try std.testing.expectEqualStrings(".", try parseDirOnly(&.{}));
    try std.testing.expectEqualStrings("myapp", try parseDirOnly(&.{"myapp"}));
    try std.testing.expectError(error.UnknownFlag, parseDirOnly(&.{"--nope"}));
}

test {
    std.testing.refAllDecls(@This());
}
