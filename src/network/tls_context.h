#ifndef COLYSEUS_TLS_CONTEXT_H
#define COLYSEUS_TLS_CONTEXT_H

#include <mbedtls/net_sockets.h>
#include <mbedtls/ssl.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/error.h>

typedef struct {
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context ctr_drbg;
    mbedtls_x509_crt ca_chain;  /* CA certificate chain for verification */
    int ca_chain_initialized;   /* Whether ca_chain was initialized */
    int handshake_done;
} colyseus_tls_context_t;

#endif /* COLYSEUS_TLS_CONTEXT_H */