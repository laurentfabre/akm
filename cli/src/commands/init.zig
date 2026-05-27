//! `akm init <name>` — scaffold a new Cloudflare + Neon app from embedded templates.
//!
//! Every embedded file lives under `base/` in the template tree. For each:
//!   - the *output path* is itself rendered (so `src/{{app_pkg}}/...` works),
//!   - a `.tmpl` suffix marks a file to render; the suffix is stripped on output,
//!   - anything else is copied verbatim.

const std = @import("std");
const templates = @import("templates");
const render = @import("../render.zig");

const main = @import("../main.zig");
const say = main.say;

pub fn run(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        say("Usage: akm init <name>\n");
        return error.MissingArgument;
    }
    const name = args[0];
    const slug = try slugify(gpa, name, '-');
    defer gpa.free(slug);
    const pkg = try slugify(gpa, name, '_');
    defer gpa.free(pkg);
    const pkg_upper = try std.ascii.allocUpperString(gpa, pkg);
    defer gpa.free(pkg_upper);

    const dest = if (args.len >= 2) args[1] else slug;

    var ctx = render.Context.init(gpa);
    defer ctx.deinit();
    try ctx.put("app_name", name);
    try ctx.put("app_slug", slug);
    try ctx.put("app_pkg", pkg);
    try ctx.put("app_pkg_upper", pkg_upper);
    // Feature flags (v1 defaults). Toggles consumed by `{{#if ui}}` etc.
    try ctx.put("ui", "true");

    // Refuse to clobber a non-empty destination.
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

        // Substitute path tokens (__pkg__ / __slug__) in directory & file names,
        // then strip a trailing ".tmpl".
        const path_pkg = try replaceOwned(gpa, rel, "__pkg__", pkg);
        defer gpa.free(path_pkg);
        const path_full = try replaceOwned(gpa, path_pkg, "__slug__", slug);
        defer gpa.free(path_full);
        const out_rel = stripSuffix(path_full, ".tmpl");
        const is_tmpl = out_rel.len != path_full.len;

        if (std.fs.path.dirnamePosix(out_rel)) |d| try dest_dir.createDirPath(io, d);

        const bytes: []const u8 = if (is_tmpl) blk: {
            break :blk try render.render(gpa, f.bytes, &ctx);
        } else f.bytes;
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
    var prev_sep = true; // suppress leading separators
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
    if (out.items.len > 0 and out.items[out.items.len - 1] == sep) {
        _ = out.pop();
    }
    if (out.items.len == 0) try out.appendSlice(gpa, "app");
    return out.toOwnedSlice(gpa);
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
