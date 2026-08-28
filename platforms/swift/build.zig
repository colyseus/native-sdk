const std = @import("std");

// Must match the platforms list in Package.swift. A library stamped with a
// newer minimum than the app targets makes the linker warn on every build.
const macos_min: std.SemanticVersion = .{ .major = 13, .minor = 0, .patch = 0 };
const ios_min: std.SemanticVersion = .{ .major = 15, .minor = 0, .patch = 0 };
const tvos_min: std.SemanticVersion = .{ .major = 15, .minor = 0, .patch = 0 };

pub fn build(b: *std.Build) void {
    const target = appleTarget(b);
    const optimize = b.standardOptimizeOption(.{});
    const apple_sdk_path = resolveAppleSdk(b, target.result);

    // Every C source, include path and third-party library comes from the root
    // build. Restating them here is what left this package unbuildable for five
    // months: the core grew room_clock.c, input_handle.c and the whole predict
    // layer, and a hand-copied file list cannot grow with it.
    const native_sdk = if (apple_sdk_path) |sdk|
        b.dependency("native_sdk", .{
            .target = target,
            .optimize = optimize,
            .@"apple-sdk" = @as([]const u8, sdk),
        })
    else
        b.dependency("native_sdk", .{ .target = target, .optimize = optimize });

    const core = native_sdk.artifact("colyseus");

    // linkLibrary records a link-time dependency, which means nothing for an
    // archive we hand to Xcode: the shipped .a must physically hold the core,
    // wslay, mbedTLS and the Zig msgpack/http objects. Merge the closure rather
    // than naming the members that happen to exist today.
    // mbedTLS compiles a few configuration-empty translation units, and libtool
    // warns once per object about them.
    const merge = b.addSystemCommand(&.{ "libtool", "-static", "-no_warning_for_no_symbols", "-o" });
    const merged = merge.addOutputFileArg("libcolyseus.a");
    for (core.getCompileDependencies(false)) |dep| {
        if (dep.isStaticLibrary()) merge.addArtifactArg(dep);
    }
    const install_lib = b.addInstallFileWithDir(merged, .lib, "libcolyseus.a");
    b.getInstallStep().dependOn(&install_lib.step);

    // Whatever the core ships, the xcframework ships — colyseus.h, the tree
    // under colyseus/, and uthash.h, which several public headers include
    // unqualified. Taking it from the artifact means this package cannot
    // disagree with the core about what is public.
    const install_headers = b.addInstallDirectory(.{
        .source_dir = core.getEmittedIncludeTree(),
        .install_dir = .header,
        .install_subdir = "",
    });
    b.getInstallStep().dependOn(&install_headers.step);

    // Clang resolves the module through these two, so they sit at the root of
    // the header tree next to colyseus/.
    for ([_][]const u8{ "colyseus_swift.h", "module.modulemap" }) |name| {
        const step = b.addInstallFileWithDir(
            b.path(b.fmt("include/{s}", .{name})),
            .header,
            name,
        );
        b.getInstallStep().dependOn(&step.step);
    }
}

/// The host target, adjusted in place — rebuilding the query field by field
/// silently drops anything not copied across, `-Dcpu` included.
fn appleTarget(b: *std.Build) std.Build.ResolvedTarget {
    const host = b.standardTargetOptions(.{});
    var query = host.query;

    // Zig resolves the simulator ABI to a baseline CPU, and mbedTLS's AES paths
    // do not compile without the features a real core carries.
    if (host.result.cpu.arch == .aarch64 and host.result.abi == .simulator) {
        switch (query.cpu_model) {
            .determined_by_arch_os => query.cpu_model = .{ .explicit = &std.Target.aarch64.cpu.apple_m1 },
            else => {},
        }
    }

    if (query.os_version_min == null) {
        switch (host.result.os.tag) {
            .macos => query.os_version_min = .{ .semver = macos_min },
            .ios => query.os_version_min = .{ .semver = ios_min },
            .tvos => query.os_version_min = .{ .semver = tvos_min },
            else => {},
        }
    }

    return b.resolveTargetQuery(query);
}

fn resolveAppleSdk(b: *std.Build, target: std.Target) ?[]const u8 {
    if (b.option([]const u8, "apple-sdk", "Path to the Apple SDK to compile against")) |sdk| {
        return sdk;
    }

    const sdk_name = switch (target.os.tag) {
        .macos => "macosx",
        // The simulator is a different SDK, not a variant of the device one:
        // its headers and stub libraries are built for the host.
        .ios => if (target.abi == .simulator) "iphonesimulator" else "iphoneos",
        .tvos => if (target.abi == .simulator) "appletvsimulator" else "appletvos",
        else => return null,
    };

    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "xcrun", "--sdk", sdk_name, "--show-sdk-path" },
    }) catch return null;
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);

    if (result.term.Exited != 0 or result.stdout.len == 0) return null;
    return b.allocator.dupe(u8, std.mem.trimRight(u8, result.stdout, "\n\r")) catch null;
}
