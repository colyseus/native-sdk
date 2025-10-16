#ifndef COLYSEUS_HTTP_H
#define COLYSEUS_HTTP_H

#include "colyseus/settings.h"
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* HTTP response structure */
typedef struct {
    int status_code;
    char* body;
    bool success;
} colyseus_http_response_t;

/* HTTP exception/error structure */
typedef struct {
    int code;
    char* message;
} colyseus_http_error_t;

/* HTTP callbacks */
typedef void (*colyseus_http_success_callback_t)(const colyseus_http_response_t* response, void* userdata);
typedef void (*colyseus_http_error_callback_t)(const colyseus_http_error_t* error, void* userdata);

/* HTTP client structure */
typedef struct {
    const colyseus_settings_t* settings;
    char* auth_token;
} colyseus_http_t;

/* Create/destroy HTTP client */
colyseus_http_t* colyseus_http_create(const colyseus_settings_t* settings);
void colyseus_http_free(colyseus_http_t* http);

/* Set auth token */
void colyseus_http_set_auth_token(colyseus_http_t* http, const char* token);
const char* colyseus_http_get_auth_token(const colyseus_http_t* http);

/* HTTP methods (async with callbacks) */
void colyseus_http_get(
    colyseus_http_t* http,
    const char* path,
    colyseus_http_success_callback_t on_success,
    colyseus_http_error_callback_t on_error,
    void* userdata
);

void colyseus_http_post(
    colyseus_http_t* http,
    const char* path,
    const char* json_body,
    colyseus_http_success_callback_t on_success,
    colyseus_http_error_callback_t on_error,
    void* userdata
);

void colyseus_http_put(
    colyseus_http_t* http,
    const char* path,
    const char* json_body,
    colyseus_http_success_callback_t on_success,
    colyseus_http_error_callback_t on_error,
    void* userdata
);

void colyseus_http_delete(
    colyseus_http_t* http,
    const char* path,
    colyseus_http_success_callback_t on_success,
    colyseus_http_error_callback_t on_error,
    void* userdata
);

/* Helper functions for response/error cleanup */
void colyseus_http_response_free(colyseus_http_response_t* response);
void colyseus_http_error_free(colyseus_http_error_t* error);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_HTTP_H */