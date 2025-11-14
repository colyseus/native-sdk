const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options
    const target = b.standardTargetOptions(.{});

    // Standard optimization options
    const optimize = b.standardOptimizeOption(.{});

    // Determine C standard based on platform
    const c_std = if (target.result.os.tag == .linux) "-std=gnu11" else "-std=c11";

    // Build options
    const build_shared = b.option(bool, "shared", "Build shared library") orelse false;
    const build_examples = b.option(bool, "examples", "Build example programs") orelse true;
    const skip_integration = b.option(bool, "skip-integration", "Skip integration tests (which require a running server)") orelse false;
    const debug_tests = b.option(bool, "debug-tests", "Install test executables for debugging") orelse false;

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
            c_std,
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
            c_std,
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
    const headers = .{
        "client.h",
        "http.h",
        "protocol.h",
        "room.h",
        "settings.h",
        "transport.h",
        "websocket_transport.h",
        "utils/sha1_c.h",
        "utils/strUtil.h",
        "auth/auth.h",
        "auth/secure_storage.h",
    };

    inline for (headers) |header| {
        const install_header = b.addInstallHeaderFile(
            b.path("include/colyseus/" ++ header),
            "colyseus/" ++ header,
        );
        b.getInstallStep().dependOn(&install_header.step);
    }

    // ========================================================================
    // Helper function to build examples
    // ========================================================================
    const ExampleConfig = struct {
        name: []const u8,
        source_file: []const u8,
        run_step_name: []const u8,
        run_step_desc: []const u8,
    };

    const buildExample = struct {
        fn build(
            builder: *std.Build,
            config: ExampleConfig,
            tgt: std.Build.ResolvedTarget,
            opt: std.builtin.OptimizeMode,
            colyseus_lib: *std.Build.Step.Compile,
            wslay_version_header: *std.Build.Step.ConfigHeader,
            c_standard: []const u8,
        ) void {
            const example_module = builder.createModule(.{
                .target = tgt,
                .optimize = opt,
            });

            const example = builder.addExecutable(.{
                .name = config.name,
                .root_module = example_module,
            });

            example.linkLibC();
            example.addCSourceFile(.{
                .file = builder.path(config.source_file),
                .flags = &.{
                    "-Wall",
                    "-Wextra",
                    c_standard,
                },
            });

            example.addIncludePath(builder.path("include"));
            example.addIncludePath(builder.path("third_party/uthash/src"));
            example.addIncludePath(builder.path("third_party/sds"));
            example.addIncludePath(builder.path("third_party/cJSON"));
            example.addIncludePath(builder.path("third_party/wslay/lib/includes"));
            example.addIncludePath(wslay_version_header.getOutput().dirname().dirname());
            example.linkLibrary(colyseus_lib);

            builder.installArtifact(example);

            const run_example = builder.addRunArtifact(example);
            run_example.step.dependOn(builder.getInstallStep());

            const run_step = builder.step(config.run_step_name, config.run_step_desc);
            run_step.dependOn(&run_example.step);
        }
    }.build;

    // ========================================================================
    // Build examples
    // ========================================================================
    if (build_examples) {
        buildExample(b, .{
            .name = "simple_example",
            .source_file = "examples/simple_example.c",
            .run_step_name = "run-example",
            .run_step_desc = "Run the simple example",
        }, target, optimize, colyseus, wslay_version_h, c_std);

        buildExample(b, .{
            .name = "auth_example",
            .source_file = "examples/auth_example.c",
            .run_step_name = "run-auth-example",
            .run_step_desc = "Run the auth example",
        }, target, optimize, colyseus, wslay_version_h, c_std);
    }

    // ========================================================================
    // Build and run tests
    // ========================================================================
    const test_step = b.step("test", "Run unit tests");

    // Define all Zig test files
    const zig_test_files = [_]struct {
        name: []const u8,
        file: []const u8,
        description: []const u8,
    }{
        .{ .name = "test_http", .file = "tests/test_http.zig", .description = "Run HTTP tests" },
        .{ .name = "test_auth", .file = "tests/test_auth.zig", .description = "Run authentication tests" },
        .{ .name = "test_room", .file = "tests/test_room.zig", .description = "Run room tests" },
        .{ .name = "test_storage", .file = "tests/test_storage.zig", .description = "Run storage tests" },
        .{ .name = "test_suite", .file = "tests/test_suite.zig", .description = "Run unit test suite" },
        .{ .name = "test_integration", .file = "tests/test_integration.zig", .description = "Run integration tests (requires server)" },
    };

    // Build each Zig test
    for (zig_test_files) |test_file| {
        // Skip integration test if requested
        if (skip_integration and std.mem.eql(u8, test_file.name, "test_integration")) {
            continue;
        }

        const test_module = b.createModule(.{
            .root_source_file = b.path(test_file.file),
            .target = target,
            .optimize = optimize,
        });

        const test_exe = b.addTest(.{
            .root_module = test_module,
        });

        test_exe.linkLibC();
        test_exe.addIncludePath(b.path("include"));
        test_exe.addIncludePath(b.path("third_party/uthash/src"));
        test_exe.addIncludePath(b.path("third_party/sds"));
        test_exe.addIncludePath(b.path("third_party/cJSON"));
        test_exe.addIncludePath(b.path("third_party/wslay/lib/includes"));
        test_exe.addIncludePath(wslay_version_h.getOutput().dirname().dirname());
        test_exe.linkLibrary(colyseus);

        // If debug-tests is enabled, install the test executable
        if (debug_tests) {
            b.installArtifact(test_exe);
        }

        // Create run command for this test
        const run_test = b.addRunArtifact(test_exe);

        // Add to main test step
        test_step.dependOn(&run_test.step);

        // Also create individual test steps
        const individual_test_step = b.step(test_file.name, test_file.description);
        individual_test_step.dependOn(&run_test.step);
    }
}
