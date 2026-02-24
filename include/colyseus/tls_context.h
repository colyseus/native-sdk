#ifndef COLYSEUS_TLS_CONTEXT_H
#define COLYSEUS_TLS_CONTEXT_H

#include <mbedtls/net_sockets.h>
#include <mbedtls/ssl.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/error.h>

typedef struct {
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context ctr_drbg;
    int handshake_done;
} colyseus_tls_context_t;

#endif /* COLYSEUS_TLS_CONTEXT_H */