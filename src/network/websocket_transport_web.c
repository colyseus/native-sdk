#ifdef __EMSCRIPTEN__

#include "colyseus/transport.h"
#include "colyseus/settings.h"
#include <emscripten.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// ============================================================================
// SIDE_MODULE (Godot) - Uses polling approach since JS can't callback to C
// ============================================================================
#ifdef GDEXTENSION_SIDE_MODULE

typedef struct {
    int socket_id;
    colyseus_transport_events_t events;
    bool is_open;
    bool pending_open;
    bool pending_error;
    bool pending_close;
    int close_code;
} colyseus_web_transport_data_t;

static void web_ws_connect_impl(colyseus_transport_t* transport, const char* url);
static void web_ws_send_impl(colyseus_transport_t* transport, const uint8_t* data, size_t length);
static void web_ws_send_unreliable_impl(colyseus_transport_t* transport, const uint8_t* data, size_t length);
static void web_ws_close_impl(colyseus_transport_t* transport, int code, const char* reason);
static bool web_ws_is_open_impl(const colyseus_transport_t* transport);
static void web_ws_destroy_impl(colyseus_transport_t* transport);

#define MAX_WS_TRANSPORTS 16
static colyseus_transport_t* g_ws_transports[MAX_WS_TRANSPORTS] = {0};

static void init_ws_polling(void) {
    static int initialized = 0;
    if (initialized) return;
    initialized = 1;
    
    emscripten_run_script(
        "if (!Module._colyseusWs) {"
        "  Module._colyseusWs = { sockets: {}, events: {}, nextId: 1 };"
        "}"
    );
}

static void register_transport(colyseus_transport_t* transport) {
    for (int i = 0; i < MAX_WS_TRANSPORTS; i++) {
        if (!g_ws_transports[i]) {
            g_ws_transports[i] = transport;
            return;
        }
    }
}

static void unregister_transport(colyseus_transport_t* transport) {
    for (int i = 0; i < MAX_WS_TRANSPORTS; i++) {
        if (g_ws_transports[i] == transport) {
            g_ws_transports[i] = NULL;
            return;
        }
    }
}

