//! Ephemeral Neon dev-branch lifecycle for `akm dev --neon-branch` (goal.md §3/§5).
//!
//! Shells out to the Neon CLI (`neonctl`): create a
//! throwaway branch on startup, hand its pooled + direct connection URLs to the
//! backend, delete it on teardown. Auth flows through the inherited environment
//! (`NEON_API_KEY` or a prior `neonctl auth`); the project id must be supplied.
//!
//! URLs are rewritten to the SQLAlchemy/psycopg form (`postgresql+psycopg://`)
//! that `neon.py` expects; the pooled URL swaps in the `-pooler` host (PgBouncer
//! transaction mode) per the dual-endpoint design.

const std = @import("std");

pub const Error = error{
    NeonCliMissing,
    NeonCliFailed,
    NeonOutputUnexpected,
} || std.mem.Allocator.Error;

/// A created branch and its connection URLs. Free with `deinit`.
pub const Branch = struct {
    gpa: std.mem.Allocator,
    id: []u8,
    pooled_url: []u8,
    direct_url: []u8,

    pub fn deinit(self: *Branch) void {
        self.gpa.free(self.id);
        self.gpa.free(self.pooled_url);
        self.gpa.free(self.direct_url);
        self.* = undefined;
    }
};

fn cli() []const u8 {
    return "neonctl";
}

/// Create an ephemeral branch and resolve its pooled + direct URLs.
pub fn create(
    gpa: std.mem.Allocator,
    io: std.Io,
    project_id: []const u8,
    name: []const u8,
) Error!Branch {
    const argv = [_][]const u8{
        cli(),                        "branches", "create",
        "--project-id",               project_id, "--name",
        name,                         "--output", "json",
    };
    const res = std.process.run(gpa, io, .{ .argv = &argv }) catch |err| switch (err) {
        error.FileNotFound => return Error.NeonCliMissing,
        else => return Error.NeonCliFailed,
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        std.log.err("neon: branch create failed: {s}", .{trim(res.stderr)});
        return Error.NeonCliFailed;
    }

    return parseCreate(gpa, res.stdout);
}

/// Delete the branch. Best-effort: logs and swallows errors so teardown of the
/// rest of the dev session always proceeds.
pub fn delete(gpa: std.mem.Allocator, io: std.Io, project_id: []const u8, id: []const u8) void {
    const argv = [_][]const u8{
        cli(), "branches", "delete", id, "--project-id", project_id,
    };
    const res = std.process.run(gpa, io, .{ .argv = &argv }) catch |err| {
        std.log.warn("neon: branch delete spawn failed ({s}); branch {s} may linger", .{ @errorName(err), id });
        return;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        std.log.warn("neon: branch delete failed; branch {s} may linger: {s}", .{ id, trim(res.stderr) });
    }
}

pub const ConnStrings = struct {
    gpa: std.mem.Allocator,
    pooled: []u8,
    direct: []u8,
    pub fn deinit(self: *ConnStrings) void {
        self.gpa.free(self.pooled);
        self.gpa.free(self.direct);
        self.* = undefined;
    }
};

/// Fetch the pooled + direct connection strings for an existing branch,
/// rewritten to the `postgresql+psycopg://` driver form.
pub fn connectionStrings(gpa: std.mem.Allocator, io: std.Io, project_id: []const u8, branch: []const u8) Error!ConnStrings {
    const pooled = try connString(gpa, io, project_id, branch, true);
    errdefer gpa.free(pooled);
    const direct = try connString(gpa, io, project_id, branch, false);
    return .{ .gpa = gpa, .pooled = pooled, .direct = direct };
}

fn connString(gpa: std.mem.Allocator, io: std.Io, project_id: []const u8, branch: []const u8, pooled: bool) Error![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    argv.appendSlice(gpa, &.{ cli(), "connection-string", "--project-id", project_id, "--branch", branch }) catch return Error.OutOfMemory;
    if (pooled) argv.append(gpa, "--pooled") catch return Error.OutOfMemory;
    const res = std.process.run(gpa, io, .{ .argv = argv.items }) catch |err| switch (err) {
        error.FileNotFound => return Error.NeonCliMissing,
        else => return Error.NeonCliFailed,
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        std.log.err("neon: connection-string failed: {s}", .{trim(res.stderr)});
        return Error.NeonCliFailed;
    }
    const raw = trim(res.stdout);
    if (raw.len == 0) return Error.NeonOutputUnexpected;
    return toPsycopgUrl(gpa, raw);
}

