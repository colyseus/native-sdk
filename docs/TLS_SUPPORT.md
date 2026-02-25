# TLS/WSS Support

The Colyseus Native SDK supports secure WebSocket connections (wss://) using mbedTLS.

**TLS is enabled at runtime** via settings — no compile-time flags needed.

**CA certificates are auto-loaded** — the SDK uses a hybrid approach:
1. **System certificates** (preferred) — loaded via Zig's `std.crypto.Certificate.Bundle.rescan()`
2. **Bundled Mozilla CA** (fallback) — ~225KB bundle included in SDK

## Building

### Prerequisites

mbedTLS is built from source as part of the SDK — no external dependencies required.

### Build

```bash
zig build

zig build run-example
```

## Usage

### Basic WSS Connection

```c
#include <colyseus/client.h>
#include <colyseus/settings.h>

colyseus_settings_t* settings = colyseus_settings_create();
colyseus_settings_set_address(settings, "your-server.com");
colyseus_settings_set_port(settings, "443");
colyseus_settings_set_secure(settings, true);  // Enable wss://

colyseus_client_t* client = colyseus_client_create(settings);
colyseus_room_t* room = colyseus_client_join_or_create(client, "my_room", NULL);
```

### Certificate Verification

By default, TLS certificate verification is **enabled** with automatic certificate loading.

#### Automatic Certificate Loading

The SDK automatically loads CA certificates using a hybrid approach:

| Priority | Source | Description |
|----------|--------|-------------|
| 1 | System certificates | Uses OS certificate store (Linux, macOS, Windows, BSD) |
| 2 | Bundled Mozilla CA | Falls back to embedded certificate bundle |
| 3 | Settings-provided | Custom certificates via `colyseus_settings_set_ca_certificates()` |

**System certificate locations scanned:**
- **Linux**: `/etc/ssl/certs/ca-certificates.crt`, `/etc/pki/tls/certs/ca-bundle.crt`, etc.
- **macOS**: System keychain
- **Windows**: Windows certificate store
- **FreeBSD/OpenBSD**: `/etc/ssl/cert.pem`

**No manual certificate loading is required for most use cases.**

#### Skip Verification (Development Only)

For development with self-signed certificates:

```c
colyseus_settings_t* settings = colyseus_settings_create();
colyseus_settings_set_secure(settings, true);
settings->tls_skip_verification = true;  // ONLY for development!
```

### TLS Configuration Options

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `use_secure_protocol` | bool | false | `true` for wss://, `false` for ws:// |
| `tls_skip_verification` | bool | false | `true` skips cert validation (testing only) |
| `ca_pem_data` | const unsigned char* | NULL | Custom CA certificates (PEM format) |
| `ca_pem_len` | size_t | 0 | Length of custom CA data |

### Custom CA Certificates

To use your own CA certificates instead of the bundled ones:

```c
#include <colyseus/settings.h>

// Your PEM certificate data (must be null-terminated)
extern const unsigned char my_ca_pem[];
extern const size_t my_ca_pem_len;

colyseus_settings_t* settings = colyseus_settings_create();
colyseus_settings_set_secure(settings, true);
colyseus_settings_set_ca_certificates(settings, my_ca_pem, my_ca_pem_len);
```

## Godot Integration

### Automatic Setup

When using the Godot GDExtension, CA certificates are automatically loaded at initialization:

```gdscript
# Just set endpoint - certificates are handled automatically
var client = ColyseusClient.new()
client.endpoint = "wss://your-server.com"
var room = client.join_or_create("my_room")
```

### Certificate Override

To use a custom certificate bundle in Godot:

1. Go to **Project > Project Settings**
2. Navigate to **Network > TLS > Certificate Bundle Override**
3. Set the path to your `.crt` or `.pem` file

The SDK will automatically use your custom certificates instead of the bundled ones.

## Security Notes

### When `tls_skip_verification = false` (default)
- Server certificate chain is validated against bundled CA certificates
- Hostname is checked against the certificate
- Secure for production use

### When `tls_skip_verification = true`
- No certificate validation is performed
- Vulnerable to man-in-the-middle attacks
- **Only use for development/testing with self-signed certificates**

## Plain WebSocket (ws://)

Plain WebSocket connections are completely unaffected by TLS settings:

```c
colyseus_settings_t* settings = colyseus_settings_create();
colyseus_settings_set_secure(settings, false);  // ws:// — TLS settings ignored
```

## Troubleshooting

**"TLS init failed"**
- Check server supports TLS 1.2 or higher
- Verify the server is reachable

**Certificate verification fails**
- Ensure your server has a valid certificate from a trusted CA
- For self-signed certificates, use `tls_skip_verification = true` (development only)
- In Godot, check if you have a certificate override that might be causing issues

**Connection hangs during TLS handshake**
- Check firewall settings
- Verify server supports TLS 1.2 or higher
- Check server certificate is valid and not expired

## Certificate Loading Details

### System Certificates (Preferred)

The SDK uses Zig's `std.crypto.Certificate.Bundle.rescan()` to load certificates from your operating system's certificate store. This means:

- Certificates are always up-to-date (managed by OS)
- No need to update SDK for certificate changes
- Works with corporate/enterprise CA certificates

### Bundled Certificates (Fallback)

If system certificates are unavailable (minimal systems, containers, etc.), the SDK falls back to bundled Mozilla CA certificates. To update them:

1. Download the latest bundle from https://curl.se/ca/cacert.pem
2. Replace `src/certs/cacert.pem`
3. Regenerate `ca_bundle.c` using the Python script
4. Rebuild the SDK
