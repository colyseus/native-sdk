#include "colyseus/room.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* Internal helper functions */
static void room_on_transport_open(void* userdata);
static void room_on_transport_message(const uint8_t* data, size_t length, void* userdata);
static void room_on_transport_close(int code, const char* reason, void* userdata);
static void room_on_transport_error(const char* error, void* userdata);
static void room_dispatch_message(colyseus_room_t* room, const char* type, const uint8_t* message, size_t length);
static char* room_get_message_key_str(const char* type);
static char* room_get_message_key_int(int type);

/* Create room */
colyseus_room_t* colyseus_room_create(const char* name, colyseus_transport_factory_fn transport_factory) {
    colyseus_room_t* room = malloc(sizeof(colyseus_room_t));
    if (!room) return NULL;

    memset(room, 0, sizeof(colyseus_room_t));

    room->name = strdup(name);
    room->has_joined = false;
    room->transport_factory = transport_factory;
    room->transport = NULL;
    room->message_handlers = NULL;

    return room;
}

void colyseus_room_free(colyseus_room_t* room) {
    if (!room) return;

    /* Cleanup transport */
    if (room->transport) {
        colyseus_transport_destroy(room->transport);
    }

    /* Free strings */
    free(room->name);
    free(room->room_id);
    free(room->session_id);
    free(room->reconnection_token);

    /* Free message handlers */
    colyseus_message_handler_t *handler, *tmp;
    HASH_ITER(hh, room->message_handlers, handler, tmp) {
        HASH_DEL(room->message_handlers, handler);
        free(handler->key);
        free(handler);
    }

    free(room);
}

/* Connection */
void colyseus_room_connect(
    colyseus_room_t* room,
    const char* endpoint,
    void (*on_success)(void* userdata),
    void (*on_error)(int code, const char* message, void* userdata),
    void* userdata
) {
    /* Setup transport events */
    colyseus_transport_events_t events = {
        .on_open = room_on_transport_open,
        .on_message = room_on_transport_message,
        .on_close = room_on_transport_close,
        .on_error = room_on_transport_error,
        .userdata = room
    };

    /* Create transport */
    room->transport = room->transport_factory(&events);
    if (!room->transport) {
        if (on_error) {
            on_error(-1, "Failed to create transport", userdata);
        }
        return;
    }

    /* Store connection callbacks temporarily */
    /* TODO: Store these properly if needed for async response */

    /* Connect */
    colyseus_transport_connect(room->transport, endpoint);
}

void colyseus_room_leave(colyseus_room_t* room, bool consented) {
    if (!room || !room->transport) {
        if (room && room->on_leave) {
            room->on_leave(COLYSEUS_CLOSE_CONSENTED, "Already left", room->on_leave_userdata);
        }
        return;
    }

    if (colyseus_transport_is_open(room->transport)) {
        if (consented) {
            uint8_t leave_msg[] = { COLYSEUS_PROTOCOL_LEAVE_ROOM };
            colyseus_transport_send(room->transport, leave_msg, 1);
        } else {
            colyseus_transport_close(room->transport, 1000, "Leave");
        }
    } else {
        if (room->on_leave) {
            room->on_leave(COLYSEUS_CLOSE_CONSENTED, "Already left", room->on_leave_userdata);
        }
    }
}

/* Getters/Setters */
const char* colyseus_room_get_id(const colyseus_room_t* room) {
    return room ? room->room_id : NULL;
}

void colyseus_room_set_id(colyseus_room_t* room, const char* room_id) {
    if (!room) return;
    free(room->room_id);
    room->room_id = room_id ? strdup(room_id) : NULL;
}

const char* colyseus_room_get_session_id(const colyseus_room_t* room) {
    return room ? room->session_id : NULL;
}

void colyseus_room_set_session_id(colyseus_room_t* room, const char* session_id) {
    if (!room) return;
    free(room->session_id);
    room->session_id = session_id ? strdup(session_id) : NULL;
}

