# TLS/WSS Support

The Colyseus Native SDK supports secure WebSocket connections (wss://) using mbedTLS.

**TLS is enabled at runtime** via settings — no compile-time flags needed.

## Building

### Prerequisites

mbedTLS is always required:

**Ubuntu/Debian:**
```bash
sudo apt-get install libmbedtls-dev
```

**macOS (Homebrew):**
```bash
brew install mbedtls
```

**Windows (vcpkg):**
```bash
vcpkg install mbedtls
```

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

By default, TLS certificate verification is **enabled**.

#### Important: CA Certificates

mbedTLS does not have a built-in system CA store. To verify server certificates you must either load CA certificates manually or skip verification for development.

**Skip verification (development/testing only):**
```c
colyseus_settings_t* settings = colyseus_settings_create();
colyseus_settings_set_secure(settings, true);
settings->tls_skip_verification = true;
```

### TLS Configuration Options

| Field | Type | Default | Description |
|---|---|---|---|
| `use_secure_protocol` | bool | false | `true` for wss://, `false` for ws:// |
| `tls_skip_verification` | bool | false | `true` skips cert validation (testing only) |

## Security Notes

### When `tls_skip_verification = false` (default)
- Server certificate chain is validated
- Hostname is checked against the certificate
- **You must provide CA certificates** — mbedTLS has no default CA store

### When `tls_skip_verification = true`
- No certificate validation is performed
- Vulnerable to man-in-the-middle attacks
- **Only use for development/testing**

### Providing CA Certificates

Options:

1. **Bundle CA certificates with your application:**
    - Download from https://curl.se/ca/cacert.pem
    - Load using `mbedtls_x509_crt_parse_file()` before connecting

2. **Use system CA store (platform-specific):**
    - Linux: `/etc/ssl/certs/ca-certificates.crt`
    - macOS: Use Security framework
    - Windows: Use CryptoAPI

## Plain WebSocket (ws://)

Plain WebSocket connections are completely unaffected by TLS settings:

```c
colyseus_settings_t* settings = colyseus_settings_create();
colyseus_settings_set_secure(settings, false);  // ws:// — tls_skip_verification is ignored
```

## Troubleshooting

**"TLS init failed"**
- Ensure mbedTLS is installed and linked
- Check server supports TLS 1.2 or higher

**Certificate verification fails**
- mbedTLS has no default CA store — you must load CA certificates
- For testing, set `tls_skip_verification = true`
- For production, bundle CA certificates with your app

**Connection hangs during TLS handshake**
- Check firewall settings
- Verify server supports TLS 1.2 or higher
- Check server certificate is valid