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

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_WEBSOCKET_TRANSPORT_H */
