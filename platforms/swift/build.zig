const std = @import("std");

// Must match the platforms list in Package.swift. A library stamped with a
// newer minimum than the app targets makes the linker warn on every build.
const macos_min: std.SemanticVersion = .{ .major = 13, .minor = 0, .patch = 0 };
const ios_min: std.SemanticVersion = .{ .major = 15, .minor = 0, .patch = 0 };
const tvos_min: std.SemanticVersion = .{ .major = 15, .minor = 0, .patch = 0 };

// Public headers that pull in a vendored dependency's headers — wslay for the
// websocket transport, mbedTLS for the TLS context. Shipping them would mean
// shipping those trees too, and Swift reaches neither: transports come from
// the default factory, TLS is configured through settings.h.
const unshippable_headers = [_][]const u8{ "websocket_transport.h", "tls_context.h" };

// The repo root, as build.zig.zon already assumes for the native_sdk dependency.
const repo_root = "../..";

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

    // The whole public tree, so a new header ships without anyone remembering.
    const install_headers = b.addInstallDirectory(.{
        .source_dir = native_sdk.path("include"),
        .install_dir = .header,
        .install_subdir = "",
        .exclude_extensions = &unshippable_headers,
    });
    b.getInstallStep().dependOn(&install_headers.step);

    // schema/dynamic_schema.h includes "uthash.h" unqualified.
    const install_uthash = b.addInstallFileWithDir(
        native_sdk.path("third_party/uthash/src/uthash.h"),
        .header,
        "uthash.h",
    );
    b.getInstallStep().dependOn(&install_uthash.step);

    checkUmbrellaIsComplete(b);

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

/// A header the core ships but the umbrella never includes is invisible to
/// Swift, and nothing else notices — the module still builds, the symbol just
/// isn't there. Clang's -Wincomplete-umbrella does not cover the nested
/// directories this tree uses, so the check lives here instead.
fn checkUmbrellaIsComplete(b: *std.Build) void {
    const umbrella = b.build_root.handle.readFileAlloc(
        b.allocator,
        "include/colyseus_swift.h",
        1 << 20,
    ) catch |err| std.debug.panic("cannot read include/colyseus_swift.h: {s}", .{@errorName(err)});

    var dir = b.build_root.handle.openDir(
        repo_root ++ "/include/colyseus",
        .{ .iterate = true },
    ) catch |err| std.debug.panic("cannot open the core's include tree: {s}", .{@errorName(err)});
    defer dir.close();

    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();

    var missing: usize = 0;
    while (walker.next() catch @panic("walk failed")) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".h")) continue;
        if (isUnshippable(entry.basename)) continue;

        // Walker paths use the host separator; the includes never do.
        const include_path = b.fmt("<colyseus/{s}>", .{entry.path});
        const normalized = std.mem.replaceOwned(u8, b.allocator, include_path, "\\", "/") catch @panic("OOM");
        if (std.mem.indexOf(u8, umbrella, normalized) == null) {
            std.debug.print("colyseus_swift.h is missing #include {s}\n", .{normalized});
            missing += 1;
        }
    }

    if (missing > 0) {
        std.debug.print("{d} public header(s) would not reach Swift\n", .{missing});
        std.process.exit(1);
    }
}

fn isUnshippable(basename: []const u8) bool {
    for (unshippable_headers) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }
    return false;
}
