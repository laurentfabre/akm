//! The local dev reverse proxy (goal.md §2 / §4 sub-problem 3 / §4.5).
//!
//! One origin for the whole app: `/api/*` is forwarded to the FastAPI backend
//! (uvicorn), everything else to the Vite dev server. On every `/api` request
//! the proxy strips client-supplied identity headers and injects a freshly
//! minted `X-Akm-Identity` assertion, so the backend's auth path is identical to
//! production (where the Cloudflare Worker mints it).
//!
//! Design choices for robustness on bleeding-edge std:
//!   - Raw HTTP/1.1 (not std.http) so WebSocket upgrades become a transparent
//!     byte tunnel and per-request header rewriting stays under our control.
//!   - One request per client connection (`Connection: close` is forced to the
//!     upstream), which makes normal-response relay trivial. Browsers reconnect
//!     freely; on localhost this is free.
//!   - One OS thread per connection; each uses its own arena (no shared mutable
//!     allocator), so connections never contend.

const std = @import("std");
const jwt = @import("jwt.zig");

const net = std.Io.net;
const IpAddress = net.IpAddress;

/// Per-connection scratch buffer. Request/response heads must fit; 32 KiB is
/// far beyond any realistic header block.
const buf_size = 32 * 1024;

pub const Config = struct {
    proxy_port: u16,
    backend_port: u16,
    vite_port: u16,
    minter: jwt.Minter,
    /// Mock dev identity injected on /api requests.
    dev_user: []const u8,
};

/// Listen on 127.0.0.1:proxy_port and serve until `stop` is set. The caller is
/// responsible for waking a blocked `accept` (e.g. a self-connect) after setting
/// `stop`; we re-check the flag on every accepted connection.
pub fn run(io: std.Io, cfg: Config, stop: *std.atomic.Value(bool)) !void {
    const addr = IpAddress.parse("127.0.0.1", cfg.proxy_port) catch unreachable;
    var server = addr.listen(io, .{ .reuse_address = true }) catch |err| {
        std.log.err("akm dev: cannot bind 127.0.0.1:{d}: {s}", .{ cfg.proxy_port, @errorName(err) });
        return err;
    };
    defer server.deinit(io);

    while (!stop.load(.acquire)) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled, error.SocketNotListening => break,
            else => {
                std.log.warn("akm dev: accept failed: {s}", .{@errorName(err)});
                continue;
            },
        };
        if (stop.load(.acquire)) {
            stream.close(io);
            break;
        }
        // Detach: the handler owns the connection's lifetime and resources.
        const t = std.Thread.spawn(.{}, connThread, .{ io, cfg, stream }) catch |err| {
            std.log.warn("akm dev: cannot spawn handler: {s}", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        t.detach();
    }
}

fn connThread(io: std.Io, cfg: Config, client: net.Stream) void {
    defer client.close(io);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var cr_buf: [buf_size]u8 = undefined;
    var cw_buf: [buf_size]u8 = undefined;
    var cr_state = client.reader(io, &cr_buf);
    var cw_state = client.writer(io, &cw_buf);
    const cr = &cr_state.interface;
    const cw = &cw_state.interface;

    serve(io, cfg, arena.allocator(), client, cr, cw) catch |err| switch (err) {
        // A client that hangs up mid-request is normal; don't log it.
        error.EndOfStream, error.ReadFailed, error.WriteFailed => {},
        else => std.log.warn("akm dev: request error: {s}", .{@errorName(err)}),
    };
    cw.flush() catch {};
}

const Header = struct { name: []const u8, value: []const u8 };