const char* colyseus_room_get_name(const colyseus_room_t* room) {
    return room ? room->name : NULL;
}

bool colyseus_room_has_joined(const colyseus_room_t* room) {
    return room ? room->has_joined : false;
}

/* Event handlers */
void colyseus_room_on_join(colyseus_room_t* room, colyseus_room_on_join_fn callback, void* userdata) {
    if (!room) return;
    room->on_join = callback;
    room->on_join_userdata = userdata;
}

void colyseus_room_on_state_change(colyseus_room_t* room, colyseus_room_on_state_change_fn callback, void* userdata) {
    if (!room) return;
    room->on_state_change = callback;
    room->on_state_change_userdata = userdata;
}

void colyseus_room_on_error(colyseus_room_t* room, colyseus_room_on_error_fn callback, void* userdata) {
    if (!room) return;
    room->on_error = callback;
    room->on_error_userdata = userdata;
}

void colyseus_room_on_leave(colyseus_room_t* room, colyseus_room_on_leave_fn callback, void* userdata) {
    if (!room) return;
    room->on_leave = callback;
    room->on_leave_userdata = userdata;
}

/* Message handlers */
void colyseus_room_on_message_str(colyseus_room_t* room, const char* type, colyseus_room_on_message_fn callback, void* userdata) {
    if (!room) return;

    char* key = room_get_message_key_str(type);

    /* Find or create handler */
    colyseus_message_handler_t* handler = NULL;
    HASH_FIND_STR(room->message_handlers, key, handler);

    if (handler) {
        handler->callback = callback;
        handler->userdata = userdata;
        free(key);
    } else {
        handler = malloc(sizeof(colyseus_message_handler_t));
        handler->key = key;
        handler->callback = callback;
        handler->userdata = userdata;
        HASH_ADD_KEYPTR(hh, room->message_handlers, handler->key, strlen(handler->key), handler);
    }
}

void colyseus_room_on_message_int(colyseus_room_t* room, int type, colyseus_room_on_message_fn callback, void* userdata) {
    if (!room) return;

    char* key = room_get_message_key_int(type);

    colyseus_message_handler_t* handler = NULL;
    HASH_FIND_STR(room->message_handlers, key, handler);

    if (handler) {
        handler->callback = callback;
        handler->userdata = userdata;
        free(key);
    } else {
        handler = malloc(sizeof(colyseus_message_handler_t));
        handler->key = key;
        handler->callback = callback;
        handler->userdata = userdata;
        HASH_ADD_KEYPTR(hh, room->message_handlers, handler->key, strlen(handler->key), handler);
    }
}

void colyseus_room_on_message_any(colyseus_room_t* room, colyseus_room_on_message_fn callback, void* userdata) {
    if (!room) return;
    room->on_message_any = callback;
    room->on_message_any_userdata = userdata;
}

/* Send messages */
void colyseus_room_send_str(colyseus_room_t* room, const char* type, const uint8_t* message, size_t length) {
    if (!room || !room->transport || !colyseus_transport_is_open(room->transport)) {
        return;
    }

    /* Build message: [PROTOCOL][type string][message] */
    size_t type_len = strlen(type);
    size_t total_len = 1 + type_len + length;
    uint8_t* data = malloc(total_len);

    data[0] = COLYSEUS_PROTOCOL_ROOM_DATA;
    memcpy(data + 1, type, type_len);
    if (message && length > 0) {
        memcpy(data + 1 + type_len, message, length);
    }

    colyseus_transport_send(room->transport, data, total_len);
    free(data);
}

void colyseus_room_send_int(colyseus_room_t* room, int type, const uint8_t* message, size_t length) {
    if (!room || !room->transport || !colyseus_transport_is_open(room->transport)) {
        return;
    }

    /* Build message: [PROTOCOL][type as byte][message] */
    size_t total_len = 2 + length;
    uint8_t* data = malloc(total_len);

    data[0] = COLYSEUS_PROTOCOL_ROOM_DATA;
    data[1] = (uint8_t)type;
    if (message && length > 0) {
        memcpy(data + 2, message, length);
    }

    colyseus_transport_send(room->transport, data, total_len);
    free(data);
}

