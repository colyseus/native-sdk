#ifndef COLYSEUS_WEBSOCKET_TRANSPORT_H
#define COLYSEUS_WEBSOCKET_TRANSPORT_H

#include "colyseus/transport.h"
#include <stdint.h>
#include <stdbool.h>

#include "settings.h"

#ifndef __EMSCRIPTEN__
#include <wslay/wslay.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif
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

    /* Who frees the transport. A destroy from inside a callback on the tick
     * thread hands the free to the loop's exit; a nested destroy returns. */
    typedef enum {
        COLYSEUS_WS_DESTROY_NONE,
        COLYSEUS_WS_DESTROY_CALLER,
        COLYSEUS_WS_DESTROY_LOOP
    } colyseus_ws_destroy_owner_t;

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
        colyseus_ws_destroy_owner_t destroy_owner;
        int url_port;
        int socket_fd;

        /* 1-byte fields */
        bool running;
        bool pending_close;          /* Close requested from within tick thread */
        int pending_close_code;      /* Close code for deferred close */
        char* pending_close_reason;  /* Close reason for deferred close (must free) */
        bool use_tls;                /* True for wss:// */
        bool tls_skip_verify;        /* Skip certificate verification */

        /* Outbound messages wait here until the tick thread moves them into
         * wslay, whose context is not thread-safe: the tick thread is its only
         * caller. The lock guards these two pointers and nothing else, so a
         * send from inside on_message cannot deadlock. */
        struct colyseus_ws_outbox_msg* outbox_head;
        struct colyseus_ws_outbox_msg* outbox_tail;
#ifdef _WIN32
        CRITICAL_SECTION outbox_lock;
#else
        pthread_mutex_t outbox_lock;
#endif
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
