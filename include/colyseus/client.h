#ifndef COLYSEUS_CLIENT_H
#define COLYSEUS_CLIENT_H

#include "colyseus/settings.h"
#include "colyseus/transport.h"
#include "colyseus/protocol.h"
#include "colyseus/http.h"
#include "colyseus/room.h"
#include "colyseus/latency.h"
#include <stdbool.h>

#include "auth/auth.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Client structure */
typedef struct {
    colyseus_settings_t* settings;
    colyseus_transport_factory_fn transport_factory;
    colyseus_http_t* http;
    colyseus_auth_t* auth;
    void* http_worker;  /* Internal: background HTTP worker thread */
} colyseus_client_t;

/* Matchmaking callbacks */
typedef void (*colyseus_client_room_callback_t)(colyseus_room_t* room, void* userdata);
typedef void (*colyseus_client_error_callback_t)(int code, const char* message, void* userdata);

/* Create and destroy client */
colyseus_client_t* colyseus_client_create(colyseus_settings_t* settings);
colyseus_client_t* colyseus_client_create_with_transport(
    colyseus_settings_t* settings,
    colyseus_transport_factory_fn transport_factory
);
void colyseus_client_free(colyseus_client_t* client);

/* Get HTTP client */
colyseus_http_t* colyseus_client_get_http(colyseus_client_t* client);

/* Get Auth client */
colyseus_auth_t* colyseus_client_get_auth(colyseus_client_t* client);

/* Matchmaking methods */
void colyseus_client_join_or_create(
    colyseus_client_t* client,
    const char* room_name,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
);

void colyseus_client_create_room(
    colyseus_client_t* client,
    const char* room_name,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
);

void colyseus_client_join(
    colyseus_client_t* client,
    const char* room_name,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
);

void colyseus_client_join_by_id(
    colyseus_client_t* client,
    const char* room_id,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
);

/* Re-take a seat the server is holding via allowReconnection(). The token is
 * what colyseus_room_get_reconnection_token() returned on the previous room. */
void colyseus_client_reconnect(
    colyseus_client_t* client,
    const char* reconnection_token,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
);

/**
 * Measure the latency to this client's configured server endpoint. TLS settings
 * are derived from the client; `options` (NULL for defaults) supplies
 * ping_count/timeout_ms. The callback fires exactly once.
 */
void colyseus_client_get_latency(
    colyseus_client_t* client,
    const colyseus_latency_options_t* options,
    colyseus_get_latency_cb_t cb,
    void* userdata
);

/**
 * Drive the SDK from the calling thread — once per frame.
 *
 * Runs, in order: completed matchmaking requests, polled websockets (read,
 * decode, dispatch, queued sends), the latency injector's due packets,
 * latency probes, and due auto-reconnection attempts. In polled mode
 * (colyseus_set_polled) this is where every SDK callback fires: on this
 * thread, inside this call, never between polls.
 *
 * Cheap when nothing is connected, and harmless in threaded mode (it only
 * drives what was started polled). A call from inside an SDK callback returns
 * at once. Poll from one thread at a time — and in polled mode, leave and
 * free rooms and clients on that same thread.
 *
 * Engine bindings call this from their own frame driver, so apps built on
 * them never have to.
 */
void colyseus_poll(void);

/**
 * Process-wide: run the SDK polled — deliver everything through
 * colyseus_poll() instead of background threads, so the thread that polls is
 * the only one that ever touches SDK state. The recommended mode for native
 * apps; off by default for now.
 *
 * Call it once at startup, before creating a client. The mode is latched when
 * each piece starts, so flipping it later never strands or splits a live
 * connection — only what starts afterwards follows:
 *  - a websocket, when it connects;
 *  - a matchmaking request, when it is submitted;
 *  - a room, on its first connect: its auto-reconnection, and every socket
 *    it reopens, keep that mode for the room's lifetime;
 *  - a latency probe, when it starts.
 *
 * With it on:
 *  - matchmaking still blocks on a worker thread, but on_success / on_error
 *    run in the poll — and so does what they start: creating the room and
 *    connecting its socket (DNS lookup included);
 *  - reconnection attempts are scheduled by the poll; giving up tears the
 *    state down and fires on_leave there;
 *  - a send from the polling thread is written at once (from inside one of
 *    the socket's own callbacks, at the end of that tick); a send from any
 *    other thread waits for the next poll.
 *
 * It also sets colyseus_ws_set_polled(), which on its own still makes only
 * the sockets polled: matchmaking and reconnection keep their worker threads.
 * Auth calls and the raw colyseus_http_* requests are unaffected either way —
 * they block and answer on the calling thread.
 */
void colyseus_set_polled(bool polled);
bool colyseus_is_polled(void);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_CLIENT_H */
