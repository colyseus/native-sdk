const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get target information
    const os_tag = target.result.os.tag;
    const arch = target.result.cpu.arch;

    // Auto-detect iOS SDK sysroot if targeting iOS and no sysroot was provided
    if (os_tag == .ios and b.sysroot == null) {
        const result = std.process.Child.run(.{
            .allocator = b.allocator,
            .argv = &.{ "xcrun", "--sdk", "iphoneos", "--show-sdk-path" },
        }) catch |err| {
            std.debug.print("Warning: Failed to detect iOS SDK path: {}\n", .{err});
            std.debug.print("You may need to pass --sysroot manually\n", .{});
            @panic("iOS SDK detection failed");
        };

        if (result.term.Exited == 0 and result.stdout.len > 0) {
            const sdk_path = std.mem.trimRight(u8, result.stdout, "\n\r");
            b.sysroot = sdk_path;
        }
    }

    // Auto-detect Android NDK sysroot if targeting Android and no sysroot was provided
    if (os_tag == .linux and target.result.abi == .android and b.sysroot == null) {
        if (std.process.getEnvVarOwned(b.allocator, "ANDROID_NDK_HOME")) |ndk_home| {
            const builtin = @import("builtin");
            const host_os = builtin.os.tag;
            const ndk_host = switch (host_os) {
                .macos => "darwin-x86_64",
                .linux => "linux-x86_64",
                .windows => "windows-x86_64",
                else => @panic("Unsupported host OS for Android NDK"),
            };
            b.sysroot = b.fmt("{s}/toolchains/llvm/prebuilt/{s}/sysroot", .{ ndk_home, ndk_host });
        } else |_| {
            std.debug.print("Warning: ANDROID_NDK_HOME not set. You may need to pass --sysroot manually\n", .{});
        }
    }

    const is_android = target.result.abi == .android;

    const os_str = switch (os_tag) {
        .linux => if (is_android) "android" else "linux",
        .macos => "macos",
        .windows => "windows",
        .ios => "ios",
        else => "unknown",
    };

    const arch_str = switch (arch) {
        .x86 => "x86",
        .x86_64 => "x86_64",
        .arm => "arm32",
        .aarch64 => "arm64",
        else => "unknown",
    };

    const build_type = if (optimize == .Debug) "debug" else "release";

    // Build library name based on platform
    // macOS uses universal binaries, iOS includes architecture
    const lib_name = if (os_tag == .macos)
        b.fmt("colyseus_godot.{s}.{s}", .{ os_str, build_type })
    else
        b.fmt("colyseus_godot.{s}.{s}.{s}", .{ os_str, arch_str, build_type });

    // Get zig-msgpack dependency
    const msgpack_dep = b.dependency("zig_msgpack", .{
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // Build Zig modules for HTTP and URL parsing (replaces libcurl)
    // ========================================================================
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

    // Add C source files - Godot extension sources
    lib.addCSourceFiles(.{
        .files = &.{
            "src/register_types.c",
            "src/colyseus_client.c",
            "src/colyseus_room.c",
            "src/colyseus_callbacks.c",
            "src/colyseus_state.c",
            "src/colyseus_schema_registry.c",
            "src/colyseus_gdscript_schema.c", // GDScript schema bridge
            "src/msgpack_variant.c",
            "src/msgpack_encoder.c",
        },
        .flags = &.{
            "-Wall",
            "-Wextra",
            "-Wno-unused-parameter",
        },
    });

    // Add colyseus core C sources directly (instead of linking pre-built libcolyseus.a)
    // This ensures the code is compiled for the correct target platform (iOS, macOS, etc.)
    lib.addCSourceFiles(.{
        .files = &.{
            // Core
            "../../src/common/settings.c",
            "../../src/client.c",
            "../../src/room.c",
            // Network (websocket only - HTTP is now in Zig)
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
    lib.addIncludePath(b.path("../../include"));
    lib.addIncludePath(b.path("../../src")); // For internal headers
    lib.addIncludePath(b.path("../../third_party/uthash/src"));
    lib.addIncludePath(b.path("../../third_party/sds"));
    lib.addIncludePath(b.path("../../third_party/cJSON"));
    lib.addIncludePath(b.path("../../third_party/wslay/lib/includes"));
    lib.addIncludePath(b.path("../../third_party/wslay/lib"));
    lib.addIncludePath(b.path("include"));
    lib.addIncludePath(b.path("src")); // For colyseus_callbacks.h, colyseus_state.h

    // Add iOS SDK system include path for C compilation
    if (os_tag == .ios) {
        if (b.sysroot) |sysroot| {
            lib.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sysroot}) });
        }
    }

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
        // Linux, macOS, iOS, and Android all have POSIX network headers
        b.addConfigHeader(.{
            .style = .blank,
            .include_path = "config.h",
        }, .{
            .HAVE_ARPA_INET_H = 1,
            .HAVE_NETINET_IN_H = 1,
        });
    lib.addConfigHeader(wslay_config_h);
    lib.addIncludePath(wslay_config_h.getOutput().dirname());

    // Link Zig HTTP and URL parsing libraries
    lib.linkLibrary(http_object);
    lib.linkLibrary(strutil_object);

    // Generate wslay version header
    const wslay_version_h = b.addConfigHeader(.{
        .style = .{ .cmake = b.path("../../third_party/wslay/lib/includes/wslay/wslayver.h.in") },
        .include_path = "wslay/wslayver.h",
    }, .{
        .PACKAGE_VERSION = "1.1.1",
    });
    lib.addConfigHeader(wslay_version_h);
    lib.addIncludePath(wslay_version_h.getOutput().dirname().dirname());

    // Link against system libraries
    lib.linkLibC();

    // Link platform-specific libraries (no curl needed - using Zig's std.http)
    if (os_tag == .macos) {
        // Add macOS SDK framework and include paths when sysroot is provided (cross-compilation)
        if (b.sysroot) |sysroot| {
            lib.root_module.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sysroot}) });
            // Add usr/local/include for libDER headers required by Security framework
            lib.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/local/include", .{sysroot}) });
        }
        lib.linkSystemLibrary("pthread");
        lib.linkFramework("CoreFoundation");
        lib.linkFramework("Security");
    } else if (os_tag == .ios) {
        // Add iOS SDK framework and library search paths (relative to sysroot)
        if (b.sysroot) |sysroot| {
            lib.root_module.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sysroot}) });
            lib.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
            // Add usr/local/include for libDER headers required by Security framework
            lib.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/local/include", .{sysroot}) });
        }
        lib.linkFramework("CoreFoundation");
        lib.linkFramework("Security");

        // Set the install_name to match Godot's .framework bundle structure
        lib.install_name = b.fmt("@rpath/lib{s}.framework/lib{s}", .{ lib_name, lib_name });
    } else if (is_android) {
        // Add Android NDK library search paths
        if (b.sysroot) |sysroot| {
            const android_triple = switch (arch) {
                .x86 => "i686-linux-android",
                .x86_64 => "x86_64-linux-android",
                .arm => "arm-linux-androideabi",
                .aarch64 => "aarch64-linux-android",
                else => @panic("Unsupported Android architecture"),
            };
            const api_level = "21";
            lib.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib/{s}/{s}", .{ sysroot, android_triple, api_level }) });
            lib.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib/{s}", .{ sysroot, android_triple }) });
        }
        lib.linkSystemLibrary("log");
        lib.linkSystemLibrary("android");
    } else if (os_tag == .linux) {
        lib.linkSystemLibrary("pthread");
        lib.linkSystemLibrary("m");
    } else if (os_tag == .windows) {
        lib.linkSystemLibrary("ws2_32");
        lib.linkSystemLibrary("crypt32");
    } else {
        lib.linkSystemLibrary("pthread");
    }

    // Install to addons/colyseus/bin directory (relative to source root, not zig-out)
    const lib_prefix = if (os_tag == .windows) "" else "lib";
    const lib_ext = switch (os_tag) {
        .macos, .ios => ".dylib",
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
