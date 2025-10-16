#ifndef COLYSEUS_SETTINGS_H
#define COLYSEUS_SETTINGS_H

#include <stdbool.h>
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
        colyseus_header_t* headers;  /* Hash map of headers */
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
