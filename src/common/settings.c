#include "colyseus/settings.h"
#include "sds.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

colyseus_settings_t* colyseus_settings_create(void) {
    colyseus_settings_t* settings = malloc(sizeof(colyseus_settings_t));
    if (!settings) return NULL;

    colyseus_settings_init(settings);
    return settings;
}

void colyseus_settings_init(colyseus_settings_t* settings) {
    settings->server_address = strdup("localhost");
    settings->server_port = strdup("2567");
    settings->use_secure_protocol = false;
    settings->headers = NULL;  /* Empty hash map */
}

void colyseus_settings_free(colyseus_settings_t* settings) {
    if (!settings) return;

    free(settings->server_address);
    free(settings->server_port);

    /* Free headers hash map */
    colyseus_header_t *current, *tmp;
    HASH_ITER(hh, settings->headers, current, tmp) {
        HASH_DEL(settings->headers, current);
        free(current->key);
        free(current->value);
        free(current);
    }

    free(settings);
}

void colyseus_settings_set_address(colyseus_settings_t* settings, const char* address) {
    free(settings->server_address);
    settings->server_address = strdup(address);
}

void colyseus_settings_set_port(colyseus_settings_t* settings, const char* port) {
    free(settings->server_port);
    settings->server_port = strdup(port);
}

void colyseus_settings_set_secure(colyseus_settings_t* settings, bool secure) {
    settings->use_secure_protocol = secure;
}

void colyseus_settings_add_header(colyseus_settings_t* settings, const char* key, const char* value) {
    colyseus_header_t* header = NULL;
    HASH_FIND_STR(settings->headers, key, header);

    if (header) {
        /* Update existing */
        free(header->value);
        header->value = strdup(value);
    } else {
        /* Add new */
        header = malloc(sizeof(colyseus_header_t));
        header->key = strdup(key);
        header->value = strdup(value);
        HASH_ADD_KEYPTR(hh, settings->headers, header->key, strlen(header->key), header);
    }
}

void colyseus_settings_remove_header(colyseus_settings_t* settings, const char* key) {
    colyseus_header_t* header = NULL;
    HASH_FIND_STR(settings->headers, key, header);

    if (header) {
        HASH_DEL(settings->headers, header);
        free(header->key);
        free(header->value);
        free(header);
    }
}

const char* colyseus_settings_get_header(colyseus_settings_t* settings, const char* key) {
    colyseus_header_t* header = NULL;
    HASH_FIND_STR(settings->headers, key, header);
    return header ? header->value : NULL;
}

char* colyseus_settings_get_websocket_endpoint(const colyseus_settings_t* settings) {
    sds endpoint = sdsempty();

    const char* scheme = settings->use_secure_protocol ? "wss" : "ws";
    endpoint = sdscatprintf(endpoint, "%s://%s", scheme, settings->server_address);

    int port = colyseus_settings_get_port(settings);
    if (port != -1) {
        endpoint = sdscatprintf(endpoint, ":%d", port);
    }

    /* Convert sds to regular char* (caller must free) */
    char* result = strdup(endpoint);
    sdsfree(endpoint);
    return result;
}

char* colyseus_settings_get_webrequest_endpoint(const colyseus_settings_t* settings) {
    sds endpoint = sdsempty();

    const char* scheme = settings->use_secure_protocol ? "https" : "http";
    endpoint = sdscatprintf(endpoint, "%s://%s", scheme, settings->server_address);

    int port = colyseus_settings_get_port(settings);
    if (port != -1) {
        endpoint = sdscatprintf(endpoint, ":%d", port);
    }

    char* result = strdup(endpoint);
    sdsfree(endpoint);
    return result;
}

int colyseus_settings_get_port(const colyseus_settings_t* settings) {
    if (!settings->server_port ||
        strcmp(settings->server_port, "80") == 0 ||
        strcmp(settings->server_port, "443") == 0) {
        return -1;
    }

    return atoi(settings->server_port);
}