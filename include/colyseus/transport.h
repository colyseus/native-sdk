#ifndef COLYSEUS_TRANSPORT_H
#define COLYSEUS_TRANSPORT_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Forward declaration */
typedef struct colyseus_transport colyseus_transport_t;

/* Transport event callbacks */
typedef void (*colyseus_transport_on_open_fn)(void* userdata);
typedef void (*colyseus_transport_on_message_fn)(const uint8_t* data, size_t length, void* userdata);
typedef void (*colyseus_transport_on_close_fn)(int code, const char* reason, void* userdata);
typedef void (*colyseus_transport_on_error_fn)(const char* error, void* userdata);

/* Transport events structure */
typedef struct {
    colyseus_transport_on_open_fn on_open;
    colyseus_transport_on_message_fn on_message;
    colyseus_transport_on_close_fn on_close;
    colyseus_transport_on_error_fn on_error;
    void* userdata;  /* User data passed to all callbacks */
} colyseus_transport_events_t;

/* Transport interface (vtable pattern) */
struct colyseus_transport {
    /* Function pointers (vtable) */
    void (*connect)(colyseus_transport_t* transport, const char* url);
    void (*send)(colyseus_transport_t* transport, const uint8_t* data, size_t length);
    void (*send_unreliable)(colyseus_transport_t* transport, const uint8_t* data, size_t length);
    void (*close)(colyseus_transport_t* transport, int code, const char* reason);
    bool (*is_open)(const colyseus_transport_t* transport);
    void (*destroy)(colyseus_transport_t* transport);

    /* Events */
    colyseus_transport_events_t events;

    /* Implementation-specific data */
    void* impl_data;
};

/* Transport interface functions (call through vtable) */
static inline void colyseus_transport_connect(colyseus_transport_t* transport, const char* url) {
    if (transport && transport->connect) {
        transport->connect(transport, url);
    }
}

static inline void colyseus_transport_send(colyseus_transport_t* transport, const uint8_t* data, size_t length) {
    if (transport && transport->send) {
        transport->send(transport, data, length);
    }
}

static inline void colyseus_transport_send_unreliable(colyseus_transport_t* transport, const uint8_t* data, size_t length) {
    if (transport && transport->send_unreliable) {
        transport->send_unreliable(transport, data, length);
    }
}

static inline void colyseus_transport_close(colyseus_transport_t* transport, int code, const char* reason) {
    if (transport && transport->close) {
        transport->close(transport, code, reason);
    }
}

static inline bool colyseus_transport_is_open(const colyseus_transport_t* transport) {
    if (transport && transport->is_open) {
        return transport->is_open(transport);
    }
    return false;
}

static inline void colyseus_transport_destroy(colyseus_transport_t* transport) {
    if (transport && transport->destroy) {
        transport->destroy(transport);
    }
}

/* Transport factory function pointer type */
typedef colyseus_transport_t* (*colyseus_transport_factory_fn)(const colyseus_transport_events_t* events);

/* WebSocket transport factory */
colyseus_transport_t* colyseus_websocket_transport_create(const colyseus_transport_events_t* events);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_TRANSPORT_H */