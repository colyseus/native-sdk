#include "colyseus/auth/auth.h"
#include "colyseus/http.h"
#include "sds.h"
#include "cJSON.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "colyseus/auth/secure_storage.h"

/* Auth structure */
struct colyseus_auth_t {
    colyseus_http_t* http;
    colyseus_auth_settings_t settings;
    bool initialized;

    colyseus_auth_change_callback_t on_change;
    void* on_change_userdata;
};

/* Internal context for async operations */
typedef struct {
    colyseus_auth_t* auth;
    colyseus_auth_success_callback_t on_success;
    colyseus_auth_error_callback_t on_error;
    void* userdata;
} colyseus_auth_context_t;

/* Storage functions (simple in-memory for now, also stored in local secure memory, see auth/secure_storage.c) */
static char* stored_token = NULL;

static void storage_set_token(const char* key, const char* token) {
    // Store in memory
    free(stored_token);
    stored_token = token ? strdup(token) : NULL;

    // Also persist to disk/keychain/etc
    if (token) {
        secure_storage_set(key, token);
    } else {
        secure_storage_remove(key);
    }
}

static char* storage_get_token(const char* key) {
    // First check in-memory cache
    if (stored_token) {
        return strdup(stored_token);
    }

    // Otherwise load from persistent storage
    char* token = secure_storage_get(key);
    if (token) {
        stored_token = strdup(token);
    }
    return token;
}

static void storage_remove_token(const char* key) {
    // Clear from memory
    free(stored_token);
    stored_token = NULL;

    // Remove from persistent storage
    secure_storage_remove(key);
}

/* Internal helpers */
static void auth_emit_change(colyseus_auth_t* auth, const colyseus_auth_data_t* data);
static colyseus_auth_data_t* auth_parse_response(const char* json_str);

/* Create auth */
colyseus_auth_t* colyseus_auth_create(colyseus_http_t* http) {
    colyseus_auth_t* auth = malloc(sizeof(colyseus_auth_t));
    if (!auth) return NULL;

    auth->http = http;
    auth->settings.path = strdup("/auth");
    auth->settings.key = strdup("colyseus-auth-token");
    auth->initialized = false;
    auth->on_change = NULL;
    auth->on_change_userdata = NULL;

    /* Load stored token */
    char* token = storage_get_token(auth->settings.key);
    if (token) {
        colyseus_http_set_auth_token(http, token);
        free(token);
    }

    return auth;
}

void colyseus_auth_free(colyseus_auth_t* auth) {
    if (!auth) return;

    free(auth->settings.path);
    free(auth->settings.key);
    free(auth);
}

/* Settings */
void colyseus_auth_set_path(colyseus_auth_t* auth, const char* path) {
    if (!auth) return;
    free(auth->settings.path);
    auth->settings.path = strdup(path);
}

void colyseus_auth_set_storage_key(colyseus_auth_t* auth, const char* key) {
    if (!auth) return;
    free(auth->settings.key);
    auth->settings.key = strdup(key);
}

/* Token management */
void colyseus_auth_set_token(colyseus_auth_t* auth, const char* token) {
    if (!auth) return;
    colyseus_http_set_auth_token(auth->http, token);
}

const char* colyseus_auth_get_token(const colyseus_auth_t* auth) {
    return auth ? colyseus_http_get_auth_token(auth->http) : NULL;
}

/* Callbacks */
void colyseus_auth_on_change(colyseus_auth_t* auth, colyseus_auth_change_callback_t callback, void* userdata) {
    if (!auth) return;

    auth->on_change = callback;
    auth->on_change_userdata = userdata;

    /* Initialize on first onChange call */
    if (!auth->initialized) {
        auth->initialized = true;

        const char* token = colyseus_auth_get_token(auth);
        if (token && strlen(token) > 0) {
            /* Try to get user data */
            colyseus_auth_get_user_data(auth, NULL, NULL, NULL);
        } else {
            /* No token, emit null state */
            colyseus_auth_data_t data = { .user_json = NULL, .token = NULL };
            auth_emit_change(auth, &data);
        }
    }
}

