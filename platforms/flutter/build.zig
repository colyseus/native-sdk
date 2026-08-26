const std = @import("std");

// Deployment minimums must match the podspecs, or the linker warns that the
// vendored library was built for a newer OS than the app targets.
const macos_min: std.SemanticVersion = .{ .major = 10, .minor = 15, .patch = 0 };
const ios_min: std.SemanticVersion = .{ .major = 13, .minor = 0, .patch = 0 };

pub fn build(b: *std.Build) void {
    // Build for all Flutter supported platforms
    const build_all = b.option(bool, "all", "Build for all Flutter platforms") orelse false;

    // Adjust the requested query in place. Rebuilding it field by field drops
    // whatever is not copied across, including -Dcpu.
    const target = blk: {
        const host = b.standardTargetOptions(.{});
        var query = host.query;

        // Zig resolves the simulator ABI to a baseline CPU, and mbedtls's AES
        // paths do not compile without the features a real core carries.
        if (host.result.cpu.arch == .aarch64 and host.result.abi == .simulator) {
            switch (query.cpu_model) {
                .determined_by_arch_os => query.cpu_model = .{ .explicit = &std.Target.aarch64.cpu.apple_m1 },
                else => {},
            }
        }

        // Apple targets get an explicit deployment minimum: without one the
        // dylib is stamped with the build machine's OS version and every
        // consumer app warns that it links something newer than it targets.
        if (query.os_version_min == null) {
            switch (host.result.os.tag) {
                .macos => query.os_version_min = .{ .semver = macos_min },
                .ios => query.os_version_min = .{ .semver = ios_min },
                else => {},
            }
        }

        break :blk b.resolveTargetQuery(query);
    };
    const optimize = b.standardOptimizeOption(.{});

    // pub.dev ships every platform's library to every user, and debug info is
    // most of the weight: an unstripped Linux .so is 12.8 MB.
    const strip = b.option(bool, "strip", "Strip debug symbols from the library") orelse false;

    // Apple SDK path (auto-detected on macOS if not specified)
    const apple_sdk_path: ?[]const u8 = b.option([]const u8, "apple-sdk", "Path to Apple SDK") orelse blk: {
        const os = target.result.os.tag;
        if (os == .macos or os == .ios or os == .tvos) {
            const sdk_name = switch (os) {
                .macos => "macosx",
                .tvos => "appletvos",
                // The simulator is a different SDK, not a variant of the device
                // one: its headers and stub libraries are built for the host.
                else => if (target.result.abi == .simulator) "iphonesimulator" else "iphoneos",
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
            // Dart resolves core symbols out of the built DLL, which needs the
            // MinGW export-all default that cJSON's dllexport would suppress.
            .@"hide-cjson-exports" = true,
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
                .os_version_min = .{ .semver = ios_min },
            }),
            // macOS
            b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = .macos,
                .os_version_min = .{ .semver = macos_min },
            }),
            b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .macos,
                .os_version_min = .{ .semver = macos_min },
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
            buildFlutterLibrary(b, build_target, optimize, native_sdk_dep, apple_sdk_path, strip);
        }
    } else {
        // Build for native target only
        buildFlutterLibrary(b, target, optimize, native_sdk_dep, apple_sdk_path, strip);
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
    strip: bool,
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
        .strip = strip,
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
    var c_flags: std.ArrayList([]const u8) = .empty;
    c_flags.appendSlice(b.allocator, &.{ "-Wall", "-Wextra", "-pedantic", c_std }) catch @panic("OOM");

    // MinGW exports every global symbol until one is marked dllexport, and
    // Dart resolves the core SDK's symbols out of this same library — so the
    // glue must stay unmarked or everything else disappears from the DLL.
    // KNOWN GAP (Windows): the predict/reconciler/spawns objects live in
    // colyseus.lib and nothing in the glue references them, so the linker
    // never pulls those archive members and they miss the export table. The
    // rest of the core (room, clock, input, netdelay) is exported and works.
    // Fixing it needs an anchor table referencing the entry points, the same
    // way iOS needs -force_load.
    if (target.result.os.tag == .windows) {
        c_flags.append(b.allocator, "-DFLUTTER_NO_DLLEXPORT") catch @panic("OOM");
        // Export every symbol instead, so the linked-in core lands in the
        // export table too.
        flutter_lib.rdynamic = true;
    }

    flutter_lib.addCSourceFiles(.{
        .root = b.path("."),
        .files = &.{
            "src/flutter_export.c",
            "src/flutter_extras.c",
            "src/flutter_http.c",
        },
        .flags = c_flags.items,
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

    if (is_ios) {
        // linkLibrary only records a link-time dependency, which means nothing
        // for an archive: the shipped .a would hold the three glue objects and
        // none of the core. Dart resolves core symbols by name out of the host
        // process, so every 0.18 binding would fail at runtime.
        //
        // The closure is deeper than glue + core: the core links http, wslay
        // and mbedtls as their own archives, each of which is equally absent.
        // Merge every static library the graph reaches rather than naming the
        // few that are known today.
        const merge = b.addSystemCommand(&.{ "libtool", "-static", "-o" });
        const merged = merge.addOutputFileArg("libcolyseus_flutter.a");
        for (flutter_lib.getCompileDependencies(false)) |dep| {
            if (dep.isStaticLibrary()) merge.addArtifactArg(dep);
        }

        const install_merged = b.addInstallFileWithDir(
            merged,
            .{ .custom = install_path },
            "libcolyseus_flutter.a",
        );
        b.getInstallStep().dependOn(&install_merged.step);
        return;
    }

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
        // Device and simulator are both arm64 but are not interchangeable, and
        // lipo cannot hold two slices of one architecture. They stay apart here
        // and are joined into an xcframework instead.
        .ios => if (target.abi == .simulator)
            (if (target.cpu.arch == .aarch64) "lib/ios/simulator-arm64" else "lib/ios/simulator-x64")
        else
            "lib/ios/device-arm64",
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