EMSCRIPTEN_KEEPALIVE
void colyseus_ws_poll(void) {
    for (int i = 0; i < MAX_WS_TRANSPORTS; i++) {
        colyseus_transport_t* transport = g_ws_transports[i];
        if (!transport) continue;
        
        colyseus_web_transport_data_t* data = (colyseus_web_transport_data_t*)transport->impl_data;
        if (!data || data->socket_id < 0) continue;
        
        char script[512];
        
        // Check for open event
        snprintf(script, sizeof(script),
            "(Module._colyseusWs.events[%d] && Module._colyseusWs.events[%d].open) ? 1 : 0",
            data->socket_id, data->socket_id);
        if (emscripten_run_script_int(script)) {
            snprintf(script, sizeof(script),
                "Module._colyseusWs.events[%d].open = false", data->socket_id);
            emscripten_run_script(script);
            
            printf("[WebSocket] Connected!\n");
            data->is_open = true;
            if (transport->events.on_open) {
                transport->events.on_open(transport->events.userdata);
            }
        }
        
        // Check for messages
        snprintf(script, sizeof(script),
            "(Module._colyseusWs.events[%d] && Module._colyseusWs.events[%d].messages && Module._colyseusWs.events[%d].messages.length) || 0",
            data->socket_id, data->socket_id, data->socket_id);
        int msg_count = emscripten_run_script_int(script);
        
        while (msg_count > 0) {
            // Get message length
            snprintf(script, sizeof(script),
                "Module._colyseusWs.events[%d].messages[0].length",
                data->socket_id);
            int msg_len = emscripten_run_script_int(script);
            
            if (msg_len > 0) {
                uint8_t* msg_data = malloc(msg_len);
                
                // Copy message data byte by byte (not ideal but works)
                for (int j = 0; j < msg_len; j++) {
                    snprintf(script, sizeof(script),
                        "Module._colyseusWs.events[%d].messages[0][%d]",
                        data->socket_id, j);
                    msg_data[j] = (uint8_t)emscripten_run_script_int(script);
                }
                
                if (transport->events.on_message) {
                    transport->events.on_message(msg_data, msg_len, transport->events.userdata);
                }
                
                free(msg_data);
            }
            
            // Remove processed message
            snprintf(script, sizeof(script),
                "Module._colyseusWs.events[%d].messages.shift()",
                data->socket_id);
            emscripten_run_script(script);
            
            msg_count--;
        }
        
        // Check for error
        snprintf(script, sizeof(script),
            "(Module._colyseusWs.events[%d] && Module._colyseusWs.events[%d].error) ? 1 : 0",
            data->socket_id, data->socket_id);
        if (emscripten_run_script_int(script)) {
            snprintf(script, sizeof(script),
                "Module._colyseusWs.events[%d].error = false", data->socket_id);
            emscripten_run_script(script);
            
            printf("[WebSocket] Error\n");
            if (transport->events.on_error) {
                transport->events.on_error("WebSocket error", transport->events.userdata);
            }
        }
        
        // Check for close
        snprintf(script, sizeof(script),
            "(Module._colyseusWs.events[%d] && Module._colyseusWs.events[%d].closed) ? 1 : 0",
            data->socket_id, data->socket_id);
        if (emscripten_run_script_int(script)) {
            snprintf(script, sizeof(script),
                "Module._colyseusWs.events[%d].closeCode || 1000",
                data->socket_id);
            int code = emscripten_run_script_int(script);
            
            snprintf(script, sizeof(script),
                "delete Module._colyseusWs.events[%d]", data->socket_id);
            emscripten_run_script(script);
            
            printf("[WebSocket] Closed: code=%d\n", code);
            data->is_open = false;
            if (transport->events.on_close) {
                transport->events.on_close(code, "", transport->events.userdata);
            }
        }
    }
}

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
    data->socket_id = -1;
    data->is_open = false;

    transport->impl_data = data;
    
    register_transport(transport);

    return transport;
}

static char* escape_string_for_js(const char* str) {
    if (!str) return strdup("\"\"");
    
    size_t len = strlen(str);
    size_t escaped_len = len * 2 + 3;
    char* escaped = malloc(escaped_len);
    char* p = escaped;
    
    *p++ = '"';
    for (size_t i = 0; i < len; i++) {
        char c = str[i];
        if (c == '"' || c == '\\') {
            *p++ = '\\';
        } else if (c == '\n') {
            *p++ = '\\';
            c = 'n';
        } else if (c == '\r') {
            *p++ = '\\';
            c = 'r';
        }
        *p++ = c;
    }
    *p++ = '"';
    *p = '\0';
    
    return escaped;
}

static void web_ws_connect_impl(colyseus_transport_t* transport, const char* url) {
    init_ws_polling();
    
    colyseus_web_transport_data_t* data = (colyseus_web_transport_data_t*)transport->impl_data;

    printf("[WebSocket] Connecting to: %s\n", url);

    char* escaped_url = escape_string_for_js(url);
    
    size_t script_len = 2048 + strlen(escaped_url);
    char* script = malloc(script_len);
    
    snprintf(script, script_len,
        "(function() {"
        "  var socketId = Module._colyseusWs.nextId++;"
        "  var url = %s;"
        "  Module._colyseusWs.events[socketId] = { open: false, messages: [], error: false, closed: false };"
        "  try {"
        "    var ws = new WebSocket(url);"
        "    ws.binaryType = \"arraybuffer\";"
        "    ws.onopen = function() {"
        "      Module._colyseusWs.events[socketId].open = true;"
        "    };"
        "    ws.onmessage = function(e) {"
        "      if (e.data instanceof ArrayBuffer) {"
        "        Module._colyseusWs.events[socketId].messages.push(new Uint8Array(e.data));"
        "      }"
        "    };"
        "    ws.onerror = function() {"
        "      Module._colyseusWs.events[socketId].error = true;"
        "    };"
        "    ws.onclose = function(e) {"
        "      Module._colyseusWs.events[socketId].closed = true;"
        "      Module._colyseusWs.events[socketId].closeCode = e.code;"
        "    };"
        "    Module._colyseusWs.sockets[socketId] = ws;"
        "    return socketId;"
        "  } catch(e) { console.error(\"[WebSocket] Failed:\", e); return -1; }"
        "})();",
        escaped_url
    );
    
    int socket_id = emscripten_run_script_int(script);
    
    free(script);
    free(escaped_url);

    data->socket_id = socket_id;
    
    if (socket_id < 0) {
        printf("[WebSocket] Failed to create socket\n");
        if (transport->events.on_error) {
            transport->events.on_error("Failed to create WebSocket", transport->events.userdata);
        }
    }
}

