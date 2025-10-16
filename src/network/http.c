#include "colyseus/http.h"
#include "sds.h"
#include <curl/curl.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* Callback context for async operations */
typedef struct {
    colyseus_http_t* http;
    colyseus_http_success_callback_t on_success;
    colyseus_http_error_callback_t on_error;
    void* userdata;
    sds response_body;
} colyseus_http_context_t;

/* CURL write callback */
static size_t colyseus_curl_write_callback(void* contents, size_t size, size_t nmemb, void* userp) {
    size_t total_size = size * nmemb;
    colyseus_http_context_t* ctx = (colyseus_http_context_t*)userp;

    ctx->response_body = sdscatlen(ctx->response_body, contents, total_size);

    return total_size;
}

/* Internal request function */
static void http_request(
    colyseus_http_t* http,
    const char* method,
    const char* path,
    const char* body,
    colyseus_http_success_callback_t on_success,
    colyseus_http_error_callback_t on_error,
    void* userdata
);

/* Create HTTP client */
colyseus_http_t* colyseus_http_create(const colyseus_settings_t* settings) {
    colyseus_http_t* http = malloc(sizeof(colyseus_http_t));
    if (!http) return NULL;

    http->settings = settings;
    http->auth_token = NULL;

    /* Initialize CURL globally */
    static bool curl_initialized = false;
    if (!curl_initialized) {
        curl_global_init(CURL_GLOBAL_DEFAULT);
        curl_initialized = true;
    }

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

/* HTTP methods */
void colyseus_http_get(
    colyseus_http_t* http,
    const char* path,
    colyseus_http_success_callback_t on_success,
    colyseus_http_error_callback_t on_error,
    void* userdata
) {
    http_request(http, "GET", path, NULL, on_success, on_error, userdata);
}

void colyseus_http_post(
    colyseus_http_t* http,
    const char* path,
    const char* json_body,
    colyseus_http_success_callback_t on_success,
    colyseus_http_error_callback_t on_error,
    void* userdata
) {
    http_request(http, "POST", path, json_body, on_success, on_error, userdata);
}

void colyseus_http_put(
    colyseus_http_t* http,
    const char* path,
    const char* json_body,
    colyseus_http_success_callback_t on_success,
    colyseus_http_error_callback_t on_error,
    void* userdata
) {
    http_request(http, "PUT", path, json_body, on_success, on_error, userdata);
}

void colyseus_http_delete(
    colyseus_http_t* http,
    const char* path,
    colyseus_http_success_callback_t on_success,
    colyseus_http_error_callback_t on_error,
    void* userdata
) {
    http_request(http, "DELETE", path, NULL, on_success, on_error, userdata);
}

/* Internal request implementation */
static void http_request(
    colyseus_http_t* http,
    const char* method,
    const char* path,
    const char* body,
    colyseus_http_success_callback_t on_success,
    colyseus_http_error_callback_t on_error,
    void* userdata
) {
    CURL* curl = curl_easy_init();
    if (!curl) {
        if (on_error) {
            colyseus_http_error_t error = { 0, "Failed to initialize CURL" };
            on_error(&error, userdata);
        }
        return;
    }

    /* Build URL */
    char* base_url = colyseus_settings_get_webrequest_endpoint(http->settings);
    sds url = sdsempty();

    /* Ensure proper path joining */
    if (base_url[strlen(base_url) - 1] == '/' && path[0] == '/') {
        url = sdscatprintf(url, "%s%s", base_url, path + 1);
    } else if (base_url[strlen(base_url) - 1] != '/' && path[0] != '/') {
        url = sdscatprintf(url, "%s/%s", base_url, path);
    } else {
        url = sdscatprintf(url, "%s%s", base_url, path);
    }

    free(base_url);

    /* Setup context for callback */
    colyseus_http_context_t ctx = {
        .http = http,
        .on_success = on_success,
        .on_error = on_error,
        .userdata = userdata,
        .response_body = sdsempty()
    };

    /* Configure CURL */
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, colyseus_curl_write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &ctx);

    /* Set method */
    if (strcmp(method, "POST") == 0) {
        curl_easy_setopt(curl, CURLOPT_POST, 1L);
        if (body) {
            curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
        }
    } else if (strcmp(method, "PUT") == 0) {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "PUT");
        if (body) {
            curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
        }
    } else if (strcmp(method, "DELETE") == 0) {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "DELETE");
    }

    /* Setup headers */
    struct curl_slist* headers = NULL;

    /* Add custom headers from settings */
    colyseus_header_t *header, *tmp;
    HASH_ITER(hh, http->settings->headers, header, tmp) {
        sds header_str = sdscatprintf(sdsempty(), "%s: %s", header->key, header->value);
        headers = curl_slist_append(headers, header_str);
        sdsfree(header_str);
    }

    /* Add auth token if present */
    if (http->auth_token) {
        sds auth_header = sdscatprintf(sdsempty(), "Authorization: Bearer %s", http->auth_token);
        headers = curl_slist_append(headers, auth_header);
        sdsfree(auth_header);
    }

    /* Add content-type for POST/PUT */
    if (body) {
        headers = curl_slist_append(headers, "Content-Type: application/json");
    }

    if (headers) {
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    }

    /* Perform request */
    CURLcode res = curl_easy_perform(curl);

    long status_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status_code);

    /* Cleanup CURL */
    if (headers) {
        curl_slist_free_all(headers);
    }
    curl_easy_cleanup(curl);
    sdsfree(url);

    /* Handle response */
    if (res != CURLE_OK) {
        if (on_error) {
            colyseus_http_error_t error = {
                .code = 0,
                .message = strdup(curl_easy_strerror(res))
            };
            on_error(&error, userdata);
            free(error.message);
        }
        sdsfree(ctx.response_body);
        return;
    }

    if (status_code >= 400) {
        if (on_error) {
            colyseus_http_error_t error = {
                .code = (int)status_code,
                .message = strdup(ctx.response_body)
            };
            on_error(&error, userdata);
            free(error.message);
        }
        sdsfree(ctx.response_body);
        return;
    }

    /* Success */
    if (on_success) {
        colyseus_http_response_t response = {
            .status_code = (int)status_code,
            .body = strdup(ctx.response_body),
            .success = true
        };
        on_success(&response, userdata);
        free(response.body);
    }

    sdsfree(ctx.response_body);
}

/* Helper functions */
void colyseus_http_response_free(colyseus_http_response_t* response) {
    if (!response) return;
    free(response->body);
    response->body = NULL;
}

void colyseus_http_error_free(colyseus_http_error_t* error) {
    if (!error) return;
    free(error->message);
    error->message = NULL;
}
