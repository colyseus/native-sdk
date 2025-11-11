#ifndef COLYSEUS_STRUTIL_H
#define COLYSEUS_STRUTIL_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#if !defined(HAVE_STRNDUP) && !defined(__APPLE__)
#ifndef _GNU_SOURCE
static inline size_t strnlen(const char *s, size_t maxlen) {
    size_t i;
    for (i = 0; i < maxlen && s[i]; i++);
    return i;
}
static inline char* strndup(const char* s, size_t n) {
    size_t len = strnlen(s, n);
    char* result = malloc(len + 1);
    if (!result) return NULL;
    memcpy(result, s, len);
    result[len] = '\0';
    return result;
}
#endif
#endif

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

    char* colyseus_base64_encode_binary(const uint8_t* data, size_t length);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_STRUTIL_H */
