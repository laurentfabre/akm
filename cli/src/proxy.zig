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

/// Upper bound on header lines per request/response — bounds the parse loop
/// against a client/upstream that streams headers forever (arena OOM).
const max_headers = 200;
/// Aggregate cap on the request head (request line + all header lines). Bounds
/// per-connection memory regardless of header *count* (200 × ~32KiB would be
/// huge × many connections).
const max_head_bytes = 64 * 1024;

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
// Concurrency note: each connection is handled on its own OS thread sharing the
// process `io` handle. This is sound for the standard threaded `Io` (the default
// from `std.process.Init`), which serves blocking ops per-thread on independent
// fds; it would NOT be sound under a single-threaded event-loop `Io`. akm always
// runs on the threaded `Io`.
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
        // Bound concurrent handlers. Each connection is one OS thread plus two
        // `buf_size` buffers and blocks in header reads with no per-read deadline,
        // so a slow/withholding peer could otherwise exhaust threads/fds/memory.
        // This is a localhost-only dev proxy (attacker needs local code-exec), so
        // a hard cap is a sufficient, cheap bound; refuse beyond it.
        if (active_conns.fetchAdd(1, .acq_rel) >= max_conns) {
            _ = active_conns.fetchSub(1, .acq_rel);
            std.log.warn("akm dev: >{d} concurrent connections, refusing", .{max_conns});
            stream.close(io);
            continue;
        }
        // Detach: the handler owns the connection's lifetime and resources, and
        // releases its slot (active_conns) on exit.
        const t = std.Thread.spawn(.{}, connThread, .{ io, cfg, stream }) catch |err| {
            _ = active_conns.fetchSub(1, .acq_rel);
            std.log.warn("akm dev: cannot spawn handler: {s}", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        t.detach();
    }

    // Drain in-flight handlers before returning so none outlives the caller-owned
    // Config (e.g. cfg.minter.key, freed by dev.run on unwind). Bounded (~1s) so
    // a stuck connection can't hang shutdown.
    var spins: usize = 0;
    while (active_conns.load(.acquire) > 0 and spins < 100) : (spins += 1) {
        io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch break;
    }
}

/// Max concurrent connection handlers (see the accept loop). A localhost dev
/// proxy never needs many; the cap bounds resource exhaustion.
const max_conns = 256;
var active_conns = std.atomic.Value(usize).init(0);

fn connThread(io: std.Io, cfg: Config, client: net.Stream) void {
    defer _ = active_conns.fetchSub(1, .acq_rel); // release the slot taken in run()
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
        error.EndOfStream => {},
        // A broken pipe mid-relay is usually a hangup too, but during bring-up
        // it can also be a real relay defect — keep it visible at debug level.
        error.ReadFailed, error.WriteFailed => std.log.debug("akm dev: relay io error: {s}", .{@errorName(err)}),
        else => std.log.warn("akm dev: request error: {s}", .{@errorName(err)}),
    };
    cw.flush() catch {};
}

const Header = struct { name: []const u8, value: []const u8 };

/// The parsed HTTP request head. All slices are owned by the allocator passed to
/// `parseRequestHead`; `method`/`target` point into `request_line`.
const RequestHead = struct {
    request_line: []const u8,
    method: []const u8,
    target: []const u8,
    headers: []Header,
    content_length: ?u64,
    chunked: bool,
    is_upgrade: bool,
};

/// True iff `list` (a comma-separated header value like `keep-alive, Upgrade`)
/// contains `tok` as a whole, case-insensitive token — not a substring (so
/// `notupgrade` does NOT match `upgrade`).
fn hasToken(list: []const u8, tok: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| if (eqlIc(std.mem.trim(u8, raw, " \t"), tok)) return true;
    return false;
}

