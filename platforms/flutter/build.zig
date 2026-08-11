const std = @import("std");

pub fn build(b: *std.Build) void {
    // Build for all Flutter supported platforms
    const build_all = b.option(bool, "all", "Build for all Flutter platforms") orelse false;

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

    // Get native-sdk dependency
    const native_sdk_dep = if (apple_sdk_path) |sdk|
        b.dependency("native_sdk", .{
            .target = target,
            .optimize = optimize,
            .@"apple-sdk" = @as([]const u8, sdk),
        })
    else
        b.dependency("native_sdk", .{
            .target = target,
            .optimize = optimize,
        });

    if (build_all) {
        const targets = [_]std.Build.ResolvedTarget{
            // Android
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
            // iOS (static library)
            b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = .ios,
            }),
            // macOS
            b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = .macos,
            }),
            b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .macos,
            }),
            // Linux
            b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .linux,
                .abi = .gnu,
            }),
            // Windows
            b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .windows,
                .abi = .gnu,
            }),
        };

        for (targets) |build_target| {
            buildFlutterLibrary(b, build_target, optimize, native_sdk_dep, apple_sdk_path);
        }
    } else {
        // Build for native target only
        buildFlutterLibrary(b, target, optimize, native_sdk_dep, apple_sdk_path);
    }
}

// Helper to add Android NDK sysroot paths
fn addAndroidNdkPaths(compile_step: *std.Build.Step.Compile, tgt: std.Target) void {
    const alloc = compile_step.step.owner.allocator;
    const ndk = std.process.getEnvVarOwned(alloc, "ANDROID_NDK_HOME") catch return;

    const host = comptime if (@import("builtin").os.tag == .macos)
        "darwin-x86_64"
    else
        "linux-x86_64";

    const sysroot = std.fmt.allocPrint(alloc, "{s}/toolchains/llvm/prebuilt/{s}/sysroot", .{ ndk, host }) catch return;

    compile_step.addSystemIncludePath(.{ .cwd_relative = std.fmt.allocPrint(
        alloc,
        "{s}/usr/include",
        .{sysroot},
    ) catch return });

    const arch_include = switch (tgt.cpu.arch) {
        .aarch64 => "aarch64-linux-android",
        .arm => "arm-linux-androideabi",
        .x86_64 => "x86_64-linux-android",
        .x86 => "i686-linux-android",
        else => return,
    };
    compile_step.addSystemIncludePath(.{ .cwd_relative = std.fmt.allocPrint(
        alloc,
        "{s}/usr/include/{s}",
        .{ sysroot, arch_include },
    ) catch return });

    compile_step.addLibraryPath(.{ .cwd_relative = std.fmt.allocPrint(
        alloc,
        "{s}/usr/lib/{s}/21",
        .{ sysroot, arch_include },
    ) catch return });
    compile_step.addLibraryPath(.{ .cwd_relative = std.fmt.allocPrint(
        alloc,
        "{s}/usr/lib/{s}",
        .{ sysroot, arch_include },
    ) catch return });
}

// Helper to add Apple SDK paths
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

fn buildFlutterLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    native_sdk_dep: *std.Build.Dependency,
    apple_sdk_path: ?[]const u8,
) void {
    const is_android = target.result.os.tag == .linux and
        (target.result.abi == .android or target.result.abi == .androideabi);

    const is_ios = target.result.os.tag == .ios;

    // Linux and Android need gnu11 for POSIX functions (strdup, etc.)
    const c_std: []const u8 = if (target.result.os.tag == .linux) "-std=gnu11" else "-std=c11";

    // iOS requires static library (no runtime dylib loading)
    const linkage: std.builtin.LinkMode = if (is_ios) .static else .dynamic;

    const flutter_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = !is_android,
    });

    const flutter_lib = b.addLibrary(.{
        .name = "colyseus_flutter",
        .root_module = flutter_module,
        .linkage = linkage,
    });

    // Add Apple SDK paths
    if (target.result.os.tag == .macos or target.result.os.tag == .ios or target.result.os.tag == .tvos) {
        addAppleSdkPaths(flutter_lib, apple_sdk_path);
    }

    // Add Android NDK sysroot paths
    if (is_android) {
        addAndroidNdkPaths(flutter_lib, target.result);
    }

    // Add include paths
    flutter_lib.addIncludePath(native_sdk_dep.path("include"));
    flutter_lib.addIncludePath(native_sdk_dep.path("third_party/uthash/src"));
    flutter_lib.addIncludePath(b.path("src"));

    // Flutter export layer
    flutter_lib.addCSourceFiles(.{
        .root = b.path("."),
        .files = &.{
            "src/flutter_export.c",
        },
        .flags = &.{
            "-Wall",
            "-Wextra",
            "-pedantic",
            c_std,
        },
    });

    // Link the pre-built colyseus library from native_sdk
    flutter_lib.linkLibrary(native_sdk_dep.artifact("colyseus"));

    // Link platform-specific system libraries
    if (target.result.os.tag == .linux) {
        if (!is_android) {
            flutter_lib.linkSystemLibrary("pthread");
            flutter_lib.linkSystemLibrary("m");
        }
    } else if (target.result.os.tag == .macos or target.result.os.tag == .ios) {
        flutter_lib.linkSystemLibrary("pthread");
        flutter_lib.linkFramework("CoreFoundation");
        flutter_lib.linkFramework("Security");
    } else if (target.result.os.tag == .windows) {
        flutter_lib.linkSystemLibrary("ws2_32");
        flutter_lib.linkSystemLibrary("crypt32");
    }

    // Install to platform-specific directory
    const install_path = getPlatformInstallPath(target.result);
    const install_step = b.addInstallArtifact(flutter_lib, .{
        .dest_dir = .{
            .override = .{
                .custom = install_path,
            },
        },
    });
    b.getInstallStep().dependOn(&install_step.step);
}

fn getPlatformInstallPath(target: std.Target) []const u8 {
    return switch (target.os.tag) {
        .windows => "lib/windows/x64",
        .macos => if (target.cpu.arch == .aarch64) "lib/macos/arm64" else "lib/macos/x64",
        .ios => "lib/ios/arm64",
        .linux => {
            if (target.abi == .android or target.abi == .androideabi) {
                return switch (target.cpu.arch) {
                    .aarch64 => "lib/android/arm64-v8a",
                    .arm => "lib/android/armeabi-v7a",
                    .x86_64 => "lib/android/x86_64",
                    else => "lib/android/unknown",
                };
            }
            return "lib/linux/x64";
        },
        else => "lib/unknown",
    };
}
