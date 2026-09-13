const std = @import("std");
const builtin = @import("builtin");

// Windows-only: cJSON marks its API __declspec(dllexport) by default, and one
// dllexport anywhere makes MinGW's linker export ONLY marked symbols. A
// consumer that links this library into a DLL and resolves colyseus_* symbols
// at runtime (the Flutter binding does) therefore finds an export table with
// nothing but cJSON in it. Opt in to hide them and get export-all back.
const cjson_hide_symbols_flag = "-DCJSON_HIDE_SYMBOLS";

// 0.16 moved std.process, std.fs and std.net onto std.Io, and both this file
// and the test suites use the 0.15 APIs. Name the version here rather than
// fail on the first of them.
pub const build = if (builtin.zig_version.major == 0 and builtin.zig_version.minor == 15)
    buildSdk
else
    @compileError("the Colyseus native SDK builds with zig 0.15.x (CI uses 0.15.2); this is zig " ++
        builtin.zig_version_string ++ ". Get 0.15.2 from https://ziglang.org/download/");

fn buildSdk(b: *std.Build) void {
    requireSubmodules(b);

    // Standard target options
    const target = b.standardTargetOptions(.{});

    // Standard optimization options
    const optimize = b.standardOptimizeOption(.{});

    // Platform detection
    const os_tag = target.result.os.tag;
    const is_emscripten = os_tag == .emscripten;
    const is_windows = os_tag == .windows;

    // Determine C standard based on platform
    // Linux and Emscripten need gnu11 for POSIX functions (strdup, strndup, etc.)
    const c_std = if (os_tag == .linux or is_emscripten) "-std=gnu11" else "-std=c11";

    // Zig 0.15's DWARF unwinder has no mcontext layout for tvOS, so every Zig
    // module that can panic fails to COMPILE for it. Stripping debug info drops
    // the stack-trace machinery that reaches for it.
    const strip_zig_modules: ?bool = if (os_tag == .tvos)
        true
    else
        b.option(bool, "strip", "Strip debug info from the Zig modules");

    // Build options
    const build_shared = b.option(bool, "shared", "Build shared library") orelse false;
    const build_examples = b.option(bool, "examples", "Build example programs") orelse (if (is_emscripten) false else true);
    const skip_integration = b.option(bool, "skip-integration", "Skip integration tests (which require a running server)") orelse false;
    const debug_tests = b.option(bool, "debug-tests", "Install test executables for debugging") orelse false;
    const hide_cjson_exports = b.option(
        bool,
        "hide-cjson-exports",
        "Windows: compile cJSON without dllexport so the consuming DLL can export all symbols",
    ) orelse false;

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

    // Emscripten sysroot path (auto-detected from em-config if not specified)
    // Required when targeting wasm32-emscripten so C sources can find <string.h>, <emscripten.h>, etc.
    const emscripten_sysroot: ?[]const u8 = b.option([]const u8, "emsdk-sysroot", "Path to Emscripten sysroot (auto-detected from em-config)") orelse blk: {
        if (!is_emscripten) break :blk null;
        const result = std.process.Child.run(.{
            .allocator = b.allocator,
            .argv = &.{ "em-config", "CACHE" },
        }) catch break :blk null;
        defer b.allocator.free(result.stdout);
        defer b.allocator.free(result.stderr);
        if (result.term.Exited == 0 and result.stdout.len > 0) {
            const cache = std.mem.trimRight(u8, result.stdout, "\n\r");
            break :blk std.fmt.allocPrint(b.allocator, "{s}/sysroot/include", .{cache}) catch null;
        }
        break :blk null;
    };

    // Android NDK path option (for cross-compiling to Android)
    // Zig doesn't ship Android Bionic headers, so the NDK sysroot is needed.
    const is_android = os_tag == .linux and (target.result.abi == .android or target.result.abi == .androideabi);
    const android_ndk_path: ?[]const u8 = b.option([]const u8, "android-ndk", "Path to Android NDK (e.g., ANDROID_NDK_HOME)") orelse blk: {
        if (!is_android) break :blk null;
        break :blk std.process.getEnvVarOwned(b.allocator, "ANDROID_NDK_HOME") catch null;
    };

    // Consolidated helper: configure libc linking and platform sysroot paths.
    // Android: skip linkLibC (Zig can't provide bionic), use NDK sysroot instead.
    // Other platforms: linkLibC normally, add Apple/Emscripten paths as needed.
    const configurePlatformLibc = struct {
        fn configure(
            lib: *std.Build.Step.Compile,
            android: bool,
            ndk_path: ?[]const u8,
            tgt: std.Target,
            sdk_path: ?[]const u8,
            emscripten: bool,
            emsdk_sysroot: ?[]const u8,
        ) void {
            if (android) {
                addAndroidNdkPaths(lib, ndk_path, tgt);
            } else {
                lib.linkLibC();
            }
            if (!emscripten) addAppleSdkPaths(lib, sdk_path);
            if (emscripten) addEmscriptenSysroot(lib, emsdk_sysroot);
        }
    }.configure;

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

        configurePlatformLibc(wslay.?, is_android, android_ndk_path, target.result, apple_sdk_path, is_emscripten, emscripten_sysroot);
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
    }

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
            .strip = strip_zig_modules,
        });
        http_zig_module.addIncludePath(b.path("include"));
        http_zig_module.addIncludePath(b.path("third_party/uthash/src"));

        http_object = b.addLibrary(.{
            .name = "http_zig",
            .root_module = http_zig_module,
            .linkage = .static,
        });
        configurePlatformLibc(http_object.?, is_android, android_ndk_path, target.result, apple_sdk_path, is_emscripten, emscripten_sysroot);
    }

    // System certificates Zig module (only for native - uses std.crypto.Certificate.Bundle)
    var system_certs_object: ?*std.Build.Step.Compile = null;
    if (!is_emscripten) {
        const system_certs_module = b.createModule(.{
            .root_source_file = b.path("src/certs/system_certs.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip_zig_modules,
        });

        system_certs_object = b.addLibrary(.{
            .name = "system_certs_zig",
            .root_module = system_certs_module,
            .linkage = .static,
        });
        configurePlatformLibc(system_certs_object.?, is_android, android_ndk_path, target.result, apple_sdk_path, is_emscripten, emscripten_sysroot);
    }

    // String util Zig module (needed for both native and emscripten)
    const strutil_zig_module = b.createModule(.{
        .root_source_file = b.path("src/utils/strUtil.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip_zig_modules,
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
    configurePlatformLibc(strutil_object, is_android, android_ndk_path, target.result, apple_sdk_path, is_emscripten, emscripten_sysroot);

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
        .strip = strip_zig_modules,
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
    configurePlatformLibc(msgpack_builder_object, is_android, android_ndk_path, target.result, apple_sdk_path, is_emscripten, emscripten_sysroot);

    // Msgpack reader module (for decoding msgpack in on_message callbacks)
    const msgpack_reader_module = b.createModule(.{
        .root_source_file = b.path("src/msgpack/msgpack_reader.zig"),
        .target = target,
        .optimize = optimize,
        // Workaround for Zig 0.15 archiver bug: odd-sized objects produce
        // malformed .a files (missing trailing pad byte). Stripping debug
        // info avoids the odd size that triggers the lld error.
        .strip = true,
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
    configurePlatformLibc(msgpack_reader_object, is_android, android_ndk_path, target.result, apple_sdk_path, is_emscripten, emscripten_sysroot);

    // ========================================================================
    // Build mbedTLS from source (v3.6.4 LTS)
    // ========================================================================

    const mbedcrypto = b.addLibrary(.{
        .name = "mbedcrypto",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
        .linkage = .static,
    });
    configurePlatformLibc(mbedcrypto, is_android, android_ndk_path, target.result, apple_sdk_path, is_emscripten, emscripten_sysroot);
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
    configurePlatformLibc(mbedx509, is_android, android_ndk_path, target.result, apple_sdk_path, is_emscripten, emscripten_sysroot);
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
    configurePlatformLibc(mbedtls, is_android, android_ndk_path, target.result, apple_sdk_path, is_emscripten, emscripten_sysroot);
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

    configurePlatformLibc(colyseus, is_android, android_ndk_path, target.result, apple_sdk_path, is_emscripten, emscripten_sysroot);

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
        "src/room_clock.c",
        "src/input_handle.c",
        "src/predict/reconciler.c",
        "src/predict/predict.c",
        "src/predict/events.c",
        "src/predict/spawns.c",
        "src/network/latency.c",
        "src/network/net_delay.c",
        // Schema
        "src/schema/decode.c",
        "src/schema/encode.c",
        "src/schema/input_encoder.c",
        "src/schema/quantize.c",
        "src/schema/ref_tracker.c",
        "src/schema/collections.c",
        "src/schema/decoder.c",
        "src/schema/serializer.c",
        "src/schema/callbacks.c",
        "src/schema/dynamic_schema.c",
        // Utils
        "src/utils/strUtil.c",
        "src/utils/sha1_c.c",
        "src/utils/time.c",
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
    const base_flags_hidden_cjson =
        base_flags ++ [_][]const u8{cjson_hide_symbols_flag};
    const web_flags = [_][]const u8{ "-Wall", "-Wextra", "-pedantic", "-Wno-newline-eof", c_std, "-DPLATFORM_WEB" };

    // Add common sources
    colyseus.addCSourceFiles(.{
        .files = &common_sources,
        .flags = if (is_emscripten)
            &web_flags
        else if (hide_cjson_exports)
            &base_flags_hidden_cjson
        else
            &base_flags,
    });

    // Link mbedTLS (native only - browser handles TLS)
    if (!is_emscripten) {
        colyseus.addIncludePath(b.path("third_party/mbedtls/include"));
        colyseus.linkLibrary(mbedtls);
        colyseus.linkLibrary(mbedx509);
        colyseus.linkLibrary(mbedcrypto);
    }

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

    // Note: emscripten links are handled by emcc at final link time
    linkPlatformSystemLibs(colyseus, os_tag, is_android);

    // The whole public tree ships, and ships to consumers: installHeadersDirectory
    // both fills zig-out/include and puts the tree on the include path of anything
    // that links this artifact, so `#include <colyseus.h>` needs no -I of its own.
    // The hand-written list this replaced had drifted 16 headers behind the tree,
    // schema/dynamic_schema.h among them, so zig-out/include did not self-compile.
    colyseus.installHeadersDirectory(b.path("include"), "", .{ .include_extensions = &.{".h"} });

    // settings.h, room.h and three schema headers include "uthash.h" unqualified,
    // so it sits at the root of the tree next to colyseus/. It has to go through
    // the artifact, not b.addInstallHeaderFile — only installed_headers propagate.
    colyseus.installHeader(b.path("third_party/uthash/src/uthash.h"), "uthash.h");

    const umbrella_step = checkUmbrellaIsComplete(b);
    b.getInstallStep().dependOn(umbrella_step);

    const vendored_step = checkVendoredSchemasMatch(b);
    b.getInstallStep().dependOn(vendored_step);

    // Install the library
    b.installArtifact(colyseus);

    // A static archive does not absorb what it links against, so `-lcolyseus`
    // alone resolves nothing from mbedTLS, wslay or the Zig modules. Zig
    // consumers never notice — linkLibrary carries the whole graph — but a
    // plain `cc` needs every member of the closure on the link line, and a
    // release archive that omits them cannot be linked at all.
    // A shared build has already absorbed them, so it ships on its own.
    if (linkage == .static) {
        for (colyseus.getCompileDependencies(false)) |dep| {
            if (dep != colyseus and dep.isStaticLibrary()) b.installArtifact(dep);
        }
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

        buildExample(b, .{
            .name = "latency_example",
            .source_file = "examples/latency_example.c",
            .run_step_name = "run-latency-example",
            .run_step_desc = "Run the latency selection example",
        }, target, optimize, colyseus, wslay_version_h, c_std);
    }

    // ========================================================================
    // Prediction-playground validation client (lives in the sibling demos
    // repo; built only when that checkout is present). Not for emscripten —
    // zig cannot link exes against emscripten's libc.
    // ========================================================================
    if (!is_emscripten) {
        const probe_src = "../demos/prediction-tools/clients/native/predict_probe.c";
        if (std.fs.cwd().access(probe_src, .{})) |_| {
            const probe_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
            });
            const probe = b.addExecutable(.{
                .name = "predict_probe",
                .root_module = probe_module,
            });
            probe.linkLibC();
            probe.addCSourceFile(.{
                .file = .{ .cwd_relative = probe_src },
                .flags = &.{ "-Wall", "-Wextra", c_std },
            });
            probe.addIncludePath(b.path("include"));
            probe.addIncludePath(b.path("third_party/uthash/src"));
            probe.addIncludePath(b.path("third_party/sds"));
            probe.addIncludePath(b.path("third_party/cJSON"));
            probe.addIncludePath(b.path("third_party/wslay/lib/includes"));
            probe.addIncludePath(wslay_version_h.getOutput().dirname().dirname());
            probe.addIncludePath(.{ .cwd_relative = "../demos/prediction-tools/clients/native" });
            probe.linkLibrary(colyseus);
            b.installArtifact(probe);
        } else |_| {}
    }

    // ========================================================================
    // Prediction-playground interactive app (same sibling repo). Needs raylib
    // from the system; skipped silently when pkg-config can't find it.
    // Never for emscripten — the web build links via emcc (see the app's
    // run-web.sh), and pkg-config would hand us the NATIVE raylib anyway.
    // ========================================================================
    if (!is_emscripten) {
        const app_src = "../demos/prediction-tools/clients/native-app/main.c";
        const raylib = pkgConfig(b, "raylib");
        if (std.fs.cwd().access(app_src, .{})) |_| {
            if (raylib) |ray| {
                const app_module = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                });
                const app = b.addExecutable(.{
                    .name = "predict_playground",
                    .root_module = app_module,
                });
                app.linkLibC();
                app.addCSourceFile(.{
                    .file = .{ .cwd_relative = app_src },
                    .flags = &.{ "-Wall", "-Wextra", c_std },
                });
                app.addIncludePath(b.path("include"));
                app.addIncludePath(b.path("third_party/uthash/src"));
                app.addIncludePath(b.path("third_party/sds"));
                app.addIncludePath(b.path("third_party/cJSON"));
                app.addIncludePath(b.path("third_party/wslay/lib/includes"));
                app.addIncludePath(wslay_version_h.getOutput().dirname().dirname());
                // Schema headers are shared with the headless probe.
                app.addIncludePath(.{ .cwd_relative = "../demos/prediction-tools/clients/native" });
                app.addIncludePath(.{ .cwd_relative = "../demos/prediction-tools/clients/native-app" });
                app.addIncludePath(.{ .cwd_relative = ray.include });
                app.addLibraryPath(.{ .cwd_relative = ray.lib });
                app.linkSystemLibrary("raylib");
                if (target.result.os.tag == .macos) {
                    app.linkFramework("Cocoa");
                    app.linkFramework("IOKit");
                    app.linkFramework("CoreVideo");
                    app.linkFramework("OpenGL");
                }
                app.linkLibrary(colyseus);
                b.installArtifact(app);

                const run_app = b.addRunArtifact(app);
                if (b.args) |args| run_app.addArgs(args);
                const run_step = b.step("run-playground", "Run the prediction playground app");
                run_step.dependOn(&run_app.step);
            } else {
                std.debug.print("note: raylib not found (pkg-config) — skipping predict_playground\n", .{});
            }
        } else |_| {}
    }

    // ========================================================================
    // Build and run tests (skip for emscripten - can't run wasm tests directly)
    // ========================================================================
    if (is_emscripten) return;

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(umbrella_step);

    // The SDK's promise is "one include, one linkLibrary". Assert it literally,
    // so it breaks here rather than in someone else's project: a header that
    // stops being self-contained, or an include path the artifact fails to
    // propagate, fails this and nothing else.
    for ([_]struct { name: []const u8, ext: []const u8, flags: []const []const u8 }{
        .{ .name = "umbrella_smoke_c", .ext = "c", .flags = &.{ "-Wall", "-Wextra", "-Werror", c_std } },
        .{ .name = "umbrella_smoke_cpp", .ext = "cpp", .flags = &.{ "-Wall", "-Wextra", "-Werror", "-std=c++17" } },
    }) |smoke| {
        const src = b.addWriteFiles().add(
            b.fmt("umbrella_smoke.{s}", .{smoke.ext}),
            "#include <colyseus.h>\nint main(void) { return 0; }\n",
        );
        const exe = b.addExecutable(.{
            .name = smoke.name,
            .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
        });
        configurePlatformLibc(exe, is_android, android_ndk_path, target.result, apple_sdk_path, is_emscripten, emscripten_sysroot);
        if (std.mem.eql(u8, smoke.ext, "cpp")) exe.linkLibCpp();
        exe.addCSourceFile(.{ .file = src, .flags = smoke.flags });
        exe.linkLibrary(colyseus); // and nothing else — no addIncludePath
        test_step.dependOn(&b.addRunArtifact(exe).step);
    }

    // The smoke tests above prove the Zig half only: linkLibrary pulls the whole
    // closure through the build graph, so they still pass when the *installed*
    // archives are unlinkable on their own. This one links them by path, the way
    // `cc app.c zig-out/lib/*.a` does, and is what catches a dependency that
    // stops being installed.
    if (linkage == .static) {
        const consumer_src = b.addWriteFiles().add(
            "c_consumer.c",
            \\#include <colyseus.h>
            \\int main(void) {
            \\    colyseus_settings_t* s = colyseus_settings_create();
            \\    colyseus_client_t* c = colyseus_client_create(s);
            \\    colyseus_client_free(c);
            \\    return 0;
            \\}
            \\
            ,
        );
        const consumer = b.addExecutable(.{
            .name = "c_consumer_smoke",
            .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
        });
        configurePlatformLibc(consumer, is_android, android_ndk_path, target.result, apple_sdk_path, is_emscripten, emscripten_sysroot);
        consumer.addCSourceFile(.{ .file = consumer_src, .flags = &.{ "-Wall", "-Wextra", "-Werror", c_std } });
        consumer.addIncludePath(colyseus.getEmittedIncludeTree());
        for (colyseus.getCompileDependencies(false)) |dep| {
            if (dep.isStaticLibrary()) consumer.addObjectFile(dep.getEmittedBin());
        }
        linkPlatformSystemLibs(consumer, os_tag, is_android);
        test_step.dependOn(&b.addRunArtifact(consumer).step);
    }

    // Define all Zig test files. `.server` marks an integration suite: the
    // server it needs, probed on localhost before the suite is wired in.
    const zig_test_files = [_]struct {
        name: []const u8,
        file: []const u8,
        description: []const u8,
        server: ?TestServer = null,
    }{
        .{ .name = "test_http", .file = "tests/test_http.zig", .description = "Run HTTP tests" },
        .{ .name = "test_auth", .file = "tests/test_auth.zig", .description = "Run authentication tests" },
        .{ .name = "test_room", .file = "tests/test_room.zig", .description = "Run room tests" },
        .{ .name = "test_storage", .file = "tests/test_storage.zig", .description = "Run storage tests" },
        .{ .name = "test_schema", .file = "tests/test_schema.zig", .description = "Run schema tests" },
        .{ .name = "test_schema_arrayops", .file = "tests/test_schema_arrayops.zig", .description = "Run ArraySchema wire-semantics tests (byte fixtures)" },
        .{ .name = "test_schema_resync", .file = "tests/test_schema_resync.zig", .description = "Run decodeResync reconciliation tests (byte fixtures)" },
        .{ .name = "test_room_protocol", .file = "tests/test_room_protocol.zig", .description = "Run 0.18 room wire-compat tests (byte fixtures)" },
        .{ .name = "test_quantized", .file = "tests/test_quantized.zig", .description = "Run 5.0 reflection + t.quantized tests (byte fixtures)" },
        .{ .name = "test_schema_core", .file = "tests/test_schema_core.zig", .description = "Run change-listener + callbacks-vs-TS tests (byte fixtures)" },
        .{ .name = "test_input", .file = "tests/test_input.zig", .description = "Run input layer + RoomClock tests (byte fixtures)" },
        .{ .name = "test_predict", .file = "tests/test_predict.zig", .description = "Run Predict layer tests (behavior fixtures)" },
        .{ .name = "test_netdelay", .file = "tests/test_netdelay.zig", .description = "Run network-delay injector tests (offline)" },
        .{ .name = "test_msgpack_builder", .file = "tests/test_msgpack_builder.zig", .description = "Run message builder ownership tests (offline)" },
        .{ .name = "test_transport", .file = "tests/test_transport.zig", .description = "Run WebSocket transport tests: address fallthrough, refusal, SIGPIPE, polled mode (offline)" },
        .{ .name = "test_poll", .file = "tests/test_poll.zig", .description = "Run colyseus_poll() tests: poll-thread delivery, nested poll, send flush, latency (offline)" },
        .{ .name = "test_gamemaker_predict", .file = "tests/test_gamemaker_predict.zig", .description = "Run GameMaker predict-bridge tests (offline, drives the GML FFI surface)" },
        .{ .name = "test_gamemaker_schema", .file = "tests/test_gamemaker_schema.zig", .description = "Run GameMaker schema-bridge tests (offline)" },
        .{ .name = "test_suite", .file = "tests/test_suite.zig", .description = "Run unit test suite" },
        .{ .name = "test_integration", .file = "tests/test_integration.zig", .description = "Run integration tests (requires server)", .server = .example },
        .{ .name = "test_schema_callbacks", .file = "tests/test_schema_callbacks.zig", .description = "Run schema callbacks tests (requires server)", .server = .example },
        .{ .name = "test_schema_reflection", .file = "tests/test_schema_reflection.zig", .description = "Run reflection-vtable decode tests (requires server)", .server = .example },
        .{ .name = "test_messages", .file = "tests/test_messages.zig", .description = "Run message types tests (requires server)", .server = .example },
        .{ .name = "test_request", .file = "tests/test_request.zig", .description = "Run room.request() outcome tests (requires server)", .server = .example },
        .{ .name = "test_view_callbacks", .file = "tests/test_view_callbacks.zig", .description = "Run StateView callback tests (requires server)", .server = .example },
        .{ .name = "test_reconnect", .file = "tests/test_reconnect.zig", .description = "Run automatic reconnection tests (requires server)", .server = .example },
        .{ .name = "test_poll_integration", .file = "tests/test_poll_integration.zig", .description = "Run colyseus_poll() session + reconnection thread-affinity tests (requires server)", .server = .example },
        .{ .name = "test_gamemaker_net", .file = "tests/test_gamemaker_net.zig", .description = "Run GameMaker bridge session tests: polled delivery on the GML thread (requires server)", .server = .example },
        .{ .name = "test_tls", .file = "tests/test_tls.zig", .description = "Run WSS/TLS verification tests (requires wss echo server)", .server = .wss_echo },
    };

    // A suite whose server is down fails up front, naming the server and how
    // to start it — rather than as a bare waitForJoin/ConnectionRefused deep
    // inside. `zig build test` off CI skips it instead, and says so at the end.
    const ci = isCi(b);
    var server_up = std.EnumArray(TestServer, ?bool).initFill(null);
    var skipped = std.EnumArray(TestServer, std.ArrayList(u8)).initFill(.empty);
    var run_steps: std.ArrayList(*std.Build.Step) = .empty;

    // Build each Zig test
    for (zig_test_files) |test_file| {
        if (skip_integration and test_file.server != null) continue;

        // test_tls needs a self-signed wss echo-server fixture that isn't wired
        // up on the Windows CI runner (Git-Bash openssl / process substitution).
        // The TLS code is OS-agnostic and is exercised on Linux + macOS.
        if (std.mem.eql(u8, test_file.name, "test_tls") and
            target.result.os.tag == .windows)
        {
            continue;
        }
        // Their in-test peer is BSD sockets, and SIGPIPE is POSIX-only.
        if ((std.mem.eql(u8, test_file.name, "test_transport") or
            std.mem.eql(u8, test_file.name, "test_poll")) and
            target.result.os.tag == .windows)
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
        // test_tls drives the transport's own state, which is not public.
        test_exe.addIncludePath(b.path("src"));
        test_exe.linkLibrary(colyseus);

        // The GM bridge isn't part of libcolyseus — compile it into its test
        // exe so the exact GML-facing FFI surface is what gets exercised.
        if (std.mem.startsWith(u8, test_file.name, "test_gamemaker")) {
            test_exe.addCSourceFiles(.{
                .root = b.path("."),
                .files = &.{
                    "platforms/gamemaker/src/gamemaker_export.c",
                    "platforms/gamemaker/src/gamemaker_predict.c",
                },
                .flags = &.{"-Wall"},
            });
            test_exe.addIncludePath(b.path("platforms/gamemaker/src"));
        }

        // If debug-tests is enabled, install the test executable
        if (debug_tests) {
            b.installArtifact(test_exe);
        }

        // Create run command for this test
        const run_test = b.addRunArtifact(test_exe);
        const individual_test_step = b.step(test_file.name, test_file.description);

        if (test_file.server) |server| {
            const up = server_up.getPtr(server);
            if (up.* == null) up.* = serverAnswers(b, server.port());
            if (!up.*.?) {
                const fail = &b.addFail(b.fmt(
                    "{s} needs the {s} on localhost:{d}, and nothing answers there. Start it with:\n    {s}",
                    .{ test_file.name, server.label(), server.port(), server.startCommand() },
                )).step;
                individual_test_step.dependOn(fail);
                if (ci) {
                    test_step.dependOn(fail);
                } else {
                    skipped.getPtr(server).print(b.allocator, " {s}", .{test_file.name}) catch @panic("OOM");
                }
                continue;
            }
        }

        test_step.dependOn(&run_test.step);
        run_steps.append(b.allocator, &run_test.step) catch @panic("OOM");
        individual_test_step.dependOn(&run_test.step);
    }

    var notice: std.ArrayList(u8) = .empty;
    for (std.enums.values(TestServer)) |server| {
        const names = skipped.get(server).items;
        if (names.len == 0) continue;
        notice.print(b.allocator, "warning: SKIPPED{s}\nwarning:   nothing answers on localhost:{d} ({s}). Start it with:\nwarning:     {s}\n", .{
            names, server.port(), server.label(), server.startCommand(),
        }) catch @panic("OOM");
    }
    if (notice.items.len > 0) {
        notice.appendSlice(b.allocator, "warning: -Dskip-integration=true skips them without this note; with CI set they fail instead.\n") catch @panic("OOM");
        // after every suite that did run, so it is the last thing on screen
        const step = Notice.create(b, notice.items);
        for (run_steps.items) |run| step.dependOn(run);
        test_step.dependOn(step);
    }
}

/// A server an integration suite talks to.
const TestServer = enum {
    example,
    wss_echo,

    fn port(self: TestServer) u16 {
        return switch (self) {
            .example => 2567,
            .wss_echo => 2569,
        };
    }

    fn label(self: TestServer) []const u8 {
        return switch (self) {
            .example => "example-server",
            .wss_echo => "wss echo server",
        };
    }

    fn startCommand(self: TestServer) []const u8 {
        return switch (self) {
            .example => "cd example-server && npm install && npx tsx src/index.ts",
            .wss_echo => "bash tests/tls/gen-certs.sh && node tests/tls/wss-echo-server.mjs --port 2569",
        };
    }
};

/// Probed while the graph is configured, the way the suites will connect.
fn serverAnswers(b: *std.Build, port: u16) bool {
    const stream = std.net.tcpConnectToHost(b.allocator, "localhost", port) catch return false;
    stream.close();
    return true;
}

/// CI never auto-skips: a server that failed to start must fail the run.
fn isCi(b: *std.Build) bool {
    const v = b.graph.env_map.get("CI") orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0") and !std.ascii.eqlIgnoreCase(v, "false");
}

/// A step that prints `text` when it runs.
const Notice = struct {
    step: std.Build.Step,
    text: []const u8,

    fn create(b: *std.Build, text: []const u8) *std.Build.Step {
        const self = b.allocator.create(Notice) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{ .id = .custom, .name = "integration skip notice", .owner = b, .makeFn = make }),
            .text = text,
        };
        return &self.step;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const self: *Notice = @fieldParentPtr("step", step);
        std.debug.print("{s}", .{self.text});
    }
};

