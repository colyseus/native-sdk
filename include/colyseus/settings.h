#ifndef COLYSEUS_SETTINGS_H
#define COLYSEUS_SETTINGS_H

#include <stdbool.h>
#include <stddef.h>
#include "uthash.h"

#ifdef __cplusplus
extern "C" {
#endif

    /* Header entry for hash map */
    typedef struct {
        char* key;
        char* value;
        UT_hash_handle hh;
    } colyseus_header_t;

    /* Settings structure */
    typedef struct {
        char* server_address;
        char* server_port;
        bool use_secure_protocol;
        bool tls_skip_verification;  /* Skip TLS certificate verification (wss:// only) */
        colyseus_header_t* headers;  /* Hash map of headers */
        
        /* CA certificate chain for TLS verification (PEM format, null-terminated) */
        const unsigned char* ca_pem_data;  /* Points to certificate data (not owned) */
        size_t ca_pem_len;                  /* Length including null terminator */
    } colyseus_settings_t;

    /* Create and destroy settings */
    colyseus_settings_t* colyseus_settings_create(void);
    void colyseus_settings_free(colyseus_settings_t* settings);

    /* Initialize with default values */
    void colyseus_settings_init(colyseus_settings_t* settings);

    /* Set properties */
    void colyseus_settings_set_address(colyseus_settings_t* settings, const char* address);
    void colyseus_settings_set_port(colyseus_settings_t* settings, const char* port);
    void colyseus_settings_set_secure(colyseus_settings_t* settings, bool secure);
    
    /* Set CA certificates for TLS verification (PEM format, must be null-terminated) */
    void colyseus_settings_set_ca_certificates(colyseus_settings_t* settings,
                                               const unsigned char* pem_data,
                                               size_t pem_len);

    /* Add/remove headers */
    void colyseus_settings_add_header(colyseus_settings_t* settings, const char* key, const char* value);
    void colyseus_settings_remove_header(colyseus_settings_t* settings, const char* key);
    const char* colyseus_settings_get_header(colyseus_settings_t* settings, const char* key);

    /* Get endpoints (returns newly allocated string - caller must free) */
    char* colyseus_settings_get_websocket_endpoint(const colyseus_settings_t* settings);
    char* colyseus_settings_get_webrequest_endpoint(const colyseus_settings_t* settings);
    int colyseus_settings_get_port(const colyseus_settings_t* settings);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_SETTINGS_H */
