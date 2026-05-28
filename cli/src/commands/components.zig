//! `akm components` — add shadcn/ui components to the app's UI (goal.md §4).
//!
//! Native HTTP + file writes (no shadcn CLI): `add` fetches a registry item over
//! HTTPS, writes its files into `ui/`, resolves `registryDependencies`, and
//! installs the npm `dependencies`. `init` makes the bare scaffold shadcn-ready
//! (Tailwind v4 + `cn` util + `@/` alias + components.json) — opt-in, so the base
//! template stays lean.

const std = @import("std");
const main = @import("../main.zig");
const project = @import("../project.zig");

const say = main.say;

/// shadcn registry base; `{style}`/`{name}` filled per item.
const registry_base = "https://ui.shadcn.com/r/styles";
const default_style = "new-york";

pub fn run(gpa: std.mem.Allocator, args: []const []const u8) !void {
    const io = main.io;
    if (args.len == 0) {
        usage();
        return error.BadArgs;
    }
    const sub = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, sub, "init")) {
        try initCmd(gpa, io, dirArg(rest));
    } else if (std.mem.eql(u8, sub, "add")) {
        try addCmd(gpa, io, rest);
    } else {
        usage();
        return error.BadArgs;
    }
}

fn usage() void {
    say(
        \\Usage:
        \\  akm components init [dir]          Make the app shadcn-ready (Tailwind + cn + aliases)
        \\  akm components add <name…> [dir]   Fetch shadcn components into ui/components/ui/
        \\
    );
}

/// Last positional arg that isn't a flag is the project dir (default ".").
fn dirArg(args: []const []const u8) []const u8 {
    var dir: []const u8 = ".";
    for (args) |a| if (!std.mem.startsWith(u8, a, "-")) {
        dir = a;
    };
    return dir;
}

// ── init ────────────────────────────────────────────────────────────────────

fn initCmd(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
    var proj = try project.openProject(io, dir);
    defer proj.close(io);

    say("akm components: making the app shadcn-ready …\n");

    try writeIfAbsent(gpa, io, proj, "components.json", components_json);
    try proj.createDirPath(io, "ui/lib");
    try writeIfAbsent(gpa, io, proj, "ui/lib/utils.ts", utils_ts);
    try writeIfAbsent(gpa, io, proj, "ui/globals.css", globals_css);

    // Idempotent, anchor-guarded config patches (fall back to a printed snippet).
    try patch(gpa, io, proj, "vite.config.ts", "@tailwindcss/vite",
        "import react from \"@vitejs/plugin-react\";",
        "import react from \"@vitejs/plugin-react\";\nimport tailwindcss from \"@tailwindcss/vite\";\nimport path from \"node:path\";",
        "add the @tailwindcss/vite plugin import to vite.config.ts");
    try patch(gpa, io, proj, "vite.config.ts", "tailwindcss()",
        "plugins: [react()],",
        "plugins: [react(), tailwindcss()],\n  resolve: { alias: { \"@\": path.resolve(import.meta.dirname, \"ui\") } },",
        "add tailwindcss() to plugins and a \"@\" -> ui resolve.alias in vite.config.ts");
    try patch(gpa, io, proj, "tsconfig.json", "\"@/*\"",
        "\"compilerOptions\": {",
        "\"compilerOptions\": {\n    \"baseUrl\": \".\",\n    \"paths\": { \"@/*\": [\"ui/*\"] },",
        "add baseUrl \".\" and paths { \"@/*\": [\"ui/*\"] } to tsconfig.json compilerOptions");
    try patch(gpa, io, proj, "tsconfig.json", "\"src\", \"ui\"",
        "\"include\": [\"src\"]",
        "\"include\": [\"src\", \"ui\"]",
        "add \"ui\" to the include array in tsconfig.json");
    try patch(gpa, io, proj, "ui/main.tsx", "globals.css",
        "import { StrictMode",
        "import \"./globals.css\";\nimport { StrictMode",
        "add `import \"./globals.css\";` to the top of ui/main.tsx");

    try npmInstall(gpa, io, dir, &.{
        "tailwindcss",            "@tailwindcss/vite", "clsx",
        "tailwind-merge",         "class-variance-authority",
        "lucide-react",           "tw-animate-css",
    });

    say("\nakm components: shadcn-ready. Next: akm components add button\n");
}

// ── add ─────────────────────────────────────────────────────────────────────

const RegFile = struct {
    path: []const u8,
    content: []const u8 = "",
};
const RegistryItem = struct {
    name: []const u8 = "",
    dependencies: [][]const u8 = &.{},
    registryDependencies: [][]const u8 = &.{},
    files: []RegFile = &.{},
};