/// True iff `s` is non-empty and all ASCII digits (a valid HTTP token like
/// Content-Length: 1*DIGIT). Rejects empty, signs (`+5`/`-0`), and stray bytes.
fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Read and validate an HTTP/1.1 request head from `r`. Pure (no sockets): the
/// reader can be a real connection or `std.Io.Reader.fixed(bytes)` in tests.
/// Enforces the framing rules the proxy depends on (bounded headers, no
/// malformed/ambiguous Content-Length) so smuggling can't slip through.
fn parseRequestHead(a: std.mem.Allocator, r: *std.Io.Reader) !RequestHead {
    const request_line = try a.dupe(u8, trimCrlf(try r.takeDelimiterInclusive('\n')));
    var head_bytes: usize = request_line.len; // aggregate head size cap (see below)
    var rl = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method = rl.next() orelse return error.BadRequest;
    const target = rl.next() orelse return error.BadRequest;

    var headers: std.ArrayList(Header) = .empty;
    var content_length: ?u64 = null;
    var chunked = false;
    var has_te = false;
    var has_upgrade = false;
    var conn_upgrade = false;

    while (true) {
        const line = trimCrlf(try r.takeDelimiterInclusive('\n'));
        if (line.len == 0) break;
        if (headers.items.len >= max_headers) return error.TooManyHeaders; // bound the loop
        head_bytes += line.len;
        if (head_bytes > max_head_bytes) return error.HeadTooLarge; // bound total bytes, not just count
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (eqlIc(name, "content-length")) {
            // Content-Length must be 1*DIGIT (RFC 9112 §6.1). parseInt alone
            // accepts `+5`/`-0`, a parser-differential smuggling surface — so
            // require bare digits first. A present-but-malformed CL must fail,
            // not silently become "no length".
            if (!isAllDigits(value)) return error.BadRequest;
            const parsed = std.fmt.parseInt(u64, value, 10) catch return error.BadRequest;
            // A *conflicting* duplicate Content-Length is the classic CL/CL
            // smuggling vector (RFC 9112 §6.3): reject rather than last-wins.
            if (content_length) |existing| {
                if (existing != parsed) return error.BadRequest;
            } else content_length = parsed;
        } else if (eqlIc(name, "transfer-encoding")) {
            // `chunked` (exactly, as the sole coding) is all the proxy frames.
            // Reject multiple TE headers and any value that isn't exactly
            // `chunked` (e.g. `gzip`, `xchunked`, `chunked, gzip`) — substring
            // matching here would be a parser-differential smuggling surface.
            if (has_te) return error.BadRequest; // multiple Transfer-Encoding headers
            has_te = true;
            chunked = eqlIc(value, "chunked");
        } else if (eqlIc(name, "connection")) {
            // Token-match, not substring: `Connection: notupgrade` must NOT count
            // as an upgrade (it would skip request-body forwarding and can pin a
            // handler against a body-reading upstream).
            if (hasToken(value, "upgrade")) conn_upgrade = true;
        } else if (eqlIc(name, "upgrade")) {
            has_upgrade = true;
        }
        try headers.append(a, .{ .name = try a.dupe(u8, name), .value = try a.dupe(u8, value) });
    }
    // RFC 9112 §6.1: ANY Transfer-Encoding + Content-Length together is a
    // smuggling vector — reject rather than guess which framing wins (not just
    // `chunked` + CL: e.g. `Transfer-Encoding: gzip` + CL must fail too).
    if (has_te and content_length != null) return error.BadRequest;
    // `chunked` is the only request transfer-coding the proxy frames. A TE the
    // proxy doesn't understand (e.g. `gzip`, or chunked-not-final) would be
    // forwarded with no body and can deadlock a close-delimited upstream — reject.
    if (has_te and !chunked) return error.BadRequest;
    // An upgrade request carrying a body is ambiguous (we forward no body on
    // upgrade); reject rather than risk a framing desync.
    const is_upgrade = has_upgrade and conn_upgrade;
    if (is_upgrade and (content_length != null or has_te)) return error.BadRequest;

    return .{
        .request_line = request_line,
        .method = method,
        .target = target,
        .headers = try headers.toOwnedSlice(a),
        .content_length = content_length,
        .chunked = chunked,
        .is_upgrade = is_upgrade,
    };
}

