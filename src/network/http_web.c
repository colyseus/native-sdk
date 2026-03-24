#ifdef __EMSCRIPTEN__

#include "colyseus/http.h"
#include "colyseus/settings.h"
#include <emscripten.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// ============================================================================
// SIDE_MODULE (Godot) - Uses polling approach since JS can't callback to C
// ============================================================================
#ifdef GDEXTENSION_SIDE_MODULE

typedef struct {
    int request_id;
    colyseus_http_success_callback_t on_success;
    colyseus_http_error_callback_t on_error;
    void* userdata;
} http_request_context_t;

static int g_next_request_id = 1;

#define MAX_PENDING_REQUESTS 64
static http_request_context_t* g_pending_requests[MAX_PENDING_REQUESTS] = {0};

static void init_http_polling(void) {
    static int initialized = 0;
    if (initialized) return;
    initialized = 1;
    
    emscripten_run_script(
        "if (!Module._colyseusHttp) {"
        "  Module._colyseusHttp = { results: {}, nextId: 1 };"
        "}"
    );
}

static char* escape_json_string(const char* str) {
    if (!str) return strdup("null");
    
    size_t len = strlen(str);
    size_t escaped_len = len * 2 + 3;
    char* escaped = malloc(escaped_len);
    char* p = escaped;
    
    *p++ = '"';
    for (size_t i = 0; i < len; i++) {
        char c = str[i];
        if (c == '"' || c == '\\') {
            *p++ = '\\';
        } else if (c == '\n') {
            *p++ = '\\';
            c = 'n';
        } else if (c == '\r') {
            *p++ = '\\';
            c = 'r';
        } else if (c == '\t') {
            *p++ = '\\';
            c = 't';
        }
        *p++ = c;
    }
    *p++ = '"';
    *p = '\0';
    
    return escaped;
}

EMSCRIPTEN_KEEPALIVE
void colyseus_http_poll(void) {
    for (int i = 0; i < MAX_PENDING_REQUESTS; i++) {
        http_request_context_t* ctx = g_pending_requests[i];
        if (!ctx) continue;
        
        char check_script[256];
        snprintf(check_script, sizeof(check_script),
            "(Module._colyseusHttp && Module._colyseusHttp.results[%d]) ? 1 : 0",
            ctx->request_id
        );
        
        int has_result = emscripten_run_script_int(check_script);
        if (!has_result) continue;
        
        char status_script[256];
        snprintf(status_script, sizeof(status_script),
            "Module._colyseusHttp.results[%d].status",
            ctx->request_id
        );
        int status = emscripten_run_script_int(status_script);
        
        char ok_script[256];
        snprintf(ok_script, sizeof(ok_script),
            "Module._colyseusHttp.results[%d].ok ? 1 : 0",
            ctx->request_id
        );
        int ok = emscripten_run_script_int(ok_script);
        
        char error_script[256];
        snprintf(error_script, sizeof(error_script),
            "Module._colyseusHttp.results[%d].error ? 1 : 0",
            ctx->request_id
        );
        int is_error = emscripten_run_script_int(error_script);
        
        if (is_error) {
            char* get_msg_script = malloc(512);
            snprintf(get_msg_script, 512,
                "(function() {"
                "  var r = Module._colyseusHttp.results[%d];"
                "  delete Module._colyseusHttp.results[%d];"
                "  return r.message || \"Network error\";"
                "})()",
                ctx->request_id, ctx->request_id
            );
            char* msg = emscripten_run_script_string(get_msg_script);
            free(get_msg_script);
            
            printf("[HTTP] Error: %s\n", msg);
            
            if (ctx->on_error) {
                colyseus_http_error_t error;
                error.code = -1;
                error.message = msg ? strdup(msg) : strdup("Network error");
                ctx->on_error(&error, ctx->userdata);
                free(error.message);
            }
        } else {
            char* get_body_script = malloc(512);
            snprintf(get_body_script, 512,
                "(function() {"
                "  var r = Module._colyseusHttp.results[%d];"
                "  delete Module._colyseusHttp.results[%d];"
                "  return r.body || \"\";"
                "})()",
                ctx->request_id, ctx->request_id
            );
            char* body = emscripten_run_script_string(get_body_script);
            free(get_body_script);
            
            printf("[HTTP] Success: status=%d\n", status);
            
            if (ctx->on_success) {
                colyseus_http_response_t response;
                response.status_code = status;
                response.success = ok;
                response.body = body ? strdup(body) : strdup("");
                ctx->on_success(&response, ctx->userdata);
                free(response.body);
            }
        }
        
        free(ctx);
        g_pending_requests[i] = NULL;
    }
}

