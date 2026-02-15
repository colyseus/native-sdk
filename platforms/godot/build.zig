const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get target information
    const os_tag = target.result.os.tag;
    const arch = target.result.cpu.arch;

    const os_str = switch (os_tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => "unknown",
    };

    const arch_str = switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "arm64",
        else => "unknown",
    };

    const build_type = if (optimize == .Debug) "debug" else "release";

    // Build library name based on platform
    const lib_name = if (os_tag == .macos)
        b.fmt("colyseus_godot.{s}.{s}", .{ os_str, build_type })
    else
        b.fmt("colyseus_godot.{s}.{s}.{s}", .{ os_str, arch_str, build_type });

    // Create module for the shared library
    const lib_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });

    // Create the shared library for the GDExtension
    const lib = b.addLibrary(.{
        .name = lib_name,
        .root_module = lib_module,
        .linkage = .dynamic,
    });

    // Add C source files
    lib.addCSourceFiles(.{
        .files = &.{
            "src/register_types.c",
            "src/colyseus_client.c",
            "src/colyseus_room.c",
            // wslay sources (needed because libcolyseus.a doesn't include them)
            "../../third_party/wslay/lib/wslay_event.c",
            "../../third_party/wslay/lib/wslay_frame.c",
            "../../third_party/wslay/lib/wslay_net.c",
            "../../third_party/wslay/lib/wslay_queue.c",
        },
        .flags = &.{
            "-Wall",
            "-Wextra",
            "-Wno-unused-parameter",
        },
    });

    // Add include paths
    lib.addIncludePath(b.path("../../include"));
    lib.addIncludePath(b.path("../../third_party/uthash/src"));
    lib.addIncludePath(b.path("../../third_party/wslay/lib/includes"));
    lib.addIncludePath(b.path("../../third_party/wslay/lib"));
    lib.addIncludePath(b.path("include"));

    // Link against the colyseus static library
    lib.addObjectFile(b.path("../../zig-out/lib/libcolyseus.a"));

    // Generate wslay version header
    const wslay_version_h = b.addConfigHeader(.{
        .style = .{ .cmake = b.path("../../third_party/wslay/lib/includes/wslay/wslayver.h.in") },
        .include_path = "wslay/wslayver.h",
    }, .{
        .PACKAGE_VERSION = "1.1.1",
    });
    lib.addConfigHeader(wslay_version_h);

    // Link against system libraries
    lib.linkLibC();

    // Link libraries that colyseus depends on
    lib.linkSystemLibrary("curl");
    lib.linkSystemLibrary("pthread");

    // Install to bin directory
    const install_step = b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = .{ .custom = "bin" } },
    });

    b.getInstallStep().dependOn(&install_step.step);
}
