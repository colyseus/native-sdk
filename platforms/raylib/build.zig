const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const os_tag = target.result.os.tag;
    const is_emscripten = os_tag == .emscripten;

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
        // For WASM: disable features that use __builtin_return_address
        .stack_check = if (is_emscripten) false else null,
        .pic = if (is_emscripten) true else null,
        .omit_frame_pointer = if (is_emscripten) true else null,
        .unwind_tables = if (is_emscripten) .none else null,
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
    const msgpack_module = msgpack_dep.module("msgpack");

    // For WASM: disable features that use __builtin_return_address on msgpack module
    if (is_emscripten) {
        msgpack_module.pic = true;
        msgpack_module.stack_check = false;
        msgpack_module.omit_frame_pointer = true;
        msgpack_module.unwind_tables = .none;
    }

    const msgpack_builder_module = b.createModule(.{
        .root_source_file = b.path("../../src/msgpack/msgpack_builder.zig"),
        .target = target,
        .optimize = optimize,
        // For WASM: disable features that use __builtin_return_address
        .stack_check = if (is_emscripten) false else null,
        .pic = if (is_emscripten) true else null,
        .omit_frame_pointer = if (is_emscripten) true else null,
        .unwind_tables = if (is_emscripten) .none else null,
    });
    msgpack_builder_module.addImport("msgpack", msgpack_module);

    const msgpack_builder_object = b.addLibrary(.{
        .name = "msgpack_builder",
        .root_module = msgpack_builder_module,
        .linkage = .static,
    });
    msgpack_builder_object.linkLibC();

    // Native executable (not used for emscripten - emcc compiles C directly)
    const exe = if (!is_emscripten) blk: {
        const exe_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

        const executable = b.addExecutable(.{
            .name = "raylib_colyseus",
            .root_module = exe_module,
        });

        // Add main.c
        executable.addCSourceFile(.{
            .file = b.path("src/main.c"),
            .flags = &.{
                "-Wall",
                "-Wextra",
                "-Wno-unused-parameter",
            },
        });

        // Add colyseus core C sources
        executable.addCSourceFiles(.{
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
        executable.addIncludePath(b.path("../../include"));
        executable.addIncludePath(b.path("../../src"));
        executable.addIncludePath(b.path("../../third_party/uthash/src"));
        executable.addIncludePath(b.path("../../third_party/sds"));
        executable.addIncludePath(b.path("../../third_party/cJSON"));
        executable.addIncludePath(b.path("../../third_party/wslay/lib/includes"));
        executable.addIncludePath(b.path("../../third_party/wslay/lib"));
        executable.addIncludePath(b.path("../../tests/schema")); // For test_room_state.h
        executable.addIncludePath(b.path("src")); // For local headers

        break :blk executable;
    } else undefined;

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

    // Generate wslay version header
    const wslay_version_h = b.addConfigHeader(.{
        .style = .{ .cmake = b.path("../../third_party/wslay/lib/includes/wslay/wslayver.h.in") },
        .include_path = "wslay/wslayver.h",
    }, .{
        .PACKAGE_VERSION = "1.1.1",
    });

    // Configure native executable (not for emscripten)
    if (!is_emscripten) {
        exe.addConfigHeader(wslay_config_h);
        exe.addIncludePath(wslay_config_h.getOutput().dirname());
        exe.addConfigHeader(wslay_version_h);
        exe.addIncludePath(wslay_version_h.getOutput().dirname().dirname());

        // Link Zig libraries
        exe.linkLibrary(http_object);
        exe.linkLibrary(strutil_object);
        exe.linkLibrary(msgpack_builder_object);

        // Link raylib
        exe.linkLibrary(raylib_dep.artifact("raylib"));
    }

    // Link platform-specific libraries (native only)
    if (!is_emscripten) {
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
    }

    if (is_emscripten) {
        // Get emsdk dependency for web builds
        if (b.lazyDependency("emsdk", .{})) |emsdk_dep| {
            // Set up emsdk if needed (install and activate)
            const dot_emsc_path = emsdk_dep.path(".emscripten").getPath(b);
            const has_emscripten = if (std.fs.accessAbsolute(dot_emsc_path, .{})) |_| true else |_| false;

            var emsdk_activate: ?*std.Build.Step.Run = null;
            if (!has_emscripten) {
                const emsdk_install = b.addSystemCommand(&.{emsdk_dep.path("emsdk").getPath(b)});
                emsdk_install.addArgs(&.{ "install", "latest" });

                const emsdk_act = b.addSystemCommand(&.{emsdk_dep.path("emsdk").getPath(b)});
                emsdk_act.addArgs(&.{ "activate", "latest" });
                emsdk_act.step.dependOn(&emsdk_install.step);
                emsdk_activate = emsdk_act;
            }

            // Use emcc from the emsdk
            const emcc_path = b.pathJoin(&.{ emsdk_dep.path("upstream/emscripten").getPath(b), "emcc" });
            const emcc = b.addSystemCommand(&.{emcc_path});

            // Add C source files directly to emcc (web-specific transport and http, no wslay)
            const c_sources = [_][]const u8{
                "src/main.c",
                "../../src/common/settings.c",
                "../../src/client.c",
                "../../src/room.c",
                "../../src/network/websocket_transport_web.c",
                "../../src/network/http_web.c",
                "../../src/schema/decode.c",
                "../../src/schema/ref_tracker.c",
                "../../src/schema/collections.c",
                "../../src/schema/decoder.c",
                "../../src/schema/serializer.c",
                "../../src/schema/callbacks.c",
                "../../src/schema/dynamic_schema.c",
                "../../src/utils/strUtil.c",
                "../../src/utils/sha1_c.c",
                "../../src/auth/auth.c",
                "../../src/auth/secure_storage.c",
                "../../third_party/sds/sds.c",
                "../../third_party/cJSON/cJSON.c",
            };

            for (c_sources) |src| {
                emcc.addFileArg(b.path(src));
            }

            // Add include paths
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(b.path("../../include"));
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(b.path("../../src"));
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(b.path("../../third_party/uthash/src"));
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(b.path("../../third_party/sds"));
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(b.path("../../third_party/cJSON"));
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(b.path("../../third_party/wslay/lib/includes"));
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(b.path("../../third_party/wslay/lib"));
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(b.path("../../tests/schema"));
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(b.path("src"));

            // Add generated config headers
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(wslay_config_h.getOutput().dirname());
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(wslay_version_h.getOutput().dirname().dirname());

            // Add raylib include path
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(raylib_dep.path("src"));

            // Add emsdk include path
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(emsdk_dep.path("upstream/emscripten/cache/sysroot/include"));

            // Add raylib static library
            emcc.addArtifactArg(raylib_dep.artifact("raylib"));

            // Add Zig libraries (excluding http which is C-based for web)
            emcc.addArtifactArg(strutil_object);
            emcc.addArtifactArg(msgpack_builder_object);

            // C flags and defines
            emcc.addArgs(&.{
                "-DPLATFORM_WEB",
                "-DHAVE_CONFIG_H",
            });

            // Emscripten flags
            emcc.addArgs(&.{
                "-o",
                "zig-out/web/index.html",
                "-sUSE_GLFW=3",
                "-sASYNCIFY",
                "-sINITIAL_MEMORY=67108864",
                "-sALLOW_MEMORY_GROWTH=0",
                "-sGL_ENABLE_GET_PROC_ADDRESS=1",
                "-sASSERTIONS=1",
                "-sWEBSOCKET_SUBPROTOCOL=null",
                "-sEXIT_RUNTIME=0",
                "-sFETCH",
                "-sSTACK_SIZE=1048576",
                // Required for Zig 0.15.2+ which uses __builtin_return_address in allocator
                "-sUSE_OFFSET_CONVERTER",
                "-lwebsocket.js",
                "-Wl,--allow-multiple-definition",
                "--shell-file",
            });

            // Use custom shell file
            emcc.addFileArg(b.path("shell.html"));

            // Set optimization flags based on optimize level
            switch (optimize) {
                .Debug => emcc.addArgs(&.{ "-O0", "-g" }),
                .ReleaseSmall => emcc.addArgs(&.{"-Os"}),
                .ReleaseFast => emcc.addArgs(&.{"-O3"}),
                .ReleaseSafe => emcc.addArgs(&.{"-O2"}),
            }

            // Create output directory
            const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/web" });
            emcc.step.dependOn(&mkdir.step);

            // Ensure config headers are generated first
            emcc.step.dependOn(&wslay_config_h.step);
            emcc.step.dependOn(&wslay_version_h.step);

            // Depend on emsdk activation if needed
            if (emsdk_activate) |act| {
                emcc.step.dependOn(&act.step);
            }

            b.getInstallStep().dependOn(&emcc.step);

            const web_step = b.step("web", "Build for web and generate HTML");
            web_step.dependOn(&emcc.step);
        } else {
            std.debug.print("Warning: emsdk dependency not available\n", .{});
        }
    } else {
        // Install the executable for native targets
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the raylib colyseus example");
        run_step.dependOn(&run_cmd.step);
    }
}
