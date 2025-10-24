const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options
    const target = b.standardTargetOptions(.{});

    // Standard optimization options
    const optimize = b.standardOptimizeOption(.{});

    // Build options
    const build_shared = b.option(bool, "shared", "Build shared library") orelse false;
    const build_examples = b.option(bool, "examples", "Build example programs") orelse true;

    // ========================================================================
    // Build wslay library
    // ========================================================================

    // Generate config.h for wslay based on target platform
    // For most common platforms (Unix-like systems)
    const wslay_config_h = b.addConfigHeader(.{
        .style = .blank,
        .include_path = "config.h",
    }, .{
        .HAVE_ARPA_INET_H = 1, // Available on Unix-like systems
        .HAVE_NETINET_IN_H = 1, // Available on Unix-like systems
        // HAVE_WINSOCK2_H not defined on Unix
        // WORDS_BIGENDIAN not defined (little-endian is most common)
    });

    // Generate wslayver.h for wslay
    const wslay_version_h = b.addConfigHeader(.{
        .style = .{ .cmake = b.path("third_party/wslay/lib/includes/wslay/wslayver.h.in") },
        .include_path = "wslay/wslayver.h",
    }, .{
        .PACKAGE_VERSION = "1.1.1",
    });

    const wslay_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });

    const wslay = b.addLibrary(.{
        .name = "wslay",
        .root_module = wslay_module,
        .linkage = .static,
    });

    wslay.linkLibC();
    wslay.addIncludePath(b.path("third_party/wslay/lib/includes"));
    wslay.addIncludePath(b.path("third_party/wslay/lib"));
    wslay.addConfigHeader(wslay_config_h);
    wslay.addConfigHeader(wslay_version_h);

    // wslay source files
    wslay.addCSourceFiles(.{
        .files = &.{
            "third_party/wslay/lib/wslay_event.c",
            "third_party/wslay/lib/wslay_frame.c",
            "third_party/wslay/lib/wslay_net.c",
            "third_party/wslay/lib/wslay_queue.c",
        },
        .flags = &.{
            "-Wall",
            "-Wextra",
            "-std=c11",
            "-DHAVE_CONFIG_H",
        },
    });

    // Install wslay headers
    const wslay_install = b.addInstallHeaderFile(
        b.path("third_party/wslay/lib/includes/wslay/wslay.h"),
        "wslay/wslay.h",
    );
    b.getInstallStep().dependOn(&wslay_install.step);

    // ========================================================================
    // Build colyseus library
    // ========================================================================
    const colyseus_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });

    const linkage: std.builtin.LinkMode = if (build_shared) .dynamic else .static;

    const colyseus = b.addLibrary(.{
        .name = "colyseus",
        .root_module = colyseus_module,
        .linkage = linkage,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });

    colyseus.linkLibC();

    // Add include paths
    colyseus.addIncludePath(b.path("include"));
    colyseus.addIncludePath(b.path("src"));
    colyseus.addIncludePath(b.path("third_party/sds"));
    colyseus.addIncludePath(b.path("third_party/uthash/src"));
    colyseus.addIncludePath(b.path("third_party/cJSON"));
    colyseus.addIncludePath(b.path("third_party/wslay/lib/includes"));

    // Add generated header paths from wslay
    // wslayver.h is in wslay/ subdirectory, so we need the parent
    colyseus.addIncludePath(wslay_config_h.getOutput().dirname());
    colyseus.addIncludePath(wslay_version_h.getOutput().dirname().dirname());

    // Colyseus source files
    colyseus.addCSourceFiles(.{
        .files = &.{
            // Core
            "src/common/settings.c",
            "src/client.c",
            "src/room.c",
            // Network
            "src/network/http.c",
            "src/network/websocket_transport.c",
            // Utils
            "src/utils/strUtil.c",
            "src/utils/sha1_c.c",

            // Auth
            "src/auth/auth.c",
            "src/auth/secure_storage.c",

            // Third-party sources
            "third_party/sds/sds.c",
            "third_party/cJSON/cJSON.c",
        },
        .flags = &.{
            "-Wall",
            "-Wextra",
            "-pedantic",
            "-std=c11",
        },
    });

    // Link wslay
    colyseus.linkLibrary(wslay);

    // Link system libraries based on platform
    if (target.result.os.tag == .linux) {
        colyseus.linkSystemLibrary("curl");
        colyseus.linkSystemLibrary("pthread");
        colyseus.linkSystemLibrary("m");
    } else if (target.result.os.tag == .macos) {
        colyseus.linkSystemLibrary("curl");
        colyseus.linkSystemLibrary("pthread");
        colyseus.linkFramework("CoreFoundation");
        colyseus.linkFramework("Security");
    } else if (target.result.os.tag == .ios) {
        colyseus.linkSystemLibrary("curl");
        colyseus.linkFramework("CoreFoundation");
        colyseus.linkFramework("Security");
    } else if (target.result.os.tag == .tvos) {
        colyseus.linkSystemLibrary("curl");
        colyseus.linkFramework("CoreFoundation");
        colyseus.linkFramework("Security");
    } else if (target.result.os.tag == .windows) {
        colyseus.linkSystemLibrary("curl");
        colyseus.linkSystemLibrary("ws2_32");
    } else {
        colyseus.linkSystemLibrary("curl");
    }

    // Install the library
    b.installArtifact(colyseus);

    // Install colyseus headers
    const install_client_h = b.addInstallHeaderFile(b.path("include/colyseus/client.h"), "colyseus/client.h");
    const install_http_h = b.addInstallHeaderFile(b.path("include/colyseus/http.h"), "colyseus/http.h");
    const install_protocol_h = b.addInstallHeaderFile(b.path("include/colyseus/protocol.h"), "colyseus/protocol.h");
    const install_room_h = b.addInstallHeaderFile(b.path("include/colyseus/room.h"), "colyseus/room.h");
    const install_settings_h = b.addInstallHeaderFile(b.path("include/colyseus/settings.h"), "colyseus/settings.h");
    const install_transport_h = b.addInstallHeaderFile(b.path("include/colyseus/transport.h"), "colyseus/transport.h");
    const install_websocket_h = b.addInstallHeaderFile(b.path("include/colyseus/websocket_transport.h"), "colyseus/websocket_transport.h");
    const install_sha1_h = b.addInstallHeaderFile(b.path("include/colyseus/utils/sha1_c.h"), "colyseus/utils/sha1_c.h");
    const install_strutil_h = b.addInstallHeaderFile(b.path("include/colyseus/utils/strUtil.h"), "colyseus/utils/strUtil.h");
    const install_auth_auth_h = b.addInstallHeaderFile(b.path("include/colyseus/auth/auth.h"), "colyseus/auth/auth.h");
    const install_auth_secure_storage_h = b.addInstallHeaderFile(b.path("include/colyseus/auth/secure_storage.h"), "colyseus/auth/secure_storage.h");

    b.getInstallStep().dependOn(&install_client_h.step);
    b.getInstallStep().dependOn(&install_http_h.step);
    b.getInstallStep().dependOn(&install_protocol_h.step);
    b.getInstallStep().dependOn(&install_room_h.step);
    b.getInstallStep().dependOn(&install_settings_h.step);
    b.getInstallStep().dependOn(&install_transport_h.step);
    b.getInstallStep().dependOn(&install_websocket_h.step);
    b.getInstallStep().dependOn(&install_sha1_h.step);
    b.getInstallStep().dependOn(&install_strutil_h.step);
    b.getInstallStep().dependOn(&install_auth_auth_h.step);
    b.getInstallStep().dependOn(&install_auth_secure_storage_h.step);

    // ========================================================================
    // Build examples
    // ========================================================================
    if (build_examples) {
        const simple_example_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        });

        const simple_example = b.addExecutable(.{
            .name = "simple_example",
            .root_module = simple_example_module,
        });

        simple_example.linkLibC();
        simple_example.addCSourceFile(.{
            .file = b.path("examples/simple_example.c"),
            .flags = &.{
                "-Wall",
                "-Wextra",
                "-std=c11",
            },
        });

        simple_example.addIncludePath(b.path("include"));
        simple_example.addIncludePath(b.path("third_party/uthash/src"));
        simple_example.addIncludePath(b.path("third_party/sds"));
        simple_example.addIncludePath(b.path("third_party/cJSON"));
        simple_example.addIncludePath(b.path("third_party/wslay/lib/includes"));
        simple_example.addIncludePath(wslay_version_h.getOutput().dirname().dirname());
        simple_example.linkLibrary(colyseus);

        // Install the example
        b.installArtifact(simple_example);

        // Create a run step for the example
        const run_example = b.addRunArtifact(simple_example);
        run_example.step.dependOn(b.getInstallStep());

        const run_step = b.step("run-example", "Run the simple example");
        run_step.dependOn(&run_example.step);
    }

    // ========================================================================
    // Test step (placeholder for future tests)
    // ========================================================================
    const test_step = b.step("test", "Run unit tests");
    _ = test_step; // Currently no tests, but keeping for future
}
