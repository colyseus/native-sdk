#ifndef COLYSEUS_PROTOCOL_H
#define COLYSEUS_PROTOCOL_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

    /* Protocol message types */
    typedef enum {
        COLYSEUS_PROTOCOL_HANDSHAKE = 9,
        COLYSEUS_PROTOCOL_JOIN_ROOM = 10,
        COLYSEUS_PROTOCOL_ERROR = 11,
        COLYSEUS_PROTOCOL_LEAVE_ROOM = 12,
        COLYSEUS_PROTOCOL_ROOM_DATA = 13,
        COLYSEUS_PROTOCOL_ROOM_STATE = 14,
        COLYSEUS_PROTOCOL_ROOM_STATE_PATCH = 15,
        COLYSEUS_PROTOCOL_ROOM_DATA_SCHEMA = 16,
        COLYSEUS_PROTOCOL_ROOM_DATA_BYTES = 17,
    } colyseus_protocol_t;

    /* Close codes */
    typedef enum {
        COLYSEUS_CLOSE_CONSENTED = 4000,
        COLYSEUS_CLOSE_DEVMODE_RESTART = 4010,
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