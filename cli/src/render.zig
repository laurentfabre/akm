//! Minimal mustache-flavored template engine.
//!
//! We own the templates, so the dialect is deliberately tiny:
//!   - `{{ key }}`            → substitute a context value (whitespace tolerant)
//!   - `{{#if key}}…{{/if}}`  → include body iff `key` is truthy
//!   - `{{#unless key}}…{{/unless}}` → include body iff `key` is falsy
//!
//! Truthy = key present AND value not one of "", "false", "0".
//! Conditionals may nest. An unknown `{{ key }}` is an error (fail loud, not silent).

const std = @import("std");

pub const Context = struct {
    map: std.StringHashMap([]const u8),

    pub fn init(gpa: std.mem.Allocator) Context {
        return .{ .map = std.StringHashMap([]const u8).init(gpa) };
    }
    pub fn deinit(self: *Context) void {
        self.map.deinit();
    }
    pub fn put(self: *Context, key: []const u8, value: []const u8) !void {
        try self.map.put(key, value);
    }
    fn truthy(self: *const Context, key: []const u8) bool {
        const v = self.map.get(key) orelse return false;
        if (v.len == 0) return false;
        if (std.mem.eql(u8, v, "false")) return false;
        if (std.mem.eql(u8, v, "0")) return false;
        return true;
    }
};

pub const Error = error{
    UnclosedTag,
    UnknownVariable,
    UnbalancedBlock,
    OutOfMemory,
};

pub fn render(gpa: std.mem.Allocator, template: []const u8, ctx: *const Context) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pos: usize = 0;
    try renderInto(gpa, &out, template, &pos, ctx, null);
    if (pos != template.len) return Error.UnbalancedBlock; // stray {{/...}}
    return out.toOwnedSlice(gpa);
}

/// Render until end-of-input or, when `stop_tag` is set, until the matching
/// `{{/stop_tag}}` (consumed). Advances `pos`.
fn renderInto(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tmpl: []const u8,
    pos: *usize,
    ctx: *const Context,
    stop_tag: ?[]const u8,
) Error!void {
    while (pos.* < tmpl.len) {
        const open = std.mem.indexOfPos(u8, tmpl, pos.*, "{{") orelse {
            try out.appendSlice(gpa, tmpl[pos.*..]);
            pos.* = tmpl.len;
            return;
        };
        try out.appendSlice(gpa, tmpl[pos.*..open]);
        const close = std.mem.indexOfPos(u8, tmpl, open + 2, "}}") orelse return Error.UnclosedTag;
        const raw = std.mem.trim(u8, tmpl[open + 2 .. close], " \t");
        pos.* = close + 2;

        if (raw.len == 0) return Error.UnknownVariable;

        switch (raw[0]) {
            '#' => {
                // Block open: "#if key" or "#unless key"
                const spec = std.mem.trim(u8, raw[1..], " \t");
                const kind, const key = splitKeyword(spec) orelse return Error.UnbalancedBlock;
                const want = if (std.mem.eql(u8, kind, "if"))
                    ctx.truthy(key)
                else if (std.mem.eql(u8, kind, "unless"))
                    !ctx.truthy(key)
                else
                    return Error.UnbalancedBlock;

                if (want) {
                    try renderInto(gpa, out, tmpl, pos, ctx, kind);
                } else {
                    try skipBlock(tmpl, pos, kind);
                }
            },
            '/' => {
                // Block close.
                const kind = std.mem.trim(u8, raw[1..], " \t");
                if (stop_tag) |st| {
                    if (std.mem.eql(u8, st, kind)) return; // matched: stop here
                }
                return Error.UnbalancedBlock;
            },
            else => {
                const v = ctx.map.get(raw) orelse return Error.UnknownVariable;
                try out.appendSlice(gpa, v);
            },
        }
    }
    if (stop_tag != null) return Error.UnbalancedBlock; // hit EOF inside a block
}