fn serve(
    io: std.Io,
    cfg: Config,
    a: std.mem.Allocator,
    client: net.Stream,
    cr: *std.Io.Reader,
    cw: *std.Io.Writer,
) !void {
    // Parse the request head (pure + table-tested — see parseRequestHead).
    const head = try parseRequestHead(a, cr);
    const request_line = head.request_line;
    const method = head.method;
    const target = head.target;
    const headers = head.headers;
    const req_content_length = head.content_length;
    const req_chunked = head.chunked;
    const is_upgrade = head.is_upgrade;

    const to_backend = std.mem.startsWith(u8, target, "/api");
    const upstream_port = if (to_backend) cfg.backend_port else cfg.vite_port;

    // ── build the rewritten head for the upstream ─────────────────────────
    var fh: std.Io.Writer.Allocating = .init(a);
    try fh.writer.print("{s}\r\n", .{request_line});
    for (headers) |h| {
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
    if (status == 0) {
        // Upstream sent an unparseable status line — emit a clean 502 rather
        // than relaying a head we don't understand (framing-desync surface).
        try cw.print(
            "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nakm dev: malformed upstream response\n",
            .{},
        );
        return;
    }
    try cw.writeAll(status_line);

    var resp_content_length: ?u64 = null;
    var resp_chunked = false;
    var resp_headers: usize = 0;
    while (true) {
        const line = try ur.takeDelimiterInclusive('\n');
        try cw.writeAll(line);
        const t = trimCrlf(line);
        if (t.len == 0) break;
        resp_headers += 1;
        if (resp_headers > max_headers) return error.TooManyHeaders; // bound the loop
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
    // ONLY a real 101 may tunnel: if the client asked to upgrade but the upstream
    // declined (200/400/404/…), tunneling raw would ignore the response framing
    // and hang the connection — fall through to a normal framed relay instead.
    if (status == 101) {
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
            var trailers: usize = 0;
            while (true) {
                const line = try src.takeDelimiterInclusive('\n');
                try dst.writeAll(line);
                if (trimCrlf(line).len == 0) break;
                trailers += 1;
                if (trailers > max_headers) return error.TooManyHeaders; // bound trailers
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

test "hasToken matches whole comma tokens, not substrings" {
    try testing.expect(hasToken("Upgrade", "upgrade"));
    try testing.expect(hasToken("keep-alive, Upgrade", "upgrade"));
    try testing.expect(!hasToken("notupgrade", "upgrade")); // substring must not match
    try testing.expect(!hasToken("upgraded", "upgrade"));
}

test "trimCrlf strips line endings only on the right" {
    try testing.expectEqualStrings("a: b", trimCrlf("a: b\r\n"));
    try testing.expectEqualStrings("", trimCrlf("\r\n"));
}

/// Parse `raw` with an arena so the test doesn't free each owned slice by hand.
fn parseHeadTest(arena: std.mem.Allocator, raw: []const u8) !RequestHead {
    var r = std.Io.Reader.fixed(raw);
    return parseRequestHead(arena, &r);
}

test "parseRequestHead: valid GET, no body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const h = try parseHeadTest(arena.allocator(), "GET /api/health HTTP/1.1\r\nHost: x\r\nAccept: */*\r\n\r\n");
    try testing.expectEqualStrings("GET", h.method);
    try testing.expectEqualStrings("/api/health", h.target);
    try testing.expectEqual(@as(usize, 2), h.headers.len);
    try testing.expect(h.content_length == null and !h.chunked and !h.is_upgrade);
}

test "parseRequestHead: Content-Length parsed; chunked detected; upgrade detected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cl = try parseHeadTest(a, "POST /api/x HTTP/1.1\r\nContent-Length: 7\r\n\r\n");
    try testing.expectEqual(@as(?u64, 7), cl.content_length);
    const ch = try parseHeadTest(a, "POST /api/x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n");
    try testing.expect(ch.chunked);
    const up = try parseHeadTest(a, "GET / HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n");
    try testing.expect(up.is_upgrade);
    // `Connection: notupgrade` is NOT an upgrade (token match, not substring)
    const nu = try parseHeadTest(a, "GET / HTTP/1.1\r\nConnection: notupgrade\r\nUpgrade: websocket\r\n\r\n");
    try testing.expect(!nu.is_upgrade);
    // an upgrade request carrying a body is rejected (ambiguous framing)
    try testing.expectError(error.BadRequest, parseHeadTest(a, "GET / HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nContent-Length: 5\r\n\r\n"));
}

test "parseRequestHead: rejects malformed/smuggling/oversized heads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // malformed Content-Length
    try testing.expectError(error.BadRequest, parseHeadTest(a, "GET / HTTP/1.1\r\nContent-Length: abc\r\n\r\n"));
    // CL + chunked together (smuggling)
    try testing.expectError(error.BadRequest, parseHeadTest(a, "POST / HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n"));
    // conflicting duplicate Content-Length (CL/CL smuggling)
    try testing.expectError(error.BadRequest, parseHeadTest(a, "POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 50\r\n\r\n"));
    // ANY Transfer-Encoding (not just chunked) + Content-Length is smuggling
    try testing.expectError(error.BadRequest, parseHeadTest(a, "POST / HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: gzip\r\n\r\n"));
    // Content-Length must be bare digits — a sign is a parser-differential vector
    try testing.expectError(error.BadRequest, parseHeadTest(a, "POST / HTTP/1.1\r\nContent-Length: +5\r\n\r\n"));
    try testing.expectError(error.BadRequest, parseHeadTest(a, "POST / HTTP/1.1\r\nContent-Length: -0\r\n\r\n"));
    // Transfer-Encoding must be exactly `chunked` — substrings/lists/dupes rejected
    try testing.expectError(error.BadRequest, parseHeadTest(a, "POST / HTTP/1.1\r\nTransfer-Encoding: xchunked\r\n\r\n"));
    try testing.expectError(error.BadRequest, parseHeadTest(a, "POST / HTTP/1.1\r\nTransfer-Encoding: chunked, gzip\r\n\r\n"));
    try testing.expectError(error.BadRequest, parseHeadTest(a, "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n"));
    // identical duplicate CL is tolerated (treated as one)
    const dup = try parseHeadTest(a, "POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n");
    try testing.expectEqual(@as(?u64, 5), dup.content_length);
    // request line with no target
    try testing.expectError(error.BadRequest, parseHeadTest(a, "GET\r\n\r\n"));
    // too many headers
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "GET / HTTP/1.1\r\n");
    for (0..max_headers + 5) |i| try buf.appendSlice(a, try std.fmt.allocPrint(a, "H{d}: v\r\n", .{i}));
    try buf.appendSlice(a, "\r\n");
    try testing.expectError(error.TooManyHeaders, parseHeadTest(a, buf.items));
}

test "parseRequestHead: garbage input never crashes or leaks" {
    // Poor-man's fuzz: feed many derived/truncated/garbled byte strings; the only
    // contract is no crash and no leak (testing.allocator catches leaks).
    const seeds = [_][]const u8{
        "GET / HTTP/1.1\r\nContent-Length: 9\r\n\r\n",
        "\r\n\r\n",
        ": novalue\r\n\r\n",
        "GET / HTTP/1.1\r\nX",
        "PUT /a HTTP/1.1\r\nConnection: upgrade\r\n\r\n",
    };
    var prng = std.Random.DefaultPrng.init(0xA11CE);
    const rnd = prng.random();
    for (seeds) |seed| {
        for (0..seed.len + 1) |cut| {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            // truncated prefix
            _ = parseHeadTest(arena.allocator(), seed[0..cut]) catch {};
            // a byte-flipped copy
            var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena2.deinit();
            const mut = arena2.allocator().dupe(u8, seed) catch continue;
            if (mut.len > 0) mut[rnd.uintLessThan(usize, mut.len)] = rnd.int(u8);
            _ = parseHeadTest(arena2.allocator(), mut) catch {};
        }
    }
}
