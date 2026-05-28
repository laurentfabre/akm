//! Mint the internal `X-Akm-Identity` assertion (see goal.md §4.5).
//!
//! In production the Cloudflare Worker mints this token after validating the
//! Access JWT; in local dev the akm proxy mints the *same* token so the
//! container's verification path (`identity.py`) is byte-for-byte identical.
//!
//! Schema (HS256, HMAC over `b64(header).b64(payload)`):
//!   header  = {"alg":"HS256","typ":"JWT"}
//!   payload = {"iss":"akm-worker","aud":"akm-backend",
//!              "iat":N,"nbf":N,"exp":N(≤iat+120),
//!              "sub":<principal>,"kind":"user"|"service"[,"email":<addr>]}

const std = @import("std");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64 = std.base64.url_safe_no_pad.Encoder;

pub const ISS = "akm-worker";
pub const AUD = "akm-backend";
/// Token lifetime in seconds. Kept at the schema ceiling (≤120 s, §4.5) so a
/// long-lived dev connection still re-mints frequently.
pub const TTL_SECONDS: i64 = 120;

pub const Kind = enum {
    user,
    service,

    fn str(self: Kind) []const u8 {
        return switch (self) {
            .user => "user",
            .service => "service",
        };
    }
};

/// A minter bound to one HMAC key. The key must match the container's
/// `AKM_INTERNAL_JWT_KEY`; akm owns the key in dev and passes it to the backend.
pub const Minter = struct {
    key: []const u8,

    /// Mint a token. Returns an owned slice; caller frees with `gpa`.
    /// `email` must be non-null iff `kind == .user` (§4.5).
    pub fn mint(
        self: Minter,
        gpa: std.mem.Allocator,
        sub: []const u8,
        kind: Kind,
        email: ?[]const u8,
        now: i64,
    ) ![]u8 {
        std.debug.assert((kind == .user) == (email != null));
        // The key crosses the trust boundary to the backend; a trivially short
        // HMAC key would make forgery cheap. Reject it loudly.
        std.debug.assert(self.key.len >= 16);

        const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";

        // Build the JSON payload into a plain ArrayList so allocation failure
        // surfaces as `error.OutOfMemory` (a `Writer.Allocating` would mask it as
        // `error.WriteFailed`). sub/email are JSON-string-escaped defensively.
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(gpa);
        const prefix = try std.fmt.allocPrint(
            gpa,
            "{{\"iss\":\"{s}\",\"aud\":\"{s}\",\"iat\":{d},\"nbf\":{d},\"exp\":{d},\"sub\":",
            .{ ISS, AUD, now, now, now + TTL_SECONDS },
        );
        defer gpa.free(prefix);
        try payload.appendSlice(gpa, prefix);
        try appendJsonString(gpa, &payload, sub);
        const kind_part = try std.fmt.allocPrint(gpa, ",\"kind\":\"{s}\"", .{kind.str()});
        defer gpa.free(kind_part);
        try payload.appendSlice(gpa, kind_part);
        if (email) |e| {
            try payload.appendSlice(gpa, ",\"email\":");
            try appendJsonString(gpa, &payload, e);
        }
        try payload.append(gpa, '}');

        // Assemble b64(header).b64(payload), HMAC it, append b64(sig).
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try appendB64(gpa, &out, header);
        try out.append(gpa, '.');
        try appendB64(gpa, &out, payload.items);

        var mac: [HmacSha256.mac_length]u8 = undefined;
        HmacSha256.create(&mac, out.items, self.key);

        try out.append(gpa, '.');
        try appendB64(gpa, &out, &mac);

        return out.toOwnedSlice(gpa);
    }
};

fn appendB64(gpa: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8) !void {
    const start = out.items.len;
    try out.resize(gpa, start + b64.calcSize(src.len));
    _ = b64.encode(out.items[start..], src);
}

/// Append a JSON-escaped string (minimal RFC 8259) to `out` — enough for the
/// sub/email values akm mints. Allocation failure propagates as OutOfMemory.
fn appendJsonString(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => if (c < 0x20) {
            var buf: [6]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable);
        } else try out.append(gpa, c),
    };
    try out.append(gpa, '"');
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn b64urlDecode(gpa: std.mem.Allocator, seg: []const u8) ![]u8 {
    const dec = std.base64.url_safe_no_pad.Decoder;
    const n = try dec.calcSizeForSlice(seg);
    const buf = try gpa.alloc(u8, n);
    try dec.decode(buf, seg);
    return buf;
}

test "mint produces three b64url segments with valid HMAC" {
    const gpa = testing.allocator;
    const m = Minter{ .key = "dev-secret-key-0123456789" };
    const tok = try m.mint(gpa, "dev@akm.local", .user, "dev@akm.local", 1_700_000_000);
    defer gpa.free(tok);

    var it = std.mem.splitScalar(u8, tok, '.');
    const h = it.next().?;
    const p = it.next().?;
    const s = it.next().?;
    try testing.expect(it.next() == null);

    // Signature verifies over "header.payload".
    var mac: [HmacSha256.mac_length]u8 = undefined;
    const signing_input = tok[0 .. h.len + 1 + p.len];
    HmacSha256.create(&mac, signing_input, m.key);
    const sig = try b64urlDecode(gpa, s);
    defer gpa.free(sig);
    try testing.expectEqualSlices(u8, &mac, sig);
}

test "user payload carries email and required claims" {
    const gpa = testing.allocator;
    const m = Minter{ .key = "test-key-0123456789ab" };
    const tok = try m.mint(gpa, "dev@akm.local", .user, "dev@akm.local", 1000);
    defer gpa.free(tok);

    var it = std.mem.splitScalar(u8, tok, '.');
    _ = it.next();
    const payload = try b64urlDecode(gpa, it.next().?);
    defer gpa.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings(ISS, obj.get("iss").?.string);
    try testing.expectEqualStrings(AUD, obj.get("aud").?.string);
    try testing.expectEqualStrings("user", obj.get("kind").?.string);
    try testing.expectEqualStrings("dev@akm.local", obj.get("email").?.string);
    try testing.expectEqual(@as(i64, 1000), obj.get("iat").?.integer);
    try testing.expectEqual(@as(i64, 1120), obj.get("exp").?.integer);
}

test "mint is OOM-safe (no leak on allocation failure)" {
    const Fn = struct {
        fn run(a: std.mem.Allocator) !void {
            const m = Minter{ .key = "test-key-0123456789ab" };
            const tok = try m.mint(a, "dev@akm.local", .user, "dev@akm.local", 1000);
            a.free(tok);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Fn.run, .{});
}

test "service token omits email" {
    const gpa = testing.allocator;
    const m = Minter{ .key = "test-key-0123456789ab" };
    const tok = try m.mint(gpa, "svc:ci", .service, null, 1000);
    defer gpa.free(tok);

    var it = std.mem.splitScalar(u8, tok, '.');
    _ = it.next();
    const payload = try b64urlDecode(gpa, it.next().?);
    defer gpa.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("service", parsed.value.object.get("kind").?.string);
    try testing.expect(parsed.value.object.get("email") == null);
}
