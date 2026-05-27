const std = @import("std");

// akm — Cloudflare + Neon full-stack app orchestrator (Zig).
//
// The generated-app templates under `templates/` are embedded into the binary at
// build time. Zig has no "embed a whole directory" builtin, so we walk the tree at
// configure time and synthesize a `templates` module whose `files` array pairs each
// relative path with its `@embedFile` bytes. The embeds are registered as anonymous
// imports *on the generated module*, since `@embedFile` resolves import names per module.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const templates_mod = buildTemplatesModule(b, target, optimize);

    const exe = b.addExecutable(.{
        .name = "akm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "templates", .module = templates_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run akm");
    run_step.dependOn(&run_cmd.step);

    // Tests live in the executable's own module.
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}

/// Every embedded template file, path relative to `templates/`.
/// Add a file here when you add it under `templates/`. Kept explicit (rather than
/// walking the dir) because Zig 0.16's build-time filesystem API is mid-migration.
const template_files = [_][]const u8{
    "base/.gitignore",
    "base/README.md.tmpl",
    "base/wrangler.jsonc.tmpl",
    "base/Dockerfile.tmpl",
    "base/package.json.tmpl",
    "base/tsconfig.json",
    "base/vite.config.ts.tmpl",
    "base/pyproject.toml.tmpl",
    "base/alembic.ini.tmpl",
    "base/.dev.vars.example.tmpl",
    "base/src/worker/index.ts.tmpl",
    "base/src/worker/container.ts.tmpl",
    "base/src/worker/auth.ts",
    "base/ui/index.html.tmpl",
    "base/ui/main.tsx",
    "base/src/__pkg__/__init__.py",
    "base/src/__pkg__/backend/__init__.py",
    "base/src/__pkg__/backend/app.py.tmpl",
    "base/src/__pkg__/backend/router.py.tmpl",
    "base/src/__pkg__/backend/config.py",
    "base/src/__pkg__/backend/identity.py",
    "base/src/__pkg__/backend/neon.py",
    "base/migrations/env.py.tmpl",
    "base/migrations/script.py.mako",
};

/// Produce a module exposing:
///   pub const File = struct { path: []const u8, bytes: []const u8 };
///   pub const files = [_]File{ ... };
fn buildTemplatesModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(b.allocator,
        \\pub const File = struct { path: []const u8, bytes: []const u8 };
        \\pub const files = [_]File{
        \\
    ) catch @panic("OOM");

    for (template_files) |rel| {
        const line = std.fmt.allocPrint(
            b.allocator,
            "    .{{ .path = \"{s}\", .bytes = @embedFile(\"{s}\") }},\n",
            .{ rel, rel },
        ) catch @panic("OOM");
        src.appendSlice(b.allocator, line) catch @panic("OOM");
    }
    src.appendSlice(b.allocator, "};\n") catch @panic("OOM");

    const wf = b.addWriteFiles();
    const manifest_path = wf.add("templates_manifest.zig", src.items);

    const mod = b.createModule(.{
        .root_source_file = manifest_path,
        .target = target,
        .optimize = optimize,
    });

    // Register every template file as an anonymous import on the manifest module,
    // so the @embedFile names above resolve (import namespace is per-module).
    for (template_files) |rel| {
        const full = b.fmt("templates/{s}", .{rel});
        mod.addAnonymousImport(rel, .{ .root_source_file = b.path(full) });
    }

    return mod;
}
