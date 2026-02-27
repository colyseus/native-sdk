#ifndef COLYSEUS_WEBSOCKET_TRANSPORT_H
#define COLYSEUS_WEBSOCKET_TRANSPORT_H

#include "colyseus/transport.h"
#include <stdint.h>
#include <stdbool.h>

#include "settings.h"

#ifndef __EMSCRIPTEN__
#include <wslay/wslay.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

#ifndef __EMSCRIPTEN__
    /* WebSocket transport state */
    typedef enum {
        COLYSEUS_WS_DISCONNECTED,
        COLYSEUS_WS_CONNECTING,
        COLYSEUS_WS_TLS_HANDSHAKE,
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
        void* tls_ctx;  /* colyseus_tls_context_t* */
        const unsigned char* ca_pem_data;  /* CA certificates in PEM format */

        /* size_t fields (8 bytes on 64-bit) */
        size_t buffer_size;
        size_t buffer_offset;
        size_t handshake_len;
        size_t ca_pem_len;           /* Length of CA PEM data */

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
        bool use_tls;                /* True for wss:// */
        bool tls_skip_verify;        /* Skip certificate verification */
    } colyseus_ws_transport_data_t;
#endif /* !__EMSCRIPTEN__ */

    /* Create WebSocket transport (implements transport interface) */
    colyseus_transport_t* colyseus_websocket_transport_create(const colyseus_transport_events_t* events);

    /* Connect with settings (extracts TLS config from settings) */
    void colyseus_websocket_connect_with_settings(colyseus_transport_t* transport,
                                                   const char* url,
                                                   const colyseus_settings_t* settings);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_WEBSOCKET_TRANSPORT_H */