static void web_ws_send_impl(colyseus_transport_t* transport, const uint8_t* msg_data, size_t length) {
    colyseus_web_transport_data_t* data = (colyseus_web_transport_data_t*)transport->impl_data;

    if (!data->is_open || data->socket_id < 0) {
        return;
    }

    // Build a script that sends the binary data
    size_t script_len = 256 + length * 4;
    char* script = malloc(script_len);
    
    char* p = script;
    p += sprintf(p, "(function() {"
        "  var ws = Module._colyseusWs.sockets[%d];"
        "  if (ws && ws.readyState === WebSocket.OPEN) {"
        "    var data = new Uint8Array([", data->socket_id);
    
    for (size_t i = 0; i < length; i++) {
        if (i > 0) p += sprintf(p, ",");
        p += sprintf(p, "%d", msg_data[i]);
    }
    
    p += sprintf(p, "]);"
        "    ws.send(data);"
        "  }"
        "})();");
    
    emscripten_run_script(script);
    free(script);
}

static void web_ws_send_unreliable_impl(colyseus_transport_t* transport, const uint8_t* data, size_t length) {
    (void)transport;
    (void)data;
    (void)length;
    printf("[WebSocket] Unreliable messages not supported on web\n");
}

static void web_ws_close_impl(colyseus_transport_t* transport, int code, const char* reason) {
    colyseus_web_transport_data_t* data = (colyseus_web_transport_data_t*)transport->impl_data;

    if (data->socket_id >= 0) {
        char* escaped_reason = escape_string_for_js(reason ? reason : "");
        
        char script[512];
        snprintf(script, sizeof(script),
            "(function() {"
            "  var ws = Module._colyseusWs.sockets[%d];"
            "  if (ws) ws.close(%d, %s);"
            "})();",
            data->socket_id,
            code,
            escaped_reason
        );
        
        emscripten_run_script(script);
        free(escaped_reason);
        
        data->socket_id = -1;
    }
    data->is_open = false;
}

static bool web_ws_is_open_impl(const colyseus_transport_t* transport) {
    colyseus_web_transport_data_t* data = (colyseus_web_transport_data_t*)transport->impl_data;
    return data->is_open;
}

static void web_ws_destroy_impl(colyseus_transport_t* transport) {
    if (!transport) return;

    unregister_transport(transport);
    
    colyseus_web_transport_data_t* data = (colyseus_web_transport_data_t*)transport->impl_data;
    if (data) {
        if (data->socket_id >= 0) {
            char script[256];
            snprintf(script, sizeof(script),
                "(function() {"
                "  var ws = Module._colyseusWs.sockets[%d];"
                "  if (ws) {"
                "    ws.close(1000, \"\");"
                "    delete Module._colyseusWs.sockets[%d];"
                "    delete Module._colyseusWs.events[%d];"
                "  }"
                "})();",
                data->socket_id,
                data->socket_id,
                data->socket_id
            );
            emscripten_run_script(script);
        }
        free(data);
    }
    free(transport);
}

// ============================================================================
// Standalone WASM (Raylib) - Uses emscripten_websocket with direct callbacks
// ============================================================================
#else

#include <emscripten/websocket.h>

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

