#include "../../../include/colyseus/client.h"
#include "../../../include/colyseus/room.h"
#include "../../../include/colyseus/settings.h"
#include "../../../include/colyseus/schema.h"
#include "../../../include/colyseus/schema/callbacks.h"
#include "../../../include/colyseus/schema/dynamic_schema.h"
#include "../../../include/colyseus/schema/collections.h"
#include "../../../include/colyseus/messages.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#elif defined(_WIN32)
#include <windows.h>
#else
#include <pthread.h>
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

// Maximum number of events in the queue
#define MAX_EVENT_QUEUE_SIZE 1024

// Maximum number of callback entries
#define MAX_GM_CALLBACK_ENTRIES 256

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
} gm_event_type_t;

// Event structure for the queue
typedef struct {
    gm_event_type_t type;
    double room_handle;  // Room pointer as double (for GameMaker)
    int code;
    char message[1024];

    union {
        // Message events (type 3)
        struct {
            uint8_t data[8192];
            size_t data_length;
        } msg;

        // Schema callback events (types 7, 8, 9)
        struct {
            double callback_handle;
            double instance_handle;
            int value_type;
            double value_number;
            double prev_value_number;
            char value_string[1024];
            char prev_value_string[1024];
            char key_string[256];
            int key_index;
        } schema;
    };
} gm_event_t;

// Event queue (circular buffer, thread-safe)
typedef struct {
    gm_event_t events[MAX_EVENT_QUEUE_SIZE];
    int head;
    int tail;
    int count;
} gm_event_queue_t;

// Callback entry — stored globally, pointer passed as userdata to trampolines
typedef struct {
    bool active;
    int index;
    double room_handle;
    int value_type;      // colyseus_field_type_t
    int callback_type;   // 0=listen, 1=on_add, 2=on_remove
    colyseus_callback_handle_t native_handle;
} gm_callback_entry_t;

// Callbacks wrapper — ties native callbacks manager to its room
typedef struct {
    colyseus_callbacks_t* native;
    colyseus_room_t* room;
    int room_ref;
} gm_callbacks_wrapper_t;

// Room reference table — maps small integer refs to room pointers
#define MAX_ROOM_REFS 16
#define MAX_CALLBACKS_PER_ROOM 4

typedef struct {
    colyseus_room_t* room;
    bool in_use;
    gm_callbacks_wrapper_t* callbacks[MAX_CALLBACKS_PER_ROOM];
    int callbacks_count;
} gm_room_ref_t;

static gm_room_ref_t g_room_refs[MAX_ROOM_REFS] = {0};

// Global event queue
static gm_event_queue_t g_event_queue = {0};

// Event queue mutex (background WS thread pushes, main GML thread pops)
#ifdef __EMSCRIPTEN__
    /* No mutex needed — single-threaded */
#elif defined(_WIN32)
static SRWLOCK g_event_queue_lock = SRWLOCK_INIT;
#else
static pthread_mutex_t g_event_queue_lock = PTHREAD_MUTEX_INITIALIZER;
#endif

// Current event (for event accessors)
static gm_event_t g_current_event = {0};

// Current message reader (lazy-created when a MESSAGE event is polled)
static colyseus_message_reader_t* g_current_message_reader = NULL;

// Map iterator state (for stepping through map entries from GML)
static colyseus_message_map_iterator_t g_current_map_iterator = {0};
static colyseus_message_reader_t* g_current_iter_key = NULL;
static colyseus_message_reader_t* g_current_iter_value = NULL;

// Global callback entry table
static gm_callback_entry_t g_callback_entries[MAX_GM_CALLBACK_ENTRIES] = {0};

// =============================================================================
// Room reference helpers
// =============================================================================

static int gm_room_ref_alloc(void) {
    for (int i = 0; i < MAX_ROOM_REFS; i++) {
        if (!g_room_refs[i].in_use) {
            g_room_refs[i].in_use = true;
            g_room_refs[i].room = NULL;
            g_room_refs[i].callbacks_count = 0;
            memset(g_room_refs[i].callbacks, 0, sizeof(g_room_refs[i].callbacks));
            return i + 1;  // 1-based, 0 = invalid
        }
    }
    return 0;
}

static colyseus_room_t* gm_room_ref_get(int ref) {
    if (ref < 1 || ref > MAX_ROOM_REFS) return NULL;
    return g_room_refs[ref - 1].room;
}

static void gm_room_ref_set(int ref, colyseus_room_t* room) {
    if (ref >= 1 && ref <= MAX_ROOM_REFS) {
        g_room_refs[ref - 1].room = room;
    }
}

// Free a callbacks wrapper and deactivate its callback entries
static void gm_callbacks_wrapper_free(gm_callbacks_wrapper_t* wrapper) {
    if (!wrapper) return;

    // Deactivate only callback entries belonging to this wrapper's room
    int room_ref = wrapper->room_ref;
    for (int i = 0; i < MAX_GM_CALLBACK_ENTRIES; i++) {
        if (g_callback_entries[i].active &&
            (int)g_callback_entries[i].room_handle == room_ref) {
            g_callback_entries[i].active = false;
        }
    }

    if (wrapper->native) {
        colyseus_callbacks_free(wrapper->native);
    }
    free(wrapper);
}

// Register a callbacks wrapper with its room ref
static void gm_room_ref_add_callbacks(int ref, gm_callbacks_wrapper_t* wrapper) {
    if (ref < 1 || ref > MAX_ROOM_REFS) return;
    gm_room_ref_t* entry = &g_room_refs[ref - 1];
    if (entry->callbacks_count < MAX_CALLBACKS_PER_ROOM) {
        entry->callbacks[entry->callbacks_count++] = wrapper;
    }
}

// Unregister a callbacks wrapper from its room ref (without freeing)
static void gm_room_ref_remove_callbacks(int ref, gm_callbacks_wrapper_t* wrapper) {
    if (ref < 1 || ref > MAX_ROOM_REFS) return;
    gm_room_ref_t* entry = &g_room_refs[ref - 1];
    for (int i = 0; i < entry->callbacks_count; i++) {
        if (entry->callbacks[i] == wrapper) {
            // Shift remaining entries
            for (int j = i; j < entry->callbacks_count - 1; j++) {
                entry->callbacks[j] = entry->callbacks[j + 1];
            }
            entry->callbacks_count--;
            entry->callbacks[entry->callbacks_count] = NULL;
            return;
        }
    }
}

