#ifndef COLYSEUS_STRUTIL_H
#define COLYSEUS_STRUTIL_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

    /* URL parts structure */
    typedef struct {
        char* scheme;
        char* host;
        uint16_t* port;  /* NULL if not specified */
        char* path_and_args;
        char* url;
    } colyseus_url_parts_t;

    /* Parse URL */
    colyseus_url_parts_t* colyseus_parse_url(const char* url);
    void colyseus_url_parts_free(colyseus_url_parts_t* parts);

    /* Base64 encoding/decoding */
    char* colyseus_base64_encode(const char* data);
    char* colyseus_base64_decode(const char* data);

    /* Helper: Create accept key for WebSocket handshake */
    char* colyseus_create_accept_key(const char* client_key);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_STRUTIL_H */