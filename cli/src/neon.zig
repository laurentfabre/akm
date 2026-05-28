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
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory, // don't masquerade OOM as a parse error
        else => return Error.NeonOutputUnexpected,
    };
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
    if (host.len == 0 or pooler_host.len == 0) return Error.NeonOutputUnexpected;

    // Pooled URL = direct URL with ONLY the authority host swapped for the
    // -pooler host. A blind string replace (the old behavior) would corrupt a
    // URL where the host substring also appears in the password, db name, or query.
    const pooled_raw = try swapHost(gpa, direct_raw, host, pooler_host);
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
    // Unknown scheme: refuse rather than hand malformed CLI output to the DB layer.
    return Error.NeonOutputUnexpected;
}

/// Swap ONLY the authority host of a `scheme://[user[:pass]@]host[:port][/...]`
/// URL with `repl`. Validates the parsed host equals `host` (Neon's reported
/// host); refuses (NeonOutputUnexpected) if the URL shape is unexpected. This
/// avoids corrupting credentials/db-name/query that may contain the host substring.
fn swapHost(gpa: std.mem.Allocator, url: []const u8, host: []const u8, repl: []const u8) ![]u8 {
    const sep = "://";
    const sidx = std.mem.indexOf(u8, url, sep) orelse return Error.NeonOutputUnexpected;
    const auth_start = sidx + sep.len;
    const rest = url[auth_start..];
    const auth_len = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const authority = rest[0..auth_len];
    // host begins after the last '@' (userinfo), if any, and ends at ':' (port).
    const host_off = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| at + 1 else 0;
    const hostport = authority[host_off..];
    const host_len = std.mem.indexOfScalar(u8, hostport, ':') orelse hostport.len;
    if (!std.mem.eql(u8, hostport[0..host_len], host)) return Error.NeonOutputUnexpected;
    const start = auth_start + host_off;
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ url[0..start], repl, url[start + host_len ..] });
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

test "parseCreate is OOM-safe (no leak; returns OutOfMemory, not a parse error)" {
    const sample =
        \\{ "branch": { "id": "br-x" },
        \\  "connection_uris": [ { "connection_uri": "postgresql://u:p@h.neon.tech/db?sslmode=require",
        \\    "connection_parameters": { "host": "h.neon.tech", "pooler_host": "h-pooler.neon.tech" } } ] }
    ;
    const Fn = struct {
        fn run(a: std.mem.Allocator, json: []const u8) !void {
            var br = try parseCreate(a, json);
            br.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Fn.run, .{sample});
}

test "swapHost replaces only the authority host, not host substrings elsewhere" {
    const gpa = testing.allocator;
    // The host token also appears inside the password AND the db-name path.
    const url = "postgresql://u:h.neon.tech@h.neon.tech:5432/h.neon.tech?sslmode=require";
    const out = try swapHost(gpa, url, "h.neon.tech", "h-pooler.neon.tech");
    defer gpa.free(out);
    try testing.expectEqualStrings(
        "postgresql://u:h.neon.tech@h-pooler.neon.tech:5432/h.neon.tech?sslmode=require",
        out,
    );
    // host shape doesn't match Neon's reported host → refuse to guess
    try testing.expectError(Error.NeonOutputUnexpected, swapHost(gpa, "postgresql://other/db", "h.neon.tech", "x"));
}

test "toPsycopgUrl rejects unknown scheme" {
    const gpa = testing.allocator;
    try testing.expectError(Error.NeonOutputUnexpected, toPsycopgUrl(gpa, "mysql://h/db"));
}

test "parseCreate rejects malformed output" {
    const gpa = testing.allocator;
    try testing.expectError(Error.NeonOutputUnexpected, parseCreate(gpa, "{}"));
    try testing.expectError(Error.NeonOutputUnexpected, parseCreate(gpa, "not json"));
}