/// Without its submodules the build dies deep inside, on
/// `unable to read ... wslayver.h.in: FileNotFound`. Say what is wrong instead.
fn requireSubmodules(b: *std.Build) void {
    const probes = [_]struct { dir: []const u8, file: []const u8 }{
        .{ .dir = "third_party/cJSON", .file = "cJSON.c" },
        .{ .dir = "third_party/mbedtls", .file = "include/mbedtls/ssl.h" },
        .{ .dir = "third_party/sds", .file = "sds.c" },
        .{ .dir = "third_party/uthash", .file = "src/uthash.h" },
        .{ .dir = "third_party/wslay", .file = "lib/includes/wslay/wslayver.h.in" },
    };
    var missing: std.ArrayList(u8) = .empty;
    for (probes) |p| {
        b.build_root.handle.access(b.fmt("{s}/{s}", .{ p.dir, p.file }), .{}) catch {
            missing.print(b.allocator, " {s}", .{p.dir}) catch @panic("OOM");
        };
    }
    if (missing.items.len == 0) return;

    if (b.pkg_hash.len != 0) {
        std.debug.print("error: the colyseus package was fetched without its git submodules (missing:{s}).\n" ++
            "       Depend on a source archive that vendors third_party/, or on a local checkout.\n", .{missing.items});
    } else {
        std.debug.print("error: git submodules are not checked out (missing:{s}). Run:\n" ++
            "           git submodule update --init --recursive\n", .{missing.items});
    }
    std.process.exit(1);
}