fn addCmd(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    // Collect requested component names (positional, non-flag) and the dir.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var dir: []const u8 = ".";
    for (args) |a| {
        if (std.mem.startsWith(u8, a, "-")) continue;
        // Heuristic: an existing path is the dir; otherwise a component name.
        if (std.Io.Dir.cwd().access(io, a, .{})) |_| dir = a else |_| try names.append(gpa, a);
    }
    if (names.items.len == 0) {
        say("akm components add: name a component, e.g. `akm components add button`\n");
        return error.BadArgs;
    }

    var proj = try project.openProject(io, dir);
    defer proj.close(io);
    proj.access(io, "components.json", .{}) catch {
        say("akm components: not shadcn-ready — run `akm components init` first.\n");
        return error.NotInitialized;
    };
    const style = try readStyle(gpa, io, proj);
    defer gpa.free(style);

    var visited = std.StringHashMap(void).init(gpa);
    defer freeKeys(&visited);
    var npm_deps = std.StringHashMap(void).init(gpa);
    defer freeKeys(&npm_deps);

    // BFS queue of component names to fetch (owned dupes).
    var queue: std.ArrayList([]const u8) = .empty;
    defer {
        for (queue.items) |n| gpa.free(n);
        queue.deinit(gpa);
    }
    for (names.items) |n| try queue.append(gpa, try gpa.dupe(u8, n));

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const name = queue.items[head];
        if (visited.contains(name)) continue;
        try visited.put(try gpa.dupe(u8, name), {});
        try fetchAndWrite(gpa, io, proj, style, name, &npm_deps, &queue, &visited);
    }

    // Install all collected npm deps in one shot.
    if (npm_deps.count() > 0) {
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(gpa);
        var it = npm_deps.keyIterator();
        while (it.next()) |k| try list.append(gpa, k.*);
        try npmInstall(gpa, io, dir, list.items);
    }
    say("\nakm components: done.\n");
}

fn fetchAndWrite(
    gpa: std.mem.Allocator,
    io: std.Io,
    proj: std.Io.Dir,
    style: []const u8,
    name: []const u8,
    npm_deps: *std.StringHashMap(void),
    queue: *std.ArrayList([]const u8),
    visited: *std.StringHashMap(void),
) !void {
    const url = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}.json", .{ registry_base, style, name });
    defer gpa.free(url);
    say2("akm components: fetch ", name);
    say("\n");

    const body = httpGetJson(gpa, io, url) catch |err| {
        say2("akm components: fetch failed for '", name);
        say2("': ", @errorName(err));
        say("\n");
        return err;
    };
    defer gpa.free(body);

    const parsed = std.json.parseFromSlice(RegistryItem, gpa, body, .{ .ignore_unknown_fields = true }) catch {
        say2("akm components: unexpected registry JSON for '", name);
        say("'\n");
        return error.RegistryParse;
    };
    defer parsed.deinit();
    const item = parsed.value;

    for (item.files) |f| {
        const dest = try mapPath(gpa, f.path);
        defer gpa.free(dest);
        if (std.fs.path.dirnamePosix(dest)) |d| try proj.createDirPath(io, d);
        try proj.writeFile(io, .{ .sub_path = dest, .data = f.content });
        say2("  + ", dest);
        say("\n");
    }
    for (item.dependencies) |d| {
        if (!npm_deps.contains(d)) try npm_deps.put(try gpa.dupe(u8, d), {});
    }
    for (item.registryDependencies) |rd| {
        if (std.mem.eql(u8, rd, "utils")) continue; // provided by `init`
        if (std.mem.indexOfScalar(u8, rd, '/') != null or std.mem.startsWith(u8, rd, "@")) {
            say2("akm components: skipping non-name registry dep ", rd);
            say(" (add it manually)\n");
            continue;
        }
        if (!visited.contains(rd)) try queue.append(gpa, try gpa.dupe(u8, rd));
    }
}

/// Map a registry file path to its location under `ui/` (alias rules).
fn mapPath(gpa: std.mem.Allocator, registry_path: []const u8) ![]u8 {
    var p = registry_path;
    if (std.mem.startsWith(u8, p, "registry/")) {
        // strip "registry/<style>/"
        if (std.mem.indexOfScalarPos(u8, p, "registry/".len, '/')) |slash| p = p[slash + 1 ..];
    }
    const slash = std.mem.indexOfScalar(u8, p, '/') orelse return std.fmt.allocPrint(gpa, "ui/{s}", .{p});
    const top = p[0..slash];
    const rest = p[slash + 1 ..];
    const mapped: []const u8 = if (std.mem.eql(u8, top, "ui")) "components/ui" else top; // others pass through
    return std.fmt.allocPrint(gpa, "ui/{s}/{s}", .{ mapped, rest });
}

fn httpGetJson(gpa: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    });
    if (res.status != .ok) {
        say2("akm components: registry returned ", @tagName(res.status));
        say("\n");
        return error.HttpStatus;
    }
    return body.toOwnedSlice();
}

