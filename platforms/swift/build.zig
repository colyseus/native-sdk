const std = @import("std");

// Builds libcolyseus as a static library for each Apple slice.
// The build.sh wrapper calls this once per slice then uses xcodebuild
// to assemble the xcframework.
//
// Supported targets (pass via -Dtarget=…):
//   aarch64-macos          – macOS Apple Silicon
//   x86_64-macos           – macOS Intel
//   aarch64-ios            – iOS device
//   aarch64-ios-simulator  – iOS Simulator (Apple Silicon host)
//   x86_64-ios-simulator   – iOS Simulator (Intel host)
//   aarch64-tvos           – tvOS device
//   aarch64-tvos-simulator – tvOS Simulator

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const os_tag = target.result.os.tag;
    const is_ios = os_tag == .ios;
    const is_tvos = os_tag == .tvos;
    const is_apple = os_tag == .macos or is_ios or is_tvos;

    // Auto-detect Apple SDK path via xcrun
    const apple_sdk_path: ?[]const u8 = b.option(
        []const u8,
        "apple-sdk",
        "Path to Apple SDK (auto-detected via xcrun if omitted)",
    ) orelse blk: {
        if (!is_apple) break :blk null;
        const sdk_name: []const u8 = switch (os_tag) {
            .macos => "macosx",
            .tvos => "appletvos",
            else => "iphoneos",
        };
        // For simulators, use the simulator SDK
        const is_sim = target.result.abi == .simulator;
        const sdk: []const u8 = if (is_sim) switch (os_tag) {
            .ios => "iphonesimulator",
            .tvos => "appletvsimulator",
            else => sdk_name,
        } else sdk_name;

        const result = std.process.Child.run(.{
            .allocator = b.allocator,
            .argv = &.{ "xcrun", "--sdk", sdk, "--show-sdk-path" },
        }) catch break :blk null;
        defer b.allocator.free(result.stdout);
        defer b.allocator.free(result.stderr);
        if (result.term.Exited == 0 and result.stdout.len > 0) {
            const trimmed = std.mem.trimRight(u8, result.stdout, "\n\r");
            break :blk b.allocator.dupe(u8, trimmed) catch null;
        }
        break :blk null;
    };

    // -------------------------------------------------------------------------
    // wslay (WebSocket framing)
    // -------------------------------------------------------------------------
    const wslay_config_h = b.addConfigHeader(.{
        .style = .blank,
        .include_path = "config.h",
    }, .{
        .HAVE_ARPA_INET_H = 1,
        .HAVE_NETINET_IN_H = 1,
    });

    const wslay_version_h = b.addConfigHeader(.{
        .style = .{ .cmake = b.path("../../third_party/wslay/lib/includes/wslay/wslayver.h.in") },
        .include_path = "wslay/wslayver.h",
    }, .{ .PACKAGE_VERSION = "1.1.1" });

    const wslay = b.addLibrary(.{
        .name = "wslay",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
        .linkage = .static,
    });
    appleLibc(wslay, apple_sdk_path);
    wslay.addIncludePath(b.path("../../third_party/wslay/lib/includes"));
    wslay.addIncludePath(b.path("../../third_party/wslay/lib"));
    wslay.addConfigHeader(wslay_config_h);
    wslay.addConfigHeader(wslay_version_h);
    wslay.addCSourceFiles(.{
        .files = &.{
            "../../third_party/wslay/lib/wslay_event.c",
            "../../third_party/wslay/lib/wslay_frame.c",
            "../../third_party/wslay/lib/wslay_net.c",
            "../../third_party/wslay/lib/wslay_queue.c",
        },
        .flags = &.{ "-Wall", "-std=c11", "-DHAVE_CONFIG_H" },
    });

    // -------------------------------------------------------------------------
    // mbedTLS
    // -------------------------------------------------------------------------
    const mbedcrypto = buildMbedcrypto(b, target, optimize, apple_sdk_path);
    const mbedx509 = buildMbedx509(b, target, optimize, apple_sdk_path, mbedcrypto);
    const mbedtls = buildMbedtls(b, target, optimize, apple_sdk_path, mbedx509, mbedcrypto);

    // -------------------------------------------------------------------------
    // Zig helper modules
    // -------------------------------------------------------------------------
    const msgpack_dep = b.dependency("zig_msgpack", .{
        .target = target,
        .optimize = optimize,
    });
    const msgpack_module = msgpack_dep.module("msgpack");

    const msgpack_builder_mod = b.createModule(.{
        .root_source_file = b.path("../../src/msgpack/msgpack_builder.zig"),
        .target = target,
        .optimize = optimize,
    });
    msgpack_builder_mod.addImport("msgpack", msgpack_module);
    const msgpack_builder = b.addLibrary(.{
        .name = "msgpack_builder",
        .root_module = msgpack_builder_mod,
        .linkage = .static,
    });
    appleLibc(msgpack_builder, apple_sdk_path);

    const msgpack_reader_mod = b.createModule(.{
        .root_source_file = b.path("../../src/msgpack/msgpack_reader.zig"),
        .target = target,
        .optimize = optimize,
    });
    msgpack_reader_mod.addImport("msgpack", msgpack_module);
    const msgpack_reader = b.addLibrary(.{
        .name = "msgpack_reader",
        .root_module = msgpack_reader_mod,
        .linkage = .static,
    });
    appleLibc(msgpack_reader, apple_sdk_path);

    const strutil_mod = b.createModule(.{
        .root_source_file = b.path("../../src/utils/strUtil.zig"),
        .target = target,
        .optimize = optimize,
    });
    const strutil = b.addLibrary(.{
        .name = "strutil_zig",
        .root_module = strutil_mod,
        .linkage = .static,
    });
    appleLibc(strutil, apple_sdk_path);

    const http_mod = b.createModule(.{
        .root_source_file = b.path("../../src/network/http.zig"),
        .target = target,
        .optimize = optimize,
    });
    http_mod.addIncludePath(b.path("../../include"));
    http_mod.addIncludePath(b.path("../../third_party/uthash/src"));
    const http_zig = b.addLibrary(.{
        .name = "http_zig",
        .root_module = http_mod,
        .linkage = .static,
    });
    appleLibc(http_zig, apple_sdk_path);

    const syscerts_mod = b.createModule(.{
        .root_source_file = b.path("../../src/certs/system_certs.zig"),
        .target = target,
        .optimize = optimize,
    });
    const syscerts = b.addLibrary(.{
        .name = "system_certs_zig",
        .root_module = syscerts_mod,
        .linkage = .static,
    });
    appleLibc(syscerts, apple_sdk_path);

    // -------------------------------------------------------------------------
    // Core colyseus C library
    // -------------------------------------------------------------------------
    const colyseus = b.addLibrary(.{
        .name = "colyseus",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
        .linkage = .static,
    });
    appleLibc(colyseus, apple_sdk_path);

    colyseus.addIncludePath(b.path("../../include"));
    colyseus.addIncludePath(b.path("../../src"));
    colyseus.addIncludePath(b.path("../../third_party/sds"));
    colyseus.addIncludePath(b.path("../../third_party/uthash/src"));
    colyseus.addIncludePath(b.path("../../third_party/cJSON"));
    colyseus.addIncludePath(b.path("../../third_party/wslay/lib/includes"));
    colyseus.addIncludePath(b.path("../../third_party/mbedtls/include"));
    colyseus.addIncludePath(wslay_config_h.getOutput().dirname());
    colyseus.addIncludePath(wslay_version_h.getOutput().dirname().dirname());

    colyseus.addCSourceFiles(.{
        .files = &.{
            "../../src/common/settings.c",
            "../../src/client.c",
            "../../src/room.c",
            "../../src/network/websocket_transport.c",
            "../../src/schema/decode.c",
            "../../src/schema/ref_tracker.c",
            "../../src/schema/collections.c",
            "../../src/schema/decoder.c",
            "../../src/schema/serializer.c",
            "../../src/schema/callbacks.c",
            "../../src/schema/dynamic_schema.c",
            "../../src/utils/strUtil.c",
            "../../src/utils/sha1_c.c",
            "../../src/auth/auth.c",
            "../../src/auth/secure_storage.c",
            "../../src/certs/ca_bundle.c",
            "../../third_party/sds/sds.c",
            "../../third_party/cJSON/cJSON.c",
        },
        .flags = &.{ "-Wall", "-Wextra", "-std=c11" },
    });

    colyseus.linkLibrary(mbedtls);
    colyseus.linkLibrary(mbedx509);
    colyseus.linkLibrary(mbedcrypto);
    colyseus.linkLibrary(wslay);
    colyseus.linkLibrary(http_zig);
    colyseus.linkLibrary(syscerts);
    colyseus.linkLibrary(strutil);
    colyseus.linkLibrary(msgpack_builder);
    colyseus.linkLibrary(msgpack_reader);

    // Frameworks are needed at final link time (by the Swift consumer), not
    // when building the static library. We add the SDK framework search path
    // so that Zig can resolve them if it needs to, but we don't force-link
    // them into the static archive.
    if (apple_sdk_path) |sdk| {
        const fw_path = b.pathJoin(&.{ sdk, "System/Library/Frameworks" });
        colyseus.addFrameworkPath(.{ .cwd_relative = fw_path });
    }
    // Record the framework dependencies so they are propagated to the linker
    // when the static lib is consumed.
    colyseus.linkFramework("CoreFoundation");
    colyseus.linkFramework("Security");
    if (os_tag == .macos) {
        colyseus.linkSystemLibrary("pthread");
    }

    b.installArtifact(colyseus);

    // Install colyseus public headers so build.sh can copy them into the xcframework.
    const header_pairs = [_][2][]const u8{
        .{ "../../include/colyseus/client.h",              "colyseus/client.h" },
        .{ "../../include/colyseus/room.h",                "colyseus/room.h" },
        .{ "../../include/colyseus/settings.h",            "colyseus/settings.h" },
        .{ "../../include/colyseus/protocol.h",            "colyseus/protocol.h" },
        .{ "../../include/colyseus/transport.h",           "colyseus/transport.h" },
        .{ "../../include/colyseus/messages.h",            "colyseus/messages.h" },
        .{ "../../include/colyseus/schema.h",              "colyseus/schema.h" },
        .{ "../../include/colyseus/http.h",                "colyseus/http.h" },
        .{ "../../include/colyseus/auth/auth.h",           "colyseus/auth/auth.h" },
        .{ "../../include/colyseus/auth/secure_storage.h", "colyseus/auth/secure_storage.h" },
        .{ "../../include/colyseus/schema/types.h",        "colyseus/schema/types.h" },
        .{ "../../include/colyseus/schema/decode.h",       "colyseus/schema/decode.h" },
        .{ "../../include/colyseus/schema/decoder.h",      "colyseus/schema/decoder.h" },
        .{ "../../include/colyseus/schema/collections.h",  "colyseus/schema/collections.h" },
        .{ "../../include/colyseus/schema/callbacks.h",    "colyseus/schema/callbacks.h" },
        .{ "../../include/colyseus/schema/dynamic_schema.h", "colyseus/schema/dynamic_schema.h" },
        .{ "../../include/colyseus/schema/ref_tracker.h",  "colyseus/schema/ref_tracker.h" },
        .{ "../../third_party/uthash/src/uthash.h",        "uthash.h" },
    };
    for (header_pairs) |pair| {
        const install_hdr = b.addInstallHeaderFile(b.path(pair[0]), pair[1]);
        b.getInstallStep().dependOn(&install_hdr.step);
    }
}

