#include "colyseus/client.h"
#include "sds.h"
#include "cJSON.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* Internal context for async operations */
typedef struct {
    colyseus_client_t* client;
    colyseus_client_room_callback_t on_success;
    colyseus_client_error_callback_t on_error;
    void* userdata;
} colyseus_matchmake_context_t;

/* Internal functions */
static void client_create_matchmake_request(
    colyseus_client_t* client,
    const char* method,
    const char* room_name,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
);

static void client_on_matchmake_success(const colyseus_http_response_t* response, void* userdata);
static void client_on_matchmake_error(const colyseus_http_error_t* error, void* userdata);

static void client_consume_seat_reservation(
    colyseus_client_t* client,
    const colyseus_seat_reservation_t* reservation,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
);

static char* client_build_room_endpoint(
    colyseus_client_t* client,
    const colyseus_room_available_t* room_data,
    const char* session_id,
    const char* reconnection_token
);

/* Create client */
colyseus_client_t* colyseus_client_create(colyseus_settings_t* settings) {
    return colyseus_client_create_with_transport(settings, colyseus_websocket_transport_create);
}

colyseus_client_t* colyseus_client_create_with_transport(
    colyseus_settings_t* settings,
    colyseus_transport_factory_fn transport_factory
) {
    colyseus_client_t* client = malloc(sizeof(colyseus_client_t));
    if (!client) return NULL;

    client->settings = settings;
    client->transport_factory = transport_factory;
    client->http = colyseus_http_create(settings);
    client->auth = colyseus_auth_create(client->http);

    return client;
}

void colyseus_client_free(colyseus_client_t* client) {
    if (!client) return;

    colyseus_http_free(client->http);
    colyseus_auth_free(client->auth);
    free(client);
}

colyseus_http_t* colyseus_client_get_http(colyseus_client_t* client) {
    return client ? client->http : NULL;
}

colyseus_auth_t* colyseus_client_get_auth(colyseus_client_t* client) {
    return client ? client->auth : NULL;
}

/* Matchmaking methods */
void colyseus_client_join_or_create(
    colyseus_client_t* client,
    const char* room_name,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
) {
    client_create_matchmake_request(client, "joinOrCreate", room_name, options_json, on_success, on_error, userdata);
}

void colyseus_client_create_room(
    colyseus_client_t* client,
    const char* room_name,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
) {
    client_create_matchmake_request(client, "create", room_name, options_json, on_success, on_error, userdata);
}

void colyseus_client_join(
    colyseus_client_t* client,
    const char* room_name,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
) {
    client_create_matchmake_request(client, "join", room_name, options_json, on_success, on_error, userdata);
}

void colyseus_client_join_by_id(
    colyseus_client_t* client,
    const char* room_id,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
) {
    client_create_matchmake_request(client, "joinById", room_id, options_json, on_success, on_error, userdata);
}

void colyseus_client_reconnect(
    colyseus_client_t* client,
    const char* reconnection_token,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
) {
    /* Parse reconnection token: "roomId:token" */
    char* token_copy = strdup(reconnection_token);
    char* colon = strchr(token_copy, ':');

    if (!colon) {
        if (on_error) {
            on_error(-1, "Invalid reconnection token format", userdata);
        }
        free(token_copy);
        return;
    }

    *colon = '\0';
    const char* room_id = token_copy;
    const char* token = colon + 1;

    /* Build options JSON with reconnection token */
    cJSON* json = cJSON_CreateObject();
    cJSON_AddStringToObject(json, "reconnectionToken", token);
    char* options_json = cJSON_PrintUnformatted(json);
    cJSON_Delete(json);

    client_create_matchmake_request(client, "reconnect", room_id, options_json, on_success, on_error, userdata);

    free(options_json);
    free(token_copy);
}

/* Internal matchmaking implementation */
static void client_create_matchmake_request(
    colyseus_client_t* client,
    const char* method,
    const char* room_name,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
) {
    /* Build path */
    sds path = sdsempty();
    path = sdscatprintf(path, "matchmake/%s/%s", method, room_name);

    /* Create context for callbacks */
    colyseus_matchmake_context_t* ctx = malloc(sizeof(colyseus_matchmake_context_t));
    ctx->client = client;
    ctx->on_success = on_success;
    ctx->on_error = on_error;
    ctx->userdata = userdata;

    /* Make HTTP request */
    colyseus_http_post(
        client->http,
        path,
        options_json ? options_json : "{}",
        client_on_matchmake_success,
        client_on_matchmake_error,
        ctx
    );

    sdsfree(path);
}

