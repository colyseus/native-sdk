const std = @import("std");

pub fn build(b: *std.Build) void {
    // Build for all Game Maker supported platforms
    const build_all = b.option(bool, "all", "Build for all Game Maker platforms (Windows, macOS, Linux)") orelse false;

    const optimize = b.standardOptimizeOption(.{});

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

        for (targets) |target| {
            buildGameMakerExtension(b, target, optimize);
        }
    } else {
        // Build for native target only
        const target = b.standardTargetOptions(.{});
        buildGameMakerExtension(b, target, optimize);
    }
}

fn buildGameMakerExtension(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const sdk_root = b.path("../../");

    // ========================================================================
    // Build wslay library
    // ========================================================================

    // Generate config.h for wslay based on target platform
    const wslay_config_h = switch (target.result.os.tag) {
        .windows => b.addConfigHeader(.{
            .style = .blank,
            .include_path = "config.h",
        }, .{
            .HAVE_WINSOCK2_H = 1,
        }),
        else => b.addConfigHeader(.{
            .style = .blank,
            .include_path = "config.h",
        }, .{
            .HAVE_ARPA_INET_H = 1,
            .HAVE_NETINET_IN_H = 1,
        }),
    };

    // Generate wslayver.h for wslay
    const wslay_version_h = b.addConfigHeader(.{
        .style = .{ .cmake = sdk_root.path(b, "third_party/wslay/lib/includes/wslay/wslayver.h.in") },
        .include_path = "wslay/wslayver.h",
    }, .{
        .PACKAGE_VERSION = "1.1.1",
    });

    const wslay_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });

    const wslay = b.addLibrary(.{
        .name = "wslay",
        .root_module = wslay_module,
        .linkage = .static,
    });

    wslay.linkLibC();
    wslay.addIncludePath(sdk_root.path(b, "third_party/wslay/lib/includes"));
    wslay.addIncludePath(sdk_root.path(b, "third_party/wslay/lib"));
    wslay.addConfigHeader(wslay_config_h);
    wslay.addConfigHeader(wslay_version_h);

    // wslay source files
    wslay.addCSourceFiles(.{
        .root = sdk_root,
        .files = &.{
            "third_party/wslay/lib/wslay_event.c",
            "third_party/wslay/lib/wslay_frame.c",
            "third_party/wslay/lib/wslay_net.c",
            "third_party/wslay/lib/wslay_queue.c",
        },
        .flags = &.{
            "-Wall",
            "-Wextra",
            "-std=c11",
            "-DHAVE_CONFIG_H",
        },
    });

    // ========================================================================
    // Build colyseus shared library for Game Maker
    // ========================================================================
    const colyseus_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });

    const extension_name = getExtensionName(target.result);

    const colyseus = b.addLibrary(.{
        .name = extension_name,
        .root_module = colyseus_module,
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });

    colyseus.linkLibC();

    // Add include paths
    colyseus.addIncludePath(sdk_root.path(b, "include"));
    colyseus.addIncludePath(sdk_root.path(b, "src"));
    colyseus.addIncludePath(sdk_root.path(b, "third_party/sds"));
    colyseus.addIncludePath(sdk_root.path(b, "third_party/uthash/src"));
    colyseus.addIncludePath(sdk_root.path(b, "third_party/cJSON"));
    colyseus.addIncludePath(sdk_root.path(b, "third_party/wslay/lib/includes"));

    // Add generated header paths from wslay
    colyseus.addIncludePath(wslay_config_h.getOutput().dirname());
    colyseus.addIncludePath(wslay_version_h.getOutput().dirname().dirname());

    // Colyseus source files
    colyseus.addCSourceFiles(.{
        .root = sdk_root,
        .files = &.{
            // Core
            "src/common/settings.c",
            "src/client.c",
            "src/room.c",
            // Network
            "src/network/http.c",
            "src/network/websocket_transport.c",
            // Utils
            "src/utils/strUtil.c",
            "src/utils/sha1_c.c",
            // Auth
            "src/auth/auth.c",
            "src/auth/secure_storage.c",
            // Third-party sources
            "third_party/sds/sds.c",
            "third_party/cJSON/cJSON.c",
        },
        .flags = &.{
            "-Wall",
            "-Wextra",
            "-pedantic",
            "-std=c11",
        },
    });

    // GameMaker export layer
    colyseus.addCSourceFiles(.{
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

    // Link wslay
    colyseus.linkLibrary(wslay);

    // Link system libraries based on platform
    if (target.result.os.tag == .linux) {
        colyseus.linkSystemLibrary("curl");
        colyseus.linkSystemLibrary("pthread");
        colyseus.linkSystemLibrary("m");
    } else if (target.result.os.tag == .macos) {
        colyseus.linkSystemLibrary("curl");
        colyseus.linkSystemLibrary("pthread");
        colyseus.linkFramework("CoreFoundation");
        colyseus.linkFramework("Security");
    } else if (target.result.os.tag == .windows) {
        colyseus.linkSystemLibrary("curl");
        colyseus.linkSystemLibrary("ws2_32");
    } else {
        colyseus.linkSystemLibrary("curl");
    }

    // Install to platform-specific directory
    const install_path = getPlatformInstallPath(target.result);
    const install_step = b.addInstallArtifact(colyseus, .{
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