// ─── helpers ─────────────────────────────────────────────────────────────────

fn appleLibc(lib: *std.Build.Step.Compile, sdk_path: ?[]const u8) void {
    lib.linkLibC();
    if (sdk_path) |sdk| {
        const b = lib.step.owner;
        const inc = b.pathJoin(&.{ sdk, "usr/include" });
        lib.addSystemIncludePath(.{ .cwd_relative = inc });
    }
}

fn buildMbedcrypto(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdk_path: ?[]const u8,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "mbedcrypto",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
        .linkage = .static,
    });
    appleLibc(lib, sdk_path);
    lib.addIncludePath(b.path("../../third_party/mbedtls/include"));
    lib.addIncludePath(b.path("../../third_party/mbedtls/library"));
    lib.addCSourceFiles(.{
        .files = &MBEDCRYPTO_SOURCES,
        .flags = &.{ "-Wall", "-std=c11" },
    });
    return lib;
}

fn buildMbedx509(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdk_path: ?[]const u8,
    mbedcrypto: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "mbedx509",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
        .linkage = .static,
    });
    appleLibc(lib, sdk_path);
    lib.addIncludePath(b.path("../../third_party/mbedtls/include"));
    lib.addIncludePath(b.path("../../third_party/mbedtls/library"));
    lib.addCSourceFiles(.{
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
        .flags = &.{ "-Wall", "-std=c11" },
    });
    lib.linkLibrary(mbedcrypto);
    return lib;
}

fn buildMbedtls(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdk_path: ?[]const u8,
    mbedx509: *std.Build.Step.Compile,
    mbedcrypto: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "mbedtls",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
        .linkage = .static,
    });
    appleLibc(lib, sdk_path);
    lib.addIncludePath(b.path("../../third_party/mbedtls/include"));
    lib.addIncludePath(b.path("../../third_party/mbedtls/library"));
    lib.addCSourceFiles(.{
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
        .flags = &.{ "-Wall", "-std=c11" },
    });
    lib.linkLibrary(mbedx509);
    lib.linkLibrary(mbedcrypto);
    return lib;
}

const MBEDCRYPTO_SOURCES = [_][]const u8{
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
};
