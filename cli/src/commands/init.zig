//! `akm init <name> [dest]` — scaffold a new Cloudflare + Neon app from embedded templates.
//!
//! Every embedded file lives under `base/` in the template tree. For each:
//!   - the *output path* has `__pkg__`/`__slug__` tokens substituted,
//!   - a `.tmpl` suffix marks a file to render; the suffix is stripped on output,
//!   - anything else is copied verbatim.
//!
//! `name` is freeform. From it we derive:
//!   - `app_slug` (kebab) for Worker/container names,
//!   - `app_pkg`  (a *valid Python/TS identifier*) for the package + bindings,
//!   - `app_name_json` / `app_name_html` — context-escaped for safe insertion.

const std = @import("std");
const templates = @import("templates");
const render = @import("../render.zig");

const main = @import("../main.zig");
const say = main.say;

pub fn run(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        say("Usage: akm init <name> [dest]\n");
        return error.MissingArgument;
    }
    const name_raw = args[0];
    // Collapse control chars (newlines/tabs) to spaces so the name is safe to drop
    // into single-line comments/markdown without breaking or injecting.
    const name = try sanitizeDisplay(gpa, name_raw);
    defer gpa.free(name);
    const slug = try slugify(gpa, name, '-');
    defer gpa.free(slug);
    const pkg_raw = try slugify(gpa, name, '_');
    defer gpa.free(pkg_raw);
    const pkg = try toPyIdentifier(gpa, pkg_raw); // valid module name (not a keyword)
    defer gpa.free(pkg);
    const pkg_upper = try std.ascii.allocUpperString(gpa, pkg);
    defer gpa.free(pkg_upper);
    const name_json = try jsonEscape(gpa, name); // safe inside double-quoted Py/TOML/JSON & docstrings
    defer gpa.free(name_json);
    const name_html = try htmlEscape(gpa, name); // safe inside HTML text
    defer gpa.free(name_html);

    const dest = if (args.len >= 2) args[1] else slug;

    var ctx = render.Context.init(gpa);
    defer ctx.deinit();
    try ctx.put("app_name", name); // single-line; safe in markdown/single-line comments
    try ctx.put("app_name_json", name_json);
    try ctx.put("app_name_html", name_html);
    try ctx.put("app_slug", slug);
    try ctx.put("app_pkg", pkg);
    try ctx.put("app_pkg_upper", pkg_upper);
    try ctx.put("ui", "true");

    if (dirExistsNonEmpty(dest)) {
        say2("akm: destination '", dest);
        say("' already exists and is not empty — aborting.\n");
        return error.DestinationNotEmpty;
    }
    const io = main.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dest);
    var dest_dir = try cwd.openDir(io, dest, .{});
    defer dest_dir.close(io);

    var count: usize = 0;
    for (templates.files) |f| {
        const rel = stripPrefix(f.path, "base/") orelse continue;
        if (rel.len == 0) continue;

        const path_pkg = try replaceOwned(gpa, rel, "__pkg__", pkg);
        defer gpa.free(path_pkg);
        const path_full = try replaceOwned(gpa, path_pkg, "__slug__", slug);
        defer gpa.free(path_full);
        const out_rel = stripSuffix(path_full, ".tmpl");
        const is_tmpl = out_rel.len != path_full.len;

        // Defense in depth: never write outside the destination tree.
        if (isUnsafePath(out_rel)) {
            say2("akm: refusing unsafe template path '", out_rel);
            say("'\n");
            return error.UnsafePath;
        }

        if (std.fs.path.dirnamePosix(out_rel)) |d| try dest_dir.createDirPath(io, d);

        const bytes: []const u8 = if (is_tmpl)
            try render.render(gpa, f.bytes, &ctx)
        else
            f.bytes;
        defer if (is_tmpl) gpa.free(@constCast(bytes));

        try dest_dir.writeFile(io, .{ .sub_path = out_rel, .data = bytes });
        count += 1;
    }

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "Scaffolded '{s}' into {s}/ ({d} files).\nNext: cd {s} && akm dev\n",
        .{ name, dest, count, dest },
    ) catch "Scaffolded app.\n";
    say(msg);
}

fn say2(a: []const u8, b: []const u8) void {
    say(a);
    say(b);
}

/// Lowercase; runs of non-alphanumerics collapse to `sep`; trimmed of `sep`.
fn slugify(gpa: std.mem.Allocator, name: []const u8, sep: u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var prev_sep = true;
    for (name) |c| {
        const lc = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lc)) {
            try out.append(gpa, lc);
            prev_sep = false;
        } else if (!prev_sep) {
            try out.append(gpa, sep);
            prev_sep = true;
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == sep) _ = out.pop();
    if (out.items.len == 0) try out.appendSlice(gpa, "app");
    return out.toOwnedSlice(gpa);
}