/* Transport event handlers */
static void room_on_transport_open(void* userdata) {
    /* Connection established, wait for JOIN_ROOM */
}

static void room_on_transport_message(const uint8_t* data, size_t length, void* userdata) {
    colyseus_room_t* room = (colyseus_room_t*)userdata;

    if (length == 0) return;

    colyseus_protocol_t code = (colyseus_protocol_t)data[0];
    size_t offset = 1;

    switch (code) {
        case COLYSEUS_PROTOCOL_JOIN_ROOM: {
            /* TODO: Decode reconnection token and serializer ID */
            room->has_joined = true;

            if (room->on_join) {
                room->on_join(room->on_join_userdata);
            }

            /* Acknowledge JOIN_ROOM */
            uint8_t ack[] = { COLYSEUS_PROTOCOL_JOIN_ROOM };
            colyseus_transport_send(room->transport, ack, 1);
            break;
        }

        case COLYSEUS_PROTOCOL_ERROR: {
            /* TODO: Decode error code and message */
            if (room->on_error) {
                room->on_error(-1, "Unknown error", room->on_error_userdata);
            }
            break;
        }

        case COLYSEUS_PROTOCOL_LEAVE_ROOM: {
            colyseus_room_leave(room, false);
            break;
        }

        case COLYSEUS_PROTOCOL_ROOM_STATE: {
            /* TODO: Handle full state */
            if (room->on_state_change) {
                room->on_state_change(room->on_state_change_userdata);
            }
            break;
        }

        case COLYSEUS_PROTOCOL_ROOM_STATE_PATCH: {
            /* TODO: Handle state patch */
            if (room->on_state_change) {
                room->on_state_change(room->on_state_change_userdata);
            }
            break;
        }

        case COLYSEUS_PROTOCOL_ROOM_DATA:
        case COLYSEUS_PROTOCOL_ROOM_DATA_BYTES: {
            /* TODO: Decode type and message properly */
            const char* type = "unknown";
            room_dispatch_message(room, type, data + offset, length - offset);
            break;
        }

        default:
            fprintf(stderr, "Unknown protocol message: %d\n", code);
            break;
    }
}

static void room_on_transport_close(int code, const char* reason, void* userdata) {
    colyseus_room_t* room = (colyseus_room_t*)userdata;

    if (!room->has_joined) {
        fprintf(stderr, "Room connection closed unexpectedly: %s\n", reason);
        if (room->on_error) {
            room->on_error(code, reason, room->on_error_userdata);
        }
    } else {
        if (room->on_leave) {
            room->on_leave(code, reason, room->on_leave_userdata);
        }
    }
}

static void room_on_transport_error(const char* error, void* userdata) {
    colyseus_room_t* room = (colyseus_room_t*)userdata;

    fprintf(stderr, "Room transport error: %s\n", error);
    if (room->on_error) {
        room->on_error(-1, error, room->on_error_userdata);
    }
}

/* Helper functions */
static void room_dispatch_message(colyseus_room_t* room, const char* type, const uint8_t* message, size_t length) {
    char* key = room_get_message_key_str(type);

    colyseus_message_handler_t* handler = NULL;
    HASH_FIND_STR(room->message_handlers, key, handler);

    if (handler && handler->callback) {
        handler->callback(message, length, handler->userdata);
    } else if (room->on_message_any) {
        room->on_message_any(message, length, room->on_message_any_userdata);
    } else {
        fprintf(stderr, "No handler for message type: %s\n", type);
    }

    free(key);
}

static char* room_get_message_key_str(const char* type) {
    return strdup(type);
}

static char* room_get_message_key_int(int type) {
    char buf[32];
    snprintf(buf, sizeof(buf), "i%d", type);
    return strdup(buf);
}