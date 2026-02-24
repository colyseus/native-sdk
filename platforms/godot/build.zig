const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const os_tag = target.result.os.tag;

    // For Emscripten side modules, force ReleaseSafe for Zig code to avoid
    // debug allocator features that use @returnAddress() (not supported in WASM side modules)
    const zig_optimize: std.builtin.OptimizeMode = if (os_tag == .emscripten) .ReleaseSafe else optimize;
    const arch = target.result.cpu.arch;
    const is_emscripten = os_tag == .emscripten;

    // Detect Android (both 64-bit .android and 32-bit .androideabi ABIs)
    const is_android = target.result.abi == .android or target.result.abi == .androideabi;

    const os_str = switch (os_tag) {
        .linux => if (is_android) "android" else "linux",
        .macos => "macos",
        .windows => "windows",
        .ios => "ios",
        .emscripten => "web",
        else => "unknown",
    };

    const arch_str = switch (arch) {
        .x86 => "x86",
        .x86_64 => "x86_64",
        .arm => "arm32",
        .aarch64 => "arm64",
        .wasm32 => "wasm32",
        else => "unknown",
    };

    const build_type = if (optimize == .Debug) "debug" else "release";

    // Build library name based on platform
    // macOS uses universal binaries, others include architecture
    const lib_name = if (os_tag == .macos)
        b.fmt("colyseus_godot.{s}.{s}", .{ os_str, build_type })
    else
        b.fmt("colyseus_godot.{s}.{s}.{s}", .{ os_str, arch_str, build_type });

    // Get zig-msgpack dependency (use zig_optimize for Emscripten compatibility)
    const msgpack_dep = b.dependency("zig_msgpack", .{
        .target = target,
        .optimize = zig_optimize,
    });
    const msgpack_module = msgpack_dep.module("msgpack");

    // Build msgpack_builder Zig module (provides msgpack_payload_encode for room.c)
    const msgpack_builder_module = b.createModule(.{
        .root_source_file = b.path("../../src/msgpack/msgpack_builder.zig"),
        .target = target,
        .optimize = zig_optimize,
        // For WASM SIDE_MODULE: disable stack check and enable PIC
        // Also disable frame pointer and unwind tables to avoid __builtin_return_address usage
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
    // Link libc for all targets except iOS and Android (which resolve at runtime)
    if (os_tag != .ios and !is_android) {
        msgpack_builder_object.linkLibC();
    }

    // For iOS and Android: disable libc linking on msgpack module
    if (os_tag == .ios or is_android) {
        msgpack_module.link_libc = false;
        msgpack_builder_module.link_libc = false;
    }

    // For WASM SIDE_MODULE: enable PIC and disable stack check on msgpack module
    // Also disable frame pointer and unwind tables to avoid __builtin_return_address usage
    if (is_emscripten) {
        msgpack_module.pic = true;
        msgpack_module.stack_check = false;
        msgpack_module.omit_frame_pointer = true;
        msgpack_module.unwind_tables = .none;
    }

    // Build msgpack_reader Zig module (provides msgpack reader API for on_message callbacks)
    const msgpack_reader_module = b.createModule(.{
        .root_source_file = b.path("../../src/msgpack/msgpack_reader.zig"),
        .target = target,
        .optimize = zig_optimize,
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
    if (os_tag != .ios and !is_android) {
        msgpack_reader_object.linkLibC();
    }

    if (os_tag == .ios or is_android) {
        msgpack_reader_module.link_libc = false;
    }

    // Build strutil Zig module (used by both native and web)
    const strutil_zig_module = b.createModule(.{
        .root_source_file = b.path("../../src/utils/strUtil.zig"),
        .target = target,
        .optimize = zig_optimize,
        // For WASM SIDE_MODULE: disable stack check and enable PIC
        // Also disable frame pointer and unwind tables to avoid __builtin_return_address usage
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
    // Link libc for all targets except iOS and Android (which resolve at runtime)
    if (os_tag != .ios and !is_android) {
        strutil_object.linkLibC();
    }

    // ========================================================================
    // Emscripten/Web Build Path
    // ========================================================================
    if (is_emscripten) {
        if (b.lazyDependency("emsdk", .{})) |emsdk_dep| {
            // Set up emsdk if needed (install and activate)
            const dot_emsc_path = emsdk_dep.path(".emscripten").getPath(b);
            const has_emscripten = if (std.fs.accessAbsolute(dot_emsc_path, .{})) |_| true else |_| false;

    // Link Zig HTTP and URL parsing libraries
            var emsdk_activate: ?*std.Build.Step.Run = null;
            if (!has_emscripten) {
                const emsdk_install = b.addSystemCommand(&.{emsdk_dep.path("emsdk").getPath(b)});
                emsdk_install.addArgs(&.{ "install", "latest" });
                const emsdk_act = b.addSystemCommand(&.{emsdk_dep.path("emsdk").getPath(b)});
                emsdk_act.addArgs(&.{ "activate", "latest" });
                emsdk_act.step.dependOn(&emsdk_install.step);
                emsdk_activate = emsdk_act;
            }

            // Use emcc from the emsdk
            const emcc_path = b.pathJoin(&.{ emsdk_dep.path("upstream/emscripten").getPath(b), "emcc" });
            const emcc = b.addSystemCommand(&.{emcc_path});

            // C source files for web (uses web-specific transport and http, no wslay)
            const c_sources = [_][]const u8{
                // Godot extension sources
                "src/register_types.c",
                "src/colyseus_client.c",
                "src/colyseus_room.c",
                "src/colyseus_callbacks.c",
                "src/colyseus_state.c",
                "src/colyseus_schema_registry.c",
                "src/colyseus_gdscript_schema.c",
                "src/msgpack_variant.c",
                "src/msgpack_encoder.c",
                // Core SDK
                "../../src/common/settings.c",
                "../../src/client.c",
                "../../src/room.c",
                // Network (web-specific - browser handles WebSocket/HTTP)
                "../../src/network/websocket_transport_web.c",
                "../../src/network/http_web.c",
                // Schema
                "../../src/schema/decode.c",
                "../../src/schema/ref_tracker.c",
                "../../src/schema/collections.c",
                "../../src/schema/decoder.c",
                "../../src/schema/serializer.c",
                "../../src/schema/callbacks.c",
                "../../src/schema/dynamic_schema.c",
                // Utils
                "../../src/utils/strUtil.c",
                "../../src/utils/sha1_c.c",
                // Auth
                "../../src/auth/auth.c",
                "../../src/auth/secure_storage.c",
                // Third-party sources (no wslay - browser handles WebSocket framing)
                "../../third_party/sds/sds.c",
                "../../third_party/cJSON/cJSON.c",
            };

            for (c_sources) |src| {
                emcc.addFileArg(b.path(src));
            }

            // Add include paths
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(b.path("../../include"));
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(b.path("../../src"));
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(b.path("../../third_party/uthash/src"));
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(b.path("../../third_party/sds"));
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(b.path("../../third_party/cJSON"));
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(b.path("include"));
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(b.path("src"));

            // Add emsdk include path
            emcc.addArgs(&.{"-I"});
            emcc.addDirectoryArg(emsdk_dep.path("upstream/emscripten/cache/sysroot/include"));

            // Build msgpack_godot Zig module for web (provides msgpack_decode_to_godot for msgpack_variant.c)
            const msgpack_godot_module = b.createModule(.{
                .root_source_file = b.path("src/msgpack_godot.zig"),
                .target = target,
                .optimize = zig_optimize, // Use ReleaseSafe to avoid @returnAddress() in debug allocator
                // For WASM SIDE_MODULE: disable stack check and enable PIC
                // Also disable frame pointer and unwind tables to avoid __builtin_return_address usage
                .stack_check = false,
                .pic = true,
                .omit_frame_pointer = true,
                .unwind_tables = .none,
            });
            msgpack_godot_module.addImport("msgpack", msgpack_module);

            const msgpack_godot_object = b.addLibrary(.{
                .name = "msgpack_godot",
                .root_module = msgpack_godot_module,
                .linkage = .static,
            });
            msgpack_godot_object.linkLibC();

            // Add Zig libraries
            emcc.addArtifactArg(strutil_object);
            emcc.addArtifactArg(msgpack_builder_object);
            emcc.addArtifactArg(msgpack_reader_object);
            emcc.addArtifactArg(msgpack_godot_object);

            // C flags and defines
            emcc.addArgs(&.{
                "-DPLATFORM_WEB",
                "-DGDEXTENSION_SIDE_MODULE",
            });

            // Output path for the WASM file
            const wasm_output = b.fmt("zig-out/bin/lib{s}.wasm", .{lib_name});

            // Emscripten flags for GDExtension side module
            // Note: Don't use ASYNCIFY - Godot's main module handles async operations
            emcc.addArgs(&.{
                "-o",
                wasm_output,
                "-sSIDE_MODULE=2",
                "-sEXPORT_ALL=1",
                // Allow multiple definitions to handle duplicate stack check symbols from Zig libs
                "-Wl,--allow-multiple-definition",
            });

            // Set optimization flags based on optimize level
            switch (optimize) {
                .Debug => emcc.addArgs(&.{ "-O0", "-g" }),
                .ReleaseSmall => emcc.addArgs(&.{"-Os"}),
                .ReleaseFast => emcc.addArgs(&.{"-O3"}),
                .ReleaseSafe => emcc.addArgs(&.{"-O2"}),
            }

            // Create output directory
            const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/bin" });
            emcc.step.dependOn(&mkdir.step);

            // Depend on emsdk activation if needed
            if (emsdk_activate) |act| {
                emcc.step.dependOn(&act.step);
            }

            // Copy the WASM file to the addon bin directory
            const copy_wasm = b.addSystemCommand(&.{
                "cp",
                wasm_output,
                b.fmt("addons/colyseus/bin/lib{s}.wasm", .{lib_name}),
            });
            copy_wasm.step.dependOn(&emcc.step);

            // Create the bin directory if it doesn't exist
            const mkdir_bin = b.addSystemCommand(&.{ "mkdir", "-p", "addons/colyseus/bin" });
            copy_wasm.step.dependOn(&mkdir_bin.step);

            b.getInstallStep().dependOn(&copy_wasm.step);

            const web_step = b.step("web", "Build WASM for Godot web export");
            web_step.dependOn(&copy_wasm.step);
        } else {
            std.debug.print("Warning: emsdk dependency not available for web build\n", .{});
        }
    } else {
        // ========================================================================
        // Native Build Path (macOS, iOS, Windows, Linux, Android)
        // ========================================================================

        // Build HTTP Zig module (native only - web uses http_web.c)
        const http_zig_module = b.createModule(.{
            .root_source_file = b.path("../../src/network/http.zig"),
            .target = target,
            .optimize = optimize,
        });
        http_zig_module.addIncludePath(b.path("../../include"));
        http_zig_module.addIncludePath(b.path("../../third_party/uthash/src"));

        const http_object = b.addLibrary(.{
            .name = "http_zig",
            .root_module = http_zig_module,
            .linkage = .static,
        });
        if (os_tag != .ios and !is_android) {
            http_object.linkLibC();
        }

        // Create module for the shared library with Zig source file
        const lib_module = b.createModule(.{
            .root_source_file = b.path("src/msgpack_godot.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msgpack", .module = msgpack_module },
            },
        });

        // Create the shared library for the GDExtension
        const lib = b.addLibrary(.{
            .name = lib_name,
            .root_module = lib_module,
            .linkage = .dynamic,
        });

        // Add C source files - Godot extension sources
        lib.addCSourceFiles(.{
            .files = &.{
                "src/register_types.c",
                "src/colyseus_client.c",
                "src/colyseus_room.c",
                "src/colyseus_callbacks.c",
                "src/colyseus_state.c",
                "src/colyseus_schema_registry.c",
                "src/colyseus_gdscript_schema.c",
                "src/msgpack_variant.c",
                "src/msgpack_encoder.c",
            },
            .flags = &.{
                "-Wall",
                "-Wextra",
                "-Wno-unused-parameter",
            },
        });

        // Add colyseus core C sources (native transport with wslay)
        lib.addCSourceFiles(.{
            .files = &.{
                // Core
                "../../src/common/settings.c",
                "../../src/client.c",
                "../../src/room.c",
                // Network (native websocket with wslay)
                "../../src/network/websocket_transport.c",
                // Schema
                "../../src/schema/decode.c",
                "../../src/schema/ref_tracker.c",
                "../../src/schema/collections.c",
                "../../src/schema/decoder.c",
                "../../src/schema/serializer.c",
                "../../src/schema/callbacks.c",
                "../../src/schema/dynamic_schema.c",
                // Utils
                "../../src/utils/strUtil.c",
                "../../src/utils/sha1_c.c",
                // Auth
                "../../src/auth/auth.c",
                "../../src/auth/secure_storage.c",
                // Third-party sources
                "../../third_party/sds/sds.c",
                "../../third_party/cJSON/cJSON.c",
                // wslay sources (native only)
                "../../third_party/wslay/lib/wslay_event.c",
                "../../third_party/wslay/lib/wslay_frame.c",
                "../../third_party/wslay/lib/wslay_net.c",
                "../../third_party/wslay/lib/wslay_queue.c",
            },
            .flags = &.{
                "-Wall",
                "-Wextra",
                "-Wno-unused-parameter",
                "-DHAVE_CONFIG_H",
            },
        });

        // Add include paths
        lib.addIncludePath(b.path("../../include"));
        lib.addIncludePath(b.path("../../src"));
        lib.addIncludePath(b.path("../../third_party/uthash/src"));
        lib.addIncludePath(b.path("../../third_party/sds"));
        lib.addIncludePath(b.path("../../third_party/cJSON"));
        lib.addIncludePath(b.path("../../third_party/wslay/lib/includes"));
        lib.addIncludePath(b.path("../../third_party/wslay/lib"));
        lib.addIncludePath(b.path("include"));
        lib.addIncludePath(b.path("src"));

        // Add iOS SDK system include path for C compilation
        if (os_tag == .ios) {
            if (b.sysroot) |sysroot| {
                lib.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sysroot}) });
            }
        }

        // Generate wslay config header based on target platform
        const is_windows = os_tag == .windows;
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
        lib.addConfigHeader(wslay_config_h);
        lib.addIncludePath(wslay_config_h.getOutput().dirname());

        // ========================================================================
        // Build mbedTLS from source (v3.6.4 LTS)
        // ========================================================================
        const mbedcrypto = b.addLibrary(.{
            .name = "mbedcrypto",
            .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
            .linkage = .static,
        });
        if (os_tag != .ios and !is_android) {
            mbedcrypto.linkLibC();
        }
        mbedcrypto.addIncludePath(b.path("../../third_party/mbedtls/include"));
        mbedcrypto.addIncludePath(b.path("../../third_party/mbedtls/library"));
        mbedcrypto.addCSourceFiles(.{
            .files = &.{
                "../../third_party/mbedtls/library/aes.c",
                "../../third_party/mbedtls/library/aesce.c",
                "../../third_party/mbedtls/library/aesni.c",
                "../../third_party/mbedtls/library/aria.c",
                "../../third_party/mbedtls/library/asn1parse.c",
                "../../third_party/mbedtls/library/asn1write.c",
                "../../third_party/mbedtls/library/base64.c",
                "../../third_party/mbedtls/library/bignum.c",
                "../../third_party/mbedtls/library/bignum_core.c",
                "../../third_party/mbedtls/library/bignum_mod.c",
                "../../third_party/mbedtls/library/bignum_mod_raw.c",
                "../../third_party/mbedtls/library/block_cipher.c",
                "../../third_party/mbedtls/library/camellia.c",
                "../../third_party/mbedtls/library/ccm.c",
                "../../third_party/mbedtls/library/chacha20.c",
                "../../third_party/mbedtls/library/chachapoly.c",
                "../../third_party/mbedtls/library/cipher.c",
                "../../third_party/mbedtls/library/cipher_wrap.c",
                "../../third_party/mbedtls/library/cmac.c",
                "../../third_party/mbedtls/library/constant_time.c",
                "../../third_party/mbedtls/library/ctr_drbg.c",
                "../../third_party/mbedtls/library/des.c",
                "../../third_party/mbedtls/library/dhm.c",
                "../../third_party/mbedtls/library/ecdh.c",
                "../../third_party/mbedtls/library/ecdsa.c",
                "../../third_party/mbedtls/library/ecjpake.c",
                "../../third_party/mbedtls/library/ecp.c",
                "../../third_party/mbedtls/library/ecp_curves.c",
                "../../third_party/mbedtls/library/ecp_curves_new.c",
                "../../third_party/mbedtls/library/entropy.c",
                "../../third_party/mbedtls/library/entropy_poll.c",
                "../../third_party/mbedtls/library/error.c",
                "../../third_party/mbedtls/library/gcm.c",
                "../../third_party/mbedtls/library/hkdf.c",
                "../../third_party/mbedtls/library/hmac_drbg.c",
                "../../third_party/mbedtls/library/lmots.c",
                "../../third_party/mbedtls/library/lms.c",
                "../../third_party/mbedtls/library/md.c",
                "../../third_party/mbedtls/library/md5.c",
                "../../third_party/mbedtls/library/memory_buffer_alloc.c",
                "../../third_party/mbedtls/library/mps_reader.c",
                "../../third_party/mbedtls/library/mps_trace.c",
                "../../third_party/mbedtls/library/nist_kw.c",
                "../../third_party/mbedtls/library/oid.c",
                "../../third_party/mbedtls/library/padlock.c",
                "../../third_party/mbedtls/library/pem.c",
                "../../third_party/mbedtls/library/pk.c",
                "../../third_party/mbedtls/library/pk_ecc.c",
                "../../third_party/mbedtls/library/pk_wrap.c",
                "../../third_party/mbedtls/library/pkcs12.c",
                "../../third_party/mbedtls/library/pkcs5.c",
                "../../third_party/mbedtls/library/pkcs7.c",
                "../../third_party/mbedtls/library/pkparse.c",
                "../../third_party/mbedtls/library/pkwrite.c",
                "../../third_party/mbedtls/library/platform.c",
                "../../third_party/mbedtls/library/platform_util.c",
                "../../third_party/mbedtls/library/poly1305.c",
                "../../third_party/mbedtls/library/psa_crypto.c",
                "../../third_party/mbedtls/library/psa_crypto_aead.c",
                "../../third_party/mbedtls/library/psa_crypto_cipher.c",
                "../../third_party/mbedtls/library/psa_crypto_client.c",
                "../../third_party/mbedtls/library/psa_crypto_driver_wrappers_no_static.c",
                "../../third_party/mbedtls/library/psa_crypto_ecp.c",
                "../../third_party/mbedtls/library/psa_crypto_ffdh.c",
                "../../third_party/mbedtls/library/psa_crypto_hash.c",
                "../../third_party/mbedtls/library/psa_crypto_mac.c",
                "../../third_party/mbedtls/library/psa_crypto_pake.c",
                "../../third_party/mbedtls/library/psa_crypto_rsa.c",
                "../../third_party/mbedtls/library/psa_crypto_se.c",
                "../../third_party/mbedtls/library/psa_crypto_slot_management.c",
                "../../third_party/mbedtls/library/psa_crypto_storage.c",
                "../../third_party/mbedtls/library/psa_its_file.c",
                "../../third_party/mbedtls/library/psa_util.c",
                "../../third_party/mbedtls/library/ripemd160.c",
                "../../third_party/mbedtls/library/rsa.c",
                "../../third_party/mbedtls/library/rsa_alt_helpers.c",
                "../../third_party/mbedtls/library/sha1.c",
                "../../third_party/mbedtls/library/sha256.c",
                "../../third_party/mbedtls/library/sha3.c",
                "../../third_party/mbedtls/library/sha512.c",
                "../../third_party/mbedtls/library/threading.c",
                "../../third_party/mbedtls/library/timing.c",
                "../../third_party/mbedtls/library/version.c",
                "../../third_party/mbedtls/library/version_features.c",
            },
            .flags = &.{ "-Wall" },
        });

        const mbedx509 = b.addLibrary(.{
            .name = "mbedx509",
            .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
            .linkage = .static,
        });
        if (os_tag != .ios and !is_android) {
            mbedx509.linkLibC();
        }
        mbedx509.addIncludePath(b.path("../../third_party/mbedtls/include"));
        mbedx509.addIncludePath(b.path("../../third_party/mbedtls/library"));
        mbedx509.addCSourceFiles(.{
            .files = &.{
                "../../third_party/mbedtls/library/x509.c",
                "../../third_party/mbedtls/library/x509_create.c",
                "../../third_party/mbedtls/library/x509_crl.c",
                "../../third_party/mbedtls/library/x509_crt.c",
                "../../third_party/mbedtls/library/x509_csr.c",
                "../../third_party/mbedtls/library/x509write.c",
                "../../third_party/mbedtls/library/x509write_crt.c",
                "../../third_party/mbedtls/library/x509write_csr.c",
            },
            .flags = &.{ "-Wall" },
        });
        mbedx509.linkLibrary(mbedcrypto);

        const mbedtls = b.addLibrary(.{
            .name = "mbedtls",
            .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
            .linkage = .static,
        });
        if (os_tag != .ios and !is_android) {
            mbedtls.linkLibC();
        }
        mbedtls.addIncludePath(b.path("../../third_party/mbedtls/include"));
        mbedtls.addIncludePath(b.path("../../third_party/mbedtls/library"));
        mbedtls.addCSourceFiles(.{
            .files = &.{
                "../../third_party/mbedtls/library/debug.c",
                "../../third_party/mbedtls/library/net_sockets.c",
                "../../third_party/mbedtls/library/ssl_cache.c",
                "../../third_party/mbedtls/library/ssl_ciphersuites.c",
                "../../third_party/mbedtls/library/ssl_client.c",
                "../../third_party/mbedtls/library/ssl_cookie.c",
                "../../third_party/mbedtls/library/ssl_debug_helpers_generated.c",
                "../../third_party/mbedtls/library/ssl_msg.c",
                "../../third_party/mbedtls/library/ssl_ticket.c",
                "../../third_party/mbedtls/library/ssl_tls.c",
                "../../third_party/mbedtls/library/ssl_tls12_client.c",
                "../../third_party/mbedtls/library/ssl_tls12_server.c",
                "../../third_party/mbedtls/library/ssl_tls13_client.c",
                "../../third_party/mbedtls/library/ssl_tls13_generic.c",
                "../../third_party/mbedtls/library/ssl_tls13_keys.c",
                "../../third_party/mbedtls/library/ssl_tls13_server.c",
            },
            .flags = &.{ "-Wall" },
        });
        mbedtls.linkLibrary(mbedx509);
        mbedtls.linkLibrary(mbedcrypto);

        lib.addIncludePath(b.path("../../third_party/mbedtls/include"));
        lib.linkLibrary(mbedtls);
        lib.linkLibrary(mbedx509);
        lib.linkLibrary(mbedcrypto);


        // Link Zig libraries
        lib.linkLibrary(http_object);
        lib.linkLibrary(strutil_object);
        lib.linkLibrary(msgpack_builder_object);
        lib.linkLibrary(msgpack_reader_object);

        // Generate wslay version header
        const wslay_version_h = b.addConfigHeader(.{
            .style = .{ .cmake = b.path("../../third_party/wslay/lib/includes/wslay/wslayver.h.in") },
            .include_path = "wslay/wslayver.h",
        }, .{
            .PACKAGE_VERSION = "1.1.1",
        });
        lib.addConfigHeader(wslay_version_h);
        lib.addIncludePath(wslay_version_h.getOutput().dirname().dirname());

        // Link platform-specific libraries
        if (os_tag == .macos) {
            lib.linkLibC();
            lib.linkSystemLibrary("pthread");

            if (b.sysroot) |sysroot| {
                lib.root_module.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sysroot}) });
                lib.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sysroot}) });
                lib.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sysroot}) });
            } else {
                const builtin = @import("builtin");
                if (builtin.os.tag == .macos) {
                    const sdk_path = "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk";
                    lib.root_module.addFrameworkPath(.{ .cwd_relative = sdk_path ++ "/System/Library/Frameworks" });
                    lib.addSystemIncludePath(.{ .cwd_relative = sdk_path ++ "/usr/include" });
                    lib.root_module.addLibraryPath(.{ .cwd_relative = sdk_path ++ "/usr/lib" });
                }
            }

            lib.linkFramework("CoreFoundation");
            lib.linkFramework("Security");
        } else if (os_tag == .ios) {
            if (b.sysroot) |sysroot| {
                lib.root_module.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sysroot}) });
            }

            lib.root_module.link_libc = false;
            http_zig_module.link_libc = false;
            strutil_zig_module.link_libc = false;

            lib.root_module.linkFramework("CoreFoundation", .{ .weak = true });
            lib.root_module.linkFramework("Security", .{ .weak = true });

            lib.install_name = b.fmt("@rpath/lib{s}.framework/lib{s}", .{ lib_name, lib_name });
        } else if (is_android) {
            lib.root_module.link_libc = false;
            http_zig_module.link_libc = false;
            strutil_zig_module.link_libc = false;

            const android_triple = switch (arch) {
                .x86 => "i686-linux-android",
                .x86_64 => "x86_64-linux-android",
                .arm => "arm-linux-androideabi",
                .aarch64 => "aarch64-linux-android",
                else => @panic("Unsupported Android architecture"),
            };
            const api_level = "21";

            if (std.process.getEnvVarOwned(b.allocator, "ANDROID_NDK_HOME")) |ndk_home| {
                const builtin = @import("builtin");
                const ndk_host = switch (builtin.os.tag) {
                    .macos => "darwin-x86_64",
                    .linux => "linux-x86_64",
                    .windows => "windows-x86_64",
                    else => @panic("Unsupported host OS for Android NDK"),
                };
                const ndk_sysroot = b.fmt("{s}/toolchains/llvm/prebuilt/{s}/sysroot", .{ ndk_home, ndk_host });

                lib.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{ndk_sysroot}) });
                lib.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include/{s}", .{ ndk_sysroot, android_triple }) });

                lib.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib/{s}/{s}", .{ ndk_sysroot, android_triple, api_level }) });
                lib.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib/{s}", .{ ndk_sysroot, android_triple }) });
            } else |_| {
                std.debug.print("Warning: ANDROID_NDK_HOME not set for Android build\n", .{});
            }

            lib.root_module.linkSystemLibrary("log", .{});
            lib.root_module.linkSystemLibrary("android", .{});
        } else if (os_tag == .linux) {
            lib.linkLibC();
            lib.linkSystemLibrary("pthread");
            lib.linkSystemLibrary("m");
        } else if (os_tag == .windows) {
            lib.linkLibC();
            lib.linkSystemLibrary("ws2_32");
            lib.linkSystemLibrary("crypt32");
        } else {
            lib.linkLibC();
            lib.linkSystemLibrary("pthread");
        }

        // Install to addons/colyseus/bin directory
        const lib_prefix = if (os_tag == .windows) "" else "lib";
        const lib_ext = switch (os_tag) {
            .macos, .ios => ".dylib",
            .windows => ".dll",
            else => ".so",
        };
        const install_file = b.addInstallFile(lib.getEmittedBin(), b.fmt("../addons/colyseus/bin/{s}{s}{s}", .{
            lib_prefix,
            lib_name,
            lib_ext,
        }));

        b.getInstallStep().dependOn(&install_file.step);
    }
}
