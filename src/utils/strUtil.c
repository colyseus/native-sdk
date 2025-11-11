#include "colyseus/utils/strUtil.h"
#include "colyseus/utils/sha1_c.h"
#include "sds.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <curl/curl.h>

/* Parse URL using curl (portable across all platforms) */
colyseus_url_parts_t* colyseus_parse_url(const char* url) {
    CURLU* url_handle = curl_url();
    if (!url_handle) {
        return NULL;
    }

    /* curl's URL parser doesn't recognize ws:// and wss:// schemes by default.
     * Temporarily replace "ws" with "http" for parsing (ws->http, wss->https). */
    char* temp_url = NULL;
    bool is_websocket = false;

    if (strncmp(url, "ws", 2) == 0) {
        is_websocket = true;
        size_t len = strlen(url) + 3; /* "http" is 4, "ws" is 2, +1 for null */
        temp_url = malloc(len);
        snprintf(temp_url, len, "http%s", url + 2); /* Replace "ws" with "http" */
    }

    const char* parse_url = temp_url ? temp_url : url;

    /* Parse the URL */
    if (curl_url_set(url_handle, CURLUPART_URL, parse_url, 0) != CURLUE_OK) {
        curl_url_cleanup(url_handle);
        free(temp_url);
        return NULL;
    }
    
    free(temp_url);

    colyseus_url_parts_t* parts = malloc(sizeof(colyseus_url_parts_t));
    if (!parts) {
        curl_url_cleanup(url_handle);
        return NULL;
    }

    memset(parts, 0, sizeof(colyseus_url_parts_t));

    /* Extract scheme */
    char* scheme = NULL;
    if (curl_url_get(url_handle, CURLUPART_SCHEME, &scheme, 0) == CURLUE_OK && scheme) {
        /* Restore original ws/wss scheme if this was a WebSocket URL */
        if (is_websocket) {
            /* Check if it was secure (https -> wss, http -> ws) */
            bool is_secure = strcmp(scheme, "https") == 0;
            parts->scheme = strdup(is_secure ? "wss" : "ws");
        } else {
            parts->scheme = strdup(scheme);
        }
        curl_free(scheme);
    }

    /* Extract host */
    char* host = NULL;
    if (curl_url_get(url_handle, CURLUPART_HOST, &host, 0) == CURLUE_OK && host) {
        parts->host = strdup(host);
        curl_free(host);
    }

    /* Extract port (if present) */
    char* port_str = NULL;
    if (curl_url_get(url_handle, CURLUPART_PORT, &port_str, 0) == CURLUE_OK && port_str) {
        uint16_t port_num = (uint16_t)strtoul(port_str, NULL, 10);
        if (port_num > 0) {
            parts->port = malloc(sizeof(uint16_t));
            *parts->port = port_num;
        }
        curl_free(port_str);
    }

    /* Extract path and query combined */
    char* path = NULL;
    char* query = NULL;

    if (curl_url_get(url_handle, CURLUPART_PATH, &path, 0) == CURLUE_OK && path) {
        /* Remove leading '/' from path if present */
        const char* path_start = (path[0] == '/') ? path + 1 : path;

        if (curl_url_get(url_handle, CURLUPART_QUERY, &query, 0) == CURLUE_OK && query) {
            /* Combine path and query */
            size_t total_len = strlen(path_start) + strlen(query) + 2; /* +2 for '?' and '\0' */
            parts->path_and_args = malloc(total_len);
            if (parts->path_and_args) {
                snprintf(parts->path_and_args, total_len, "%s?%s", path_start, query);
            }
            curl_free(query);
        } else {
            /* Just the path */
            parts->path_and_args = strdup(path_start);
        }
        curl_free(path);
    } else {
        /* No path found, use empty string */
        parts->path_and_args = strdup("");
    }

    /* Store original URL */
    parts->url = strdup(url);

    curl_url_cleanup(url_handle);
    return parts;
}

void colyseus_url_parts_free(colyseus_url_parts_t* parts) {
    if (!parts) return;

    free(parts->scheme);
    free(parts->host);
    free(parts->port);
    free(parts->path_and_args);
    free(parts->url);
    free(parts);
}

/* Base64 encoding */
static const char base64_chars[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "abcdefghijklmnopqrstuvwxyz"
    "0123456789+/";

char* colyseus_base64_encode(const char* data) {
    if (!data) return NULL;

    size_t in_len = strlen(data);
    return colyseus_base64_encode_binary((const uint8_t*)data, in_len);
}

char* colyseus_base64_encode_binary(const uint8_t* data, size_t in_len) {
    if (!data || in_len == 0) return NULL;

    size_t out_len = 4 * ((in_len + 2) / 3);

    char* result = malloc(out_len + 1);
    if (!result) return NULL;

    size_t i = 0, j = 0;
    unsigned char char_array_3[3];
    unsigned char char_array_4[4];

    size_t idx = 0;
    while (in_len--) {
        char_array_3[i++] = data[idx++];
        if (i == 3) {
            char_array_4[0] = (char_array_3[0] & 0xfc) >> 2;
            char_array_4[1] = ((char_array_3[0] & 0x03) << 4) + ((char_array_3[1] & 0xf0) >> 4);
            char_array_4[2] = ((char_array_3[1] & 0x0f) << 2) + ((char_array_3[2] & 0xc0) >> 6);
            char_array_4[3] = char_array_3[2] & 0x3f;

            for (i = 0; i < 4; i++)
                result[j++] = base64_chars[char_array_4[i]];
            i = 0;
        }
    }

    if (i) {
        for (size_t k = i; k < 3; k++)
            char_array_3[k] = '\0';

        char_array_4[0] = (char_array_3[0] & 0xfc) >> 2;
        char_array_4[1] = ((char_array_3[0] & 0x03) << 4) + ((char_array_3[1] & 0xf0) >> 4);
        char_array_4[2] = ((char_array_3[1] & 0x0f) << 2) + ((char_array_3[2] & 0xc0) >> 6);

        for (size_t k = 0; k < i + 1; k++)
            result[j++] = base64_chars[char_array_4[k]];

        while (i++ < 3)
            result[j++] = '=';
    }

    result[j] = '\0';
    return result;
}

char* colyseus_base64_decode(const char* data) {
    /* TODO: Implement if needed */
    (void)data;
    return NULL;
}

/* WebSocket accept key generation */
char* colyseus_create_accept_key(const char* client_key) {
    const char* magic_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    sds combined = sdsempty();
    combined = sdscat(combined, client_key);
    combined = sdscat(combined, magic_guid);

    /* Calculate SHA1 */
    uint8_t digest[20];
    sha1_hash((const uint8_t*)combined, sdslen(combined), digest);

    sdsfree(combined);

    /* Base64 encode the hash - use binary version */
    char* result = colyseus_base64_encode_binary(digest, 20);

    return result;
}
