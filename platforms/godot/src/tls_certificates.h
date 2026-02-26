#ifndef GDEXT_TLS_CERTIFICATES_H
#define GDEXT_TLS_CERTIFICATES_H

#include <stddef.h>
#include <gdextension_interface.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Set the GDExtension API function for accessing singletons.
 * Must be called from colyseus_sdk_init() before gdext_tls_certificates_init().
 */
void gdext_tls_certificates_set_api(GDExtensionInterfaceGetProcAddress p_get_proc_address);

/**
 * Initialize TLS certificates for the Godot platform.
 * 
 * This function checks Godot's ProjectSettings for a certificate bundle override.
 * If found, it loads certificates from that file.
 * Otherwise, it uses the bundled Mozilla CA certificates.
 * 
 * Should be called during extension initialization.
 */
void gdext_tls_certificates_init(void);

/**
 * Clean up TLS certificates.
 * Should be called during extension deinitialization.
 */
void gdext_tls_certificates_cleanup(void);

/**
 * Get the loaded CA certificate data.
 * Returns a pointer to PEM-formatted certificate data (null-terminated).
 * Returns NULL if no certificates are loaded.
 */
const unsigned char* gdext_tls_get_ca_certificates(void);

/**
 * Get the length of the loaded CA certificate data.
 * Returns the length including the null terminator.
 * Returns 0 if no certificates are loaded.
 */
size_t gdext_tls_get_ca_certificates_len(void);

#ifdef __cplusplus
}
#endif

#endif /* GDEXT_TLS_CERTIFICATES_H */