static void http_fetch_request(
    colyseus_http_t* http_client,
    const char* method,
    const char* path,
    const char* json_body,
    colyseus_http_success_callback_t on_success,
    colyseus_http_error_callback_t on_error,
    void* userdata
) {
    init_http_polling();
    
    char* base_url = colyseus_settings_get_webrequest_endpoint(http_client->settings);
    if (!base_url) {
        if (on_error) {
            colyseus_http_error_t error = { .code = -1, .message = "No base URL" };
            on_error(&error, userdata);
        }
        return;
    }
    
    size_t url_len = strlen(base_url) + strlen(path) + 2;
    char* full_url = malloc(url_len);
    snprintf(full_url, url_len, "%s/%s", base_url, path);
    free(base_url);
    
    printf("[HTTP] %s %s\n", method, full_url);
    if (json_body) {
        printf("[HTTP] Body: %s\n", json_body);
    }
    
    int request_id = g_next_request_id++;
    
    http_request_context_t* ctx = malloc(sizeof(http_request_context_t));
    ctx->request_id = request_id;
    ctx->on_success = on_success;
    ctx->on_error = on_error;
    ctx->userdata = userdata;
    
    for (int i = 0; i < MAX_PENDING_REQUESTS; i++) {
        if (!g_pending_requests[i]) {
            g_pending_requests[i] = ctx;
            break;
        }
    }
    
    char* escaped_url = escape_json_string(full_url);
    char* escaped_body = json_body ? escape_json_string(json_body) : strdup("null");
    
    size_t script_len = 2048 + strlen(escaped_url) + strlen(escaped_body);
    char* script = malloc(script_len);
    
    snprintf(script, script_len,
        "(function() {"
        "  var reqId = %d;"
        "  var url = %s;"
        "  var method = \"%s\";"
        "  var body = %s;"
        "  var opts = { method: method, headers: { \"Content-Type\": \"application/json\", \"Accept\": \"application/json\" } };"
        "  if (body !== null && method !== \"GET\") opts.body = body;"
        "  fetch(url, opts)"
        "    .then(function(r) { return r.text().then(function(t) { return { status: r.status, body: t, ok: r.ok }; }); })"
        "    .then(function(res) {"
        "      Module._colyseusHttp.results[reqId] = { status: res.status, body: res.body, ok: res.ok, error: false };"
        "    })"
        "    .catch(function(e) {"
        "      Module._colyseusHttp.results[reqId] = { error: true, message: e.message || \"Network error\" };"
        "    });"
        "})();",
        request_id,
        escaped_url,
        method,
        escaped_body
    );
    
    emscripten_run_script(script);
    
    free(script);
    free(escaped_url);
    free(escaped_body);
    free(full_url);
}

// ============================================================================
// Standalone WASM (Raylib) - Uses emscripten_fetch with direct callbacks
// ============================================================================
#else

#include <emscripten/fetch.h>

typedef struct {
    colyseus_http_success_callback_t on_success;
    colyseus_http_error_callback_t on_error;
    void* userdata;
} http_request_context_t;

static void on_fetch_success(emscripten_fetch_t* fetch) {
    http_request_context_t* ctx = (http_request_context_t*)fetch->userData;
    
    printf("[HTTP] Success: status=%d\n", fetch->status);
    
    if (ctx && ctx->on_success) {
        colyseus_http_response_t response;
        response.status_code = fetch->status;
        response.success = (fetch->status >= 200 && fetch->status < 300);
        response.body = fetch->numBytes > 0 ? strndup(fetch->data, fetch->numBytes) : strdup("");
        ctx->on_success(&response, ctx->userdata);
        free(response.body);
    }
    
    free(ctx);
    emscripten_fetch_close(fetch);
}

static void on_fetch_error(emscripten_fetch_t* fetch) {
    http_request_context_t* ctx = (http_request_context_t*)fetch->userData;
    
    printf("[HTTP] Error: status=%d\n", fetch->status);
    
    if (ctx && ctx->on_error) {
        colyseus_http_error_t error;
        error.code = fetch->status;
        error.message = strdup(fetch->statusText[0] ? fetch->statusText : "Network error");
        ctx->on_error(&error, ctx->userdata);
        free(error.message);
    }
    
    free(ctx);
    emscripten_fetch_close(fetch);
}

