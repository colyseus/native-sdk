const std = @import("std");

pub fn build(b: *std.Build) void {
    // Build for all Game Maker supported platforms
    const build_all = b.option(bool, "all", "Build for all Game Maker platforms (Windows, macOS, Linux)") orelse false;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Apple SDK path (auto-detected on macOS if not specified)
    const apple_sdk_path: ?[]const u8 = b.option([]const u8, "apple-sdk", "Path to Apple SDK") orelse blk: {
        const os = target.result.os.tag;
        if (os == .macos or os == .ios or os == .tvos) {
            const sdk_name = switch (os) {
                .macos => "macosx",
                .tvos => "appletvos",
                else => "iphoneos",
            };
            const result = std.process.Child.run(.{
                .allocator = b.allocator,
                .argv = &.{ "xcrun", "--sdk", sdk_name, "--show-sdk-path" },
            }) catch break :blk null;
            defer b.allocator.free(result.stdout);
            defer b.allocator.free(result.stderr);
            if (result.term.Exited == 0 and result.stdout.len > 0) {
                const trimmed = std.mem.trimRight(u8, result.stdout, "\n\r");
                break :blk b.allocator.dupe(u8, trimmed) catch null;
            }
        }
        break :blk null;
    };

    // Android NDK path (for cross-compiling to Android)
    const is_android = target.result.os.tag == .linux and
        (target.result.abi == .android or target.result.abi == .androideabi);
    const android_ndk_path: ?[]const u8 = b.option([]const u8, "android-ndk", "Path to Android NDK") orelse blk: {
        if (!is_android) break :blk null;
        break :blk std.process.getEnvVarOwned(b.allocator, "ANDROID_NDK_HOME") catch null;
    };

    // Get native-sdk dependency (provides pre-built colyseus library)
    // Pass platform SDK paths through so the dependency can also find headers/frameworks
    const native_sdk_dep = blk: {
        if (apple_sdk_path) |sdk| {
            break :blk b.dependency("native_sdk", .{
                .target = target,
                .optimize = optimize,
                .@"apple-sdk" = @as([]const u8, sdk),
            });
        }
        if (android_ndk_path) |ndk| {
            break :blk b.dependency("native_sdk", .{
                .target = target,
                .optimize = optimize,
                .@"android-ndk" = @as([]const u8, ndk),
            });
        }
        break :blk b.dependency("native_sdk", .{
            .target = target,
            .optimize = optimize,
        });
    };

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
            b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = .ios,
            }),
            b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = .linux,
                .abi = .android,
            }),
            b.resolveTargetQuery(.{
                .cpu_arch = .arm,
                .os_tag = .linux,
                .abi = .androideabi,
            }),
            b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .linux,
                .abi = .android,
            }),
        };

        for (targets) |build_target| {
            buildGameMakerExtension(b, build_target, optimize, native_sdk_dep, apple_sdk_path);
        }
    } else {
        // Build for native target only
        buildGameMakerExtension(b, target, optimize, native_sdk_dep, apple_sdk_path);
    }
}

// Helper to add Apple SDK paths to a compile step (macOS, iOS, tvOS)
fn addAppleSdkPaths(compile_step: *std.Build.Step.Compile, sdk_path: ?[]const u8) void {
    if (sdk_path) |sdk| {
        const alloc = compile_step.step.owner.allocator;
        compile_step.addSystemIncludePath(.{ .cwd_relative = std.fmt.allocPrint(
            alloc,
            "{s}/usr/include",
            .{sdk},
        ) catch return });
        compile_step.addLibraryPath(.{ .cwd_relative = std.fmt.allocPrint(
            alloc,
            "{s}/usr/lib",
            .{sdk},
        ) catch return });
        compile_step.addFrameworkPath(.{ .cwd_relative = std.fmt.allocPrint(
            alloc,
            "{s}/System/Library/Frameworks",
            .{sdk},
        ) catch return });
    }
}

fn buildGameMakerExtension(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    native_sdk_dep: *std.Build.Dependency,
    apple_sdk_path: ?[]const u8,
) void {
    const extension_name = getExtensionName(target.result);

    // Linux and Android need gnu11 for POSIX functions (strdup, etc.)
    const c_std: []const u8 = if (target.result.os.tag == .linux) "-std=gnu11" else "-std=c11";

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

    // Add Apple SDK paths for framework resolution (macOS, iOS)
    if (target.result.os.tag == .macos or target.result.os.tag == .ios or target.result.os.tag == .tvos) {
        addAppleSdkPaths(gamemaker, apple_sdk_path);
    }

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
            c_std,
        },
    });

    // Link the pre-built colyseus library from native_sdk
    gamemaker.linkLibrary(native_sdk_dep.artifact("colyseus"));

    // Link platform-specific system libraries
    if (target.result.os.tag == .linux) {
        const is_android = target.result.abi == .android or target.result.abi == .androideabi;
        if (!is_android) {
            gamemaker.linkSystemLibrary("pthread");
            gamemaker.linkSystemLibrary("m");
        }
    } else if (target.result.os.tag == .macos or target.result.os.tag == .ios) {
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
        .ios => "lib/ios/arm64",
        .linux => {
            if (target.abi == .android or target.abi == .androideabi) {
                return switch (target.cpu.arch) {
                    .aarch64 => "lib/android/arm64",
                    .arm => "lib/android/arm32",
                    .x86_64 => "lib/android/x64",
                    else => "lib/android/unknown",
                };
            }
            return if (target.cpu.arch == .x86_64) "lib/linux/x64" else "lib/linux/x86";
        },
        else => "lib/unknown",
    };
}
