const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get target information
    const os_tag = target.result.os.tag;
    const arch = target.result.cpu.arch;

    // Detect Android (both 64-bit .android and 32-bit .androideabi ABIs)
    const is_android = target.result.abi == .android or target.result.abi == .androideabi;

    // For non-Android targets, auto-detect sysroot if needed
    // Note: Android is handled differently - we don't set sysroot to avoid Zig trying to provide libc
    if (os_tag == .linux and !is_android and b.sysroot == null) {
        // Only set sysroot for non-Android Linux targets if needed
    }

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
    const msgpack_module = msgpack_dep.module("msgpack");

    // For iOS and Android: disable libc linking on msgpack module
    // iOS: works around Zig's libSystem search issue
    // Android: Zig cannot provide Bionic libc
    if (os_tag == .ios or is_android) {
        msgpack_module.link_libc = false;
    }

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
    // Link libc for targets where Zig can provide it
    // iOS: handled via libSystem.tbd at runtime
    // Android: Zig cannot provide Bionic libc, symbols resolve at runtime
    if (os_tag != .ios and !is_android) {
        http_object.linkLibC();
    }

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
    // Link libc for targets where Zig can provide it
    // iOS: handled via libSystem.tbd at runtime
    // Android: Zig cannot provide Bionic libc, symbols resolve at runtime
    if (os_tag != .ios and !is_android) {
        strutil_object.linkLibC();
    }

    // Create module for the shared library with Zig source file
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/msgpack_godot.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "msgpack", .module = msgpack_module },
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

    // Link platform-specific libraries (no curl needed - using Zig's std.http)
    if (os_tag == .macos) {
        lib.linkLibC();
        lib.linkSystemLibrary("pthread");

        // Add macOS SDK paths for cross-compilation
        if (b.sysroot) |sysroot| {
            lib.root_module.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sysroot}) });
            lib.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sysroot}) });
            lib.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sysroot}) });
        } else {
            // Try to auto-detect Xcode SDK path on macOS host
            const builtin = @import("builtin");
            if (builtin.os.tag == .macos) {
                const sdk_path = "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk";
                lib.root_module.addFrameworkPath(.{ .cwd_relative = sdk_path ++ "/System/Library/Frameworks" });
                lib.addSystemIncludePath(.{ .cwd_relative = sdk_path ++ "/usr/include" });
                lib.root_module.addLibraryPath(.{ .cwd_relative = sdk_path ++ "/usr/lib" });
            }
        }

        lib.linkFramework("CoreFoundation");
        lib.linkFramework("Security");
    } else if (os_tag == .ios) {
        // For iOS: set up SDK paths for cross-compilation
        if (b.sysroot) |sysroot| {
            lib.root_module.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sysroot}) });
        }

        // For iOS dynamic library: don't link libc at build time, symbols resolve at runtime
        // This works around Zig's inability to find libSystem in iOS sysroot
        lib.root_module.link_libc = false;
        http_zig_module.link_libc = false;
        strutil_zig_module.link_libc = false;

        // Use weak framework linking to avoid dependency resolution issues
        lib.root_module.linkFramework("CoreFoundation", .{ .weak = true });
        lib.root_module.linkFramework("Security", .{ .weak = true });

        // Set the install_name to match Godot's .framework bundle structure
        lib.install_name = b.fmt("@rpath/lib{s}.framework/lib{s}", .{ lib_name, lib_name });
    } else if (is_android) {
        // For Android: Zig cannot provide Bionic libc, so we configure NDK paths manually
        // This avoids setting b.sysroot which would trigger Zig's libc provision
        lib.root_module.link_libc = false;
        http_zig_module.link_libc = false;
        strutil_zig_module.link_libc = false;

        const android_triple = switch (arch) {
            .x86 => "i686-linux-android",
            .x86_64 => "x86_64-linux-android",
            .arm => "arm-linux-androideabi",
            .aarch64 => "aarch64-linux-android",
            else => @panic("Unsupported Android architecture"),
        };
        const api_level = "21";

        // Get NDK paths from environment or sysroot
        if (std.process.getEnvVarOwned(b.allocator, "ANDROID_NDK_HOME")) |ndk_home| {
            const builtin = @import("builtin");
            const ndk_host = switch (builtin.os.tag) {
                .macos => "darwin-x86_64",
                .linux => "linux-x86_64",
                .windows => "windows-x86_64",
                else => @panic("Unsupported host OS for Android NDK"),
            };
            const ndk_sysroot = b.fmt("{s}/toolchains/llvm/prebuilt/{s}/sysroot", .{ ndk_home, ndk_host });

            // Add NDK include paths for C headers
            lib.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{ndk_sysroot}) });
            lib.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include/{s}", .{ ndk_sysroot, android_triple }) });

            // Add NDK library paths
            lib.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib/{s}/{s}", .{ ndk_sysroot, android_triple, api_level }) });
            lib.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib/{s}", .{ ndk_sysroot, android_triple }) });
        } else |_| {
            std.debug.print("Warning: ANDROID_NDK_HOME not set for Android build\n", .{});
        }

        // Link Android system libraries
        // Note: link_libc is already set to false on root_module, so these won't trigger libc provision
        lib.root_module.linkSystemLibrary("log", .{});
        lib.root_module.linkSystemLibrary("android", .{});
    } else if (os_tag == .linux) {
        lib.linkLibC();
        lib.linkSystemLibrary("pthread");
        lib.linkSystemLibrary("m");
    } else if (os_tag == .windows) {
        lib.linkLibC();
        lib.linkSystemLibrary("ws2_32");
        lib.linkSystemLibrary("crypt32");
    } else {
        lib.linkLibC();
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
