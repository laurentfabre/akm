//! Shared helpers for commands that operate on a scaffolded akm project
//! (`dev`, `build`, later `deploy`): locating the project, discovering the
//! backend package, and building the child-process environment.

const std = @import("std");
const main = @import("main.zig");

const Environ = std.process.Environ;
const say = main.say;

/// Open and minimally validate a project directory (must contain package.json).
/// Caller closes the returned dir with `.close(main.io)`.
pub fn openProject(io: std.Io, dir: []const u8) !std.Io.Dir {
    var proj = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch {
        say("akm: cannot open project directory '");
        say(dir);
        say("'\n");
        return error.NoProject;
    };
    proj.access(io, "package.json", .{}) catch {
        proj.close(io);
        say("akm: no package.json here — run inside an akm project (or pass its dir).\n");
        return error.NoProject;
    };
    return proj;
}

/// Find the backend package: the single `src/<pkg>/backend/app.py`. Returns the
/// package directory name (owned by `gpa`).
pub fn discoverPkg(gpa: std.mem.Allocator, io: std.Io, proj: std.Io.Dir) ![]u8 {
    var src = proj.openDir(io, "src", .{ .iterate = true }) catch {
        say("akm: no src/ directory — not an akm project.\n");
        return error.NoProject;
    };
    defer src.close(io);

    // Iterate fully and require exactly one match — don't silently pick the
    // first of several (iteration order isn't stable).
    var found: ?[]u8 = null;
    errdefer if (found) |f| gpa.free(f);
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        var buf: [512]u8 = undefined;
        const probe = std.fmt.bufPrint(&buf, "src/{s}/backend/app.py", .{entry.name}) catch continue;
        proj.access(io, probe, .{}) catch continue;
        if (found != null) {
            say("akm: multiple backend packages under src/ — expected exactly one src/<pkg>/backend/app.py.\n");
            return error.AmbiguousPackage;
        }
        found = try gpa.dupe(u8, entry.name);
    }
    if (found) |f| return f;
    say("akm: could not find a backend package (src/<pkg>/backend/app.py).\n");
    return error.NoProject;
}

/// One `KEY=value` binding parsed from a `.dev.vars`/`.prod.vars`-style file.
/// `key`/`value` borrow from the input bytes — keep them alive while in use.
pub const Var = struct { key: []const u8, value: []const u8 };

/// Parse `KEY=value` / `KEY="value"` lines (`#` comments, blank lines ignored;
/// one layer of matching surrounding quotes stripped). Returns an owned slice
/// (free with `gpa.free`); the entries borrow from `bytes`.
pub fn parseVars(gpa: std.mem.Allocator, bytes: []const u8) ![]Var {
    var list: std.ArrayList(Var) = .empty;
    errdefer list.deinit(gpa);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) continue;
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) {
            value = value[1 .. value.len - 1];
        }
        try list.append(gpa, .{ .key = key, .value = value });
    }
    return list.toOwnedSlice(gpa);
}

/// A child environment seeded from the parent process env plus `PYTHONPATH=src`
/// (so `import <pkg>` resolves without an editable install). Caller deinits.
pub fn baseChildEnv(gpa: std.mem.Allocator) !Environ.Map {
    var env = Environ.Map.init(gpa);
    errdefer env.deinit();
    var it = main.environ_map.array_hash_map.iterator();
    while (it.next()) |e| try env.put(e.key_ptr.*, e.value_ptr.*);
    try env.put("PYTHONPATH", "src");
    return env;
}

test "parseVars is OOM-safe (no leak on allocation failure)" {
    const Fn = struct {
        fn run(a: std.mem.Allocator) !void {
            const vars = try parseVars(a, "A=1\nB=\"two\"\n# c\nLONG=value-here-0123456789\n");
            a.free(vars); // entries borrow from the input; only the slice is owned
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Fn.run, .{});
}

test "parseVars: comments, quotes, whitespace" {
    const gpa = std.testing.allocator;
    const vars = try parseVars(gpa,
        \\# comment
        \\
        \\DATABASE_URL="postgresql://u:p@h/db?sslmode=require"
        \\AKM_INTERNAL_JWT_KEY = bare-value
        \\EMPTY=
    );
    defer gpa.free(vars);
    try std.testing.expectEqual(@as(usize, 3), vars.len);
    try std.testing.expectEqualStrings("DATABASE_URL", vars[0].key);
    try std.testing.expectEqualStrings("postgresql://u:p@h/db?sslmode=require", vars[0].value);
    try std.testing.expectEqualStrings("AKM_INTERNAL_JWT_KEY", vars[1].key);
    try std.testing.expectEqualStrings("bare-value", vars[1].value);
    try std.testing.expectEqualStrings("", vars[2].value);
}
