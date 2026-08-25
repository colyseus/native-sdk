#ifndef COLYSEUS_PROTOCOL_H
#define COLYSEUS_PROTOCOL_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

    /*
     * Protocol message types.
     *
     * Codes occupy bits 0..4 of the leading message byte (values 0..31).
     * Bits 5..7 carry modifier decorations OR'd onto the base code at send
     * time. Decoders strip the modifier bits before dispatching:
     *
     *     uint8_t code = byte & COLYSEUS_PROTOCOL_CODE_MASK;
     *     uint8_t modifiers = byte & COLYSEUS_PROTOCOL_MODIFIER_MASK;
     */
    typedef enum {
        /* Room-related (10~18) */
        COLYSEUS_PROTOCOL_JOIN_ROOM = 10,
        COLYSEUS_PROTOCOL_ERROR = 11,
        COLYSEUS_PROTOCOL_LEAVE_ROOM = 12,
        COLYSEUS_PROTOCOL_ROOM_DATA = 13,
        COLYSEUS_PROTOCOL_ROOM_STATE = 14,
        COLYSEUS_PROTOCOL_ROOM_STATE_PATCH = 15,
        COLYSEUS_PROTOCOL_ROOM_DATA_SCHEMA = 16, /* deprecated in 0.18 — never dispatched */
        COLYSEUS_PROTOCOL_ROOM_DATA_BYTES = 17,
        COLYSEUS_PROTOCOL_PING = 18, /* ping/pong share this code (the server echoes it) */

        /* Input-related (19~20) — consumed by the input layer (not ported yet) */
        COLYSEUS_PROTOCOL_ROOM_INPUT_RELIABLE = 19,
        COLYSEUS_PROTOCOL_ROOM_INPUT_UNRELIABLE = 20,

        /* Request/response (21~22) */
        COLYSEUS_PROTOCOL_ROOM_REQUEST = 21,  /* [byte, requestId varint, type(str|num), msgpack payload?] */
        COLYSEUS_PROTOCOL_ROOM_RESPONSE = 22, /* [byte, requestId varint, status uint8, msgpack payload?] */
    } colyseus_protocol_t;

    /* Isolates the base protocol code (low 5 bits, values 0..31). */
    #define COLYSEUS_PROTOCOL_CODE_MASK 0x1F

    /* Isolates modifier bits (high 3 bits; only TIMED is assigned today). */
    #define COLYSEUS_PROTOCOL_MODIFIER_MASK 0xE0

    /*
     * A [uint32 sNow][uint32 inputSeq] prefix precedes the body — server
     * time (ms since room start) + this client's last PROCESSED input seq.
     * Set by the server on ROOM_STATE / ROOM_STATE_PATCH whenever the room
     * called defineInput().
     */
    #define COLYSEUS_PROTOCOL_MODIFIER_TIMED 0x80

    /* Status byte of a ROOM_RESPONSE reply. */
    typedef enum {
        COLYSEUS_RESPONSE_OK = 0,
        /* deliberate, typed rejection — the authored reason rides as the payload */
        COLYSEUS_RESPONSE_REJECTED = 1,
        /* handler fault (threw / no handler) — payload is {name, message, code?} */
        COLYSEUS_RESPONSE_ERROR = 2,
    } colyseus_response_status_t;

    /*
     * Section tags for trailing tagged blobs in the JOIN_ROOM handshake:
     * [tag uint8][length varint][payload], repeated until end-of-buffer.
     * Unknown tags are skipped via length (forward-compatible).
     */
    typedef enum {
        /* reflection bytes for the room's input schema (defineInput()) */
        COLYSEUS_HANDSHAKE_INPUT_REFLECTION = 1,
        /* input feature flags + rates the client mirrors (defineInput()) */
        COLYSEUS_HANDSHAKE_INPUT_OPTIONS = 2,
    } colyseus_handshake_section_t;

    /*
     * Bit flags in the leading byte of the INPUT_OPTIONS section. Some flags
     * imply a trailing varint in the section payload, appended in bit order.
     */
    typedef enum {
        /* reliable inputs carry the SNAPSHOT-timeline stamp (renderTime) */
        COLYSEUS_INPUT_FLAG_RENDER_TIME = 1,
        /* [tickRate varint] (Hz) follows — the server's fixed step rate */
        COLYSEUS_INPUT_FLAG_FIXED_TIMESTEP = 2,
        /* [patchRate varint] (ms) follows — the state-patch interval */
        COLYSEUS_INPUT_FLAG_PATCH_RATE = 4,
        /* [subSteps varint] follows — physics sub-steps per input tick */
        COLYSEUS_INPUT_FLAG_SUB_STEPS = 8,
        /* reliable inputs carry the RECKON-timeline stamp (reckonTime) */
        COLYSEUS_INPUT_FLAG_RECKON_TIME = 16,
    } colyseus_input_flags_t;

    /* Close codes */
    typedef enum {
        COLYSEUS_CLOSE_NORMAL_CLOSURE = 1000,
        COLYSEUS_CLOSE_GOING_AWAY = 1001,
        COLYSEUS_CLOSE_NO_STATUS_RECEIVED = 1005,
        COLYSEUS_CLOSE_ABNORMAL_CLOSURE = 1006,

        COLYSEUS_CLOSE_CONSENTED = 4000,
        COLYSEUS_CLOSE_SERVER_SHUTDOWN = 4001,
        COLYSEUS_CLOSE_WITH_ERROR = 4002,
        COLYSEUS_CLOSE_FAILED_TO_RECONNECT = 4003,

        COLYSEUS_CLOSE_MAY_TRY_RECONNECT = 4010,
        COLYSEUS_CLOSE_DEVMODE_RESTART = 4010, /* deprecated alias */
    } colyseus_close_code_t;

    /* Error codes */
    typedef enum {
        COLYSEUS_ERROR_MATCHMAKE_NO_HANDLER = 4210,
        COLYSEUS_ERROR_MATCHMAKE_INVALID_CRITERIA = 4211,
        COLYSEUS_ERROR_MATCHMAKE_INVALID_ROOM_ID = 4212,
        COLYSEUS_ERROR_MATCHMAKE_UNHANDLED = 4213,
        COLYSEUS_ERROR_MATCHMAKE_EXPIRED = 4214,
        COLYSEUS_ERROR_AUTH_FAILED = 4215,
        COLYSEUS_ERROR_APPLICATION_ERROR = 4216,
    } colyseus_error_code_t;

    /* Room metadata */
    typedef struct {
        char* room_id;
        char* name;
        char* process_id;
        char* public_address;
        int clients;
        int max_clients;
    } colyseus_room_available_t;

    /* Seat reservation from matchmaking */
    typedef struct {
        colyseus_room_available_t room;
        char* session_id;
        char* reconnection_token;
        bool dev_mode;
        char* protocol;
    } colyseus_seat_reservation_t;

    /* Helper functions for memory management */
    void colyseus_room_available_free(colyseus_room_available_t* room);
    void colyseus_seat_reservation_free(colyseus_seat_reservation_t* reservation);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_PROTOCOL_H */