static void http_fetch_request(
    colyseus_http_t* http_client,
    const char* method,
    const char* path,
    const char* json_body,
    colyseus_http_success_callback_t on_success,
    colyseus_http_error_callback_t on_error,
    void* userdata
) {
    char* base_url = colyseus_settings_get_webrequest_endpoint(http_client->settings);
    if (!base_url) {
        if (on_error) {
            colyseus_http_error_t error = { .code = -1, .message = "No base URL" };
            on_error(&error, userdata);
        }
        return;
    }
    
    size_t url_len = strlen(base_url) + strlen(path) + 2;
    char* full_url = malloc(url_len);
    snprintf(full_url, url_len, "%s/%s", base_url, path);
    free(base_url);
    
    printf("[HTTP] %s %s\n", method, full_url);
    if (json_body) {
        printf("[HTTP] Body: %s\n", json_body);
    }
    
    http_request_context_t* ctx = malloc(sizeof(http_request_context_t));
    ctx->on_success = on_success;
    ctx->on_error = on_error;
    ctx->userdata = userdata;
    
    emscripten_fetch_attr_t attr;
    emscripten_fetch_attr_init(&attr);
    strncpy(attr.requestMethod, method, sizeof(attr.requestMethod) - 1);
    attr.attributes = EMSCRIPTEN_FETCH_LOAD_TO_MEMORY;
    attr.onsuccess = on_fetch_success;
    attr.onerror = on_fetch_error;
    attr.userData = ctx;
    
    const char* headers[] = {
        "Content-Type", "application/json",
        "Accept", "application/json",
        NULL
    };
    attr.requestHeaders = headers;
    
    if (json_body && strcmp(method, "GET") != 0) {
        attr.requestData = json_body;
        attr.requestDataSize = strlen(json_body);
    }
    
    emscripten_fetch(&attr, full_url);
    free(full_url);
}

#endif /* GDEXTENSION_SIDE_MODULE */

colyseus_http_t* colyseus_http_create(const colyseus_settings_t* settings) {
    colyseus_http_t* http = malloc(sizeof(colyseus_http_t));
    if (!http) return NULL;
    
    http->settings = settings;
    http->auth_token = NULL;
    
    return http;
}

void colyseus_http_free(colyseus_http_t* http) {
    if (!http) return;
    free(http->auth_token);
    free(http);
}

void colyseus_http_set_auth_token(colyseus_http_t* http, const char* token) {
    if (!http) return;
    free(http->auth_token);
    http->auth_token = token ? strdup(token) : NULL;
}

const char* colyseus_http_get_auth_token(const colyseus_http_t* http) {
    return http ? http->auth_token : NULL;
}

void colyseus_http_get(
    colyseus_http_t* http,
    const char* path,
    colyseus_http_success_callback_t on_success,
    colyseus_http_error_callback_t on_error,
    void* userdata
) {
    http_fetch_request(http, "GET", path, NULL, on_success, on_error, userdata);
}

void colyseus_http_post(
    colyseus_http_t* http,
    const char* path,
    const char* json_body,
    colyseus_http_success_callback_t on_success,
    colyseus_http_error_callback_t on_error,
    void* userdata
) {
    http_fetch_request(http, "POST", path, json_body, on_success, on_error, userdata);
}

void colyseus_http_put(
    colyseus_http_t* http,
    const char* path,
    const char* json_body,
    colyseus_http_success_callback_t on_success,
    colyseus_http_error_callback_t on_error,
    void* userdata
) {
    http_fetch_request(http, "PUT", path, json_body, on_success, on_error, userdata);
}

void colyseus_http_delete(
    colyseus_http_t* http,
    const char* path,
    colyseus_http_success_callback_t on_success,
    colyseus_http_error_callback_t on_error,
    void* userdata
) {
    http_fetch_request(http, "DELETE", path, NULL, on_success, on_error, userdata);
}

void colyseus_http_patch(
    colyseus_http_t* http,
    const char* path,
    const char* json_body,
    colyseus_http_success_callback_t on_success,
    colyseus_http_error_callback_t on_error,
    void* userdata
) {
    http_fetch_request(http, "PATCH", path, json_body, on_success, on_error, userdata);
}

void colyseus_http_response_free(colyseus_http_response_t* response) {
    (void)response;
}

void colyseus_http_error_free(colyseus_http_error_t* error) {
    (void)error;
}

#endif /* __EMSCRIPTEN__ */
