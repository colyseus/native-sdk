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

    // Get zig-msgpack dependency
    const msgpack_dep = b.dependency("zig_msgpack", .{
        .target = target,
        .optimize = optimize,
    });

    // Create module for the shared library with Zig source file
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/msgpack_godot.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "msgpack", .module = msgpack_dep.module("msgpack") },
        },
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
            "src/colyseus_callbacks.c",
            "src/colyseus_state.c",
            "src/colyseus_schema_registry.c",
            "src/colyseus_gdscript_schema.c",  // GDScript schema bridge
            "src/msgpack_variant.c",
            "src/msgpack_encoder.c",
            // Dynamic schema support (for GDScript-defined schemas)
            "../../src/schema/dynamic_schema.c",
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
    lib.addIncludePath(b.path("src"));  // For colyseus_callbacks.h, colyseus_state.h

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

    // Link libraries that colyseus depends on (platform-specific)
    // TODO: have a shared place for this. We have the same code in the root build.zig.
    if (os_tag == .macos) {
        lib.linkSystemLibrary("curl");
        lib.linkSystemLibrary("pthread");
        lib.linkFramework("CoreFoundation");
        lib.linkFramework("Security");
    } else if (os_tag == .linux) {
        lib.linkSystemLibrary("curl");
        lib.linkSystemLibrary("pthread");
        lib.linkSystemLibrary("m");
    } else if (os_tag == .windows) {
        lib.linkSystemLibrary("libcurl");
        lib.linkSystemLibrary("ws2_32");
        lib.linkSystemLibrary("crypt32");
    } else {
        lib.linkSystemLibrary("curl");
        lib.linkSystemLibrary("pthread");
    }

    // Install to addons/colyseus/bin directory (relative to source root, not zig-out)
    const lib_prefix = if (os_tag == .windows) "" else "lib";
    const lib_ext = switch (os_tag) {
        .macos => ".dylib",
        .windows => ".dll",
        else => ".so",
    };
    const install_file = b.addInstallFile(lib.getEmittedBin(), b.fmt("../addons/colyseus/bin/{s}{s}{s}", .{
        lib_prefix,
        lib_name,
        lib_ext,
    }));

    b.getInstallStep().dependOn(&install_file.step);
}
