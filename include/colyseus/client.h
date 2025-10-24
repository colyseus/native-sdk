#ifndef COLYSEUS_CLIENT_H
#define COLYSEUS_CLIENT_H

#include "colyseus/settings.h"
#include "colyseus/transport.h"
#include "colyseus/protocol.h"
#include "colyseus/http.h"
#include "colyseus/room.h"
#include <stdbool.h>

#include "auth/auth.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Client structure */
typedef struct {
    colyseus_settings_t* settings;
    colyseus_transport_factory_fn transport_factory;
    colyseus_http_t* http;
    colyseus_auth_t* auth;
} colyseus_client_t;

/* Matchmaking callbacks */
typedef void (*colyseus_client_room_callback_t)(colyseus_room_t* room, void* userdata);
typedef void (*colyseus_client_error_callback_t)(int code, const char* message, void* userdata);

/* Create and destroy client */
colyseus_client_t* colyseus_client_create(colyseus_settings_t* settings);
colyseus_client_t* colyseus_client_create_with_transport(
    colyseus_settings_t* settings,
    colyseus_transport_factory_fn transport_factory
);
void colyseus_client_free(colyseus_client_t* client);

/* Get HTTP client */
colyseus_http_t* colyseus_client_get_http(colyseus_client_t* client);

/* Get Auth client */
colyseus_auth_t* colyseus_client_get_auth(colyseus_client_t* client);

/* Matchmaking methods */
void colyseus_client_join_or_create(
    colyseus_client_t* client,
    const char* room_name,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
);

void colyseus_client_create_room(
    colyseus_client_t* client,
    const char* room_name,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
);

void colyseus_client_join(
    colyseus_client_t* client,
    const char* room_name,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
);

void colyseus_client_join_by_id(
    colyseus_client_t* client,
    const char* room_id,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
);

void colyseus_client_reconnect(
    colyseus_client_t* client,
    const char* reconnection_token,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_CLIENT_H */
