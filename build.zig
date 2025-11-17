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
    // Helper functions for Windows vcpkg setup
    // ========================================================================
    const getVcpkgSubPath = struct {
        fn get(builder: *std.Build, subdir: []const u8) []const u8 {
            const vcpkg_root_env = std.process.getEnvVarOwned(builder.allocator, "VCPKG_ROOT") catch null;
            const vcpkg_root = vcpkg_root_env orelse "../vcpkg/installed/x64-windows";
            defer if (vcpkg_root_env) |env| builder.allocator.free(env);
            return builder.fmt("{s}/{s}", .{ vcpkg_root, subdir });
        }
    }.get;

    const setupWindowsVcpkgLibPath = struct {
        fn setup(builder: *std.Build, tgt: std.Build.ResolvedTarget, compile_step: *std.Build.Step.Compile) void {
            if (tgt.result.os.tag == .windows) {
                const vcpkg_lib_path = getVcpkgSubPath(builder, "lib");
                compile_step.addLibraryPath(.{ .cwd_relative = vcpkg_lib_path });
            }
        }
    }.setup;

    const setupWindowsVcpkgIncludePath = struct {
        fn setup(builder: *std.Build, tgt: std.Build.ResolvedTarget, compile_step: *std.Build.Step.Compile) void {
            if (tgt.result.os.tag == .windows) {
                const vcpkg_include_path = getVcpkgSubPath(builder, "include");
                compile_step.addIncludePath(.{ .cwd_relative = vcpkg_include_path });
            }
        }
    }.setup;

    const setupWindowsPath = struct {
        fn setup(builder: *std.Build, tgt: std.Build.ResolvedTarget, run_step: *std.Build.Step.Run) void {
            if (tgt.result.os.tag == .windows) {
                const vcpkg_bin_path = getVcpkgSubPath(builder, "bin");

                // Get current PATH and prepend vcpkg/bin
                const current_path = std.process.getEnvVarOwned(builder.allocator, "PATH") catch "";
                defer if (current_path.len > 0) builder.allocator.free(current_path);

                const new_path = if (current_path.len > 0)
                    builder.fmt("{s};{s}", .{ vcpkg_bin_path, current_path })
                else
                    vcpkg_bin_path;

                run_step.setEnvironmentVariable("PATH", new_path);
            }
        }
    }.setup;

    // ========================================================================
    // Build wslay library
    // ========================================================================

    // Generate config.h for wslay based on target platform
    // For most common platforms (Unix-like systems)
    const is_windows = target.result.os.tag == .windows;

    // Create config header with platform-specific values
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
        setupWindowsVcpkgIncludePath(b, target, colyseus);
        setupWindowsVcpkgLibPath(b, target, colyseus);

        // Link libcurl as a system library
        colyseus.linkSystemLibrary("libcurl");
        colyseus.linkSystemLibrary("ws2_32");
        colyseus.linkSystemLibrary("crypt32");
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
            setup_path: fn (*std.Build, std.Build.ResolvedTarget, *std.Build.Step.Run) void,
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

            setupWindowsVcpkgLibPath(builder, tgt, example);

            builder.installArtifact(example);

            const run_example = builder.addRunArtifact(example);
            run_example.step.dependOn(builder.getInstallStep());
            setup_path(builder, tgt, run_example);

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
        }, target, optimize, colyseus, wslay_version_h, c_std, setupWindowsPath);

        buildExample(b, .{
            .name = "auth_example",
            .source_file = "examples/auth_example.c",
            .run_step_name = "run-auth-example",
            .run_step_desc = "Run the auth example",
        }, target, optimize, colyseus, wslay_version_h, c_std, setupWindowsPath);
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

        setupWindowsVcpkgLibPath(b, target, test_exe);

        // If debug-tests is enabled, install the test executable
        if (debug_tests) {
            b.installArtifact(test_exe);
        }

        // Create run command for this test
        const run_test = b.addRunArtifact(test_exe);
        setupWindowsPath(b, target, run_test);

        // Add to main test step
        test_step.dependOn(&run_test.step);

        // Also create individual test steps
        const individual_test_step = b.step(test_file.name, test_file.description);
        individual_test_step.dependOn(&run_test.step);
    }
}