static void gm_room_ref_release(int ref) {
    if (ref >= 1 && ref <= MAX_ROOM_REFS) {
        gm_room_ref_t* entry = &g_room_refs[ref - 1];

        // Auto-free all callbacks associated with this room
        for (int i = 0; i < entry->callbacks_count; i++) {
            gm_callbacks_wrapper_free(entry->callbacks[i]);
            entry->callbacks[i] = NULL;
        }
        entry->callbacks_count = 0;

        entry->room = NULL;
        entry->in_use = false;
    }
}

// =============================================================================
// Event queue functions (thread-safe via mutex)
// =============================================================================

static void event_queue_lock(void) {
#ifdef __EMSCRIPTEN__
    /* no-op */
#elif defined(_WIN32)
    AcquireSRWLockExclusive(&g_event_queue_lock);
#else
    pthread_mutex_lock(&g_event_queue_lock);
#endif
}

static void event_queue_unlock(void) {
#ifdef __EMSCRIPTEN__
    /* no-op */
#elif defined(_WIN32)
    ReleaseSRWLockExclusive(&g_event_queue_lock);
#else
    pthread_mutex_unlock(&g_event_queue_lock);
#endif
}

static void event_queue_push(const gm_event_t* event) {
    event_queue_lock();

    if (g_event_queue.count >= MAX_EVENT_QUEUE_SIZE) {
        // Queue is full, drop oldest event
        g_event_queue.head = (g_event_queue.head + 1) % MAX_EVENT_QUEUE_SIZE;
        g_event_queue.count--;
    }

    g_event_queue.events[g_event_queue.tail] = *event;
    g_event_queue.tail = (g_event_queue.tail + 1) % MAX_EVENT_QUEUE_SIZE;
    g_event_queue.count++;

    event_queue_unlock();
}

static int event_queue_pop(gm_event_t* event) {
    event_queue_lock();

    if (g_event_queue.count == 0) {
        event_queue_unlock();
        return 0;  // Queue is empty
    }

    *event = g_event_queue.events[g_event_queue.head];
    g_event_queue.head = (g_event_queue.head + 1) % MAX_EVENT_QUEUE_SIZE;
    g_event_queue.count--;

    event_queue_unlock();
    return 1;
}

// =============================================================================
// Callback entry helpers
// =============================================================================

static gm_callback_entry_t* gm_find_free_callback_entry(void) {
    for (int i = 0; i < MAX_GM_CALLBACK_ENTRIES; i++) {
        if (!g_callback_entries[i].active) {
            memset(&g_callback_entries[i], 0, sizeof(gm_callback_entry_t));
            g_callback_entries[i].index = i;
            return &g_callback_entries[i];
        }
    }
    return NULL;
}

// Resolve field type from schema vtable (dynamic or static)
static void gm_resolve_field_type(void* instance, const char* property, gm_callback_entry_t* entry) {
    colyseus_schema_t* schema = (colyseus_schema_t*)instance;
    if (!schema || !schema->__vtable) return;

    if (colyseus_vtable_is_dynamic(schema->__vtable)) {
        const colyseus_dynamic_vtable_t* dyn = colyseus_vtable_as_dynamic(schema->__vtable);
        if (dyn) {
            const colyseus_dynamic_field_t* field =
                colyseus_dynamic_vtable_find_field_by_name(dyn, property);
            if (field) {
                entry->value_type = field->type;
            }
        }
    } else {
        for (int i = 0; i < schema->__vtable->field_count; i++) {
            if (schema->__vtable->fields[i].name &&
                strcmp(schema->__vtable->fields[i].name, property) == 0) {
                entry->value_type = schema->__vtable->fields[i].type;
                break;
            }
        }
    }
}

// =============================================================================
// Schema callback trampolines — push events to queue
// =============================================================================

// Snapshot a value into the event struct based on field type
static void gm_snapshot_value(int value_type, void* value,
    double* out_number, char* out_string, size_t out_string_size,
    double* out_instance)
{
    if (!value) return;

    switch (value_type) {
        case COLYSEUS_FIELD_STRING:
            strncpy(out_string, (const char*)value, out_string_size - 1);
            break;
        case COLYSEUS_FIELD_NUMBER:
        case COLYSEUS_FIELD_FLOAT64:
            *out_number = *(double*)value;
            break;
        case COLYSEUS_FIELD_FLOAT32:
            *out_number = (double)*(float*)value;
            break;
        case COLYSEUS_FIELD_BOOLEAN:
            *out_number = *(bool*)value ? 1.0 : 0.0;
            break;
        case COLYSEUS_FIELD_INT8:
            *out_number = (double)*(int8_t*)value;
            break;
        case COLYSEUS_FIELD_UINT8:
            *out_number = (double)*(uint8_t*)value;
            break;
        case COLYSEUS_FIELD_INT16:
            *out_number = (double)*(int16_t*)value;
            break;
        case COLYSEUS_FIELD_UINT16:
            *out_number = (double)*(uint16_t*)value;
            break;
        case COLYSEUS_FIELD_INT32:
            *out_number = (double)*(int32_t*)value;
            break;
        case COLYSEUS_FIELD_UINT32:
            *out_number = (double)*(uint32_t*)value;
            break;
        case COLYSEUS_FIELD_INT64:
            *out_number = (double)*(int64_t*)value;
            break;
        case COLYSEUS_FIELD_UINT64:
            *out_number = (double)*(uint64_t*)value;
            break;
        case COLYSEUS_FIELD_REF:
            *out_instance = (double)(uintptr_t)value;
            break;
        default:
            break;
    }
}

static void gm_property_change_trampoline(void* value, void* previous_value, void* userdata) {
    gm_callback_entry_t* entry = (gm_callback_entry_t*)userdata;
    if (!entry || !entry->active) return;

    gm_event_t event = {0};
    event.type = GM_EVENT_PROPERTY_CHANGE;
    event.room_handle = entry->room_handle;
    event.schema.callback_handle = (double)entry->index;
    event.schema.value_type = entry->value_type;

    gm_snapshot_value(entry->value_type, value,
        &event.schema.value_number, event.schema.value_string,
        sizeof(event.schema.value_string), &event.schema.instance_handle);

    gm_snapshot_value(entry->value_type, previous_value,
        &event.schema.prev_value_number, event.schema.prev_value_string,
        sizeof(event.schema.prev_value_string), NULL);

    event_queue_push(&event);
}

