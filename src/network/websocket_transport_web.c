#ifdef __EMSCRIPTEN__

#include "colyseus/transport.h"
#include <emscripten/websocket.h>
#include <emscripten/emscripten.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef struct {
    EMSCRIPTEN_WEBSOCKET_T socket;
    colyseus_transport_events_t events;
    bool is_open;
} colyseus_web_transport_data_t;

static void web_ws_connect_impl(colyseus_transport_t* transport, const char* url);
static void web_ws_send_impl(colyseus_transport_t* transport, const uint8_t* data, size_t length);
static void web_ws_send_unreliable_impl(colyseus_transport_t* transport, const uint8_t* data, size_t length);
static void web_ws_close_impl(colyseus_transport_t* transport, int code, const char* reason);
static bool web_ws_is_open_impl(const colyseus_transport_t* transport);
static void web_ws_destroy_impl(colyseus_transport_t* transport);

static EM_BOOL on_open(int eventType, const EmscriptenWebSocketOpenEvent *websocketEvent, void *userData);
static EM_BOOL on_message(int eventType, const EmscriptenWebSocketMessageEvent *websocketEvent, void *userData);
static EM_BOOL on_error(int eventType, const EmscriptenWebSocketErrorEvent *websocketEvent, void *userData);
static EM_BOOL on_close(int eventType, const EmscriptenWebSocketCloseEvent *websocketEvent, void *userData);

colyseus_transport_t* colyseus_websocket_transport_create(const colyseus_transport_events_t* events) {
    colyseus_transport_t* transport = malloc(sizeof(colyseus_transport_t));
    if (!transport) return NULL;

    transport->connect = web_ws_connect_impl;
    transport->send = web_ws_send_impl;
    transport->send_unreliable = web_ws_send_unreliable_impl;
    transport->close = web_ws_close_impl;
    transport->is_open = web_ws_is_open_impl;
    transport->destroy = web_ws_destroy_impl;

    if (events) {
        transport->events = *events;
    } else {
        memset(&transport->events, 0, sizeof(colyseus_transport_events_t));
    }

    colyseus_web_transport_data_t* data = malloc(sizeof(colyseus_web_transport_data_t));
    if (!data) {
        free(transport);
        return NULL;
    }

    memset(data, 0, sizeof(colyseus_web_transport_data_t));
    data->socket = 0;
    data->is_open = false;
    data->events = transport->events;

    transport->impl_data = data;

    return transport;
}

static void web_ws_connect_impl(colyseus_transport_t* transport, const char* url) {
    colyseus_web_transport_data_t* data = (colyseus_web_transport_data_t*)transport->impl_data;

    printf("[WebSocket] Connecting to: %s\n", url);

    EmscriptenWebSocketCreateAttributes attrs = {
        .url = url,
        .protocols = NULL,
        .createOnMainThread = EM_TRUE
    };

    data->socket = emscripten_websocket_new(&attrs);
    if (data->socket <= 0) {
        printf("[WebSocket] Failed to create socket\n");
        if (transport->events.on_error) {
            transport->events.on_error("Failed to create WebSocket", transport->events.userdata);
        }
        return;
    }

    emscripten_websocket_set_onopen_callback(data->socket, transport, on_open);
    emscripten_websocket_set_onmessage_callback(data->socket, transport, on_message);
    emscripten_websocket_set_onerror_callback(data->socket, transport, on_error);
    emscripten_websocket_set_onclose_callback(data->socket, transport, on_close);
}

static void web_ws_send_impl(colyseus_transport_t* transport, const uint8_t* msg_data, size_t length) {
    colyseus_web_transport_data_t* data = (colyseus_web_transport_data_t*)transport->impl_data;

    if (!data->is_open || data->socket <= 0) {
        return;
    }

    EMSCRIPTEN_RESULT result = emscripten_websocket_send_binary(data->socket, (void*)msg_data, length);
    if (result != EMSCRIPTEN_RESULT_SUCCESS) {
        printf("[WebSocket] Send failed: %d\n", result);
    }
}

static void web_ws_send_unreliable_impl(colyseus_transport_t* transport, const uint8_t* data, size_t length) {
    (void)transport;
    (void)data;
    (void)length;
    printf("[WebSocket] Unreliable messages not supported on web\n");
}

static void web_ws_close_impl(colyseus_transport_t* transport, int code, const char* reason) {
    colyseus_web_transport_data_t* data = (colyseus_web_transport_data_t*)transport->impl_data;

    if (data->socket > 0) {
        emscripten_websocket_close(data->socket, code, reason ? reason : "");
        data->socket = 0;
    }
    data->is_open = false;
}

static bool web_ws_is_open_impl(const colyseus_transport_t* transport) {
    colyseus_web_transport_data_t* data = (colyseus_web_transport_data_t*)transport->impl_data;
    return data->is_open;
}

static void web_ws_destroy_impl(colyseus_transport_t* transport) {
    if (!transport) return;

    colyseus_web_transport_data_t* data = (colyseus_web_transport_data_t*)transport->impl_data;
    if (data) {
        if (data->socket > 0) {
            emscripten_websocket_close(data->socket, 1000, "");
            emscripten_websocket_delete(data->socket);
        }
        free(data);
    }
    free(transport);
}

static EM_BOOL on_open(int eventType, const EmscriptenWebSocketOpenEvent *websocketEvent, void *userData) {
    (void)eventType;
    (void)websocketEvent;
    
    colyseus_transport_t* transport = (colyseus_transport_t*)userData;
    colyseus_web_transport_data_t* data = (colyseus_web_transport_data_t*)transport->impl_data;

    printf("[WebSocket] Connected!\n");
    data->is_open = true;

    if (transport->events.on_open) {
        transport->events.on_open(transport->events.userdata);
    }

    return EM_TRUE;
}

static EM_BOOL on_message(int eventType, const EmscriptenWebSocketMessageEvent *websocketEvent, void *userData) {
    (void)eventType;
    
    colyseus_transport_t* transport = (colyseus_transport_t*)userData;

    if (websocketEvent->isText) {
        printf("[WebSocket] Text message received (unexpected)\n");
        return EM_TRUE;
    }

    if (transport->events.on_message && websocketEvent->numBytes > 0) {
        transport->events.on_message(
            (const uint8_t*)websocketEvent->data,
            websocketEvent->numBytes,
            transport->events.userdata
        );
    }

    return EM_TRUE;
}

static EM_BOOL on_error(int eventType, const EmscriptenWebSocketErrorEvent *websocketEvent, void *userData) {
    (void)eventType;
    (void)websocketEvent;
    
    colyseus_transport_t* transport = (colyseus_transport_t*)userData;

    printf("[WebSocket] Error occurred\n");

    if (transport->events.on_error) {
        transport->events.on_error("WebSocket error", transport->events.userdata);
    }

    return EM_TRUE;
}

static EM_BOOL on_close(int eventType, const EmscriptenWebSocketCloseEvent *websocketEvent, void *userData) {
    (void)eventType;
    
    colyseus_transport_t* transport = (colyseus_transport_t*)userData;
    colyseus_web_transport_data_t* data = (colyseus_web_transport_data_t*)transport->impl_data;

    printf("[WebSocket] Closed: code=%d, reason=%s\n", websocketEvent->code, websocketEvent->reason);
    data->is_open = false;

    if (transport->events.on_close) {
        transport->events.on_close(websocketEvent->code, websocketEvent->reason, transport->events.userdata);
    }

    return EM_TRUE;
}

#endif /* __EMSCRIPTEN__ */