/* Get user data */
static void auth_on_get_user_success(const colyseus_http_response_t* response, void* userdata) {
    colyseus_auth_context_t* ctx = (colyseus_auth_context_t*)userdata;

    colyseus_auth_data_t* data = auth_parse_response(response->body);
    if (data) {
        if (ctx->on_success) {
            ctx->on_success(data, ctx->userdata);
        }
        auth_emit_change(ctx->auth, data);
        colyseus_auth_data_free(data);
    }

    free(ctx);
}

static void auth_on_get_user_error(const colyseus_http_error_t* error, void* userdata) {
    colyseus_auth_context_t* ctx = (colyseus_auth_context_t*)userdata;

    if (ctx->on_error) {
        ctx->on_error(error->message, ctx->userdata);
    }

    /* Emit null state on error */
    colyseus_auth_data_t data = { .user_json = NULL, .token = NULL };
    auth_emit_change(ctx->auth, &data);

    free(ctx);
}

void colyseus_auth_get_user_data(
    colyseus_auth_t* auth,
    colyseus_auth_success_callback_t on_success,
    colyseus_auth_error_callback_t on_error,
    void* userdata
) {
    if (!auth) return;

    const char* token = colyseus_auth_get_token(auth);
    if (!token || strlen(token) == 0) {
        if (on_error) {
            on_error("missing auth.token", userdata);
        }
        return;
    }

    colyseus_auth_context_t* ctx = malloc(sizeof(colyseus_auth_context_t));
    ctx->auth = auth;
    ctx->on_success = on_success;
    ctx->on_error = on_error;
    ctx->userdata = userdata;

    sds path = sdscatprintf(sdsempty(), "%s/userdata", auth->settings.path);
    colyseus_http_get(auth->http, path, auth_on_get_user_success, auth_on_get_user_error, ctx);
    sdsfree(path);
}

/* Register with email/password */
static void auth_on_register_success(const colyseus_http_response_t* response, void* userdata) {
    colyseus_auth_context_t* ctx = (colyseus_auth_context_t*)userdata;

    colyseus_auth_data_t* data = auth_parse_response(response->body);
    if (data) {
        if (ctx->on_success) {
            ctx->on_success(data, ctx->userdata);
        }
        auth_emit_change(ctx->auth, data);
        colyseus_auth_data_free(data);
    }

    free(ctx);
}

static void auth_on_register_error(const colyseus_http_error_t* error, void* userdata) {
    colyseus_auth_context_t* ctx = (colyseus_auth_context_t*)userdata;

    if (ctx->on_error) {
        ctx->on_error(error->message, ctx->userdata);
    }

    free(ctx);
}

void colyseus_auth_register_email_password(
    colyseus_auth_t* auth,
    const char* email,
    const char* password,
    const char* options_json,
    colyseus_auth_success_callback_t on_success,
    colyseus_auth_error_callback_t on_error,
    void* userdata
) {
    if (!auth) return;

    /* Build request body */
    cJSON* json = cJSON_CreateObject();
    cJSON_AddStringToObject(json, "email", email);
    cJSON_AddStringToObject(json, "password", password);

    if (options_json) {
        cJSON* options = cJSON_Parse(options_json);
        if (options) {
            cJSON_AddItemToObject(json, "options", options);
        }
    }

    char* body = cJSON_PrintUnformatted(json);
    cJSON_Delete(json);

    colyseus_auth_context_t* ctx = malloc(sizeof(colyseus_auth_context_t));
    ctx->auth = auth;
    ctx->on_success = on_success;
    ctx->on_error = on_error;
    ctx->userdata = userdata;

    sds path = sdscatprintf(sdsempty(), "%s/register", auth->settings.path);
    colyseus_http_post(auth->http, path, body, auth_on_register_success, auth_on_register_error, ctx);
    sdsfree(path);
    free(body);
}

/* Sign in with email/password */
void colyseus_auth_signin_email_password(
    colyseus_auth_t* auth,
    const char* email,
    const char* password,
    colyseus_auth_success_callback_t on_success,
    colyseus_auth_error_callback_t on_error,
    void* userdata
) {
    if (!auth) return;

    /* Build request body */
    cJSON* json = cJSON_CreateObject();
    cJSON_AddStringToObject(json, "email", email);
    cJSON_AddStringToObject(json, "password", password);
    char* body = cJSON_PrintUnformatted(json);
    cJSON_Delete(json);

    colyseus_auth_context_t* ctx = malloc(sizeof(colyseus_auth_context_t));
    ctx->auth = auth;
    ctx->on_success = on_success;
    ctx->on_error = on_error;
    ctx->userdata = userdata;

    sds path = sdscatprintf(sdsempty(), "%s/login", auth->settings.path);
    colyseus_http_post(auth->http, path, body, auth_on_register_success, auth_on_register_error, ctx);
    sdsfree(path);
    free(body);
}