// ============================================================================
// System-library discovery
// ============================================================================

const PkgPaths = struct { include: []const u8, lib: []const u8 };

/// Resolve a system package's include/lib dirs via pkg-config. Returns null
/// when pkg-config is missing or doesn't know the package — callers treat that
/// as "skip this optional target".
fn pkgConfig(b: *std.Build, name: []const u8) ?PkgPaths {
    const query = struct {
        fn run(bb: *std.Build, pkg: []const u8, variable: []const u8) ?[]const u8 {
            const result = std.process.Child.run(.{
                .allocator = bb.allocator,
                .argv = &.{ "pkg-config", variable, pkg },
            }) catch return null;
            defer bb.allocator.free(result.stderr);
            if (result.term != .Exited or result.term.Exited != 0 or result.stdout.len == 0) {
                bb.allocator.free(result.stdout);
                return null;
            }
            const trimmed = std.mem.trim(u8, result.stdout, " \n\r\"");
            const owned = bb.allocator.dupe(u8, trimmed) catch null;
            bb.allocator.free(result.stdout);
            return owned;
        }
    }.run;

    const include = query(b, name, "--variable=includedir") orelse return null;
    const lib = query(b, name, "--variable=libdir") orelse return null;
    return .{ .include = include, .lib = lib };
}

