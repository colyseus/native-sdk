// Shared internals of the GameMaker bridge — split from gamemaker_export.c so
// sibling translation units (gamemaker_predict.c) can push events and resolve
// room refs. NOT part of the GML-facing API.
#ifndef GAMEMAKER_INTERNAL_H
#define GAMEMAKER_INTERNAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#endif

// Export macro for GameMaker DLL functions
#ifndef GM_EXPORT
#ifdef __EMSCRIPTEN__
#define GM_EXPORT EMSCRIPTEN_KEEPALIVE
#elif defined(_WIN32)
#define GM_EXPORT __declspec(dllexport)
#else
#define GM_EXPORT __attribute__((visibility("default")))
#endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

struct colyseus_room;

// Event types for GameMaker polling
typedef enum {
    GM_EVENT_NONE = 0,
    GM_EVENT_ROOM_JOIN = 1,
    GM_EVENT_ROOM_STATE_CHANGE = 2,
    GM_EVENT_ROOM_MESSAGE = 3,
    GM_EVENT_ROOM_ERROR = 4,
    GM_EVENT_ROOM_LEAVE = 5,
    GM_EVENT_CLIENT_ERROR = 6,
    GM_EVENT_PROPERTY_CHANGE = 7,
    GM_EVENT_ITEM_ADD = 8,
    GM_EVENT_ITEM_REMOVE = 9,
    GM_EVENT_HTTP_RESPONSE = 10,
    GM_EVENT_HTTP_ERROR = 11,
    GM_EVENT_INSTANCE_CHANGE = 12,
    GM_EVENT_COLLECTION_CHANGE = 13,
    GM_EVENT_ROOM_DROP = 14,
    GM_EVENT_ROOM_RECONNECT = 15,
    GM_EVENT_LATENCY_RESPONSE = 16,  // get_latency success
    GM_EVENT_LATENCY_ERROR = 17,     // get_latency failure
    GM_EVENT_LATENCY_SELECTED = 18,  // select_by_latency complete
    // predict layer: an event channel entry settled — `code` is the kind
    // (0 predict, 1 confirm, 2 reject, 3 unpredicted), `callback_handle` the
    // channel id, `message` the key
    GM_EVENT_PREDICT_SETTLE = 19,
    // predict layer: a pending spawn was rejected (TTL) — `callback_handle`
    // the spawns id, `code` the spawn id
    GM_EVENT_SPAWN_REJECT = 20,
} gm_event_type_t;

// Event structure for the queue
typedef struct {
    gm_event_type_t type;
    double room_handle;  // Room pointer as double (for GameMaker)
    double callback_handle;  // Shared across schema & HTTP & latency (request id) events
    int code;
    double latency_ms;   // latency events: measured / best round-trip ms
    char message[1024];

    union {
        // Message events (type 3)
        struct {
            uint8_t data[8192];
            size_t data_length;
        } msg;

        // Schema callback events (types 7, 8, 9)
        struct {
            double instance_handle;
            int value_type;
            double value_number;
            double prev_value_number;
            char value_string[1024];
            char prev_value_string[1024];
            char key_string[256];
            int key_index;
        } schema;

        // HTTP response/error events (types 10, 11)
        struct {
            char* body;  // dynamically allocated, freed on next poll
        } http;
    };
} gm_event_t;

#define GM_MAX_ROOM_REFS 16

// implemented in gamemaker_export.c
void gm_event_queue_push(const gm_event_t* event);
struct colyseus_room* gm_room_ref_get(int ref);

// Flatten one decoded field into the GML-facing event slots. Every out-param is
// optional — the previous-value snapshot has no instance slot to write into.
// Reachable from GML only through a live room, so it carries its own test.
void gm_snapshot_value(int value_type, void* value,
    double* out_number, char* out_string, size_t out_string_size,
    double* out_instance);

// implemented in gamemaker_predict.c: free every predict-layer object bound
// to this room ref (reconcilers, spawns, event channels, predicts). Runs
// BEFORE colyseus_room_free — the objects deregister from room-owned layers.
void gm_predict_room_released(int room_ref);

#ifdef __cplusplus
}
#endif

#endif /* GAMEMAKER_INTERNAL_H */
