#ifdef __EMSCRIPTEN__

#include "colyseus/http.h"
#include "colyseus/settings.h"
#include <emscripten/fetch.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef struct {
    colyseus_http_success_callback_t on_success;
    colyseus_http_error_callback_t on_error;
    void* userdata;
} http_request_context_t;

static void on_fetch_success(emscripten_fetch_t* fetch) {
    http_request_context_t* ctx = (http_request_context_t*)fetch->userData;
    
    printf("[HTTP] Success: status=%d, bytes=%llu\n", fetch->status, fetch->numBytes);
    
    if (ctx->on_success) {
        colyseus_http_response_t response;
        response.status_code = fetch->status;
        response.success = (fetch->status >= 200 && fetch->status < 300);
        
        if (fetch->numBytes > 0) {
            response.body = malloc(fetch->numBytes + 1);
            memcpy(response.body, fetch->data, fetch->numBytes);
            response.body[fetch->numBytes] = '\0';
        } else {
            response.body = strdup("");
        }
        
        ctx->on_success(&response, ctx->userdata);
        free(response.body);
    }
    
    free(ctx);
    emscripten_fetch_close(fetch);
}

static void on_fetch_error(emscripten_fetch_t* fetch) {
    http_request_context_t* ctx = (http_request_context_t*)fetch->userData;
    
    printf("[HTTP] Error: status=%d, statusText=%s\n", fetch->status, fetch->statusText);
    
    if (ctx->on_error) {
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
    strcpy(attr.requestMethod, method);
    attr.attributes = EMSCRIPTEN_FETCH_LOAD_TO_MEMORY;
    attr.onsuccess = on_fetch_success;
    attr.onerror = on_fetch_error;
    attr.userData = ctx;
    
    if (json_body && strlen(json_body) > 0) {
        attr.requestData = json_body;
        attr.requestDataSize = strlen(json_body);
    }
    
    const char* headers[] = {
        "Content-Type", "application/json",
        "Accept", "application/json",
        NULL
    };
    attr.requestHeaders = headers;
    
    emscripten_fetch(&attr, full_url);
    free(full_url);
}

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

void colyseus_http_response_free(colyseus_http_response_t* response) {
    (void)response;
}

void colyseus_http_error_free(colyseus_http_error_t* error) {
    (void)error;
}

#endif /* __EMSCRIPTEN__ */
