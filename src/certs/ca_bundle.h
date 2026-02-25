#ifndef COLYSEUS_CA_BUNDLE_H
#define COLYSEUS_CA_BUNDLE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Mozilla CA certificate bundle in PEM format.
 * Source: https://curl.se/ca/cacert.pem
 * 
 * This bundle is automatically used for TLS certificate verification
 * when connecting to wss:// endpoints.
 */
extern const unsigned char colyseus_ca_bundle_pem[];
extern const size_t colyseus_ca_bundle_pem_len;

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_CA_BUNDLE_H */