/// Replace control characters (newline, tab, etc.) with spaces so a freeform
/// display name can't break single-line comments/markdown or escape contexts.
fn sanitizeDisplay(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (s) |c| try out.append(gpa, if (c < 0x20 or c == 0x7f) ' ' else c);
    return out.toOwnedSlice(gpa);
}

/// Make a `_`-slug into a valid Python (and TS) identifier: ensure it starts with
/// a letter/underscore, and isn't a Python keyword (which would break imports).
fn toPyIdentifier(gpa: std.mem.Allocator, slug: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (slug.len == 0 or !(std.ascii.isAlphabetic(slug[0]) or slug[0] == '_')) {
        try out.appendSlice(gpa, "app_"); // e.g. "2026_crm" → "app_2026_crm"
    }
    try out.appendSlice(gpa, slug);
    if (isPyKeyword(out.items)) try out.append(gpa, '_'); // "class" → "class_"
    return out.toOwnedSlice(gpa);
}

const py_keywords = [_][]const u8{
    "False",  "None",   "True",   "and",      "as",       "assert", "async",
    "await",  "break",  "class",  "continue", "def",      "del",    "elif",
    "else",   "except", "finally","for",      "from",     "global", "if",
    "import", "in",     "is",     "lambda",   "nonlocal", "not",    "or",
    "pass",   "raise",  "return", "try",      "while",    "with",   "yield",
};
fn isPyKeyword(s: []const u8) bool {
    for (py_keywords) |kw| if (std.mem.eql(u8, s, kw)) return true;
    return false;
}

/// Escape for insertion inside a double-quoted JSON/Python/TOML string (no quotes added).
fn jsonEscape(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => if (c < 0x20) {
            var b: [6]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch "");
        } else try out.append(gpa, c),
    };
    return out.toOwnedSlice(gpa);
}

/// Escape for insertion inside HTML text/attribute content.
fn htmlEscape(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(gpa, "&amp;"),
        '<' => try out.appendSlice(gpa, "&lt;"),
        '>' => try out.appendSlice(gpa, "&gt;"),
        '"' => try out.appendSlice(gpa, "&quot;"),
        '\'' => try out.appendSlice(gpa, "&#39;"),
        else => try out.append(gpa, c),
    };
    return out.toOwnedSlice(gpa);
}

/// Reject absolute paths and any `..` component.
fn isUnsafePath(p: []const u8) bool {
    if (std.fs.path.isAbsolute(p)) return true;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |c| if (std.mem.eql(u8, c, "..")) return true;
    return false;
}

/// Allocate a copy of `s` with every occurrence of `needle` replaced by `repl`.
fn replaceOwned(gpa: std.mem.Allocator, s: []const u8, needle: []const u8, repl: []const u8) ![]u8 {
    const n = std.mem.replacementSize(u8, s, needle, repl);
    const buf = try gpa.alloc(u8, n);
    _ = std.mem.replace(u8, s, needle, repl, buf);
    return buf;
}

fn stripPrefix(s: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, s, prefix)) return s[prefix.len..];
    return null;
}
fn stripSuffix(s: []const u8, suffix: []const u8) []const u8 {
    if (std.mem.endsWith(u8, s, suffix)) return s[0 .. s.len - suffix.len];
    return s;
}

fn dirExistsNonEmpty(path: []const u8) bool {
    const io = main.io;
    var d = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer d.close(io);
    var it = d.iterate();
    return (it.next(io) catch return false) != null;
}

// ── tests ──────────────────────────────────────────────────────────────────

test "slugify dash and underscore" {
    const gpa = std.testing.allocator;
    const a = try slugify(gpa, "My Cool App!!", '-');
    defer gpa.free(a);
    try std.testing.expectEqualStrings("my-cool-app", a);
    const b = try slugify(gpa, "My Cool App!!", '_');
    defer gpa.free(b);
    try std.testing.expectEqualStrings("my_cool_app", b);
}

test "slugify empty falls back" {
    const gpa = std.testing.allocator;
    const a = try slugify(gpa, "***", '-');
    defer gpa.free(a);
    try std.testing.expectEqualStrings("app", a);
}

test "toPyIdentifier digit prefix and keyword" {
    const gpa = std.testing.allocator;
    const a = try toPyIdentifier(gpa, "2026_crm");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("app_2026_crm", a);
    const b = try toPyIdentifier(gpa, "class");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("class_", b);
    const c = try toPyIdentifier(gpa, "notes");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("notes", c);
}

test "jsonEscape" {
    const gpa = std.testing.allocator;
    const a = try jsonEscape(gpa, "a\"b\\c\nd");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\nd", a);
}

test "htmlEscape" {
    const gpa = std.testing.allocator;
    const a = try htmlEscape(gpa, "<b>&\"x");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("&lt;b&gt;&amp;&quot;x", a);
}

test "isUnsafePath" {
    try std.testing.expect(isUnsafePath("/etc/passwd"));
    try std.testing.expect(isUnsafePath("a/../b"));
    try std.testing.expect(!isUnsafePath("a/b/c.txt"));
}
