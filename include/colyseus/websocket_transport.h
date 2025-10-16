#ifndef COLYSEUS_WEBSOCKET_TRANSPORT_H
#define COLYSEUS_WEBSOCKET_TRANSPORT_H

#include "colyseus/transport.h"
#include <stdint.h>
#include <stdbool.h>

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
        colyseus_ws_state_t state;
        bool running;

        char* url;
        char* url_host;
        int url_port;
        char* url_path;

        char* client_key;
        char* buffer;
        size_t buffer_size;
        size_t buffer_offset;

        void* wslay_ctx;  /* wslay_event_context_ptr */
        int socket_fd;

        /* Thread handle (platform specific) */
        void* tick_thread;
    } colyseus_ws_transport_data_t;

    /* Create WebSocket transport (implements transport interface) */
    colyseus_transport_t* colyseus_websocket_transport_create(const colyseus_transport_events_t* events);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_WEBSOCKET_TRANSPORT_H */