// ============================================================================
// Platform sysroot helpers
// ============================================================================

fn addEmscriptenSysroot(compile_step: *std.Build.Step.Compile, sysroot: ?[]const u8) void {
    if (sysroot) |sr| {
        compile_step.addSystemIncludePath(.{ .cwd_relative = sr });
    }
}

fn addAndroidNdkPaths(compile_step: *std.Build.Step.Compile, ndk_path: ?[]const u8, tgt: std.Target) void {
    if (ndk_path) |ndk| {
        const alloc = compile_step.step.owner.allocator;

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
}

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

/// A public header that reaches no umbrella reaches no binding, and nothing
/// else notices — the library still builds, the symbol just isn't there.
/// Clang's -Wincomplete-umbrella does not cover the nested directories this
/// tree uses, so the check lives here instead.
fn checkUmbrellaIsComplete(b: *std.Build) *std.Build.Step {
    const step = b.step("check-umbrella", "Verify include/colyseus.h reaches every public header");

    // Only the root package owns this invariant; a consumer's b.dependency()
    // should neither pay for it nor fail on it.
    if (b.pkg_hash.len != 0) return step;

    const umbrella = b.build_root.handle.readFileAlloc(
        b.allocator,
        "include/colyseus.h",
        1 << 20,
    ) catch |err| {
        step.dependOn(&b.addFail(b.fmt("cannot read include/colyseus.h: {s}", .{@errorName(err)})).step);
        return step;
    };

    // Walk all of include/, not just include/colyseus/: installHeadersDirectory
    // ships the whole tree, so a header at the root would otherwise reach
    // consumers without ever being checked against the umbrella.
    var dir = b.build_root.handle.openDir("include", .{ .iterate = true }) catch |err| {
        step.dependOn(&b.addFail(b.fmt("cannot open include/: {s}", .{@errorName(err)})).step);
        return step;
    };
    defer dir.close();

    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();

    var missing: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    while (walker.next() catch @panic("walk failed")) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".h")) continue;
        if (std.mem.eql(u8, entry.path, "colyseus.h")) continue; // the umbrella itself

        // Walker paths use the host separator; the includes never do.
        const include_path = b.fmt("<{s}>", .{entry.path});
        const normalized = std.mem.replaceOwned(u8, b.allocator, include_path, "\\", "/") catch @panic("OOM");
        if (std.mem.indexOf(u8, umbrella, normalized) == null) {
            missing.print(b.allocator, "  #include {s}\n", .{normalized}) catch @panic("OOM");
            count += 1;
        }
    }

    if (count > 0) {
        step.dependOn(&b.addFail(b.fmt(
            "include/colyseus.h is missing {d} public header(s):\n{s}",
            .{ count, missing.items },
        )).step);
    }

    return step;
}