fn readStyle(gpa: std.mem.Allocator, io: std.Io, proj: std.Io.Dir) ![]u8 {
    const bytes = proj.readFileAlloc(io, "components.json", gpa, .limited(1 << 20)) catch
        return gpa.dupe(u8, default_style);
    defer gpa.free(bytes);
    const Conf = struct { style: []const u8 = default_style };
    const parsed = std.json.parseFromSlice(Conf, gpa, bytes, .{ .ignore_unknown_fields = true }) catch
        return gpa.dupe(u8, default_style);
    defer parsed.deinit();
    return gpa.dupe(u8, parsed.value.style);
}

// ── shared helpers ────────────────────────────────────────────────────────────

fn writeIfAbsent(gpa: std.mem.Allocator, io: std.Io, proj: std.Io.Dir, path: []const u8, data: []const u8) !void {
    _ = gpa;
    if (proj.access(io, path, .{})) |_| {
        say2("  · ", path);
        say(" exists, kept\n");
        return;
    } else |_| {}
    try proj.writeFile(io, .{ .sub_path = path, .data = data });
    say2("  + ", path);
    say("\n");
}

/// Read `path`; if `guard` is already present, no-op. Else replace the first
/// `anchor` with `replacement` and write back. If `anchor` is missing, print the
/// manual hint rather than corrupting the file.
fn patch(
    gpa: std.mem.Allocator,
    io: std.Io,
    proj: std.Io.Dir,
    path: []const u8,
    guard: []const u8,
    anchor: []const u8,
    replacement: []const u8,
    manual_hint: []const u8,
) !void {
    const bytes = proj.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch {
        say2("akm components: cannot read ", path);
        say(" — manual step: ");
        say(manual_hint);
        say("\n");
        return;
    };
    defer gpa.free(bytes);
    if (std.mem.indexOf(u8, bytes, guard) != null) {
        say2("  · ", path);
        say(" already configured\n");
        return;
    }
    const at = std.mem.indexOf(u8, bytes, anchor) orelse {
        say2("akm components: could not patch ", path);
        say(" — manual step: ");
        say(manual_hint);
        say("\n");
        return;
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, bytes[0..at]);
    try out.appendSlice(gpa, replacement);
    try out.appendSlice(gpa, bytes[at + anchor.len ..]);
    try proj.writeFile(io, .{ .sub_path = path, .data = out.items });
    say2("  ~ patched ", path);
    say("\n");
}

fn npmInstall(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, pkgs: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "npm", "install" });
    try argv.appendSlice(gpa, pkgs);
    say("akm components: npm install …\n");
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .path = dir },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        say2("akm components: npm install failed to start: ", @errorName(err));
        say("\n");
        return err;
    };
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.NpmInstallFailed;
}

fn freeKeys(map: *std.StringHashMap(void)) void {
    var it = map.keyIterator();
    while (it.next()) |k| map.allocator.free(k.*);
    map.deinit();
}

fn say2(a: []const u8, b: []const u8) void {
    say(a);
    say(b);
}

// ── embedded shadcn-ready files ───────────────────────────────────────────────

const components_json =
    \\{
    \\  "$schema": "https://ui.shadcn.com/schema.json",
    \\  "style": "new-york",
    \\  "rsc": false,
    \\  "tsx": true,
    \\  "tailwind": {
    \\    "config": "",
    \\    "css": "ui/globals.css",
    \\    "baseColor": "neutral",
    \\    "cssVariables": true,
    \\    "prefix": ""
    \\  },
    \\  "aliases": {
    \\    "components": "@/components",
    \\    "utils": "@/lib/utils",
    \\    "ui": "@/components/ui",
    \\    "lib": "@/lib",
    \\    "hooks": "@/hooks"
    \\  }
    \\}
    \\
;

const utils_ts =
    \\import { clsx, type ClassValue } from "clsx";
    \\import { twMerge } from "tailwind-merge";
    \\
    \\export function cn(...inputs: ClassValue[]) {
    \\  return twMerge(clsx(inputs));
    \\}
    \\
;