/// Whether a branch with this name already exists on the project.
pub fn branchExists(gpa: std.mem.Allocator, io: std.Io, project_id: []const u8, name: []const u8) Error!bool {
    const argv = [_][]const u8{ cli(), "branches", "list", "--project-id", project_id, "--output", "json" };
    const res = std.process.run(gpa, io, .{ .argv = &argv }) catch |err| switch (err) {
        error.FileNotFound => return Error.NeonCliMissing,
        else => return Error.NeonCliFailed,
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) return Error.NeonCliFailed;

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, res.stdout, .{}) catch return Error.NeonOutputUnexpected;
    defer parsed.deinit();
    const list = arr(parsed.value) orelse return Error.NeonOutputUnexpected;
    for (list.items) |item| {
        const o = obj(item) orelse continue;
        if (str(o.get("name"))) |n| if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Get-or-create: reuse the branch if it exists (fetch its URLs), else create it.
/// Idempotent — safe to call once per PR-preview deploy.
pub fn ensure(gpa: std.mem.Allocator, io: std.Io, project_id: []const u8, name: []const u8) Error!Branch {
    if (try branchExists(gpa, io, project_id, name)) {
        var cs = try connectionStrings(gpa, io, project_id, name);
        errdefer cs.deinit();
        // Reuse: neonctl accepts the branch *name* for later delete, so id := name.
        const id = try gpa.dupe(u8, name);
        return .{ .gpa = gpa, .id = id, .pooled_url = cs.pooled, .direct_url = cs.direct };
    }
    return create(gpa, io, project_id, name);
}

/// Parse `neonctl branches create --output json`, building owned pooled/direct
/// URLs. Split out from `create` so it can be unit-tested without the CLI.
fn parseCreate(gpa: std.mem.Allocator, json_bytes: []const u8) Error!Branch {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{}) catch
        return Error.NeonOutputUnexpected;
    defer parsed.deinit();

    const root = obj(parsed.value) orelse return Error.NeonOutputUnexpected;
    const branch = obj(root.get("branch") orelse return Error.NeonOutputUnexpected) orelse
        return Error.NeonOutputUnexpected;
    const id = str(branch.get("id")) orelse return Error.NeonOutputUnexpected;

    const uris = arr(root.get("connection_uris")) orelse return Error.NeonOutputUnexpected;
    if (uris.items.len == 0) return Error.NeonOutputUnexpected;
    const first = obj(uris.items[0]) orelse return Error.NeonOutputUnexpected;
    const direct_raw = str(first.get("connection_uri")) orelse return Error.NeonOutputUnexpected;
    const params = obj(first.get("connection_parameters")) orelse return Error.NeonOutputUnexpected;
    const host = str(params.get("host")) orelse return Error.NeonOutputUnexpected;
    const pooler_host = str(params.get("pooler_host")) orelse return Error.NeonOutputUnexpected;

    // Pooled URL = direct URL with the host swapped for the -pooler host.
    const pooled_raw = try replaceOwned(gpa, direct_raw, host, pooler_host);
    defer gpa.free(pooled_raw);

    const direct_url = try toPsycopgUrl(gpa, direct_raw);
    errdefer gpa.free(direct_url);
    const pooled_url = try toPsycopgUrl(gpa, pooled_raw);
    errdefer gpa.free(pooled_url);
    const id_owned = try gpa.dupe(u8, id);

    return .{ .gpa = gpa, .id = id_owned, .pooled_url = pooled_url, .direct_url = direct_url };
}

/// Rewrite a `postgresql://` / `postgres://` URL to the `postgresql+psycopg://`
/// driver form `neon.py` / SQLAlchemy expects. The scheme is the only change;
/// the Neon URL already carries `?sslmode=require`.
fn toPsycopgUrl(gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    const want = "postgresql+psycopg://";
    inline for (.{ "postgresql://", "postgres://" }) |scheme| {
        if (std.mem.startsWith(u8, url, scheme)) {
            return std.fmt.allocPrint(gpa, "{s}{s}", .{ want, url[scheme.len..] });
        }
    }
    if (std.mem.startsWith(u8, url, want)) return gpa.dupe(u8, url);
    return gpa.dupe(u8, url); // unknown scheme — pass through unchanged
}

fn replaceOwned(gpa: std.mem.Allocator, haystack: []const u8, needle: []const u8, repl: []const u8) ![]u8 {
    const n = std.mem.replacementSize(u8, haystack, needle, repl);
    const out = try gpa.alloc(u8, n);
    _ = std.mem.replace(u8, haystack, needle, repl, out);
    return out;
}

// JSON Value navigation helpers (tolerant — return null on type mismatch).
fn obj(v: ?std.json.Value) ?std.json.ObjectMap {
    return if (v) |x| switch (x) {
        .object => |o| o,
        else => null,
    } else null;
}
fn arr(v: ?std.json.Value) ?std.json.Array {
    return if (v) |x| switch (x) {
        .array => |a| a,
        else => null,
    } else null;
}
fn str(v: ?std.json.Value) ?[]const u8 {
    return if (v) |x| switch (x) {
        .string => |s| s,
        else => null,
    } else null;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseCreate extracts id and builds pooled/direct psycopg URLs" {
    const gpa = testing.allocator;
    const sample =
        \\{
        \\ "branch": { "id": "br-frosty-art-30264288", "name": "akm-dev" },
        \\ "connection_uris": [
        \\   { "connection_uri": "postgresql://alex:pw@ep-cool-123.us-east-2.aws.neon.tech/db?sslmode=require",
        \\     "connection_parameters": {
        \\       "database": "db", "password": "pw", "role": "alex",
        \\       "host": "ep-cool-123.us-east-2.aws.neon.tech",
        \\       "pooler_host": "ep-cool-123-pooler.us-east-2.aws.neon.tech" } }
        \\ ]
        \\}
    ;
    var br = try parseCreate(gpa, sample);
    defer br.deinit();

    try testing.expectEqualStrings("br-frosty-art-30264288", br.id);
    try testing.expectEqualStrings(
        "postgresql+psycopg://alex:pw@ep-cool-123.us-east-2.aws.neon.tech/db?sslmode=require",
        br.direct_url,
    );
    try testing.expectEqualStrings(
        "postgresql+psycopg://alex:pw@ep-cool-123-pooler.us-east-2.aws.neon.tech/db?sslmode=require",
        br.pooled_url,
    );
}

test "parseCreate rejects malformed output" {
    const gpa = testing.allocator;
    try testing.expectError(Error.NeonOutputUnexpected, parseCreate(gpa, "{}"));
    try testing.expectError(Error.NeonOutputUnexpected, parseCreate(gpa, "not json"));
}
