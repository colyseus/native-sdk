#ifndef COLYSEUS_WEBSOCKET_TRANSPORT_INTERNAL_H
#define COLYSEUS_WEBSOCKET_TRANSPORT_INTERNAL_H

/*
 * The transport's own state. Kept out of the public header so that including
 * <colyseus.h> does not drag wslay, pthread or windows.h into a consumer's
 * translation unit.
 */

#include "colyseus/websocket_transport.h"

#include <stddef.h>
#include <stdbool.h>

#include <wslay/wslay.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

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
    void* addr_list;  /* struct addrinfo* — every resolved address, tried in order */
    void* addr_cur;   /* next address to try on a refused connect */
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
    bool polled;                 /* ticked by colyseus_ws_poll(); fixed at connect */
    bool send_failed;            /* an inline flush hit a write error; the next tick closes */
    int connect_mode;            /* colyseus_ws_pin_polled(): 0 follows the process default */

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

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_WEBSOCKET_TRANSPORT_INTERNAL_H */