static void gm_item_add_trampoline(void* value, void* key, void* userdata) {
    gm_callback_entry_t* entry = (gm_callback_entry_t*)userdata;
    if (!entry || !entry->active) return;

    gm_event_t event = {0};
    event.type = GM_EVENT_ITEM_ADD;
    event.room_handle = entry->room_handle;
    event.schema.callback_handle = (double)entry->index;
    event.schema.value_type = entry->value_type;

    if (value) {
        event.schema.instance_handle = (double)(uintptr_t)value;
    }

    if (key) {
        // MAP keys are char*, ARRAY keys are int*
        if (entry->value_type == COLYSEUS_FIELD_ARRAY) {
            event.schema.key_index = *(int*)key;
        } else {
            strncpy(event.schema.key_string, (const char*)key,
                    sizeof(event.schema.key_string) - 1);
        }
    }

    event_queue_push(&event);
}

static void gm_item_remove_trampoline(void* value, void* key, void* userdata) {
    gm_callback_entry_t* entry = (gm_callback_entry_t*)userdata;
    if (!entry || !entry->active) return;

    gm_event_t event = {0};
    event.type = GM_EVENT_ITEM_REMOVE;
    event.room_handle = entry->room_handle;
    event.schema.callback_handle = (double)entry->index;
    event.schema.value_type = entry->value_type;

    if (value) {
        event.schema.instance_handle = (double)(uintptr_t)value;
    }

    if (key) {
        if (entry->value_type == COLYSEUS_FIELD_ARRAY) {
            event.schema.key_index = *(int*)key;
        } else {
            strncpy(event.schema.key_string, (const char*)key,
                    sizeof(event.schema.key_string) - 1);
        }
    }

    event_queue_push(&event);
}

// =============================================================================
// Room event callback adapters — push events to queue
// =============================================================================

static void on_room_join(void* userdata) {
    int ref = (int)(intptr_t)userdata;
    gm_event_t event = {0};
    event.type = GM_EVENT_ROOM_JOIN;
    event.room_handle = (double)ref;
    event_queue_push(&event);
}

static void on_room_state_change(void* userdata) {
    int ref = (int)(intptr_t)userdata;
    gm_event_t event = {0};
    event.type = GM_EVENT_ROOM_STATE_CHANGE;
    event.room_handle = (double)ref;
    event_queue_push(&event);
}

static void on_room_message_with_type_encoded(const char* type, const uint8_t* data, size_t length, void* userdata) {
    int ref = (int)(intptr_t)userdata;
    gm_event_t event = {0};
    event.type = GM_EVENT_ROOM_MESSAGE;
    event.room_handle = (double)ref;
    strncpy(event.message, type ? type : "", sizeof(event.message) - 1);
    event.msg.data_length = length < sizeof(event.msg.data) ? length : sizeof(event.msg.data);
    memcpy(event.msg.data, data, event.msg.data_length);
    event_queue_push(&event);
}

static void on_room_error(int code, const char* message, void* userdata) {
    int ref = (int)(intptr_t)userdata;
    gm_event_t event = {0};
    event.type = GM_EVENT_ROOM_ERROR;
    event.room_handle = (double)ref;
    event.code = code;
    strncpy(event.message, message ? message : "", sizeof(event.message) - 1);
    event_queue_push(&event);
}

static void on_room_leave(int code, const char* reason, void* userdata) {
    int ref = (int)(intptr_t)userdata;
    gm_event_t event = {0};
    event.type = GM_EVENT_ROOM_LEAVE;
    event.room_handle = (double)ref;
    event.code = code;
    strncpy(event.message, reason ? reason : "", sizeof(event.message) - 1);
    event_queue_push(&event);
}

static void on_client_room_success(colyseus_room_t* room, void* userdata) {
    int ref = (int)(intptr_t)userdata;
    gm_room_ref_set(ref, room);

    // Set up room callbacks — pass ref as userdata
    void* ref_as_ptr = (void*)(intptr_t)ref;
    colyseus_room_on_join(room, on_room_join, ref_as_ptr);
    colyseus_room_on_state_change(room, on_room_state_change, ref_as_ptr);
    colyseus_room_on_message_any_with_type_encoded(room, on_room_message_with_type_encoded, ref_as_ptr);
    colyseus_room_on_error(room, on_room_error, ref_as_ptr);
    colyseus_room_on_leave(room, on_room_leave, ref_as_ptr);
}

static void on_client_error(int code, const char* message, void* userdata) {
    int ref = (int)(intptr_t)userdata;
    gm_event_t event = {0};
    event.type = GM_EVENT_CLIENT_ERROR;
    event.room_handle = (double)ref;
    event.code = code;
    strncpy(event.message, message ? message : "", sizeof(event.message) - 1);
    event_queue_push(&event);

    // Release the room ref slot on error
    gm_room_ref_release(ref);
}

// =============================================================================
// GameMaker Exported Functions — Module readiness
// =============================================================================

GM_EXPORT double colyseus_gm_is_ready(void) {
    // Native builds are always ready (no async WASM init).
    // On HTML5/WASM, the JS shim overrides this with a check on module init state.
    return 1.0;
}

// =============================================================================
// GameMaker Exported Functions — Client
// =============================================================================

GM_EXPORT double colyseus_gm_client_create(const char* endpoint) {
    colyseus_settings_t* settings = colyseus_settings_create();
    if (!settings) {
        return 0.0;
    }

    // Parse endpoint URL: "http://host:port", "ws://host:port", etc.
    const char* url = endpoint;
    bool secure = false;

    // Detect and strip protocol prefix
    if (strncmp(url, "https://", 8) == 0 || strncmp(url, "wss://", 6) == 0) {
        secure = true;
        url = strchr(url, '/') + 2;  // skip "://"
    } else if (strncmp(url, "http://", 7) == 0 || strncmp(url, "ws://", 5) == 0) {
        secure = false;
        url = strchr(url, '/') + 2;  // skip "://"
    }

    // Now url points to "host:port" or "host"
    char* host_port = strdup(url);

    // Strip trailing slash if present
    size_t len = strlen(host_port);
    if (len > 0 && host_port[len - 1] == '/') {
        host_port[len - 1] = '\0';
    }

    // Split host and port (find LAST colon to handle IPv6)
    char* colon = strrchr(host_port, ':');

    colyseus_settings_set_secure(settings, secure);

    if (colon) {
        *colon = '\0';
        colyseus_settings_set_address(settings, host_port);
        colyseus_settings_set_port(settings, colon + 1);
    } else {
        colyseus_settings_set_address(settings, host_port);
        colyseus_settings_set_port(settings, secure ? "443" : "80");
    }

    free(host_port);

    colyseus_client_t* client = colyseus_client_create(settings);
    if (!client) {
        colyseus_settings_free(settings);
        return 0.0;
    }

    return (double)(uintptr_t)client;
}