static void client_on_matchmake_success(const colyseus_http_response_t* response, void* userdata) {
    colyseus_matchmake_context_t* ctx = (colyseus_matchmake_context_t*)userdata;

    /* Parse JSON response */
    cJSON* json = cJSON_Parse(response->body);
    if (!json) {
        if (ctx->on_error) {
            ctx->on_error(-1, "Failed to parse matchmaking response", ctx->userdata);
        }
        free(ctx);
        return;
    }

    /* Parse seat reservation */
    colyseus_seat_reservation_t reservation = {0};

    cJSON* session_id = cJSON_GetObjectItem(json, "sessionId");
    if (session_id && cJSON_IsString(session_id)) {
        reservation.session_id = strdup(session_id->valuestring);
    }

    cJSON* reconnection_token = cJSON_GetObjectItem(json, "reconnectionToken");
    if (reconnection_token && cJSON_IsString(reconnection_token)) {
        reservation.reconnection_token = strdup(reconnection_token->valuestring);
    }

    cJSON* dev_mode = cJSON_GetObjectItem(json, "devMode");
    if (dev_mode && cJSON_IsBool(dev_mode)) {
        reservation.dev_mode = cJSON_IsTrue(dev_mode);
    }

    cJSON* protocol = cJSON_GetObjectItem(json, "protocol");
    if (protocol && cJSON_IsString(protocol)) {
        reservation.protocol = strdup(protocol->valuestring);
    }

    /* Parse room data */
    cJSON* room_id = cJSON_GetObjectItem(json, "roomId");
    if (room_id && cJSON_IsString(room_id)) {
        reservation.room.room_id = strdup(room_id->valuestring);
    }

    cJSON* name = cJSON_GetObjectItem(json, "name");
    if (name && cJSON_IsString(name)) {
        reservation.room.name = strdup(name->valuestring);
    }

    cJSON* process_id = cJSON_GetObjectItem(json, "processId");
    if (process_id && cJSON_IsString(process_id)) {
        reservation.room.process_id = strdup(process_id->valuestring);
    }

    cJSON* public_address = cJSON_GetObjectItem(json, "publicAddress");
    if (public_address && cJSON_IsString(public_address)) {
        reservation.room.public_address = strdup(public_address->valuestring);
    }

    cJSON_Delete(json);

    /* Consume seat reservation */
    client_consume_seat_reservation(ctx->client, &reservation, ctx->on_success, ctx->on_error, ctx->userdata);

    /* Cleanup */
    colyseus_seat_reservation_free(&reservation);
    free(ctx);
}

static void client_on_matchmake_error(const colyseus_http_error_t* error, void* userdata) {
    colyseus_matchmake_context_t* ctx = (colyseus_matchmake_context_t*)userdata;

    if (ctx->on_error) {
        ctx->on_error(error->code, error->message, ctx->userdata);
    }

    free(ctx);
}

static void client_consume_seat_reservation(
    colyseus_client_t* client,
    const colyseus_seat_reservation_t* reservation,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
) {
    /* Create room */
    colyseus_room_t* room = colyseus_room_create(reservation->room.name, client->transport_factory);
    if (!room) {
        if (on_error) {
            on_error(-1, "Failed to create room", userdata);
        }
        return;
    }

    colyseus_room_set_id(room, reservation->room.room_id);
    colyseus_room_set_session_id(room, reservation->session_id);

    /* Build WebSocket endpoint */
    char* endpoint = client_build_room_endpoint(
        client,
        &reservation->room,
        reservation->session_id,
        reservation->reconnection_token
    );

    /* Connect room */
    colyseus_room_connect(
        room,
        endpoint,
        NULL,  /* on_success handled via room.on_join */
        on_error,
        userdata
    );

    /* Return room to user */
    if (on_success) {
        on_success(room, userdata);
    }

    free(endpoint);
}

static char* client_build_room_endpoint(
    colyseus_client_t* client,
    const colyseus_room_available_t* room_data,
    const char* session_id,
    const char* reconnection_token
) {
    char* base = colyseus_settings_get_websocket_endpoint(client->settings);

    sds endpoint = sdsempty();
    endpoint = sdscatprintf(endpoint, "%s/%s/%s", base, room_data->process_id, room_data->room_id);

    /* Add query parameters */
    endpoint = sdscatprintf(endpoint, "?sessionId=%s", session_id);

    if (reconnection_token && strlen(reconnection_token) > 0) {
        endpoint = sdscatprintf(endpoint, "&reconnectionToken=%s", reconnection_token);
    }

    char* result = strdup(endpoint);
    sdsfree(endpoint);
    free(base);

    return result;
}

/* Helper to free seat reservation */
void colyseus_seat_reservation_free(colyseus_seat_reservation_t* reservation) {
    if (!reservation) return;

    free(reservation->session_id);
    free(reservation->reconnection_token);
    free(reservation->protocol);
    colyseus_room_available_free(&reservation->room);
}

void colyseus_room_available_free(colyseus_room_available_t* room) {
    if (!room) return;

    free(room->room_id);
    free(room->name);
    free(room->process_id);
    free(room->public_address);
}
