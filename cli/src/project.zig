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
        // The name is interpolated into `python -c "from <pkg>.backend.app …"`
        // by build/deploy — reject anything that isn't a plain Python identifier
        // (blocks code injection via a crafted dir name + catches names like
        // `my-app` that would only fail later at import).
        if (!isValidPkgName(entry.name)) {
            say("akm: backend package directory '");
            say(entry.name);
            say("' is not a valid Python identifier (use letters/digits/underscore, not starting with a digit, not a keyword).\n");
            return error.InvalidPackageName;
        }
        found = try gpa.dupe(u8, entry.name);
    }
    if (found) |f| return f;
    say("akm: could not find a backend package (src/<pkg>/backend/app.py).\n");
    return error.NoProject;
}

/// Is `name` a plain Python identifier (and not a keyword)? Used to validate a
/// discovered backend package dir before it is interpolated into `python -c`.
pub fn isValidPkgName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return !isPyKeyword(name);
}

const py_keywords = [_][]const u8{
    "False",  "None",   "True",    "and",      "as",       "assert", "async",
    "await",  "break",  "class",   "continue", "def",      "del",    "elif",
    "else",   "except", "finally", "for",      "from",     "global", "if",
    "import", "in",     "is",      "lambda",   "nonlocal", "not",    "or",
    "pass",   "raise",  "return",  "try",      "while",    "with",   "yield",
};
fn isPyKeyword(s: []const u8) bool {
    for (py_keywords) |kw| if (std.mem.eql(u8, s, kw)) return true;
    return false;
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
        // A NUL would panic `Environ.Map.put` (key) or silently truncate the
        // child env (value) — reject the file rather than crash `akm dev`.
        if (std.mem.indexOfScalar(u8, key, 0) != null or std.mem.indexOfScalar(u8, value, 0) != null) {
            return error.InvalidVarByte;
        }
        // Reject duplicate keys: consumers differ on which wins (deploy's migrate
        // takes the first DATABASE_URL_DIRECT, but `wrangler secret bulk` gets the
        // whole JSON and is commonly last-wins) — that could migrate one database
        // and deploy the Worker pointed at another.
        for (list.items) |existing| if (std.mem.eql(u8, existing.key, key)) return error.DuplicateVar;
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

test "isValidPkgName: identifiers, rejects, keywords" {
    try std.testing.expect(isValidPkgName("app"));
    try std.testing.expect(isValidPkgName("my_app2"));
    try std.testing.expect(isValidPkgName("_private"));
    try std.testing.expect(!isValidPkgName("")); // empty
    try std.testing.expect(!isValidPkgName("2cool")); // leading digit
    try std.testing.expect(!isValidPkgName("my-app")); // hyphen
    try std.testing.expect(!isValidPkgName("a.b")); // dot (import-path injection)
    try std.testing.expect(!isValidPkgName("a b")); // space
    try std.testing.expect(!isValidPkgName("x\nimport os")); // newline injection
    try std.testing.expect(!isValidPkgName("class")); // python keyword
}

test "parseVars rejects NUL bytes (would panic Environ.Map.put)" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidVarByte, parseVars(gpa, "BAD\x00KEY=value\n"));
    try std.testing.expectError(error.InvalidVarByte, parseVars(gpa, "KEY=va\x00lue\n"));
}

test "parseVars rejects duplicate keys" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.DuplicateVar, parseVars(gpa, "DATABASE_URL=a\nDATABASE_URL=b\n"));
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