/// The system libraries the core needs. Anything that links libcolyseus.a
/// statically needs the same set, so it lives in one place — the platform
/// build files each restate it, and have already drifted (Flutter and
/// GameMaker omit bcrypt on Windows).
fn linkPlatformSystemLibs(compile: *std.Build.Step.Compile, os_tag: std.Target.Os.Tag, is_android: bool) void {
    if (os_tag == .linux and !is_android) {
        compile.linkSystemLibrary("pthread");
        compile.linkSystemLibrary("m");
    } else if (os_tag == .macos) {
        compile.linkSystemLibrary("pthread");
        compile.linkFramework("CoreFoundation");
        compile.linkFramework("Security");
    } else if (os_tag == .ios or os_tag == .tvos) {
        compile.linkFramework("CoreFoundation");
        compile.linkFramework("Security");
    } else if (os_tag == .windows) {
        compile.linkSystemLibrary("ws2_32");
        compile.linkSystemLibrary("crypt32");
        compile.linkSystemLibrary("bcrypt");
    }
}

/// The raylib example carries its own copy of a generated schema header so it
/// reads like something a user generated, rather than reaching into the SDK's
/// test fixtures. Both come from the same room, and a drifted copy would
/// misdecode silently rather than fail to build — so they must stay identical.
fn checkVendoredSchemasMatch(b: *std.Build) *std.Build.Step {
    const step = b.step("check-vendored-schemas", "Verify vendored example schemas match their fixture");
    if (b.pkg_hash.len != 0) return step;

    const pairs = [_]struct { fixture: []const u8, copy: []const u8 }{
        .{ .fixture = "tests/schema/test_room_state.h", .copy = "platforms/raylib/src/test_room_state.h" },
    };

    for (pairs) |pair| {
        const a = b.build_root.handle.readFileAlloc(b.allocator, pair.fixture, 1 << 20) catch |err| {
            step.dependOn(&b.addFail(b.fmt("cannot read {s}: {s}", .{ pair.fixture, @errorName(err) })).step);
            continue;
        };
        const c = b.build_root.handle.readFileAlloc(b.allocator, pair.copy, 1 << 20) catch |err| {
            step.dependOn(&b.addFail(b.fmt("cannot read {s}: {s}", .{ pair.copy, @errorName(err) })).step);
            continue;
        };
        if (!std.mem.eql(u8, a, c)) {
            step.dependOn(&b.addFail(b.fmt(
                "{s} has drifted from {s} — regenerate both, or copy the fixture over it",
                .{ pair.copy, pair.fixture },
            )).step);
        }
    }

    return step;
}