/* Sign in anonymously */
void colyseus_auth_signin_anonymous(
    colyseus_auth_t* auth,
    const char* options_json,
    colyseus_auth_success_callback_t on_success,
    colyseus_auth_error_callback_t on_error,
    void* userdata
) {
    if (!auth) return;

    /* Build request body */
    cJSON* json = cJSON_CreateObject();

    if (options_json) {
        cJSON* options = cJSON_Parse(options_json);
        if (options) {
            cJSON_AddItemToObject(json, "options", options);
        }
    }

    char* body = cJSON_PrintUnformatted(json);
    cJSON_Delete(json);

    colyseus_auth_context_t* ctx = malloc(sizeof(colyseus_auth_context_t));
    ctx->auth = auth;
    ctx->on_success = on_success;
    ctx->on_error = on_error;
    ctx->userdata = userdata;

    sds path = sdscatprintf(sdsempty(), "%s/anonymous", auth->settings.path);
    colyseus_http_post(auth->http, path, body, auth_on_register_success, auth_on_register_error, ctx);
    sdsfree(path);
    free(body);
}

/* Send password reset email */
void colyseus_auth_send_password_reset(
    colyseus_auth_t* auth,
    const char* email,
    colyseus_auth_success_callback_t on_success,
    colyseus_auth_error_callback_t on_error,
    void* userdata
) {
    if (!auth) return;

    /* Build request body */
    cJSON* json = cJSON_CreateObject();
    cJSON_AddStringToObject(json, "email", email);
    char* body = cJSON_PrintUnformatted(json);
    cJSON_Delete(json);

    colyseus_auth_context_t* ctx = malloc(sizeof(colyseus_auth_context_t));
    ctx->auth = auth;
    ctx->on_success = on_success;
    ctx->on_error = on_error;
    ctx->userdata = userdata;

    sds path = sdscatprintf(sdsempty(), "%s/forgot-password", auth->settings.path);
    colyseus_http_post(auth->http, path, body, auth_on_register_success, auth_on_register_error, ctx);
    sdsfree(path);
    free(body);
}

/* Sign out */
void colyseus_auth_signout(colyseus_auth_t* auth) {
    if (!auth) return;

    colyseus_auth_data_t data = { .user_json = NULL, .token = NULL };
    auth_emit_change(auth, &data);
}

/* Internal helpers */
static void auth_emit_change(colyseus_auth_t* auth, const colyseus_auth_data_t* data) {
    if (!auth) return;

    /* Update token */
    if (data->token) {
        colyseus_http_set_auth_token(auth->http, data->token);
        storage_set_token(auth->settings.key, data->token);
    } else {
        colyseus_http_set_auth_token(auth->http, NULL);
        storage_remove_token(auth->settings.key);
    }

    /* Call change callback */
    if (auth->on_change) {
        auth->on_change(data, auth->on_change_userdata);
    }
}

static colyseus_auth_data_t* auth_parse_response(const char* json_str) {
    cJSON* json = cJSON_Parse(json_str);
    if (!json) return NULL;

    colyseus_auth_data_t* data = malloc(sizeof(colyseus_auth_data_t));
    data->user_json = NULL;
    data->token = NULL;

    cJSON* user = cJSON_GetObjectItem(json, "user");
    if (user) {
        data->user_json = cJSON_PrintUnformatted(user);
    }

    cJSON* token = cJSON_GetObjectItem(json, "token");
    if (token && cJSON_IsString(token)) {
        data->token = strdup(token->valuestring);
    }

    cJSON_Delete(json);
    return data;
}

/* Free auth data */
void colyseus_auth_data_free(colyseus_auth_data_t* data) {
    if (!data) return;
    free(data->user_json);
    free(data->token);
    free(data);
}