GM_EXPORT void colyseus_gm_client_free(double client_handle) {
    colyseus_client_t* client = (colyseus_client_t*)(uintptr_t)client_handle;
    if (client) {
        colyseus_client_free(client);
    }
}

GM_EXPORT double colyseus_gm_client_join_or_create(double client_handle, const char* room_name, const char* options_json) {
    colyseus_client_t* client = (colyseus_client_t*)(uintptr_t)client_handle;
    if (!client) {
        return 0.0;
    }

    int ref = gm_room_ref_alloc();
    if (ref == 0) return 0.0;

    const char* options = (options_json && strlen(options_json) > 0) ? options_json : "{}";

    colyseus_client_join_or_create(
        client,
        room_name,
        options,
        on_client_room_success,
        on_client_error,
        (void*)(intptr_t)ref
    );

    return (double)ref;
}

GM_EXPORT double colyseus_gm_client_create_room(double client_handle, const char* room_name, const char* options_json) {
    colyseus_client_t* client = (colyseus_client_t*)(uintptr_t)client_handle;
    if (!client) {
        return 0.0;
    }

    int ref = gm_room_ref_alloc();
    if (ref == 0) return 0.0;

    const char* options = (options_json && strlen(options_json) > 0) ? options_json : "{}";

    colyseus_client_create_room(
        client,
        room_name,
        options,
        on_client_room_success,
        on_client_error,
        (void*)(intptr_t)ref
    );

    return (double)ref;
}

GM_EXPORT double colyseus_gm_client_join(double client_handle, const char* room_name, const char* options_json) {
    colyseus_client_t* client = (colyseus_client_t*)(uintptr_t)client_handle;
    if (!client) {
        return 0.0;
    }

    int ref = gm_room_ref_alloc();
    if (ref == 0) return 0.0;

    const char* options = (options_json && strlen(options_json) > 0) ? options_json : "{}";

    colyseus_client_join(
        client,
        room_name,
        options,
        on_client_room_success,
        on_client_error,
        (void*)(intptr_t)ref
    );

    return (double)ref;
}

GM_EXPORT double colyseus_gm_client_join_by_id(double client_handle, const char* room_id, const char* options_json) {
    colyseus_client_t* client = (colyseus_client_t*)(uintptr_t)client_handle;
    if (!client) {
        return 0.0;
    }

    int ref = gm_room_ref_alloc();
    if (ref == 0) return 0.0;

    const char* options = (options_json && strlen(options_json) > 0) ? options_json : "{}";

    colyseus_client_join_by_id(
        client,
        room_id,
        options,
        on_client_room_success,
        on_client_error,
        (void*)(intptr_t)ref
    );

    return (double)ref;
}

GM_EXPORT double colyseus_gm_client_reconnect(double client_handle, const char* reconnection_token) {
    colyseus_client_t* client = (colyseus_client_t*)(uintptr_t)client_handle;
    if (!client) {
        return 0.0;
    }

    int ref = gm_room_ref_alloc();
    if (ref == 0) return 0.0;

    colyseus_client_reconnect(
        client,
        reconnection_token,
        on_client_room_success,
        on_client_error,
        (void*)(intptr_t)ref
    );

    return (double)ref;
}

// =============================================================================
// GameMaker Exported Functions — Room
// =============================================================================

GM_EXPORT void colyseus_gm_room_leave(double room_handle) {
    colyseus_room_t* room = gm_room_ref_get((int)room_handle);
    if (room) {
        colyseus_room_leave(room, true);
    }
}

GM_EXPORT void colyseus_gm_room_free(double room_handle) {
    colyseus_room_t* room = gm_room_ref_get((int)room_handle);
    if (room) {
        colyseus_room_free(room);
    }
    gm_room_ref_release((int)room_handle);
}

GM_EXPORT void colyseus_gm_room_send(double room_handle, const char* type, const char* data) {
    colyseus_room_t* room = gm_room_ref_get((int)room_handle);
    if (room && data) {
        colyseus_room_send_encoded(room, type, (const uint8_t*)data, strlen(data));
    }
}

GM_EXPORT void colyseus_gm_room_send_bytes(double room_handle, const char* type, const uint8_t* data, double length) {
    colyseus_room_t* room = gm_room_ref_get((int)room_handle);
    if (room && data) {
        colyseus_room_send_bytes(room, type, data, (size_t)length);
    }
}

GM_EXPORT void colyseus_gm_room_send_int(double room_handle, double type, const char* data) {
    colyseus_room_t* room = gm_room_ref_get((int)room_handle);
    if (room && data) {
        colyseus_room_send_int_encoded(room, (int)type, (const uint8_t*)data, strlen(data));
    }
}

GM_EXPORT const char* colyseus_gm_room_get_id(double room_handle) {
    colyseus_room_t* room = gm_room_ref_get((int)room_handle);
    if (room) {
        const char* id = colyseus_room_get_id(room);
        return id ? id : "";
    }
    return "";
}

GM_EXPORT const char* colyseus_gm_room_get_session_id(double room_handle) {
    colyseus_room_t* room = gm_room_ref_get((int)room_handle);
    if (room) {
        const char* id = colyseus_room_get_session_id(room);
        return id ? id : "";
    }
    return "";
}

GM_EXPORT const char* colyseus_gm_room_get_name(double room_handle) {
    colyseus_room_t* room = gm_room_ref_get((int)room_handle);
    if (room) {
        const char* name = colyseus_room_get_name(room);
        return name ? name : "";
    }
    return "";
}

GM_EXPORT double colyseus_gm_room_is_connected(double room_handle) {
    colyseus_room_t* room = gm_room_ref_get((int)room_handle);
    if (room) {
        return colyseus_room_is_connected(room) ? 1.0 : 0.0;
    }
    return 0.0;
}

// =============================================================================
// GameMaker Exported Functions — State Access
// =============================================================================

GM_EXPORT double colyseus_gm_room_get_state(double room_handle) {
    colyseus_room_t* room = gm_room_ref_get((int)room_handle);
    if (!room) return 0.0;
    void* state = colyseus_room_get_state(room);
    return (double)(uintptr_t)state;
}

