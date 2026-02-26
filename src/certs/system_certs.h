#ifndef COLYSEUS_SYSTEM_CERTS_H
#define COLYSEUS_SYSTEM_CERTS_H

#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialize system certificates by scanning OS certificate stores.
 * 
 * Scans platform-specific locations:
 * - Linux: /etc/ssl/certs/ca-certificates.crt, /etc/pki/tls/certs/ca-bundle.crt, etc.
 * - macOS: System keychain
 * - Windows: Windows certificate store
 * - FreeBSD/OpenBSD: /etc/ssl/cert.pem
 * 
 * Returns true if certificates were loaded successfully.
 * Safe to call multiple times - subsequent calls are no-ops.
 */
bool colyseus_system_certs_init(void);

/**
 * Get the loaded certificates in PEM format.
 * Returns NULL if no certificates are loaded.
 */
const unsigned char* colyseus_system_certs_get_pem(void);

/**
 * Get the length of the PEM certificate data (including null terminator).
 * Returns 0 if no certificates are loaded.
 */
size_t colyseus_system_certs_get_pem_len(void);

/**
 * Check if system certificates are available.
 */
bool colyseus_system_certs_available(void);

/**
 * Clean up and free certificate resources.
 */
void colyseus_system_certs_cleanup(void);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_SYSTEM_CERTS_H */
