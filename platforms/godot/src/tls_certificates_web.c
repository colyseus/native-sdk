/* No-op TLS certificate stubs for web builds.
 * The browser handles TLS natively — no certificate bundle needed. */

#include "tls_certificates.h"

void gdext_tls_certificates_set_api(GDExtensionInterfaceGetProcAddress p_get_proc_address) {
    (void)p_get_proc_address;
}

void gdext_tls_certificates_init(void) {}

void gdext_tls_certificates_cleanup(void) {}

const unsigned char* gdext_tls_get_ca_certificates(void) {
    return NULL;
}

size_t gdext_tls_get_ca_certificates_len(void) {
    return 0;
}
