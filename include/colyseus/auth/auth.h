#ifndef COLYSEUS_AUTH_H
#define COLYSEUS_AUTH_H

#include <stddef.h>
#include <stdbool.h>

#include "colyseus/http.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct colyseus_auth_t colyseus_auth_t;

/* Auth data structure */
typedef struct {
    char* user_json;  /* JSON string of user data */
    char* token;
} colyseus_auth_data_t;

/* Auth settings */
typedef struct {
    char* path;       /* Default: "/auth" */
    char* key;        /* Storage key, default: "colyseus-auth-token" */
} colyseus_auth_settings_t;

/* Callbacks */
typedef void (*colyseus_auth_change_callback_t)(const colyseus_auth_data_t* auth_data, void* userdata);
typedef void (*colyseus_auth_success_callback_t)(const colyseus_auth_data_t* auth_data, void* userdata);
typedef void (*colyseus_auth_error_callback_t)(const char* error, void* userdata);

/* Create/destroy */
colyseus_auth_t* colyseus_auth_create(colyseus_http_t* http);
void colyseus_auth_free(colyseus_auth_t* auth);

/* Settings */
void colyseus_auth_set_path(colyseus_auth_t* auth, const char* path);
void colyseus_auth_set_storage_key(colyseus_auth_t* auth, const char* key);

/* Token management */
void colyseus_auth_set_token(colyseus_auth_t* auth, const char* token);
const char* colyseus_auth_get_token(const colyseus_auth_t* auth);

/* Callbacks */
void colyseus_auth_on_change(colyseus_auth_t* auth, colyseus_auth_change_callback_t callback, void* userdata);

/* Authentication methods */
void colyseus_auth_get_user_data(
    colyseus_auth_t* auth,
    colyseus_auth_success_callback_t on_success,
    colyseus_auth_error_callback_t on_error,
    void* userdata
);

void colyseus_auth_register_email_password(
    colyseus_auth_t* auth,
    const char* email,
    const char* password,
    const char* options_json,
    colyseus_auth_success_callback_t on_success,
    colyseus_auth_error_callback_t on_error,
    void* userdata
);

void colyseus_auth_signin_email_password(
    colyseus_auth_t* auth,
    const char* email,
    const char* password,
    colyseus_auth_success_callback_t on_success,
    colyseus_auth_error_callback_t on_error,
    void* userdata
);

void colyseus_auth_signin_anonymous(
    colyseus_auth_t* auth,
    const char* options_json,
    colyseus_auth_success_callback_t on_success,
    colyseus_auth_error_callback_t on_error,
    void* userdata
);

void colyseus_auth_send_password_reset(
    colyseus_auth_t* auth,
    const char* email,
    colyseus_auth_success_callback_t on_success,
    colyseus_auth_error_callback_t on_error,
    void* userdata
);

void colyseus_auth_signout(colyseus_auth_t* auth);

/* Helpers */
void colyseus_auth_data_free(colyseus_auth_data_t* data);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_AUTH_H */