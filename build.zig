const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options
    const target = b.standardTargetOptions(.{});

    // Standard optimization options
    const optimize = b.standardOptimizeOption(.{});

    // Platform detection
    const os_tag = target.result.os.tag;
    const is_emscripten = os_tag == .emscripten;
    const is_windows = os_tag == .windows;

    // Determine C standard based on platform
    const c_std = if (os_tag == .linux) "-std=gnu11" else "-std=c11";

    // Build options
    const build_shared = b.option(bool, "shared", "Build shared library") orelse false;
    const build_examples = b.option(bool, "examples", "Build example programs") orelse (if (is_emscripten) false else true);
    const skip_integration = b.option(bool, "skip-integration", "Skip integration tests (which require a running server)") orelse false;
    const debug_tests = b.option(bool, "debug-tests", "Install test executables for debugging") orelse false;

    // Apple SDK path option (auto-detected on macOS if not specified)
    // Handles macOS, iOS, and tvOS targets
    const apple_sdk_path: ?[]const u8 = b.option([]const u8, "apple-sdk", "Path to Apple SDK (e.g., from 'xcrun --sdk macosx --show-sdk-path')") orelse blk: {
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

    // Helper to add Apple SDK paths to a compile step (macOS, iOS, tvOS)
    const addAppleSdkPaths = struct {
        fn add(compile_step: *std.Build.Step.Compile, sdk_path: ?[]const u8) void {
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
    }.add;

    // ========================================================================
    // Build wslay library (not needed for emscripten - uses browser WebSocket)
    // ========================================================================

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

    // Build wslay only for native targets (emscripten uses browser WebSocket)
    var wslay: ?*std.Build.Step.Compile = null;
    if (!is_emscripten) {
        const wslay_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        });

        wslay = b.addLibrary(.{
            .name = "wslay",
            .root_module = wslay_module,
            .linkage = .static,
        });

        wslay.?.linkLibC();
        addAppleSdkPaths(wslay.?, apple_sdk_path);
        wslay.?.addIncludePath(b.path("third_party/wslay/lib/includes"));
        wslay.?.addIncludePath(b.path("third_party/wslay/lib"));
        wslay.?.addConfigHeader(wslay_config_h);
        wslay.?.addConfigHeader(wslay_version_h);

        wslay.?.addCSourceFiles(.{
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

        // Install wslay headers (only for native)
        const wslay_install = b.addInstallHeaderFile(
            b.path("third_party/wslay/lib/includes/wslay/wslay.h"),
            "wslay/wslay.h",
        );
        b.getInstallStep().dependOn(&wslay_install.step);

        const wslay_ver_install = b.addInstallHeaderFile(
            wslay_version_h.getOutput(),
            "wslay/wslayver.h",
        );
        b.getInstallStep().dependOn(&wslay_ver_install.step);
    }

    // Install uthash header (used by public colyseus headers)
    const uthash_install = b.addInstallHeaderFile(
        b.path("third_party/uthash/src/uthash.h"),
        "uthash.h",
    );
    b.getInstallStep().dependOn(&uthash_install.step);

    // ========================================================================
    // Build Zig modules for HTTP and URL parsing
    // For emscripten: use WASM-specific flags and skip http.zig (use http_web.c)
    // ========================================================================

    // HTTP Zig module (only for native - emscripten uses http_web.c)
    var http_object: ?*std.Build.Step.Compile = null;
    if (!is_emscripten) {
        const http_zig_module = b.createModule(.{
            .root_source_file = b.path("src/network/http.zig"),
            .target = target,
            .optimize = optimize,
        });
        http_zig_module.addIncludePath(b.path("include"));
        http_zig_module.addIncludePath(b.path("third_party/uthash/src"));

        http_object = b.addLibrary(.{
            .name = "http_zig",
            .root_module = http_zig_module,
            .linkage = .static,
        });
        http_object.?.linkLibC();
        addAppleSdkPaths(http_object.?, apple_sdk_path);
    }

    // System certificates Zig module (only for native - uses std.crypto.Certificate.Bundle)
    var system_certs_object: ?*std.Build.Step.Compile = null;
    if (!is_emscripten) {
        const system_certs_module = b.createModule(.{
            .root_source_file = b.path("src/certs/system_certs.zig"),
            .target = target,
            .optimize = optimize,
        });

        system_certs_object = b.addLibrary(.{
            .name = "system_certs_zig",
            .root_module = system_certs_module,
            .linkage = .static,
        });
        system_certs_object.?.linkLibC();
        addAppleSdkPaths(system_certs_object.?, apple_sdk_path);
    }

    // String util Zig module (needed for both native and emscripten)
    const strutil_zig_module = b.createModule(.{
        .root_source_file = b.path("src/utils/strUtil.zig"),
        .target = target,
        .optimize = optimize,
        // WASM-specific flags for emscripten
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
    if (!is_emscripten) addAppleSdkPaths(strutil_object, apple_sdk_path);

    // ========================================================================
    // Build msgpack builder module (wraps zig-msgpack for C interop)
    // ========================================================================
    const msgpack_dep = b.dependency("zig_msgpack", .{
        .target = target,
        .optimize = optimize,
    });

    const msgpack_module = msgpack_dep.module("msgpack");

    // Apply WASM-specific flags to msgpack module for emscripten
    if (is_emscripten) {
        msgpack_module.pic = true;
        msgpack_module.stack_check = false;
        msgpack_module.omit_frame_pointer = true;
        msgpack_module.unwind_tables = .none;
    }

    const msgpack_builder_module = b.createModule(.{
        .root_source_file = b.path("src/msgpack/msgpack_builder.zig"),
        .target = target,
        .optimize = optimize,
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
    if (!is_emscripten) addAppleSdkPaths(msgpack_builder_object, apple_sdk_path);

    // Msgpack reader module (for decoding msgpack in on_message callbacks)
    const msgpack_reader_module = b.createModule(.{
        .root_source_file = b.path("src/msgpack/msgpack_reader.zig"),
        .target = target,
        .optimize = optimize,
        .stack_check = if (is_emscripten) false else null,
        .pic = if (is_emscripten) true else null,
        .omit_frame_pointer = if (is_emscripten) true else null,
        .unwind_tables = if (is_emscripten) .none else null,
    });
    msgpack_reader_module.addImport("msgpack", msgpack_module);

    const msgpack_reader_object = b.addLibrary(.{
        .name = "msgpack_reader",
        .root_module = msgpack_reader_module,
        .linkage = .static,
    });
    msgpack_reader_object.linkLibC();
    if (!is_emscripten) addAppleSdkPaths(msgpack_reader_object, apple_sdk_path);

    // ========================================================================
    // Build mbedTLS from source (v3.6.4 LTS)
    // ========================================================================

    const mbedcrypto = b.addLibrary(.{
        .name = "mbedcrypto",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
        .linkage = .static,
    });
    mbedcrypto.linkLibC();
    addAppleSdkPaths(mbedcrypto, apple_sdk_path);
    mbedcrypto.addIncludePath(b.path("third_party/mbedtls/include"));
    mbedcrypto.addIncludePath(b.path("third_party/mbedtls/library"));
    mbedcrypto.addCSourceFiles(.{
        .files = &.{
            "third_party/mbedtls/library/aes.c",
            "third_party/mbedtls/library/aesce.c",
            "third_party/mbedtls/library/aesni.c",
            "third_party/mbedtls/library/aria.c",
            "third_party/mbedtls/library/asn1parse.c",
            "third_party/mbedtls/library/asn1write.c",
            "third_party/mbedtls/library/base64.c",
            "third_party/mbedtls/library/bignum.c",
            "third_party/mbedtls/library/bignum_core.c",
            "third_party/mbedtls/library/bignum_mod.c",
            "third_party/mbedtls/library/bignum_mod_raw.c",
            "third_party/mbedtls/library/block_cipher.c",
            "third_party/mbedtls/library/camellia.c",
            "third_party/mbedtls/library/ccm.c",
            "third_party/mbedtls/library/chacha20.c",
            "third_party/mbedtls/library/chachapoly.c",
            "third_party/mbedtls/library/cipher.c",
            "third_party/mbedtls/library/cipher_wrap.c",
            "third_party/mbedtls/library/cmac.c",
            "third_party/mbedtls/library/constant_time.c",
            "third_party/mbedtls/library/ctr_drbg.c",
            "third_party/mbedtls/library/des.c",
            "third_party/mbedtls/library/dhm.c",
            "third_party/mbedtls/library/ecdh.c",
            "third_party/mbedtls/library/ecdsa.c",
            "third_party/mbedtls/library/ecjpake.c",
            "third_party/mbedtls/library/ecp.c",
            "third_party/mbedtls/library/ecp_curves.c",
            "third_party/mbedtls/library/ecp_curves_new.c",
            "third_party/mbedtls/library/entropy.c",
            "third_party/mbedtls/library/entropy_poll.c",
            "third_party/mbedtls/library/error.c",
            "third_party/mbedtls/library/gcm.c",
            "third_party/mbedtls/library/hkdf.c",
            "third_party/mbedtls/library/hmac_drbg.c",
            "third_party/mbedtls/library/lmots.c",
            "third_party/mbedtls/library/lms.c",
            "third_party/mbedtls/library/md.c",
            "third_party/mbedtls/library/md5.c",
            "third_party/mbedtls/library/memory_buffer_alloc.c",
            "third_party/mbedtls/library/mps_reader.c",
            "third_party/mbedtls/library/mps_trace.c",
            "third_party/mbedtls/library/nist_kw.c",
            "third_party/mbedtls/library/oid.c",
            "third_party/mbedtls/library/padlock.c",
            "third_party/mbedtls/library/pem.c",
            "third_party/mbedtls/library/pk.c",
            "third_party/mbedtls/library/pk_ecc.c",
            "third_party/mbedtls/library/pk_wrap.c",
            "third_party/mbedtls/library/pkcs12.c",
            "third_party/mbedtls/library/pkcs5.c",
            "third_party/mbedtls/library/pkcs7.c",
            "third_party/mbedtls/library/pkparse.c",
            "third_party/mbedtls/library/pkwrite.c",
            "third_party/mbedtls/library/platform.c",
            "third_party/mbedtls/library/platform_util.c",
            "third_party/mbedtls/library/poly1305.c",
            "third_party/mbedtls/library/psa_crypto.c",
            "third_party/mbedtls/library/psa_crypto_aead.c",
            "third_party/mbedtls/library/psa_crypto_cipher.c",
            "third_party/mbedtls/library/psa_crypto_client.c",
            "third_party/mbedtls/library/psa_crypto_driver_wrappers_no_static.c",
            "third_party/mbedtls/library/psa_crypto_ecp.c",
            "third_party/mbedtls/library/psa_crypto_ffdh.c",
            "third_party/mbedtls/library/psa_crypto_hash.c",
            "third_party/mbedtls/library/psa_crypto_mac.c",
            "third_party/mbedtls/library/psa_crypto_pake.c",
            "third_party/mbedtls/library/psa_crypto_rsa.c",
            "third_party/mbedtls/library/psa_crypto_se.c",
            "third_party/mbedtls/library/psa_crypto_slot_management.c",
            "third_party/mbedtls/library/psa_crypto_storage.c",
            "third_party/mbedtls/library/psa_its_file.c",
            "third_party/mbedtls/library/psa_util.c",
            "third_party/mbedtls/library/ripemd160.c",
            "third_party/mbedtls/library/rsa.c",
            "third_party/mbedtls/library/rsa_alt_helpers.c",
            "third_party/mbedtls/library/sha1.c",
            "third_party/mbedtls/library/sha256.c",
            "third_party/mbedtls/library/sha3.c",
            "third_party/mbedtls/library/sha512.c",
            "third_party/mbedtls/library/threading.c",
            "third_party/mbedtls/library/timing.c",
            "third_party/mbedtls/library/version.c",
            "third_party/mbedtls/library/version_features.c",
        },
        .flags = &.{ "-Wall", c_std },
    });

    const mbedx509 = b.addLibrary(.{
        .name = "mbedx509",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
        .linkage = .static,
    });
    mbedx509.linkLibC();
    addAppleSdkPaths(mbedx509, apple_sdk_path);
    mbedx509.addIncludePath(b.path("third_party/mbedtls/include"));
    mbedx509.addIncludePath(b.path("third_party/mbedtls/library"));
    mbedx509.addCSourceFiles(.{
        .files = &.{
            "third_party/mbedtls/library/x509.c",
            "third_party/mbedtls/library/x509_create.c",
            "third_party/mbedtls/library/x509_crl.c",
            "third_party/mbedtls/library/x509_crt.c",
            "third_party/mbedtls/library/x509_csr.c",
            "third_party/mbedtls/library/x509write.c",
            "third_party/mbedtls/library/x509write_crt.c",
            "third_party/mbedtls/library/x509write_csr.c",
        },
        .flags = &.{ "-Wall", c_std },
    });
    mbedx509.linkLibrary(mbedcrypto);

    const mbedtls = b.addLibrary(.{
        .name = "mbedtls",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
        .linkage = .static,
    });
    mbedtls.linkLibC();
    addAppleSdkPaths(mbedtls, apple_sdk_path);
    mbedtls.addIncludePath(b.path("third_party/mbedtls/include"));
    mbedtls.addIncludePath(b.path("third_party/mbedtls/library"));
    mbedtls.addCSourceFiles(.{
        .files = &.{
            "third_party/mbedtls/library/debug.c",
            "third_party/mbedtls/library/net_sockets.c",
            "third_party/mbedtls/library/ssl_cache.c",
            "third_party/mbedtls/library/ssl_ciphersuites.c",
            "third_party/mbedtls/library/ssl_client.c",
            "third_party/mbedtls/library/ssl_cookie.c",
            "third_party/mbedtls/library/ssl_debug_helpers_generated.c",
            "third_party/mbedtls/library/ssl_msg.c",
            "third_party/mbedtls/library/ssl_ticket.c",
            "third_party/mbedtls/library/ssl_tls.c",
            "third_party/mbedtls/library/ssl_tls12_client.c",
            "third_party/mbedtls/library/ssl_tls12_server.c",
            "third_party/mbedtls/library/ssl_tls13_client.c",
            "third_party/mbedtls/library/ssl_tls13_generic.c",
            "third_party/mbedtls/library/ssl_tls13_keys.c",
            "third_party/mbedtls/library/ssl_tls13_server.c",
        },
        .flags = &.{ "-Wall", c_std },
    });
    mbedtls.linkLibrary(mbedx509);
    mbedtls.linkLibrary(mbedcrypto);

    // ========================================================================
    // Build colyseus library
    // ========================================================================
    const colyseus_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        // WASM-specific flags for emscripten
        .pic = if (is_emscripten) true else null,
    });

    const linkage: std.builtin.LinkMode = if (build_shared) .dynamic else .static;

    const colyseus = b.addLibrary(.{
        .name = "colyseus",
        .root_module = colyseus_module,
        .linkage = linkage,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });

    colyseus.linkLibC();
    if (!is_emscripten) addAppleSdkPaths(colyseus, apple_sdk_path);

    // Add include paths
    colyseus.addIncludePath(b.path("include"));
    colyseus.addIncludePath(b.path("src"));
    colyseus.addIncludePath(b.path("third_party/sds"));
    colyseus.addIncludePath(b.path("third_party/uthash/src"));
    colyseus.addIncludePath(b.path("third_party/cJSON"));
    colyseus.addIncludePath(b.path("third_party/wslay/lib/includes"));

    // Add generated header paths from wslay
    colyseus.addIncludePath(wslay_config_h.getOutput().dirname());
    colyseus.addIncludePath(wslay_version_h.getOutput().dirname().dirname());

    // Common C source files (shared between native and web)
    const common_sources = [_][]const u8{
        // Core
        "src/common/settings.c",
        "src/client.c",
        "src/room.c",
        // Schema
        "src/schema/decode.c",
        "src/schema/ref_tracker.c",
        "src/schema/collections.c",
        "src/schema/decoder.c",
        "src/schema/serializer.c",
        "src/schema/callbacks.c",
        "src/schema/dynamic_schema.c",
        // Utils
        "src/utils/strUtil.c",
        "src/utils/sha1_c.c",
        // Auth
        "src/auth/auth.c",
        "src/auth/secure_storage.c",
        // TLS certificates bundle
        "src/certs/ca_bundle.c",
        // Third-party sources
        "third_party/sds/sds.c",
        "third_party/cJSON/cJSON.c",
    };

    // Platform-specific network sources
    const native_network_sources = [_][]const u8{
        "src/network/websocket_transport.c",
    };

    const web_network_sources = [_][]const u8{
        "src/network/websocket_transport_web.c",
        "src/network/http_web.c",
    };

    // C flags
    const base_flags = [_][]const u8{ "-Wall", "-Wextra", "-pedantic", c_std };
    const web_flags = [_][]const u8{ "-Wall", "-Wextra", "-pedantic", c_std, "-DPLATFORM_WEB" };

    // Add common sources
    colyseus.addCSourceFiles(.{
        .files = &common_sources,
        .flags = if (is_emscripten) &web_flags else &base_flags,
    });

    // Always link mbedTLS (TLS is runtime-enabled via settings)
    colyseus.addIncludePath(b.path("third_party/mbedtls/include"));
    colyseus.linkLibrary(mbedtls);
    colyseus.linkLibrary(mbedx509);
    colyseus.linkLibrary(mbedcrypto);

    // Add platform-specific network sources
    if (is_emscripten) {
        colyseus.addCSourceFiles(.{
            .files = &web_network_sources,
            .flags = &web_flags,
        });
    } else {
        colyseus.addCSourceFiles(.{
            .files = &native_network_sources,
            .flags = &base_flags,
        });
    }

    // Link Zig libraries
    if (http_object) |http| colyseus.linkLibrary(http);
    if (system_certs_object) |certs| colyseus.linkLibrary(certs);
    colyseus.linkLibrary(strutil_object);
    colyseus.linkLibrary(msgpack_builder_object);
    colyseus.linkLibrary(msgpack_reader_object);

    // Link wslay (native only)
    if (wslay) |w| colyseus.linkLibrary(w);

    // Link system libraries based on platform
    if (os_tag == .linux) {
        colyseus.linkSystemLibrary("pthread");
        colyseus.linkSystemLibrary("m");
    } else if (os_tag == .macos) {
        colyseus.linkSystemLibrary("pthread");
        colyseus.linkFramework("CoreFoundation");
        colyseus.linkFramework("Security");
    } else if (os_tag == .ios or os_tag == .tvos) {
        colyseus.linkFramework("CoreFoundation");
        colyseus.linkFramework("Security");
    } else if (os_tag == .windows) {
        colyseus.linkSystemLibrary("ws2_32");
        colyseus.linkSystemLibrary("crypt32");
        colyseus.linkSystemLibrary("bcrypt");
    }
    // Note: emscripten links are handled by emcc at final link time

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
        "schema.h",
        "schema/types.h",
        "schema/decode.h",
        "schema/ref_tracker.h",
        "schema/collections.h",
        "schema/decoder.h",
        "schema/callbacks.h",
        "utils/sha1_c.h",
        "utils/strUtil.h",
        "auth/auth.h",
        "auth/secure_storage.h",
        "messages.h",
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
    // Build and run tests (skip for emscripten - can't run wasm tests directly)
    // ========================================================================
    if (is_emscripten) return;

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
        .{ .name = "test_schema", .file = "tests/test_schema.zig", .description = "Run schema tests" },
        .{ .name = "test_suite", .file = "tests/test_suite.zig", .description = "Run unit test suite" },
        .{ .name = "test_integration", .file = "tests/test_integration.zig", .description = "Run integration tests (requires server)" },
        .{ .name = "test_schema_callbacks", .file = "tests/test_schema_callbacks.zig", .description = "Run schema callbacks tests (requires server)" },
        .{ .name = "test_messages", .file = "tests/test_messages.zig", .description = "Run message types tests (requires server)" },
    };

    // Build each Zig test
    for (zig_test_files) |test_file| {
        // Skip integration tests if requested (these require a running server)
        if (skip_integration and
            (std.mem.eql(u8, test_file.name, "test_integration") or
                std.mem.eql(u8, test_file.name, "test_schema_callbacks") or
                std.mem.eql(u8, test_file.name, "test_messages")))
        {
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
        test_exe.addIncludePath(b.path("tests"));
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