GM_EXPORT const char* colyseus_gm_schema_get_string(double instance_handle, const char* field_name) {
    static char buffer[4096];
    buffer[0] = '\0';

    colyseus_schema_t* schema = (colyseus_schema_t*)(uintptr_t)instance_handle;
    if (!schema || !field_name) return buffer;

    if (colyseus_vtable_is_dynamic(schema->__vtable)) {
        colyseus_dynamic_schema_t* dyn = (colyseus_dynamic_schema_t*)schema;
        colyseus_dynamic_value_t* val = colyseus_dynamic_schema_get_by_name(dyn, field_name);
        if (val && val->type == COLYSEUS_FIELD_STRING && val->data.str) {
            strncpy(buffer, val->data.str, sizeof(buffer) - 1);
        }
    } else {
        for (int i = 0; i < schema->__vtable->field_count; i++) {
            if (schema->__vtable->fields[i].name &&
                strcmp(schema->__vtable->fields[i].name, field_name) == 0) {
                if (schema->__vtable->fields[i].type == COLYSEUS_FIELD_STRING) {
                    const char* str = *(const char**)((const char*)schema +
                                      schema->__vtable->fields[i].offset);
                    if (str) strncpy(buffer, str, sizeof(buffer) - 1);
                }
                break;
            }
        }
    }
    return buffer;
}

GM_EXPORT double colyseus_gm_schema_get_field_type(double instance_handle, const char* field_name) {
    colyseus_schema_t* schema = (colyseus_schema_t*)(uintptr_t)instance_handle;
    if (!schema || !field_name) return -1.0;

    if (colyseus_vtable_is_dynamic(schema->__vtable)) {
        colyseus_dynamic_schema_t* dyn = (colyseus_dynamic_schema_t*)schema;
        colyseus_dynamic_value_t* val = colyseus_dynamic_schema_get_by_name(dyn, field_name);
        if (val) return (double)val->type;
    } else {
        for (int i = 0; i < schema->__vtable->field_count; i++) {
            if (schema->__vtable->fields[i].name &&
                strcmp(schema->__vtable->fields[i].name, field_name) == 0) {
                return (double)schema->__vtable->fields[i].type;
            }
        }
    }
    return -1.0;
}

GM_EXPORT double colyseus_gm_schema_get_number(double instance_handle, const char* field_name) {
    colyseus_schema_t* schema = (colyseus_schema_t*)(uintptr_t)instance_handle;
    if (!schema || !field_name) return 0.0;

    if (colyseus_vtable_is_dynamic(schema->__vtable)) {
        colyseus_dynamic_schema_t* dyn = (colyseus_dynamic_schema_t*)schema;
        colyseus_dynamic_value_t* val = colyseus_dynamic_schema_get_by_name(dyn, field_name);
        if (!val) return 0.0;
        switch (val->type) {
            case COLYSEUS_FIELD_NUMBER:
            case COLYSEUS_FIELD_FLOAT64: return val->data.num;
            case COLYSEUS_FIELD_FLOAT32: return (double)val->data.f32;
            case COLYSEUS_FIELD_BOOLEAN: return val->data.boolean ? 1.0 : 0.0;
            case COLYSEUS_FIELD_INT8:    return (double)val->data.i8;
            case COLYSEUS_FIELD_UINT8:   return (double)val->data.u8;
            case COLYSEUS_FIELD_INT16:   return (double)val->data.i16;
            case COLYSEUS_FIELD_UINT16:  return (double)val->data.u16;
            case COLYSEUS_FIELD_INT32:   return (double)val->data.i32;
            case COLYSEUS_FIELD_UINT32:  return (double)val->data.u32;
            case COLYSEUS_FIELD_INT64:   return (double)val->data.i64;
            case COLYSEUS_FIELD_UINT64:  return (double)val->data.u64;
            case COLYSEUS_FIELD_REF:     return val->data.ref ? (double)(uintptr_t)val->data.ref : 0.0;
            case COLYSEUS_FIELD_ARRAY:   return val->data.array ? (double)(uintptr_t)val->data.array : 0.0;
            case COLYSEUS_FIELD_MAP:     return val->data.map ? (double)(uintptr_t)val->data.map : 0.0;
            default: return 0.0;
        }
    } else {
        for (int i = 0; i < schema->__vtable->field_count; i++) {
            if (schema->__vtable->fields[i].name &&
                strcmp(schema->__vtable->fields[i].name, field_name) == 0) {
                void* ptr = (char*)schema + schema->__vtable->fields[i].offset;
                switch (schema->__vtable->fields[i].type) {
                    case COLYSEUS_FIELD_NUMBER:
                    case COLYSEUS_FIELD_FLOAT64: return *(double*)ptr;
                    case COLYSEUS_FIELD_FLOAT32: return (double)*(float*)ptr;
                    case COLYSEUS_FIELD_BOOLEAN: return *(bool*)ptr ? 1.0 : 0.0;
                    case COLYSEUS_FIELD_INT8:    return (double)*(int8_t*)ptr;
                    case COLYSEUS_FIELD_UINT8:   return (double)*(uint8_t*)ptr;
                    case COLYSEUS_FIELD_INT16:   return (double)*(int16_t*)ptr;
                    case COLYSEUS_FIELD_UINT16:  return (double)*(uint16_t*)ptr;
                    case COLYSEUS_FIELD_INT32:   return (double)*(int32_t*)ptr;
                    case COLYSEUS_FIELD_UINT32:  return (double)*(uint32_t*)ptr;
                    case COLYSEUS_FIELD_INT64:   return (double)*(int64_t*)ptr;
                    case COLYSEUS_FIELD_UINT64:  return (double)*(uint64_t*)ptr;
                    case COLYSEUS_FIELD_REF:
                    case COLYSEUS_FIELD_ARRAY:
                    case COLYSEUS_FIELD_MAP: {
                        void* ref = *(void**)ptr;
                        return ref ? (double)(uintptr_t)ref : 0.0;
                    }
                    default: return 0.0;
                }
            }
        }
    }
    return 0.0;
}

// Unified schema_get: returns the field type (or -1). Stores the result internally.
// For string fields, call colyseus_gm_schema_get_result_string() to retrieve.
// For number/ref/array/map fields, call colyseus_gm_schema_get_result_number().
static struct {
    double number;
    char string[4096];
} gm_schema_get_result = {0};