fn serve(
    io: std.Io,
    cfg: Config,
    a: std.mem.Allocator,
    client: net.Stream,
    cr: *std.Io.Reader,
    cw: *std.Io.Writer,
) !void {
    // ── request line ──────────────────────────────────────────────────────
    const request_line = try a.dupe(u8, trimCrlf(try cr.takeDelimiterInclusive('\n')));
    var rl = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method = rl.next() orelse return error.BadRequest;
    const target = rl.next() orelse return error.BadRequest;

    const to_backend = std.mem.startsWith(u8, target, "/api");
    const upstream_port = if (to_backend) cfg.backend_port else cfg.vite_port;

    // ── request headers ───────────────────────────────────────────────────
    var headers: std.ArrayList(Header) = .empty;
    var req_content_length: ?u64 = null;
    var req_chunked = false;
    var has_upgrade = false;
    var conn_upgrade = false;

    while (true) {
        const line = trimCrlf(try cr.takeDelimiterInclusive('\n'));
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (eqlIc(name, "content-length")) {
            req_content_length = std.fmt.parseInt(u64, value, 10) catch null;
        } else if (eqlIc(name, "transfer-encoding") and containsIc(value, "chunked")) {
            req_chunked = true;
        } else if (eqlIc(name, "connection") and containsIc(value, "upgrade")) {
            conn_upgrade = true;
        } else if (eqlIc(name, "upgrade")) {
            has_upgrade = true;
        }
        try headers.append(a, .{
            .name = try a.dupe(u8, name),
            .value = try a.dupe(u8, value),
        });
    }
    const is_upgrade = has_upgrade and conn_upgrade;

    // ── build the rewritten head for the upstream ─────────────────────────
    var fh: std.Io.Writer.Allocating = .init(a);
    try fh.writer.print("{s}\r\n", .{request_line});
    for (headers.items) |h| {
        // §4.5: the backend never trusts client identity headers.
        if (to_backend and (startsWithIc(h.name, "cf-access-") or
            startsWithIc(h.name, "x-forwarded-") or startsWithIc(h.name, "x-akm-")))
            continue;
        // Hop-by-hop headers are dropped on normal requests; on an upgrade we
        // must preserve Connection/Upgrade so the handshake reaches the upstream.
        if (!is_upgrade and (eqlIc(h.name, "connection") or
            eqlIc(h.name, "keep-alive") or eqlIc(h.name, "proxy-connection")))
            continue;
        try fh.writer.print("{s}: {s}\r\n", .{ h.name, h.value });
    }
    if (to_backend) {
        const now = std.Io.Clock.now(.real, io).toSeconds();
        const token = try cfg.minter.mint(a, cfg.dev_user, .user, cfg.dev_user, now);
        try fh.writer.print("X-Akm-Identity: {s}\r\n", .{token});
    }
    if (!is_upgrade) try fh.writer.writeAll("Connection: close\r\n");
    try fh.writer.writeAll("\r\n");

    // ── connect upstream ──────────────────────────────────────────────────
    const up_addr = IpAddress.parse("127.0.0.1", upstream_port) catch unreachable;
    const upstream = up_addr.connect(io, .{ .mode = .stream }) catch {
        try writeGatewayError(cw, to_backend, upstream_port);
        return;
    };
    defer upstream.close(io);

    var ur_buf: [buf_size]u8 = undefined;
    var uw_buf: [buf_size]u8 = undefined;
    var ur_state = upstream.reader(io, &ur_buf);
    var uw_state = upstream.writer(io, &uw_buf);
    const ur = &ur_state.interface;
    const uw = &uw_state.interface;

    try uw.writeAll(fh.written());
    if (!is_upgrade) {
        if (req_chunked) {
            try copyChunked(cr, uw);
        } else if (req_content_length) |n| {
            try cr.streamExact(uw, n);
        }
    }
    try uw.flush();

    // ── relay response ────────────────────────────────────────────────────
    const status_line = try ur.takeDelimiterInclusive('\n');
    const status = parseStatus(status_line);
    try cw.writeAll(status_line);

    var resp_content_length: ?u64 = null;
    var resp_chunked = false;
    while (true) {
        const line = try ur.takeDelimiterInclusive('\n');
        try cw.writeAll(line);
        const t = trimCrlf(line);
        if (t.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
        const name = std.mem.trim(u8, t[0..colon], " \t");
        const value = std.mem.trim(u8, t[colon + 1 ..], " \t");
        if (eqlIc(name, "content-length")) {
            resp_content_length = std.fmt.parseInt(u64, value, 10) catch null;
        } else if (eqlIc(name, "transfer-encoding") and containsIc(value, "chunked")) {
            resp_chunked = true;
        }
    }

    // 101 Switching Protocols → bidirectional byte tunnel (WebSocket / HMR).
    if (status == 101 or is_upgrade) {
        try cw.flush();
        tunnel(io, client, upstream, cr, cw, ur, uw);
        return;
    }

    // RFC 9112: HEAD and 204/304 carry no body.
    const no_body = eqlIc(method, "HEAD") or status == 204 or status == 304;
    if (!no_body) {
        if (resp_chunked) {
            try copyChunked(ur, cw);
        } else if (resp_content_length) |n| {
            try ur.streamExact(cw, n);
        } else {
            // No framing: rely on the upstream closing (we sent Connection: close).
            try pumpToEof(ur, cw);
        }
    }
    try cw.flush();
}

/// Copy an HTTP/1.1 chunked body verbatim from `src` to `dst`, including chunk
/// size lines, data, trailing CRLFs, and any trailer headers.
fn copyChunked(src: *std.Io.Reader, dst: *std.Io.Writer) !void {
    while (true) {
        const size_line = try src.takeDelimiterInclusive('\n');
        try dst.writeAll(size_line);
        const t = trimCrlf(size_line);
        const hex_end = std.mem.indexOfScalar(u8, t, ';') orelse t.len;
        const size = std.fmt.parseInt(u64, t[0..hex_end], 16) catch return error.BadChunk;
        if (size == 0) {
            // Trailer section: copy header lines through the terminating blank line.
            while (true) {
                const line = try src.takeDelimiterInclusive('\n');
                try dst.writeAll(line);
                if (trimCrlf(line).len == 0) break;
            }
            return;
        }
        try src.streamExact(dst, size);
        const crlf = try src.take(2); // the CRLF that closes each chunk
        try dst.writeAll(crlf);
    }
}

/// Copy from `src` to `dst` until `src` reaches EOF, flushing each read so
/// streamed/interactive responses aren't buffered.
fn pumpToEof(src: *std.Io.Reader, dst: *std.Io.Writer) !void {
    while (true) {
        const chunk = src.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        try dst.writeAll(chunk);
        src.toss(chunk.len);
        try dst.flush();
    }
}

const TunnelSide = struct {
    src: *std.Io.Reader,
    dst: *std.Io.Writer,
    a_stream: net.Stream,
    b_stream: net.Stream,
    io: std.Io,
};

/// Bidirectional raw byte tunnel for an upgraded (WebSocket) connection. One
/// direction runs on a helper thread; when either side closes we shut down both
/// sockets to unblock the other, then join.
fn tunnel(
    io: std.Io,
    client: net.Stream,
    upstream: net.Stream,
    cr: *std.Io.Reader,
    cw: *std.Io.Writer,
    ur: *std.Io.Reader,
    uw: *std.Io.Writer,
) void {
    var up_to_client = TunnelSide{ .src = ur, .dst = cw, .a_stream = client, .b_stream = upstream, .io = io };
    const t = std.Thread.spawn(.{}, tunnelSide, .{&up_to_client}) catch {
        // Fall back to a single direction rather than failing outright.
        var only = TunnelSide{ .src = cr, .dst = uw, .a_stream = client, .b_stream = upstream, .io = io };
        tunnelSide(&only);
        return;
    };
    var client_to_up = TunnelSide{ .src = cr, .dst = uw, .a_stream = client, .b_stream = upstream, .io = io };
    tunnelSide(&client_to_up);
    t.join();
}

fn tunnelSide(s: *TunnelSide) void {
    pumpToEof(s.src, s.dst) catch {};
    // Unblock the opposite direction: both sockets, both ways. Idempotent.
    s.a_stream.shutdown(s.io, .both) catch {};
    s.b_stream.shutdown(s.io, .both) catch {};
}

fn writeGatewayError(cw: *std.Io.Writer, to_backend: bool, port: u16) !void {
    const who = if (to_backend) "backend (uvicorn)" else "Vite dev server";
    var body: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer body.deinit();
    try body.writer.print("akm dev: cannot reach {s} on 127.0.0.1:{d}.\n", .{ who, port });
    try cw.print(
        "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.written().len, body.written() },
    );
}

// ── small helpers ─────────────────────────────────────────────────────────

fn trimCrlf(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r\n");
}

fn parseStatus(status_line: []const u8) u16 {
    var it = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = it.next(); // HTTP/1.1
    const code = it.next() orelse return 0;
    return std.fmt.parseInt(u16, code, 10) catch 0;
}

fn eqlIc(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn startsWithIc(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

fn containsIc(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseStatus reads the code" {
    try testing.expectEqual(@as(u16, 200), parseStatus("HTTP/1.1 200 OK"));
    try testing.expectEqual(@as(u16, 101), parseStatus("HTTP/1.1 101 Switching Protocols"));
    try testing.expectEqual(@as(u16, 0), parseStatus("garbage"));
}

test "header helpers are case-insensitive" {
    try testing.expect(eqlIc("Content-Length", "content-length"));
    try testing.expect(startsWithIc("Cf-Access-Jwt-Assertion", "cf-access-"));
    try testing.expect(startsWithIc("X-Akm-Identity", "x-akm-"));
    try testing.expect(!startsWithIc("X-Real-Ip", "x-akm-"));
    try testing.expect(containsIc("Upgrade, keep-alive", "upgrade"));
    try testing.expect(!containsIc("keep-alive", "upgrade"));
}

test "trimCrlf strips line endings only on the right" {
    try testing.expectEqualStrings("a: b", trimCrlf("a: b\r\n"));
    try testing.expectEqualStrings("", trimCrlf("\r\n"));
}
