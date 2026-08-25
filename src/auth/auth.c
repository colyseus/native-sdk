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

/* `stored_token` is process-wide and every auth response rewrites it from
 * whichever thread ran the request — a host that dispatches HTTP to a worker
 * (the Flutter and GameMaker bindings do) then races it against a client being
 * constructed on the main thread, freeing the string out from under a strdup.
 * Same precedent as net_delay.c: no lock on the web, where there is one
 * thread. */
#ifdef __EMSCRIPTEN__
#define AUTH_LOCK()   ((void)0)
#define AUTH_UNLOCK() ((void)0)
#else
#include <pthread.h>
static pthread_mutex_t g_auth_token_mu = PTHREAD_MUTEX_INITIALIZER;
#define AUTH_LOCK()   pthread_mutex_lock(&g_auth_token_mu)
#define AUTH_UNLOCK() pthread_mutex_unlock(&g_auth_token_mu)
#endif

static char* stored_token = NULL;

static void storage_set_token(const char* key, const char* token) {
    // Store in memory
    AUTH_LOCK();
    free(stored_token);
    stored_token = token ? strdup(token) : NULL;
    AUTH_UNLOCK();

    // Also persist to disk/keychain/etc
    if (token) {
        secure_storage_set(key, token);
    } else {
        secure_storage_remove(key);
    }
}

static char* storage_get_token(const char* key) {
    // First check in-memory cache
    AUTH_LOCK();
    if (stored_token) {
        char* cached = strdup(stored_token);
        AUTH_UNLOCK();
        return cached;
    }
    AUTH_UNLOCK();

    // Otherwise load from persistent storage
    char* token = secure_storage_get(key);
    if (token) {
        AUTH_LOCK();
        free(stored_token);
        stored_token = strdup(token);
        AUTH_UNLOCK();
    }
    return token;
}

static void storage_remove_token(const char* key) {
    // Clear from memory
    AUTH_LOCK();
    free(stored_token);
    stored_token = NULL;
    AUTH_UNLOCK();

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
        /* /auth/userdata answers with the user alone. Emitting that verbatim
         * would take auth_emit_change's no-token branch and clear the very
         * token that authorised the read — the JS SDK emits
         * `{...userData, token: this.token}` for exactly this reason. */
        if (!data->token) {
            const char* current = colyseus_auth_get_token(ctx->auth);
            if (current && current[0]) data->token = strdup(current);
        }
        /* Emit before handing the result out — see auth_on_register_success. */
        auth_emit_change(ctx->auth, data);
        if (ctx->on_success) {
            ctx->on_success(data, ctx->userdata);
        }
        colyseus_auth_data_free(data);
    }

    free(ctx);
}

static void auth_on_get_user_error(const colyseus_http_error_t* error, void* userdata) {
    colyseus_auth_context_t* ctx = (colyseus_auth_context_t*)userdata;

    /* Emit null state on error, before handing the failure out — see
     * auth_on_register_success. */
    colyseus_auth_data_t data = { .user_json = NULL, .token = NULL };
    auth_emit_change(ctx->auth, &data);

    if (ctx->on_error) {
        ctx->on_error(error->message, ctx->userdata);
    }

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
        /* Settle our own state BEFORE handing the result out. A binding that
         * resolves a future here gives the app the thread back mid-callback,
         * and disposing the client then frees `auth` under the emit. The JS
         * SDK emits before it resolves for the same reason. */
        auth_emit_change(ctx->auth, data);
        if (ctx->on_success) {
            ctx->on_success(data, ctx->userdata);
        }
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