static EM_BOOL on_ws_open(int eventType, const EmscriptenWebSocketOpenEvent* event, void* userData) {
    (void)eventType;
    (void)event;
    colyseus_transport_t* transport = (colyseus_transport_t*)userData;
    colyseus_web_transport_data_t* data = (colyseus_web_transport_data_t*)transport->impl_data;
    
    printf("[WebSocket] Connected!\n");
    data->is_open = true;
    
    if (transport->events.on_open) {
        transport->events.on_open(transport->events.userdata);
    }
    return EM_TRUE;
}

static EM_BOOL on_ws_message(int eventType, const EmscriptenWebSocketMessageEvent* event, void* userData) {
    (void)eventType;
    colyseus_transport_t* transport = (colyseus_transport_t*)userData;
    
    if (event->isText) {
        return EM_TRUE;
    }
    
    if (transport->events.on_message) {
        transport->events.on_message(event->data, event->numBytes, transport->events.userdata);
    }
    return EM_TRUE;
}

static EM_BOOL on_ws_error(int eventType, const EmscriptenWebSocketErrorEvent* event, void* userData) {
    (void)eventType;
    (void)event;
    colyseus_transport_t* transport = (colyseus_transport_t*)userData;
    
    printf("[WebSocket] Error\n");
    
    if (transport->events.on_error) {
        transport->events.on_error("WebSocket error", transport->events.userdata);
    }
    return EM_TRUE;
}

static EM_BOOL on_ws_close(int eventType, const EmscriptenWebSocketCloseEvent* event, void* userData) {
    (void)eventType;
    colyseus_transport_t* transport = (colyseus_transport_t*)userData;
    colyseus_web_transport_data_t* data = (colyseus_web_transport_data_t*)transport->impl_data;
    
    printf("[WebSocket] Closed: code=%d\n", event->code);
    data->is_open = false;
    
    if (transport->events.on_close) {
        transport->events.on_close(event->code, event->reason, transport->events.userdata);
    }
    return EM_TRUE;
}

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

    transport->impl_data = data;

    return transport;
}

static void web_ws_connect_impl(colyseus_transport_t* transport, const char* url) {
    colyseus_web_transport_data_t* data = (colyseus_web_transport_data_t*)transport->impl_data;

    printf("[WebSocket] Connecting to: %s\n", url);

    EmscriptenWebSocketCreateAttributes attr;
    emscripten_websocket_init_create_attributes(&attr);
    attr.url = url;
    attr.protocols = NULL;
    attr.createOnMainThread = EM_TRUE;

    EMSCRIPTEN_WEBSOCKET_T socket = emscripten_websocket_new(&attr);
    if (socket <= 0) {
        printf("[WebSocket] Failed to create socket\n");
        if (transport->events.on_error) {
            transport->events.on_error("Failed to create WebSocket", transport->events.userdata);
        }
        return;
    }

    data->socket = socket;

    emscripten_websocket_set_onopen_callback(socket, transport, on_ws_open);
    emscripten_websocket_set_onmessage_callback(socket, transport, on_ws_message);
    emscripten_websocket_set_onerror_callback(socket, transport, on_ws_error);
    emscripten_websocket_set_onclose_callback(socket, transport, on_ws_close);
}

static void web_ws_send_impl(colyseus_transport_t* transport, const uint8_t* msg_data, size_t length) {
    colyseus_web_transport_data_t* data = (colyseus_web_transport_data_t*)transport->impl_data;

    if (!data->is_open || data->socket <= 0) {
        return;
    }

    emscripten_websocket_send_binary(data->socket, (void*)msg_data, length);
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

#endif /* GDEXTENSION_SIDE_MODULE */

/* Web stub: browser handles TLS natively, so settings are ignored */
void colyseus_websocket_connect_with_settings(colyseus_transport_t* transport,
                                               const char* url,
                                               const colyseus_settings_t* settings) {
    (void)settings;
    colyseus_transport_connect(transport, url);
}

#endif /* __EMSCRIPTEN__ */