// shadcn "new-york" / neutral theme for Tailwind v4 (CSS variables).
const globals_css =
    \\@import "tailwindcss";
    \\@import "tw-animate-css";
    \\
    \\@custom-variant dark (&:is(.dark *));
    \\
    \\:root {
    \\  --radius: 0.625rem;
    \\  --background: oklch(1 0 0);
    \\  --foreground: oklch(0.145 0 0);
    \\  --card: oklch(1 0 0);
    \\  --card-foreground: oklch(0.145 0 0);
    \\  --popover: oklch(1 0 0);
    \\  --popover-foreground: oklch(0.145 0 0);
    \\  --primary: oklch(0.205 0 0);
    \\  --primary-foreground: oklch(0.985 0 0);
    \\  --secondary: oklch(0.97 0 0);
    \\  --secondary-foreground: oklch(0.205 0 0);
    \\  --muted: oklch(0.97 0 0);
    \\  --muted-foreground: oklch(0.556 0 0);
    \\  --accent: oklch(0.97 0 0);
    \\  --accent-foreground: oklch(0.205 0 0);
    \\  --destructive: oklch(0.577 0.245 27.325);
    \\  --border: oklch(0.922 0 0);
    \\  --input: oklch(0.922 0 0);
    \\  --ring: oklch(0.708 0 0);
    \\}
    \\
    \\.dark {
    \\  --background: oklch(0.145 0 0);
    \\  --foreground: oklch(0.985 0 0);
    \\  --card: oklch(0.205 0 0);
    \\  --card-foreground: oklch(0.985 0 0);
    \\  --popover: oklch(0.205 0 0);
    \\  --popover-foreground: oklch(0.985 0 0);
    \\  --primary: oklch(0.922 0 0);
    \\  --primary-foreground: oklch(0.205 0 0);
    \\  --secondary: oklch(0.269 0 0);
    \\  --secondary-foreground: oklch(0.985 0 0);
    \\  --muted: oklch(0.269 0 0);
    \\  --muted-foreground: oklch(0.708 0 0);
    \\  --accent: oklch(0.269 0 0);
    \\  --accent-foreground: oklch(0.985 0 0);
    \\  --destructive: oklch(0.704 0.191 22.216);
    \\  --border: oklch(1 0 0 / 10%);
    \\  --input: oklch(1 0 0 / 15%);
    \\  --ring: oklch(0.556 0 0);
    \\}
    \\
    \\@theme inline {
    \\  --radius-sm: calc(var(--radius) - 4px);
    \\  --radius-md: calc(var(--radius) - 2px);
    \\  --radius-lg: var(--radius);
    \\  --radius-xl: calc(var(--radius) + 4px);
    \\  --color-background: var(--background);
    \\  --color-foreground: var(--foreground);
    \\  --color-card: var(--card);
    \\  --color-card-foreground: var(--card-foreground);
    \\  --color-popover: var(--popover);
    \\  --color-popover-foreground: var(--popover-foreground);
    \\  --color-primary: var(--primary);
    \\  --color-primary-foreground: var(--primary-foreground);
    \\  --color-secondary: var(--secondary);
    \\  --color-secondary-foreground: var(--secondary-foreground);
    \\  --color-muted: var(--muted);
    \\  --color-muted-foreground: var(--muted-foreground);
    \\  --color-accent: var(--accent);
    \\  --color-accent-foreground: var(--accent-foreground);
    \\  --color-destructive: var(--destructive);
    \\  --color-border: var(--border);
    \\  --color-input: var(--input);
    \\  --color-ring: var(--ring);
    \\}
    \\
    \\@layer base {
    \\  * {
    \\    border-color: var(--color-border);
    \\  }
    \\  body {
    \\    background-color: var(--color-background);
    \\    color: var(--color-foreground);
    \\  }
    \\}
    \\
;

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "mapPath alias rules" {
    const gpa = testing.allocator;
    const a = try mapPath(gpa, "ui/button.tsx");
    defer gpa.free(a);
    try testing.expectEqualStrings("ui/components/ui/button.tsx", a);

    const b = try mapPath(gpa, "lib/utils.ts");
    defer gpa.free(b);
    try testing.expectEqualStrings("ui/lib/utils.ts", b);

    const c = try mapPath(gpa, "hooks/use-toast.ts");
    defer gpa.free(c);
    try testing.expectEqualStrings("ui/hooks/use-toast.ts", c);

    const d = try mapPath(gpa, "registry/new-york/ui/card.tsx");
    defer gpa.free(d);
    try testing.expectEqualStrings("ui/components/ui/card.tsx", d);
}

test "RegistryItem parse with unknown fields ignored" {
    const gpa = testing.allocator;
    const sample =
        \\{ "name":"button","type":"registry:ui","author":"x",
        \\  "dependencies":["@radix-ui/react-slot"],
        \\  "files":[{"path":"ui/button.tsx","content":"export {}","type":"registry:ui"}] }
    ;
    const parsed = try std.json.parseFromSlice(RegistryItem, gpa, sample, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("button", parsed.value.name);
    try testing.expectEqual(@as(usize, 1), parsed.value.dependencies.len);
    try testing.expectEqualStrings("ui/button.tsx", parsed.value.files[0].path);
}

test "dirArg picks the non-flag" {
    try testing.expectEqualStrings(".", dirArg(&.{}));
    try testing.expectEqualStrings("myapp", dirArg(&.{ "--x", "myapp" }));
}