GM_EXPORT double colyseus_gm_schema_get(double instance_handle, const char* field_name) {
    gm_schema_get_result.number = 0.0;
    gm_schema_get_result.string[0] = '\0';

    colyseus_schema_t* schema = (colyseus_schema_t*)(uintptr_t)instance_handle;
    if (!schema || !field_name) return -1.0;

    double type = colyseus_gm_schema_get_field_type(instance_handle, field_name);
    if (type < 0) return -1.0;

    if ((int)type == COLYSEUS_FIELD_STRING) {
        const char* s = colyseus_gm_schema_get_string(instance_handle, field_name);
        if (s) strncpy(gm_schema_get_result.string, s, sizeof(gm_schema_get_result.string) - 1);
    } else {
        gm_schema_get_result.number = colyseus_gm_schema_get_number(instance_handle, field_name);
    }
    return type;
}

GM_EXPORT const char* colyseus_gm_schema_get_result_string(void) {
    return gm_schema_get_result.string;
}

GM_EXPORT double colyseus_gm_schema_get_result_number(void) {
    return gm_schema_get_result.number;
}

GM_EXPORT double colyseus_gm_map_get(double instance_handle, const char* field_name, const char* key) {
    colyseus_schema_t* schema = (colyseus_schema_t*)(uintptr_t)instance_handle;
    if (!schema || !field_name || !key) return 0.0;

    colyseus_map_schema_t* map = NULL;

    if (colyseus_vtable_is_dynamic(schema->__vtable)) {
        colyseus_dynamic_schema_t* dyn = (colyseus_dynamic_schema_t*)schema;
        colyseus_dynamic_value_t* val = colyseus_dynamic_schema_get_by_name(dyn, field_name);
        if (val && val->type == COLYSEUS_FIELD_MAP) {
            map = val->data.map;
        }
    } else {
        for (int i = 0; i < schema->__vtable->field_count; i++) {
            if (schema->__vtable->fields[i].name &&
                strcmp(schema->__vtable->fields[i].name, field_name) == 0 &&
                schema->__vtable->fields[i].type == COLYSEUS_FIELD_MAP) {
                map = *(colyseus_map_schema_t**)((char*)schema +
                       schema->__vtable->fields[i].offset);
                break;
            }
        }
    }

    if (!map) return 0.0;
    void* item = colyseus_map_schema_get(map, key);
    return (double)(uintptr_t)item;
}

// =============================================================================
// GameMaker Exported Functions — Callbacks
// =============================================================================

GM_EXPORT double colyseus_gm_callbacks_create(double room_handle) {
    colyseus_room_t* room = gm_room_ref_get((int)room_handle);
    if (!room || !room->serializer || !room->serializer->decoder) return 0.0;

    gm_callbacks_wrapper_t* wrapper = (gm_callbacks_wrapper_t*)calloc(1, sizeof(gm_callbacks_wrapper_t));
    if (!wrapper) return 0.0;

    wrapper->native = colyseus_callbacks_create(room->serializer->decoder);
    wrapper->room = room;
    wrapper->room_ref = (int)room_handle;

    // Track for auto-free when room is freed
    gm_room_ref_add_callbacks((int)room_handle, wrapper);

    return (double)(uintptr_t)wrapper;
}

GM_EXPORT void colyseus_gm_callbacks_free(double callbacks_handle) {
    gm_callbacks_wrapper_t* wrapper = (gm_callbacks_wrapper_t*)(uintptr_t)callbacks_handle;
    if (!wrapper) return;

    // Unregister from room ref so it won't be double-freed
    gm_room_ref_remove_callbacks(wrapper->room_ref, wrapper);

    gm_callbacks_wrapper_free(wrapper);
}

GM_EXPORT void colyseus_gm_callbacks_remove_handle(double callbacks_handle, double callback_handle) {
    gm_callbacks_wrapper_t* wrapper = (gm_callbacks_wrapper_t*)(uintptr_t)callbacks_handle;
    int idx = (int)callback_handle;
    if (!wrapper || !wrapper->native || idx < 0 || idx >= MAX_GM_CALLBACK_ENTRIES) return;

    gm_callback_entry_t* entry = &g_callback_entries[idx];
    if (!entry->active) return;

    colyseus_callbacks_remove(wrapper->native, entry->native_handle);
    entry->active = false;
}

GM_EXPORT double colyseus_gm_callbacks_listen(double callbacks_handle, double instance_handle, const char* property) {
    gm_callbacks_wrapper_t* wrapper = (gm_callbacks_wrapper_t*)(uintptr_t)callbacks_handle;
    if (!wrapper || !wrapper->native || !property) return -1.0;

    // Resolve instance: 0.0 = root state
    void* instance = NULL;
    if (instance_handle == 0.0) {
        instance = colyseus_room_get_state(wrapper->room);
    } else {
        instance = (void*)(uintptr_t)instance_handle;
    }
    if (!instance) return -1.0;

    gm_callback_entry_t* entry = gm_find_free_callback_entry();
    if (!entry) return -1.0;

    entry->active = true;
    entry->room_handle = (double)wrapper->room_ref;
    entry->callback_type = 0;  // LISTEN
    entry->value_type = COLYSEUS_FIELD_STRING;  // default

    gm_resolve_field_type(instance, property, entry);

    entry->native_handle = colyseus_callbacks_listen(
        wrapper->native,
        instance,
        property,
        gm_property_change_trampoline,
        entry,
        false  // not immediate — avoid event before GML is ready
    );

    return (double)entry->index;
}

GM_EXPORT double colyseus_gm_callbacks_on_add(double callbacks_handle, double instance_handle, const char* property) {
    gm_callbacks_wrapper_t* wrapper = (gm_callbacks_wrapper_t*)(uintptr_t)callbacks_handle;
    if (!wrapper || !wrapper->native || !property) return -1.0;

    void* instance = NULL;
    if (instance_handle == 0.0) {
        instance = colyseus_room_get_state(wrapper->room);
    } else {
        instance = (void*)(uintptr_t)instance_handle;
    }
    if (!instance) return -1.0;

    gm_callback_entry_t* entry = gm_find_free_callback_entry();
    if (!entry) return -1.0;

    entry->active = true;
    entry->room_handle = (double)wrapper->room_ref;
    entry->callback_type = 1;  // ON_ADD
    entry->value_type = COLYSEUS_FIELD_MAP;  // default for collections

    gm_resolve_field_type(instance, property, entry);

    entry->native_handle = colyseus_callbacks_on_add(
        wrapper->native,
        instance,
        property,
        gm_item_add_trampoline,
        entry,
        true  // immediate — fire for items already in collection
    );

    return (double)entry->index;
}

