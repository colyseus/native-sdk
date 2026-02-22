const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const os_tag = target.result.os.tag;

    // Get raylib dependency
    const raylib_dep = b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
    });

    // Build Zig modules for HTTP (replaces libcurl)
    const http_zig_module = b.createModule(.{
        .root_source_file = b.path("../../src/network/http.zig"),
        .target = target,
        .optimize = optimize,
    });
    http_zig_module.addIncludePath(b.path("../../include"));
    http_zig_module.addIncludePath(b.path("../../third_party/uthash/src"));

    const http_object = b.addLibrary(.{
        .name = "http_zig",
        .root_module = http_zig_module,
        .linkage = .static,
    });
    http_object.linkLibC();

    const strutil_zig_module = b.createModule(.{
        .root_source_file = b.path("../../src/utils/strUtil.zig"),
        .target = target,
        .optimize = optimize,
    });

    const strutil_object = b.addLibrary(.{
        .name = "strutil_zig",
        .root_module = strutil_zig_module,
        .linkage = .static,
    });
    strutil_object.linkLibC();

    // Create msgpack builder module using zig-msgpack
    const msgpack_dep = b.dependency("zig_msgpack", .{
        .target = target,
        .optimize = optimize,
    });

    const msgpack_builder_module = b.createModule(.{
        .root_source_file = b.path("../../src/msgpack/msgpack_builder.zig"),
        .target = target,
        .optimize = optimize,
    });
    msgpack_builder_module.addImport("msgpack", msgpack_dep.module("msgpack"));

    const msgpack_builder_object = b.addLibrary(.{
        .name = "msgpack_builder",
        .root_module = msgpack_builder_module,
        .linkage = .static,
    });
    msgpack_builder_object.linkLibC();

    // Create executable module
    const exe_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Create executable
    const exe = b.addExecutable(.{
        .name = "raylib_colyseus",
        .root_module = exe_module,
    });

    // Add main.c
    exe.addCSourceFile(.{
        .file = b.path("src/main.c"),
        .flags = &.{
            "-Wall",
            "-Wextra",
            "-Wno-unused-parameter",
        },
    });

    // Add colyseus core C sources
    exe.addCSourceFiles(.{
        .files = &.{
            // Core
            "../../src/common/settings.c",
            "../../src/client.c",
            "../../src/room.c",
            // Network (websocket only - HTTP is in Zig)
            "../../src/network/websocket_transport.c",
            // Schema
            "../../src/schema/decode.c",
            "../../src/schema/ref_tracker.c",
            "../../src/schema/collections.c",
            "../../src/schema/decoder.c",
            "../../src/schema/serializer.c",
            "../../src/schema/callbacks.c",
            "../../src/schema/dynamic_schema.c",
            // Utils
            "../../src/utils/strUtil.c",
            "../../src/utils/sha1_c.c",
            // Auth
            "../../src/auth/auth.c",
            "../../src/auth/secure_storage.c",
            // Third-party sources
            "../../third_party/sds/sds.c",
            "../../third_party/cJSON/cJSON.c",
            // wslay sources
            "../../third_party/wslay/lib/wslay_event.c",
            "../../third_party/wslay/lib/wslay_frame.c",
            "../../third_party/wslay/lib/wslay_net.c",
            "../../third_party/wslay/lib/wslay_queue.c",
        },
        .flags = &.{
            "-Wall",
            "-Wextra",
            "-Wno-unused-parameter",
            "-DHAVE_CONFIG_H",
        },
    });

    // Add include paths
    exe.addIncludePath(b.path("../../include"));
    exe.addIncludePath(b.path("../../src"));
    exe.addIncludePath(b.path("../../third_party/uthash/src"));
    exe.addIncludePath(b.path("../../third_party/sds"));
    exe.addIncludePath(b.path("../../third_party/cJSON"));
    exe.addIncludePath(b.path("../../third_party/wslay/lib/includes"));
    exe.addIncludePath(b.path("../../third_party/wslay/lib"));
    exe.addIncludePath(b.path("../../tests/schema")); // For test_room_state.h
    exe.addIncludePath(b.path("src")); // For local headers

    // Generate wslay config header based on target platform
    const is_windows = os_tag == .windows;
    const wslay_config_h: *std.Build.Step.ConfigHeader = if (is_windows)
        b.addConfigHeader(.{
            .style = .blank,
            .include_path = "config.h",
        }, .{
            .HAVE_WINSOCK2_H = 1,
        })
    else
        b.addConfigHeader(.{
            .style = .blank,
            .include_path = "config.h",
        }, .{
            .HAVE_ARPA_INET_H = 1,
            .HAVE_NETINET_IN_H = 1,
        });
    exe.addConfigHeader(wslay_config_h);
    exe.addIncludePath(wslay_config_h.getOutput().dirname());

    // Generate wslay version header
    const wslay_version_h = b.addConfigHeader(.{
        .style = .{ .cmake = b.path("../../third_party/wslay/lib/includes/wslay/wslayver.h.in") },
        .include_path = "wslay/wslayver.h",
    }, .{
        .PACKAGE_VERSION = "1.1.1",
    });
    exe.addConfigHeader(wslay_version_h);
    exe.addIncludePath(wslay_version_h.getOutput().dirname().dirname());

    // Link Zig libraries
    exe.linkLibrary(http_object);
    exe.linkLibrary(strutil_object);
    exe.linkLibrary(msgpack_builder_object);

    // Link raylib
    exe.linkLibrary(raylib_dep.artifact("raylib"));

    // Link platform-specific libraries
    if (os_tag == .macos) {
        exe.linkSystemLibrary("pthread");

        // macOS SDK paths
        const sdk_path = "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk";
        exe.root_module.addFrameworkPath(.{ .cwd_relative = sdk_path ++ "/System/Library/Frameworks" });
        exe.addSystemIncludePath(.{ .cwd_relative = sdk_path ++ "/usr/include" });
        exe.root_module.addLibraryPath(.{ .cwd_relative = sdk_path ++ "/usr/lib" });

        exe.linkFramework("CoreFoundation");
        exe.linkFramework("Security");
        exe.linkFramework("IOKit");
        exe.linkFramework("Cocoa");
    } else if (os_tag == .linux) {
        exe.linkSystemLibrary("pthread");
        exe.linkSystemLibrary("m");
        exe.linkSystemLibrary("GL");
        exe.linkSystemLibrary("X11");
    } else if (os_tag == .windows) {
        exe.linkSystemLibrary("ws2_32");
        exe.linkSystemLibrary("crypt32");
        exe.linkSystemLibrary("gdi32");
        exe.linkSystemLibrary("winmm");
    }

    // Install the executable
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the raylib colyseus example");
    run_step.dependOn(&run_cmd.step);
}
