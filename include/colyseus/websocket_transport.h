#ifndef COLYSEUS_WEBSOCKET_TRANSPORT_H
#define COLYSEUS_WEBSOCKET_TRANSPORT_H

#include "colyseus/transport.h"
#include <stdint.h>
#include <stdbool.h>
#include <wslay/wslay.h>

#ifdef __cplusplus
extern "C" {
#endif

    /* WebSocket transport state */
    typedef enum {
        COLYSEUS_WS_DISCONNECTED,
        COLYSEUS_WS_CONNECTING,
        COLYSEUS_WS_HANDSHAKE_SENDING,
        COLYSEUS_WS_HANDSHAKE_RECEIVING,
        COLYSEUS_WS_CONNECTED,
        COLYSEUS_WS_REMOTE_DISCONNECT
    } colyseus_ws_state_t;

    /* WebSocket transport implementation data */
    typedef struct {
        /* Pointers first (8-byte aligned on 64-bit) */
        char* url;
        char* url_host;
        char* url_path;
        char* client_key;
        char* buffer;
        wslay_event_context_ptr wslay_ctx;  /* wslay_event_context_ptr */
        void* tick_thread;  /* Thread handle (platform specific) */

        /* size_t fields (8 bytes on 64-bit) */
        size_t buffer_size;
        size_t buffer_offset;

        /* 4-byte fields */
        colyseus_ws_state_t state;
        int url_port;
        int socket_fd;

        /* 1-byte fields */
        bool running;
        bool in_tick_thread;         /* True when executing inside tick thread */
        bool pending_close;          /* Close requested from within tick thread */
        int pending_close_code;      /* Close code for deferred close */
        char* pending_close_reason;  /* Close reason for deferred close (must free) */
    } colyseus_ws_transport_data_t;

    /* Create WebSocket transport (implements transport interface) */
    colyseus_transport_t* colyseus_websocket_transport_create(const colyseus_transport_events_t* events);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_WEBSOCKET_TRANSPORT_H */