GM_EXPORT double colyseus_gm_callbacks_on_remove(double callbacks_handle, double instance_handle, const char* property) {
    gm_callbacks_wrapper_t* wrapper = (gm_callbacks_wrapper_t*)(uintptr_t)callbacks_handle;
    if (!wrapper || !wrapper->native || !property) return -1.0;

    void* instance = NULL;
    if (instance_handle == 0.0) {
        instance = colyseus_room_get_state(wrapper->room);
    } else {
        instance = (void*)(uintptr_t)instance_handle;
    }
    if (!instance) return -1.0;

    gm_callback_entry_t* entry = gm_find_free_callback_entry();
    if (!entry) return -1.0;

    entry->active = true;
    entry->room_handle = (double)wrapper->room_ref;
    entry->callback_type = 2;  // ON_REMOVE
    entry->value_type = COLYSEUS_FIELD_MAP;  // default for collections

    gm_resolve_field_type(instance, property, entry);

    entry->native_handle = colyseus_callbacks_on_remove(
        wrapper->native,
        instance,
        property,
        gm_item_remove_trampoline,
        entry
    );

    return (double)entry->index;
}

// =============================================================================
// Event Polling Functions
// =============================================================================

GM_EXPORT double colyseus_gm_poll_event(void) {
    // Clean up previous iterator state
    if (g_current_iter_key) {
        colyseus_message_reader_free(g_current_iter_key);
        g_current_iter_key = NULL;
    }
    if (g_current_iter_value) {
        colyseus_message_reader_free(g_current_iter_value);
        g_current_iter_value = NULL;
    }
    memset(&g_current_map_iterator, 0, sizeof(g_current_map_iterator));

    // Clean up previous message reader
    if (g_current_message_reader) {
        colyseus_message_reader_free(g_current_message_reader);
        g_current_message_reader = NULL;
    }

    if (event_queue_pop(&g_current_event)) {
        return (double)g_current_event.type;
    }

    memset(&g_current_event, 0, sizeof(g_current_event));
    return 0.0;
}

GM_EXPORT double colyseus_gm_event_get_room(void) {
    return g_current_event.room_handle;
}

GM_EXPORT double colyseus_gm_event_get_code(void) {
    return (double)g_current_event.code;
}

GM_EXPORT const char* colyseus_gm_event_get_message(void) {
    return g_current_event.message;
}

GM_EXPORT const uint8_t* colyseus_gm_event_get_data(void) {
    return g_current_event.msg.data;
}

GM_EXPORT double colyseus_gm_event_get_data_length(void) {
    return (double)g_current_event.msg.data_length;
}

// Schema event accessors

GM_EXPORT double colyseus_gm_event_get_callback_handle(void) {
    return g_current_event.schema.callback_handle;
}

GM_EXPORT double colyseus_gm_event_get_instance(void) {
    return g_current_event.schema.instance_handle;
}

GM_EXPORT double colyseus_gm_event_get_value_number(void) {
    return g_current_event.schema.value_number;
}

GM_EXPORT const char* colyseus_gm_event_get_value_string(void) {
    return g_current_event.schema.value_string;
}

GM_EXPORT double colyseus_gm_event_get_prev_value_number(void) {
    return g_current_event.schema.prev_value_number;
}

GM_EXPORT const char* colyseus_gm_event_get_prev_value_string(void) {
    return g_current_event.schema.prev_value_string;
}

GM_EXPORT const char* colyseus_gm_event_get_key_string(void) {
    return g_current_event.schema.key_string;
}

GM_EXPORT double colyseus_gm_event_get_value_type(void) {
    return (double)g_current_event.schema.value_type;
}

// =============================================================================
// Message Builder — construct messages for room_send
// =============================================================================

GM_EXPORT double colyseus_gm_message_create_map(void) {
    colyseus_message_t* msg = colyseus_message_map_create();
    return (double)(uintptr_t)msg;
}

GM_EXPORT void colyseus_gm_message_put_str(double msg_handle, const char* key, const char* value) {
    colyseus_message_t* msg = (colyseus_message_t*)(uintptr_t)msg_handle;
    if (msg && key && value) {
        colyseus_message_map_put_str(msg, key, value);
    }
}

GM_EXPORT void colyseus_gm_message_put_number(double msg_handle, const char* key, double value) {
    colyseus_message_t* msg = (colyseus_message_t*)(uintptr_t)msg_handle;
    if (msg && key) {
        colyseus_message_map_put_float(msg, key, value);
    }
}

GM_EXPORT void colyseus_gm_message_put_bool(double msg_handle, const char* key, double value) {
    colyseus_message_t* msg = (colyseus_message_t*)(uintptr_t)msg_handle;
    if (msg && key) {
        colyseus_message_map_put_bool(msg, key, value > 0.5);
    }
}

GM_EXPORT void colyseus_gm_message_free(double msg_handle) {
    colyseus_message_t* msg = (colyseus_message_t*)(uintptr_t)msg_handle;
    if (msg) {
        colyseus_message_free(msg);
    }
}

GM_EXPORT void colyseus_gm_room_send_message(double room_handle, const char* type, double msg_handle) {
    colyseus_room_t* room = gm_room_ref_get((int)room_handle);
    colyseus_message_t* msg = (colyseus_message_t*)(uintptr_t)msg_handle;
    if (room && msg) {
        colyseus_room_send(room, type, msg);
        colyseus_message_free(msg);
    }
}

// =============================================================================
// Raw value message creators (for sending non-map/non-struct values)
// =============================================================================

GM_EXPORT double colyseus_gm_message_create_bool(double value) {
    colyseus_message_t* msg = colyseus_message_bool_create(value > 0.5);
    return (double)(uintptr_t)msg;
}

GM_EXPORT double colyseus_gm_message_create_number(double value) {
    colyseus_message_t* msg = colyseus_message_float_create(value);
    return (double)(uintptr_t)msg;
}

GM_EXPORT double colyseus_gm_message_create_int(double value) {
    colyseus_message_t* msg = colyseus_message_int_create((int64_t)value);
    return (double)(uintptr_t)msg;
}

GM_EXPORT double colyseus_gm_message_create_string(const char* value) {
    colyseus_message_t* msg = colyseus_message_str_create(value ? value : "");
    return (double)(uintptr_t)msg;
}

// =============================================================================
// Message Reader — read fields from received messages
// =============================================================================

