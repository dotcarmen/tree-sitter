const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wasm = b.option(bool, "enable-wasm", "Enable Wasm support") orelse false;
    const shared = b.option(bool, "build-shared", "Build a shared library") orelse false;
    const amalgamated = b.option(bool, "amalgamated", "Build using an amalgamated source") orelse false;

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = if (shared) true else null,
    });

    if (amalgamated) {
        mod.addCSourceFile(.{
            .file = b.path("lib/src/lib.c"),
            .flags = &.{"-std=c11"},
        });
    } else {
        const files = try findSourceFiles(b);
        defer b.allocator.free(files);
        mod.addCSourceFiles(.{
            .root = b.path("lib/src"),
            .files = files,
            .flags = &.{"-std=c11"},
        });
    }

    mod.addIncludePath(b.path("lib/include"));
    mod.addIncludePath(b.path("lib/src"));
    mod.addIncludePath(b.path("lib/src/wasm"));

    mod.addCMacro("_POSIX_C_SOURCE", "200112L");
    mod.addCMacro("_DEFAULT_SOURCE", "");
    mod.addCMacro("_BSD_SOURCE", "");
    mod.addCMacro("_DARWIN_C_SOURCE", "");

    if (wasm) {
        if (b.lazyDependency(wasmtimeDep(target.result), .{})) |wasmtime| {
            mod.addCMacro("TREE_SITTER_FEATURE_WASM", "");
            mod.addSystemIncludePath(wasmtime.path("include"));
            mod.addLibraryPath(wasmtime.path("lib"));
            if (shared) mod.linkSystemLibrary("wasmtime", .{ .needed = true });
        }
    }

    const lib = b.addLibrary(.{
        .name = "tree-sitter",
        .linkage = if (shared) .dynamic else .static,
        .root_module = mod,
    });
    lib.installHeadersDirectory(b.path("lib/include"), ".", .{});
    b.installArtifact(lib);
}

/// Get the name of the wasmtime dependency for this target.
pub fn wasmtimeDep(target: std.Target) []const u8 {
    const arch = target.cpu.arch;
    const os = target.os.tag;
    const abi = target.abi;
    return @as(?[]const u8, switch (os) {
        .linux => switch (arch) {
            .x86_64 => switch (abi) {
                .gnu => "wasmtime_c_api_x86_64_linux",
                .musl => "wasmtime_c_api_x86_64_musl",
                .android => "wasmtime_c_api_x86_64_android",
                else => null,
            },
            .aarch64 => switch (abi) {
                .gnu => "wasmtime_c_api_aarch64_linux",
                .musl => "wasmtime_c_api_aarch64_musl",
                .android => "wasmtime_c_api_aarch64_android",
                else => null,
            },
            .x86 => switch (abi) {
                .gnu => "wasmtime_c_api_i686_linux",
                else => null,
            },
            .arm => switch (abi) {
                .gnueabi => "wasmtime_c_api_armv7_linux",
                else => null,
            },
            .s390x => switch (abi) {
                .gnu => "wasmtime_c_api_s390x_linux",
                else => null,
            },
            .riscv64 => switch (abi) {
                .gnu => "wasmtime_c_api_riscv64gc_linux",
                else => null,
            },
            else => null,
        },
        .windows => switch (arch) {
            .x86_64 => switch (abi) {
                .gnu => "wasmtime_c_api_x86_64_mingw",
                .msvc => "wasmtime_c_api_x86_64_windows",
                else => null,
            },
            .aarch64 => switch (abi) {
                .msvc => "wasmtime_c_api_aarch64_windows",
                else => null,
            },
            .x86 => switch (abi) {
                .msvc => "wasmtime_c_api_i686_windows",
                else => null,
            },
            else => null,
        },
        .macos => switch (arch) {
            .x86_64 => "wasmtime_c_api_x86_64_macos",
            .aarch64 => "wasmtime_c_api_aarch64_macos",
            else => null,
        },
        else => null,
    }) orelse std.debug.panic(
        "Unsupported target for wasmtime: {s}-{s}-{s}",
        .{ @tagName(arch), @tagName(os), @tagName(abi) },
    );
}

fn findSourceFiles(b: *std.Build) ![]const []const u8 {
    var sources: std.ArrayListUnmanaged([]const u8) = .empty;

    var dir = try b.build_root.handle.openDir(b.graph.io, "lib/src", .{ .iterate = true });
    var iter = dir.iterate();
    defer dir.close(b.graph.io);

    while (try iter.next(b.graph.io)) |entry| {
        if (entry.kind != .file) continue;
        const file = entry.name;
        const ext = std.fs.path.extension(file);
        if (std.mem.eql(u8, ext, ".c") and !std.mem.eql(u8, file, "lib.c")) {
            try sources.append(b.allocator, b.dupe(file));
        }
    }

    return sources.toOwnedSlice(b.allocator);
}