/// Skip the body of a non-taken block, honoring nesting of the same kind.
fn skipBlock(tmpl: []const u8, pos: *usize, kind: []const u8) Error!void {
    // Track ALL nested block kinds with a stack (not just `kind`), so an
    // interleaved tag like `{{#if a}}{{#unless b}}{{/if}}` is reported as
    // unbalanced rather than silently closed at the wrong level.
    var stack: [64][]const u8 = undefined;
    var depth: usize = 1;
    stack[0] = kind;
    while (pos.* < tmpl.len) {
        const open = std.mem.indexOfPos(u8, tmpl, pos.*, "{{") orelse return Error.UnbalancedBlock;
        const close = std.mem.indexOfPos(u8, tmpl, open + 2, "}}") orelse return Error.UnclosedTag;
        const raw = std.mem.trim(u8, tmpl[open + 2 .. close], " \t");
        pos.* = close + 2;
        if (raw.len == 0) continue;
        if (raw[0] == '#') {
            const spec = std.mem.trim(u8, raw[1..], " \t");
            const k, _ = splitKeyword(spec) orelse continue;
            if (depth >= stack.len) return Error.UnbalancedBlock; // nesting too deep
            stack[depth] = k;
            depth += 1;
        } else if (raw[0] == '/') {
            const k = std.mem.trim(u8, raw[1..], " \t");
            // A close must match the innermost open (LIFO), regardless of kind.
            if (depth == 0 or !std.mem.eql(u8, stack[depth - 1], k)) return Error.UnbalancedBlock;
            depth -= 1;
            if (depth == 0) return;
        }
    }
    return Error.UnbalancedBlock;
}

/// "if key" → ("if","key"); "unless key" → ("unless","key").
fn splitKeyword(spec: []const u8) ?struct { []const u8, []const u8 } {
    const sp = std.mem.indexOfScalar(u8, spec, ' ') orelse return null;
    const kind = spec[0..sp];
    const key = std.mem.trim(u8, spec[sp + 1 ..], " \t");
    if (key.len == 0) return null;
    return .{ kind, key };
}

// ── tests ──────────────────────────────────────────────────────────────────

test "substitution" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa);
    defer ctx.deinit();
    try ctx.put("name", "Pixel");
    const r = try render(gpa, "Hello {{ name }}!", &ctx);
    defer gpa.free(r);
    try std.testing.expectEqualStrings("Hello Pixel!", r);
}

test "if taken and not taken" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa);
    defer ctx.deinit();
    try ctx.put("ui", "true");
    try ctx.put("db", "");
    const r = try render(gpa, "a{{#if ui}}B{{/if}}{{#if db}}C{{/if}}d", &ctx);
    defer gpa.free(r);
    try std.testing.expectEqualStrings("aBd", r);
}

test "unless and nesting" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa);
    defer ctx.deinit();
    try ctx.put("ui", "true");
    try ctx.put("auth", "");
    const r = try render(gpa,
        \\{{#if ui}}ui[{{#unless auth}}no-auth{{/unless}}]{{/if}}
    , &ctx);
    defer gpa.free(r);
    try std.testing.expectEqualStrings("ui[no-auth]", r);
}

test "skipBlock rejects cross-kind mis-nesting in a skipped branch" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa);
    defer ctx.deinit();
    try ctx.put("off", ""); // falsy → the if-body is skipped
    try ctx.put("x", "true");
    // The skipped branch closes `if` while `unless` is still open → unbalanced.
    try std.testing.expectError(Error.UnbalancedBlock, render(gpa, "{{#if off}}{{#unless x}}{{/if}}OK", &ctx));
    // Properly nested skip still works.
    const r = try render(gpa, "{{#if off}}{{#unless x}}no{{/unless}}{{/if}}OK", &ctx);
    defer gpa.free(r);
    try std.testing.expectEqualStrings("OK", r);
}

test "unknown variable errors" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa);
    defer ctx.deinit();
    try std.testing.expectError(Error.UnknownVariable, render(gpa, "{{ missing }}", &ctx));
}

test "stray close errors" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa);
    defer ctx.deinit();
    try std.testing.expectError(Error.UnbalancedBlock, render(gpa, "x{{/if}}", &ctx));
}
