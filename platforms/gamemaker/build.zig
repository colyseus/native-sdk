const std = @import("std");

pub fn build(b: *std.Build) void {
    // Build for all Game Maker supported platforms
    const build_all = b.option(bool, "all", "Build for all Game Maker platforms (Windows, macOS, Linux)") orelse false;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get native-sdk dependency (provides pre-built colyseus library)
    const native_sdk_dep = b.dependency("native_sdk", .{
        .target = target,
        .optimize = optimize,
    });

    if (build_all) {
        // Build for all Game Maker platforms
        const targets = [_]std.Build.ResolvedTarget{
            b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .windows,
                .abi = .gnu,
            }),
            b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .macos,
            }),
            b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = .macos,
            }),
            b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .linux,
                .abi = .gnu,
            }),
        };

        for (targets) |build_target| {
            buildGameMakerExtension(b, build_target, optimize, native_sdk_dep);
        }
    } else {
        // Build for native target only
        buildGameMakerExtension(b, target, optimize, native_sdk_dep);
    }
}

fn buildGameMakerExtension(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    native_sdk_dep: *std.Build.Dependency,
) void {
    const extension_name = getExtensionName(target.result);

    // ========================================================================
    // Build GameMaker dynamic library
    // ========================================================================
    const gamemaker_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });

    const gamemaker = b.addLibrary(.{
        .name = extension_name,
        .root_module = gamemaker_module,
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });

    gamemaker.linkLibC();

    // Add include paths
    gamemaker.addIncludePath(native_sdk_dep.path("include"));
    gamemaker.addIncludePath(native_sdk_dep.path("third_party/uthash/src"));
    gamemaker.addIncludePath(b.path("src")); // For local headers

    // GameMaker export layer (C code that wraps colyseus C API)
    gamemaker.addCSourceFiles(.{
        .root = b.path("."),
        .files = &.{
            "src/gamemaker_export.c",
        },
        .flags = &.{
            "-Wall",
            "-Wextra",
            "-pedantic",
            "-std=c11",
        },
    });

    // Link the pre-built colyseus library from native_sdk
    gamemaker.linkLibrary(native_sdk_dep.artifact("colyseus"));

    // Link platform-specific system libraries
    if (target.result.os.tag == .linux) {
        gamemaker.linkSystemLibrary("pthread");
        gamemaker.linkSystemLibrary("m");
    } else if (target.result.os.tag == .macos) {
        gamemaker.linkSystemLibrary("pthread");
        gamemaker.linkFramework("CoreFoundation");
        gamemaker.linkFramework("Security");
    } else if (target.result.os.tag == .windows) {
        gamemaker.linkSystemLibrary("ws2_32");
        gamemaker.linkSystemLibrary("crypt32");
    }

    // Install to platform-specific directory
    const install_path = getPlatformInstallPath(target.result);
    const install_step = b.addInstallArtifact(gamemaker, .{
        .dest_dir = .{
            .override = .{
                .custom = install_path,
            },
        },
    });
    b.getInstallStep().dependOn(&install_step.step);
}

fn getExtensionName(_: std.Target) []const u8 {
    // Game Maker expects specific naming for extensions
    return "colyseus";
}

fn getPlatformInstallPath(target: std.Target) []const u8 {
    // Install to platform-specific directories for Game Maker
    return switch (target.os.tag) {
        .windows => if (target.cpu.arch == .x86_64) "lib/windows/x64" else "lib/windows/x86",
        .macos => if (target.cpu.arch == .aarch64) "lib/macos/arm64" else "lib/macos/x64",
        .linux => if (target.cpu.arch == .x86_64) "lib/linux/x64" else "lib/linux/x86",
        else => "lib/unknown",
    };
}
