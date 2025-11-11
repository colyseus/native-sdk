#include "colyseus/utils/strUtil.h"
#include "colyseus/utils/sha1_c.h"
#include "sds.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <curl/curl.h>

/* Parse URL using regex */
colyseus_url_parts_t* colyseus_parse_url(const char* url) {
    CURLU* h = curl_url();
    if (!h) return NULL;

    CURLUcode rc = curl_url_set(h, CURLUPART_URL, url, 0);
    if (rc != CURLUE_OK) {
        curl_url_cleanup(h);
        return NULL;
    }

    colyseus_url_parts_t* parts = malloc(sizeof(colyseus_url_parts_t));
    if (!parts) {
        curl_url_cleanup(h);
        return NULL;
    }
    memset(parts, 0, sizeof(*parts));

    char* scheme = NULL;
    char* host = NULL;
    char* port_str = NULL;
    char* path = NULL;
    char* query = NULL;

    /* Extract scheme */
    if (curl_url_get(h, CURLUPART_SCHEME, &scheme, 0) == CURLUE_OK)
        parts->scheme = strdup(scheme);

    /* Extract host */
    if (curl_url_get(h, CURLUPART_HOST, &host, 0) == CURLUE_OK)
        parts->host = strdup(host);

    /* Extract port */
    if (curl_url_get(h, CURLUPART_PORT, &port_str, 0) == CURLUE_OK && port_str && *port_str) {
        uint16_t port_num = (uint16_t)strtoul(port_str, NULL, 10);
        if (port_num > 0) {
            parts->port = malloc(sizeof(uint16_t));
            *parts->port = port_num;
        }
    }

    /* Extract path and query */
    if (curl_url_get(h, CURLUPART_PATH, &path, 0) == CURLUE_OK) {
        if (curl_url_get(h, CURLUPART_QUERY, &query, 0) == CURLUE_OK && query && *query) {
            size_t total_len = strlen(path) + 1 + strlen(query) + 1;
            parts->path_and_args = malloc(total_len);
            snprintf(parts->path_and_args, total_len, "%s?%s", path, query);
        } else {
            parts->path_and_args = strdup(path);
        }
    }

    /* Store original URL */
    parts->url = strdup(url);

    curl_free(scheme);
    curl_free(host);
    curl_free(port_str);
    curl_free(path);
    curl_free(query);
    curl_url_cleanup(h);

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