static void gm_ensure_message_reader(void) {
    if (g_current_message_reader) return;
    if (g_current_event.type != GM_EVENT_ROOM_MESSAGE) return;
    if (g_current_event.msg.data_length == 0) return;
    g_current_message_reader = colyseus_message_reader_create(
        g_current_event.msg.data, g_current_event.msg.data_length);
}

GM_EXPORT double colyseus_gm_message_get_type(void) {
    gm_ensure_message_reader();
    if (!g_current_message_reader) return 0.0;
    return (double)colyseus_message_reader_get_type(g_current_message_reader);
}

GM_EXPORT const char* colyseus_gm_message_read_string(const char* key) {
    static char buf[4096];
    buf[0] = '\0';
    gm_ensure_message_reader();
    if (!g_current_message_reader || !key) return buf;
    const char* value = NULL;
    size_t len = 0;
    if (colyseus_message_reader_map_get_str(g_current_message_reader, key, &value, &len)) {
        if (value && len > 0) {
            if (len >= sizeof(buf)) len = sizeof(buf) - 1;
            memcpy(buf, value, len);
            buf[len] = '\0';
            return buf;
        }
    }
    return buf;
}

GM_EXPORT double colyseus_gm_message_read_number(const char* key) {
    gm_ensure_message_reader();
    if (!g_current_message_reader || !key) return 0.0;
    double fval = 0.0;
    if (colyseus_message_reader_map_get_float(g_current_message_reader, key, &fval)) {
        return fval;
    }
    int64_t ival = 0;
    if (colyseus_message_reader_map_get_int(g_current_message_reader, key, &ival)) {
        return (double)ival;
    }
    uint64_t uval = 0;
    if (colyseus_message_reader_map_get_uint(g_current_message_reader, key, &uval)) {
        return (double)uval;
    }
    return 0.0;
}

GM_EXPORT double colyseus_gm_message_read_bool(const char* key) {
    gm_ensure_message_reader();
    if (!g_current_message_reader || !key) return 0.0;
    bool value = false;
    if (colyseus_message_reader_map_get_bool(g_current_message_reader, key, &value)) {
        return value ? 1.0 : 0.0;
    }
    return 0.0;
}

GM_EXPORT const char* colyseus_gm_message_read_string_value(void) {
    static char buf[4096];
    buf[0] = '\0';
    gm_ensure_message_reader();
    if (!g_current_message_reader) return buf;
    size_t len = 0;
    const char* value = colyseus_message_reader_get_str(g_current_message_reader, &len);
    if (value && len > 0) {
        if (len >= sizeof(buf)) len = sizeof(buf) - 1;
        memcpy(buf, value, len);
        buf[len] = '\0';
    }
    return buf;
}

GM_EXPORT double colyseus_gm_message_read_number_value(void) {
    gm_ensure_message_reader();
    if (!g_current_message_reader) return 0.0;
    if (colyseus_message_reader_is_float(g_current_message_reader)) {
        return colyseus_message_reader_get_float(g_current_message_reader);
    }
    if (colyseus_message_reader_is_int(g_current_message_reader)) {
        return (double)colyseus_message_reader_get_int(g_current_message_reader);
    }
    return 0.0;
}

// =============================================================================
// Message Map Iterator — step through all key-value pairs
// =============================================================================

GM_EXPORT double colyseus_gm_message_map_size(void) {
    gm_ensure_message_reader();
    if (!g_current_message_reader) return 0.0;
    return (double)colyseus_message_reader_get_map_size(g_current_message_reader);
}

GM_EXPORT void colyseus_gm_message_iter_begin(void) {
    // Clean up previous iteration
    if (g_current_iter_key) {
        colyseus_message_reader_free(g_current_iter_key);
        g_current_iter_key = NULL;
    }
    if (g_current_iter_value) {
        colyseus_message_reader_free(g_current_iter_value);
        g_current_iter_value = NULL;
    }

    gm_ensure_message_reader();
    if (!g_current_message_reader) {
        memset(&g_current_map_iterator, 0, sizeof(g_current_map_iterator));
        return;
    }
    g_current_map_iterator = colyseus_message_reader_map_iterator(g_current_message_reader);
}

GM_EXPORT double colyseus_gm_message_iter_next(void) {
    // Free previous key/value
    if (g_current_iter_key) {
        colyseus_message_reader_free(g_current_iter_key);
        g_current_iter_key = NULL;
    }
    if (g_current_iter_value) {
        colyseus_message_reader_free(g_current_iter_value);
        g_current_iter_value = NULL;
    }

    return colyseus_message_map_iterator_next(
        &g_current_map_iterator,
        &g_current_iter_key,
        &g_current_iter_value
    ) ? 1.0 : 0.0;
}

GM_EXPORT const char* colyseus_gm_message_iter_key(void) {
    static char buf[1024];
    buf[0] = '\0';
    if (!g_current_iter_key) return buf;
    size_t len = 0;
    const char* key = colyseus_message_reader_get_str(g_current_iter_key, &len);
    if (key && len > 0) {
        if (len >= sizeof(buf)) len = sizeof(buf) - 1;
        memcpy(buf, key, len);
        buf[len] = '\0';
    }
    return buf;
}

GM_EXPORT double colyseus_gm_message_iter_value_type(void) {
    if (!g_current_iter_value) return 0.0;
    return (double)colyseus_message_reader_get_type(g_current_iter_value);
}

GM_EXPORT const char* colyseus_gm_message_iter_value_string(void) {
    static char buf[4096];
    buf[0] = '\0';
    if (!g_current_iter_value) return buf;
    size_t len = 0;
    const char* str = colyseus_message_reader_get_str(g_current_iter_value, &len);
    if (str && len > 0) {
        if (len >= sizeof(buf)) len = sizeof(buf) - 1;
        memcpy(buf, str, len);
        buf[len] = '\0';
    }
    return buf;
}

GM_EXPORT double colyseus_gm_message_iter_value_number(void) {
    if (!g_current_iter_value) return 0.0;
    if (colyseus_message_reader_is_float(g_current_iter_value)) {
        return colyseus_message_reader_get_float(g_current_iter_value);
    }
    if (colyseus_message_reader_is_int(g_current_iter_value)) {
        return (double)colyseus_message_reader_get_int(g_current_iter_value);
    }
    if (colyseus_message_reader_is_bool(g_current_iter_value)) {
        return colyseus_message_reader_get_bool(g_current_iter_value) ? 1.0 : 0.0;
    }
    return 0.0;
}
