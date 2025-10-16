#ifndef COLYSEUS_ROOM_H
#define COLYSEUS_ROOM_H

#include "colyseus/transport.h"
#include "colyseus/protocol.h"
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "uthash.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Forward declaration */
typedef struct colyseus_room colyseus_room_t;

/* Room event callbacks */
typedef void (*colyseus_room_on_join_fn)(void* userdata);
typedef void (*colyseus_room_on_state_change_fn)(void* userdata);
typedef void (*colyseus_room_on_message_fn)(const uint8_t* data, size_t length, void* userdata);
typedef void (*colyseus_room_on_error_fn)(int code, const char* message, void* userdata);
typedef void (*colyseus_room_on_leave_fn)(int code, const char* reason, void* userdata);

/* Message handler entry for hash map */
typedef struct {
    char* key;  /* Message type as string (or "i123" for numeric) */
    colyseus_room_on_message_fn callback;
    void* userdata;
    UT_hash_handle hh;
} colyseus_message_handler_t;

/* Room structure */
struct colyseus_room {
    char* name;
    char* room_id;
    char* session_id;
    char* reconnection_token;
    bool has_joined;

    colyseus_transport_t* transport;
    colyseus_transport_factory_fn transport_factory;

    /* Event callbacks */
    colyseus_room_on_join_fn on_join;
    void* on_join_userdata;

    colyseus_room_on_state_change_fn on_state_change;
    void* on_state_change_userdata;

    colyseus_room_on_error_fn on_error;
    void* on_error_userdata;

    colyseus_room_on_leave_fn on_leave;
    void* on_leave_userdata;

    /* Message handlers hash map */
    colyseus_message_handler_t* message_handlers;

    /* Wildcard message handler (for all messages) */
    colyseus_room_on_message_fn on_message_any;
    void* on_message_any_userdata;
};

/* Create and destroy room */
colyseus_room_t* colyseus_room_create(const char* name, colyseus_transport_factory_fn transport_factory);
void colyseus_room_free(colyseus_room_t* room);

/* Connection */
void colyseus_room_connect(
    colyseus_room_t* room,
    const char* endpoint,
    void (*on_success)(void* userdata),
    void (*on_error)(int code, const char* message, void* userdata),
    void* userdata
);

void colyseus_room_leave(colyseus_room_t* room, bool consented);

/* Getters/Setters */
const char* colyseus_room_get_id(const colyseus_room_t* room);
void colyseus_room_set_id(colyseus_room_t* room, const char* room_id);

const char* colyseus_room_get_session_id(const colyseus_room_t* room);
void colyseus_room_set_session_id(colyseus_room_t* room, const char* session_id);

const char* colyseus_room_get_name(const colyseus_room_t* room);
bool colyseus_room_has_joined(const colyseus_room_t* room);

/* Event handlers */
void colyseus_room_on_join(colyseus_room_t* room, colyseus_room_on_join_fn callback, void* userdata);
void colyseus_room_on_state_change(colyseus_room_t* room, colyseus_room_on_state_change_fn callback, void* userdata);
void colyseus_room_on_error(colyseus_room_t* room, colyseus_room_on_error_fn callback, void* userdata);
void colyseus_room_on_leave(colyseus_room_t* room, colyseus_room_on_leave_fn callback, void* userdata);

/* Message handlers */
void colyseus_room_on_message_str(colyseus_room_t* room, const char* type, colyseus_room_on_message_fn callback, void* userdata);
void colyseus_room_on_message_int(colyseus_room_t* room, int type, colyseus_room_on_message_fn callback, void* userdata);
void colyseus_room_on_message_any(colyseus_room_t* room, colyseus_room_on_message_fn callback, void* userdata);

/* Send messages */
void colyseus_room_send_str(colyseus_room_t* room, const char* type, const uint8_t* message, size_t length);
void colyseus_room_send_int(colyseus_room_t* room, int type, const uint8_t* message, size_t length);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_ROOM_H */
