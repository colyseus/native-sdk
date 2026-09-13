#ifndef COLYSEUS_WEBSOCKET_TRANSPORT_H
#define COLYSEUS_WEBSOCKET_TRANSPORT_H

#include "colyseus/transport.h"
#include "colyseus/settings.h"

#ifdef __cplusplus
extern "C" {
#endif

    /* Create WebSocket transport (implements transport interface) */
    colyseus_transport_t* colyseus_websocket_transport_create(const colyseus_transport_events_t* events);

    /* Connect with settings (extracts TLS config from settings) */
    void colyseus_websocket_connect_with_settings(colyseus_transport_t* transport,
                                                   const char* url,
                                                   const colyseus_settings_t* settings);

    /**
     * Threading contract
     *
     * Every transport callback runs on the socket's driving thread, and so
     * does everything a room does with a frame: schema decode, the
     * onChange/onAdd/listen callbacks, prediction bookkeeping, on_leave after
     * a drop. Room state may only be read on that thread (or while it is
     * known to be idle). Which thread that is depends on the mode:
     *
     *  - Polled — recommended for native apps: colyseus_set_polled(true) once
     *    at startup, colyseus_poll() once per frame (client.h). No thread:
     *    the poll ticks every polled socket on the calling thread, so decode
     *    and every callback run inside that call and nowhere else — and so do
     *    matchmaking results, reconnection and latency probes. Poll from the
     *    thread that reads state.
     *    colyseus_ws_set_polled() + colyseus_ws_poll() are its sockets-only
     *    half: matchmaking and reconnection keep their worker threads.
     *  - Threaded (native default, for now): connect starts one tick thread
     *    per socket. Decode runs there, concurrently with the rest of the
     *    program, so an app that reads state from its own main loop races the
     *    decoder. colyseus_netdelay_wrap(room, true) + colyseus_netdelay_pump()
     *    moves message decode to the pumping thread, but open/close/error (and
     *    the teardown a close does) still run on the tick thread. The HTTP
     *    worker runs matchmaking's success and error callbacks, and the
     *    reconnection worker recreates the socket and fires on_leave once
     *    retries run out (a build with -DCOLYSEUS_RECONNECT_POLLED schedules
     *    reconnection from colyseus_reconnect_poll() instead).
     *  - Web (Emscripten): single-threaded. Callbacks run on the browser's
     *    event loop (or inside colyseus_ws_poll() in a GDExtension side
     *    module); colyseus_ws_set_polled() is a no-op.
     *
     * The mode is read once per socket, when it connects; changing it later
     * affects only sockets connected afterwards (a room's reconnect sockets
     * keep the mode the room first connected in).
     *
     * send, close and destroy may be called from any thread in every mode. A
     * threaded socket writes sends on its tick thread within ~10ms. A polled
     * one writes a send from the polling thread on the spot (from inside one
     * of its own callbacks, at the end of that tick); another thread's send
     * waits for the next poll. Off the driving thread, close and destroy first
     * wait for a tick in flight (the tick thread's join, or the poll's current
     * tick of that socket), then report on_close synchronously.
     */

    /**
     * Select polled mode for sockets connected from now on (see the threading
     * contract above). Process-wide; call it once at startup, before the first
     * connect. Prefer colyseus_set_polled(), which sets this and routes
     * matchmaking, reconnection and latency probes through colyseus_poll() too.
     */
    void colyseus_ws_set_polled(bool polled);

    /**
     * Tick every polled socket on the calling thread: connect progress, TLS,
     * the handshake, inbound frames (and their decode) and queued sends. A
     * no-op for threaded sockets, and from inside a transport callback.
     * colyseus_poll() calls it.
     */
    void colyseus_ws_poll(void);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_WEBSOCKET_TRANSPORT_H */
