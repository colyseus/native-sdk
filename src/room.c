#include "colyseus/room.h"
#include "colyseus/schema.h"
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

/* Decode helpers using schema decode functions */
static float decode_number(const uint8_t* bytes, size_t* offset);
static char* decode_string(const uint8_t* bytes, size_t* offset);

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
    room->serializer = NULL;
    room->serializer_id = NULL;

    return room;
}

void colyseus_room_free(colyseus_room_t* room) {
    if (!room) return;

    /* Cleanup transport */
    if (room->transport) {
        colyseus_transport_destroy(room->transport);
    }

    /* Cleanup serializer */
    if (room->serializer) {
        colyseus_schema_serializer_free(room->serializer);
    }

    /* Free strings */
    free(room->name);
    free(room->room_id);
    free(room->session_id);
    free(room->reconnection_token);
    free(room->serializer_id);

    /* Free message handlers */
    colyseus_message_handler_t *handler, *tmp;
    HASH_ITER(hh, room->message_handlers, handler, tmp) {
        HASH_DEL(room->message_handlers, handler);
        free(handler->key);
        free(handler);
    }

    free(room);
}

/* Set the state schema vtable - must be called before connect */
void colyseus_room_set_state_type(colyseus_room_t* room, const colyseus_schema_vtable_t* state_vtable) {
    if (!room) return;
    room->state_vtable = state_vtable;
}

