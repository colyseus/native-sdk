#include "colyseus/utils/StrUtil.h"
#include "colyseus/utils/sha1.h"
#include "sds.h"
#include <stdlib.h>
#include <string.h>
#include <regex.h>
#include <stdio.h>

/* Parse URL using regex */
colyseus_url_parts_t* colyseus_parse_url(const char* url) {
    /* Regex pattern: (scheme)://(host)(:port)?/(path) */
    regex_t regex;
    const char* pattern = "^([^:]+)://([^:/]+)(:([0-9]+))?/(.*)$";

    if (regcomp(&regex, pattern, REG_EXTENDED) != 0) {
        return NULL;
    }

    regmatch_t matches[6];
    if (regexec(&regex, url, 6, matches, 0) != 0) {
        regfree(&regex);
        return NULL;
    }

    colyseus_url_parts_t* parts = malloc(sizeof(colyseus_url_parts_t));
    if (!parts) {
        regfree(&regex);
        return NULL;
    }

    memset(parts, 0, sizeof(colyseus_url_parts_t));

    /* Extract scheme */
    int len = matches[1].rm_eo - matches[1].rm_so;
    parts->scheme = strndup(url + matches[1].rm_so, len);

    /* Extract host */
    len = matches[2].rm_eo - matches[2].rm_so;
    parts->host = strndup(url + matches[2].rm_so, len);

    /* Extract port (if present) */
    if (matches[4].rm_so != -1) {
        len = matches[4].rm_eo - matches[4].rm_so;
        char port_str[16];
        strncpy(port_str, url + matches[4].rm_so, len);
        port_str[len] = '\0';

        uint16_t port_num = (uint16_t)strtoul(port_str, NULL, 10);
        if (port_num > 0) {
            parts->port = malloc(sizeof(uint16_t));
            *parts->port = port_num;
        }
    }

    /* Extract path and args */
    len = matches[5].rm_eo - matches[5].rm_so;
    parts->path_and_args = strndup(url + matches[5].rm_so, len);

    /* Store original URL */
    parts->url = strdup(url);

    regfree(&regex);
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
    size_t out_len = 4 * ((in_len + 2) / 3);

    char* result = malloc(out_len + 1);
    if (!result) return NULL;

    const unsigned char* bytes = (const unsigned char*)data;
    size_t i = 0, j = 0;
    unsigned char char_array_3[3];
    unsigned char char_array_4[4];

    while (in_len--) {
        char_array_3[i++] = *(bytes++);
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
    /* Concatenate with magic GUID */
    const char* magic_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    sds combined = sdsempty();
    combined = sdscat(combined, client_key);
    combined = sdscat(combined, magic_guid);

    /* Calculate SHA1 */
    SHA1 sha;
    SHA1_Init(&sha);
    SHA1_Update(&sha, combined, sdslen(combined));

    std::array<char, 20> digest;
    SHA1_Final(&sha, digest);

    sdsfree(combined);

    /* Base64 encode the hash */
    char hash_str[21];
    memcpy(hash_str, digest.data(), 20);
    hash_str[20] = '\0';

    char* result = colyseus_base64_encode(hash_str);

    return result;
}