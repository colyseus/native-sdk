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

    // Get native-sdk dependency (provides colyseus library with all its dependencies)
    const native_sdk_dep = b.dependency("native_sdk", .{
        .target = target,
        .optimize = optimize,
    });

    if (!is_emscripten) {
        // Native executable - link pre-built colyseus library
        const exe_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

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

        // Add include paths from native-sdk
        exe.addIncludePath(native_sdk_dep.path("include"));
        exe.addIncludePath(native_sdk_dep.path("third_party/uthash/src"));
        exe.addIncludePath(native_sdk_dep.path("third_party/wslay/lib/includes"));
        exe.addIncludePath(native_sdk_dep.path("tests/schema")); // For test_room_state.h
        exe.addIncludePath(b.path("src")); // For local headers

        // Link colyseus library (includes all internal dependencies: wslay, http, msgpack, etc.)
        exe.linkLibrary(native_sdk_dep.artifact("colyseus"));

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

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the raylib colyseus example");
        run_step.dependOn(&run_cmd.step);
    } else {
        // Emscripten build - link pre-built WASM library
        // Get emsdk dependency for web builds
        if (b.lazyDependency("emsdk", .{})) |emsdk_dep| {
            const emsdk_version = "4.0.9";

            // Always run install and activate to ensure correct version
            // (emsdk is smart enough to skip if already installed/active)
            const emsdk_install = b.addSystemCommand(&.{emsdk_dep.path("emsdk").getPath(b)});
            emsdk_install.addArgs(&.{ "install", emsdk_version });

            const emsdk_activate = b.addSystemCommand(&.{emsdk_dep.path("emsdk").getPath(b)});
            emsdk_activate.addArgs(&.{ "activate", emsdk_version });
            emsdk_activate.step.dependOn(&emsdk_install.step);

            // Build Zig modules for emscripten (need special WASM flags)
            // These are not included in the pre-built library
            const strutil_zig_module = b.createModule(.{
                .root_source_file = native_sdk_dep.path("src/utils/strUtil.zig"),
                .target = target,
                .optimize = optimize,
                .stack_check = false,
                .pic = true,
                .omit_frame_pointer = true,
                .unwind_tables = .none,
            });

            const strutil_object = b.addLibrary(.{
                .name = "strutil_zig",
                .root_module = strutil_zig_module,
                .linkage = .static,
            });
            strutil_object.linkLibC();

            // Get msgpack dependency (lazy, only loaded for emscripten builds)
            const msgpack_dep = b.lazyDependency("zig_msgpack", .{
                .target = target,
                .optimize = optimize,
            }) orelse {
                std.debug.print("Warning: zig_msgpack dependency not available for emscripten build\n", .{});
                return;
            };
            const msgpack_module = msgpack_dep.module("msgpack");
            msgpack_module.pic = true;
            msgpack_module.stack_check = false;
            msgpack_module.omit_frame_pointer = true;
            msgpack_module.unwind_tables = .none;

            const msgpack_builder_module = b.createModule(.{
                .root_source_file = native_sdk_dep.path("src/msgpack/msgpack_builder.zig"),
                .target = target,
                .optimize = optimize,
                .stack_check = false,
                .pic = true,
                .omit_frame_pointer = true,
                .unwind_tables = .none,
            });
            msgpack_builder_module.addImport("msgpack", msgpack_module);

            const msgpack_builder_object = b.addLibrary(.{
                .name = "msgpack_builder",
                .root_module = msgpack_builder_module,
                .linkage = .static,
            });
            msgpack_builder_object.linkLibC();

            const msgpack_reader_module = b.createModule(.{
                .root_source_file = native_sdk_dep.path("src/msgpack/msgpack_reader.zig"),
                .target = target,
                .optimize = optimize,
                .stack_check = false,
                .pic = true,
                .omit_frame_pointer = true,
                .unwind_tables = .none,
            });
            msgpack_reader_module.addImport("msgpack", msgpack_module);

            const msgpack_reader_object = b.addLibrary(.{
                .name = "msgpack_reader",
                .root_module = msgpack_reader_module,
                .linkage = .static,
            });
            msgpack_reader_object.linkLibC();

            // Use emcc from the emsdk
            const emcc_path = b.pathJoin(&.{ emsdk_dep.path("upstream/emscripten").getPath(b), "emcc" });
            const emcc = b.addSystemCommand(&.{emcc_path});

            // Add main.c (the only app-specific source file)
            emcc.addFileArg(b.path("src/main.c"));

            // Link pre-built colyseus WASM library from native_sdk/build/
            // Build it first with: cd native-sdk && mkdir -p build && (run emcc commands from CI)
            emcc.addFileArg(native_sdk_dep.path("build/libcolyseus.a"));

            // Add include paths (only need the main include directory)
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(native_sdk_dep.path("include"));
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(native_sdk_dep.path("third_party/uthash/src"));
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(native_sdk_dep.path("tests/schema"));
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(b.path("src"));

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
            emcc.addArtifactArg(msgpack_reader_object);

            // C flags and defines
            emcc.addArgs(&.{
                "-DPLATFORM_WEB",
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

            // Depend on emsdk activation
            emcc.step.dependOn(&emsdk_activate.step);

            b.getInstallStep().dependOn(&emcc.step);

            const web_step = b.step("web", "Build for web and generate HTML");
            web_step.dependOn(&emcc.step);
        } else {
            std.debug.print("Warning: emsdk dependency not available\n", .{});
        }
    }
}