/* Get current state */
void* colyseus_room_get_state(colyseus_room_t* room) {
    if (!room || !room->serializer) return NULL;
    return colyseus_schema_serializer_get_state(room->serializer);
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

    /* Store connection callbacks */
    room->connect_on_success = on_success;
    room->connect_on_error = on_error;
    room->connect_userdata = userdata;

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

const char* colyseus_room_get_reconnection_token(const colyseus_room_t* room) {
    return room ? room->reconnection_token : NULL;
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

void colyseus_room_on_message_any_with_type(colyseus_room_t* room, colyseus_room_on_message_with_type_fn callback, void* userdata) {
    if (!room) return;
    room->on_message_any_with_type = callback;
    room->on_message_any_with_type_userdata = userdata;
}

/* Helper function to encode msgpack string */
static size_t msgpack_encode_string(uint8_t* dest, const char* str, size_t str_len) {
    if (str_len <= 31) {
        /* fixstr: 0xa0 | length */
        dest[0] = 0xa0 | (uint8_t)str_len;
        memcpy(dest + 1, str, str_len);
        return 1 + str_len;
    } else if (str_len <= 255) {
        /* str8: 0xd9, length (1 byte), string */
        dest[0] = 0xd9;
        dest[1] = (uint8_t)str_len;
        memcpy(dest + 2, str, str_len);
        return 2 + str_len;
    } else if (str_len <= 65535) {
        /* str16: 0xda, length (2 bytes big-endian), string */
        dest[0] = 0xda;
        dest[1] = (uint8_t)(str_len >> 8);
        dest[2] = (uint8_t)(str_len & 0xff);
        memcpy(dest + 3, str, str_len);
        return 3 + str_len;
    } else {
        /* str32: 0xdb, length (4 bytes big-endian), string */
        dest[0] = 0xdb;
        dest[1] = (uint8_t)(str_len >> 24);
        dest[2] = (uint8_t)((str_len >> 16) & 0xff);
        dest[3] = (uint8_t)((str_len >> 8) & 0xff);
        dest[4] = (uint8_t)(str_len & 0xff);
        memcpy(dest + 5, str, str_len);
        return 5 + str_len;
    }
}

/* Helper function to encode msgpack integer */
static size_t msgpack_encode_number(uint8_t* dest, int value) {
    if (value >= 0 && value <= 127) {
        /* Positive fixint: single byte */
        dest[0] = (uint8_t)value;
        return 1;
    } else if (value >= -32 && value < 0) {
        /* Negative fixint: 0xe0 to 0xff */
        dest[0] = (uint8_t)(0xe0 | (value & 0x1f));
        return 1;
    } else if (value >= -128 && value <= 127) {
        /* int8: 0xd0, value */
        dest[0] = 0xd0;
        dest[1] = (uint8_t)value;
        return 2;
    } else if (value >= -32768 && value <= 32767) {
        /* int16: 0xd1, value (2 bytes big-endian) */
        dest[0] = 0xd1;
        dest[1] = (uint8_t)(value >> 8);
        dest[2] = (uint8_t)(value & 0xff);
        return 3;
    } else {
        /* int32: 0xd2, value (4 bytes big-endian) */
        dest[0] = 0xd2;
        dest[1] = (uint8_t)(value >> 24);
        dest[2] = (uint8_t)((value >> 16) & 0xff);
        dest[3] = (uint8_t)((value >> 8) & 0xff);
        dest[4] = (uint8_t)(value & 0xff);
        return 5;
    }
}

/* Decode helpers */
static float decode_number(const uint8_t* bytes, size_t* offset) {
    colyseus_iterator_t it = { .offset = (int)*offset };
    float result = colyseus_decode_number(bytes, &it);
    *offset = (size_t)it.offset;
    return result;
}

static char* decode_string(const uint8_t* bytes, size_t* offset) {
    colyseus_iterator_t it = { .offset = (int)*offset };
    char* result = colyseus_decode_string(bytes, &it);
    *offset = (size_t)it.offset;
    return result;
}

static bool decode_number_check(const uint8_t* bytes, size_t offset) {
    colyseus_iterator_t it = { .offset = (int)offset };
    return colyseus_decode_number_check(bytes, &it);
}

/* Send messages */
void colyseus_room_send_str(colyseus_room_t* room, const char* type, const uint8_t* message, size_t length) {
    if (!room || !room->transport || !colyseus_transport_is_open(room->transport)) {
        return;
    }

    /* Build message: [PROTOCOL][msgpack-encoded type string][message] */
    size_t type_len = strlen(type);

    /* Calculate msgpack encoding size */
    size_t msgpack_size = (type_len <= 31) ? (1 + type_len) :
                          (type_len <= 255) ? (2 + type_len) :
                          (type_len <= 65535) ? (3 + type_len) :
                          (5 + type_len);

    size_t total_len = 1 + msgpack_size + length;
    uint8_t* data = malloc(total_len);

    /* Protocol byte */
    data[0] = COLYSEUS_PROTOCOL_ROOM_DATA;

    /* Msgpack-encoded type string */
    size_t encoded_len = msgpack_encode_string(data + 1, type, type_len);

    /* Message payload */
    if (message && length > 0) {
        memcpy(data + 1 + encoded_len, message, length);
    }

    colyseus_transport_send(room->transport, data, total_len);
    free(data);
}

void colyseus_room_send_int(colyseus_room_t* room, int type, const uint8_t* message, size_t length) {
    if (!room || !room->transport || !colyseus_transport_is_open(room->transport)) {
        return;
    }

    /* Build message: [PROTOCOL][msgpack-encoded type integer][message] */
    uint8_t type_buffer[5];  /* Max size for int32 msgpack encoding */
    size_t type_encoded_size = msgpack_encode_number(type_buffer, type);

    size_t total_len = 1 + type_encoded_size + length;
    uint8_t* data = malloc(total_len);

    /* Protocol byte */
    data[0] = COLYSEUS_PROTOCOL_ROOM_DATA;

    /* Msgpack-encoded type integer */
    memcpy(data + 1, type_buffer, type_encoded_size);

    /* Message payload */
    if (message && length > 0) {
        memcpy(data + 1 + type_encoded_size, message, length);
    }

    colyseus_transport_send(room->transport, data, total_len);
    free(data);
}

/* Transport event handlers */
static void room_on_transport_open(void* userdata) {
    (void)userdata;
    /* Connection established, wait for JOIN_ROOM from server */
}

static void room_on_transport_message(const uint8_t* data, size_t length, void* userdata) {
    colyseus_room_t* room = (colyseus_room_t*)userdata;

    if (length == 0) return;

    colyseus_protocol_t code = (colyseus_protocol_t)data[0];
    size_t offset = 1;

    switch (code) {
        case COLYSEUS_PROTOCOL_JOIN_ROOM: {
            /* Decode reconnection token (string with length prefix) */
            if (offset < length) {
                uint8_t token_len = data[offset];
                offset++;

                if (offset + token_len <= length) {
                    free(room->reconnection_token);
                    room->reconnection_token = malloc(token_len + 1);
                    if (room->reconnection_token) {
                        memcpy(room->reconnection_token, data + offset, token_len);
                        room->reconnection_token[token_len] = '\0';
                    }
                    offset += token_len;
                }
            }

            /* Decode serializer ID (string with length prefix) */
            if (offset < length) {
                uint8_t serializer_len = data[offset];
                offset++;

                if (offset + serializer_len <= length) {
                    free(room->serializer_id);
                    room->serializer_id = malloc(serializer_len + 1);
                    if (room->serializer_id) {
                        memcpy(room->serializer_id, data + offset, serializer_len);
                        room->serializer_id[serializer_len] = '\0';
                    }
                    offset += serializer_len;
                }
            }

            /* Create serializer based on serializer ID */
            if (room->serializer_id && strcmp(room->serializer_id, "schema") == 0) {
                if (room->state_vtable) {
                    room->serializer = colyseus_schema_serializer_create(room->state_vtable);

                    /* Handle handshake if there's more data */
                    if (offset < length && room->serializer) {
                        colyseus_schema_serializer_handshake(room->serializer, data, length, (int)offset);
                    }
                } else {
                    fprintf(stderr, "Warning: Schema serializer requested but no state vtable set. "
                                    "Call colyseus_room_set_state_type() before connecting.\n");
                }
            } else if (room->serializer_id && strcmp(room->serializer_id, "fossil-delta") == 0) {
                fprintf(stderr, "Error: FossilDelta serialization has been deprecated.\n");
            }
            /* else: "none" serializer or unknown - no state handling */

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
            /* Decode error code and message */
            int error_code = (int)decode_number(data, &offset);
            char* error_message = decode_string(data, &offset);

            if (room->on_error) {
                room->on_error(error_code, error_message ? error_message : "Unknown error", room->on_error_userdata);
            }

            free(error_message);
            break;
        }

        case COLYSEUS_PROTOCOL_LEAVE_ROOM: {
            colyseus_room_leave(room, false);
            break;
        }

        case COLYSEUS_PROTOCOL_ROOM_STATE: {
            /* Handle full state */
            if (room->serializer) {
                colyseus_schema_serializer_set_state(room->serializer, data, length, (int)offset);
            }

            if (room->on_state_change) {
                room->on_state_change(room->on_state_change_userdata);
            }
            break;
        }

        case COLYSEUS_PROTOCOL_ROOM_STATE_PATCH: {
            /* Handle state patch */
            if (room->serializer) {
                colyseus_schema_serializer_patch(room->serializer, data, length, (int)offset);
            }

            if (room->on_state_change) {
                room->on_state_change(room->on_state_change_userdata);
            }
            break;
        }

        case COLYSEUS_PROTOCOL_ROOM_DATA:
        case COLYSEUS_PROTOCOL_ROOM_DATA_BYTES: {
            /* Decode message type and data */
            if (length > offset) {
                char type_str[256] = {0};

                if (decode_number_check(data, offset)) {
                    /* Numeric type */
                    int type_num = (int)decode_number(data, &offset);
                    snprintf(type_str, sizeof(type_str), "i%d", type_num);
                } else {
                    /* String type */
                    char* decoded_type = decode_string(data, &offset);
                    if (decoded_type) {
                        strncpy(type_str, decoded_type, sizeof(type_str) - 1);
                        free(decoded_type);
                    }
                }

                /* Dispatch the message with remaining data */
                if (strlen(type_str) > 0) {
                    room_dispatch_message(room, type_str, data + offset, length - offset);
                }
            }
            break;
        }

        default:
            fprintf(stderr, "Unknown protocol message: %d\n", code);
            break;
    }
}

static void room_on_transport_close(int code, const char* reason, void* userdata) {
    colyseus_room_t* room = (colyseus_room_t*)userdata;

    /* Teardown serializer */
    if (room->serializer) {
        colyseus_schema_serializer_teardown(room->serializer);
    }

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
    }

    /* Also call the "with type" callback if registered */
    if (room->on_message_any_with_type) {
        room->on_message_any_with_type(type, message, length, room->on_message_any_with_type_userdata);
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