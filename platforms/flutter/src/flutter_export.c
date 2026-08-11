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

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

// Export macro for Flutter FFI
#ifndef FLUTTER_EXPORT
#ifdef _WIN32
#define FLUTTER_EXPORT __declspec(dllexport)
#else
#define FLUTTER_EXPORT __attribute__((visibility("default")))
#endif
#endif

// Maximum number of events in the queue
#define MAX_EVENT_QUEUE_SIZE 1024

// Maximum number of callback entries
#define MAX_FLUTTER_CALLBACK_ENTRIES 256

// Event types for Flutter polling
typedef enum {
    FLUTTER_EVENT_NONE = 0,
    FLUTTER_EVENT_ROOM_JOIN = 1,
    FLUTTER_EVENT_ROOM_STATE_CHANGE = 2,
    FLUTTER_EVENT_ROOM_MESSAGE = 3,
    FLUTTER_EVENT_ROOM_ERROR = 4,
    FLUTTER_EVENT_ROOM_LEAVE = 5,
    FLUTTER_EVENT_CLIENT_ERROR = 6,
    FLUTTER_EVENT_PROPERTY_CHANGE = 7,
    FLUTTER_EVENT_ITEM_ADD = 8,
    FLUTTER_EVENT_ITEM_REMOVE = 9,
    FLUTTER_EVENT_ROOM_DROP = 14,
    FLUTTER_EVENT_ROOM_RECONNECT = 15,
} flutter_event_type_t;

// Event structure for the queue
typedef struct {
    flutter_event_type_t type;
    int room_handle;  // Room ref (1-based integer)
    int code;
    char message[1024];

    union {
        // Message events (type 3). Heap-owned so payloads aren't truncated;
        // freed when the event is dropped from the queue or replaced on poll.
        struct {
            uint8_t* data;
            size_t data_length;
        } msg;

        // Schema callback events (types 7, 8, 9)
        struct {
            int callback_handle;
            intptr_t instance_handle;
            int value_type;
            double value_number;
            double prev_value_number;
            char value_string[1024];
            char prev_value_string[1024];
            char key_string[256];
            int key_index;
        } schema;
    };
} flutter_event_t;

// Event queue (circular buffer, thread-safe)
typedef struct {
    flutter_event_t events[MAX_EVENT_QUEUE_SIZE];
    int head;
    int tail;
    int count;
} flutter_event_queue_t;

// Callback entry
typedef struct {
    bool active;
    int index;
    int room_handle;
    int value_type;      // colyseus_field_type_t
    int callback_type;   // 0=listen, 1=on_add, 2=on_remove
    colyseus_callback_handle_t native_handle;

    // Collection callbacks: where to find the child's type. Resolved lazily —
    // the collection often doesn't exist yet when the listener is registered.
    void* parent_instance;
    char property[128];
    int child_type;      // colyseus_field_type_t, -1 = unresolved, -2 = schema child
} flutter_callback_entry_t;

#define FLUTTER_CHILD_UNRESOLVED (-1)
#define FLUTTER_CHILD_SCHEMA     (-2)

// Callbacks wrapper
typedef struct {
    colyseus_callbacks_t* native;
    colyseus_room_t* room;
    int room_ref;
} flutter_callbacks_wrapper_t;

// Room reference table
#define MAX_ROOM_REFS 16

typedef struct {
    colyseus_room_t* room;
    bool in_use;
    flutter_callbacks_wrapper_t** callbacks;  // grown on demand
    int callbacks_count;
    int callbacks_capacity;
} flutter_room_ref_t;

static flutter_room_ref_t g_room_refs[MAX_ROOM_REFS] = {0};

// Global event queue
static flutter_event_queue_t g_event_queue = {0};

// Event queue mutex
#ifdef _WIN32
static SRWLOCK g_event_queue_lock = SRWLOCK_INIT;
#else
static pthread_mutex_t g_event_queue_lock = PTHREAD_MUTEX_INITIALIZER;
#endif

// Current event (for event accessors)
static flutter_event_t g_current_event = {0};

// Current message reader (lazy-created when a MESSAGE event is polled)
static colyseus_message_reader_t* g_current_message_reader = NULL;

// Map iterator state
static colyseus_message_map_iterator_t g_current_map_iterator = {0};
static colyseus_message_reader_t* g_current_iter_key = NULL;
static colyseus_message_reader_t* g_current_iter_value = NULL;

// Array element reader cache
static colyseus_message_reader_t* g_current_array_element = NULL;

// Global callback entry table
static flutter_callback_entry_t g_callback_entries[MAX_FLUTTER_CALLBACK_ENTRIES] = {0};

// =============================================================================
// Room reference helpers
// =============================================================================

static int flutter_room_ref_alloc(void) {
    for (int i = 0; i < MAX_ROOM_REFS; i++) {
        if (!g_room_refs[i].in_use) {
            g_room_refs[i].in_use = true;
            g_room_refs[i].room = NULL;
            g_room_refs[i].callbacks_count = 0;
            return i + 1;  // 1-based, 0 = invalid
        }
    }
    return 0;
}

static colyseus_room_t* flutter_room_ref_get(int ref) {
    if (ref < 1 || ref > MAX_ROOM_REFS) return NULL;
    return g_room_refs[ref - 1].room;
}

/* Room-ref lookup for the sibling translation units (flutter_extras.c). */
colyseus_room_t* flutter_room_from_ref(int ref) {
    return flutter_room_ref_get(ref);
}

static void flutter_room_ref_set(int ref, colyseus_room_t* room) {
    if (ref >= 1 && ref <= MAX_ROOM_REFS) {
        g_room_refs[ref - 1].room = room;
    }
}

static void flutter_callbacks_wrapper_free(flutter_callbacks_wrapper_t* wrapper) {
    if (!wrapper) return;

    int room_ref = wrapper->room_ref;
    for (int i = 0; i < MAX_FLUTTER_CALLBACK_ENTRIES; i++) {
        if (g_callback_entries[i].active &&
            g_callback_entries[i].room_handle == room_ref) {
            g_callback_entries[i].active = false;
        }
    }

    if (wrapper->native) {
        colyseus_callbacks_free(wrapper->native);
    }
    free(wrapper);
}

static void flutter_room_ref_add_callbacks(int ref, flutter_callbacks_wrapper_t* wrapper) {
    if (ref < 1 || ref > MAX_ROOM_REFS) return;
    flutter_room_ref_t* entry = &g_room_refs[ref - 1];

    if (entry->callbacks_count >= entry->callbacks_capacity) {
        int cap = entry->callbacks_capacity ? entry->callbacks_capacity * 2 : 8;
        flutter_callbacks_wrapper_t** grown = (flutter_callbacks_wrapper_t**)realloc(
            entry->callbacks, (size_t)cap * sizeof(*grown));
        if (!grown) return;
        entry->callbacks = grown;
        entry->callbacks_capacity = cap;
    }

    entry->callbacks[entry->callbacks_count++] = wrapper;
}

static void flutter_room_ref_remove_callbacks(int ref, flutter_callbacks_wrapper_t* wrapper) {
    if (ref < 1 || ref > MAX_ROOM_REFS) return;
    flutter_room_ref_t* entry = &g_room_refs[ref - 1];
    for (int i = 0; i < entry->callbacks_count; i++) {
        if (entry->callbacks[i] == wrapper) {
            for (int j = i; j < entry->callbacks_count - 1; j++) {
                entry->callbacks[j] = entry->callbacks[j + 1];
            }
            entry->callbacks_count--;
            entry->callbacks[entry->callbacks_count] = NULL;
            return;
        }
    }
}

static void flutter_room_ref_release(int ref) {
    if (ref >= 1 && ref <= MAX_ROOM_REFS) {
        flutter_room_ref_t* entry = &g_room_refs[ref - 1];
        for (int i = 0; i < entry->callbacks_count; i++) {
            flutter_callbacks_wrapper_free(entry->callbacks[i]);
            entry->callbacks[i] = NULL;
        }
        free(entry->callbacks);
        entry->callbacks = NULL;
        entry->callbacks_count = 0;
        entry->callbacks_capacity = 0;
        entry->room = NULL;
        entry->in_use = false;
    }
}

// =============================================================================
// Event queue functions (thread-safe via mutex)
// =============================================================================

static void event_queue_lock(void) {
#ifdef _WIN32
    AcquireSRWLockExclusive(&g_event_queue_lock);
#else
    pthread_mutex_lock(&g_event_queue_lock);
#endif
}

static void event_queue_unlock(void) {
#ifdef _WIN32
    ReleaseSRWLockExclusive(&g_event_queue_lock);
#else
    pthread_mutex_unlock(&g_event_queue_lock);
#endif
}

// Release a queued event's heap payload. Only MESSAGE events carry one.
static void event_release_payload(flutter_event_t* event) {
    if (event->type == FLUTTER_EVENT_ROOM_MESSAGE && event->msg.data) {
        free(event->msg.data);
        event->msg.data = NULL;
        event->msg.data_length = 0;
    }
}

static void event_queue_push(const flutter_event_t* event) {
    event_queue_lock();

    if (g_event_queue.count >= MAX_EVENT_QUEUE_SIZE) {
        event_release_payload(&g_event_queue.events[g_event_queue.head]);
        g_event_queue.head = (g_event_queue.head + 1) % MAX_EVENT_QUEUE_SIZE;
        g_event_queue.count--;
    }

    g_event_queue.events[g_event_queue.tail] = *event;
    g_event_queue.tail = (g_event_queue.tail + 1) % MAX_EVENT_QUEUE_SIZE;
    g_event_queue.count++;

    event_queue_unlock();
}

static int event_queue_pop(flutter_event_t* event) {
    event_queue_lock();

    if (g_event_queue.count == 0) {
        event_queue_unlock();
        return 0;
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

static flutter_callback_entry_t* flutter_find_free_callback_entry(void) {
    for (int i = 0; i < MAX_FLUTTER_CALLBACK_ENTRIES; i++) {
        if (!g_callback_entries[i].active) {
            memset(&g_callback_entries[i], 0, sizeof(flutter_callback_entry_t));
            g_callback_entries[i].index = i;
            return &g_callback_entries[i];
        }
    }
    return NULL;
}

static void flutter_resolve_field_type(void* instance, const char* property, flutter_callback_entry_t* entry) {
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
// Schema callback trampolines
// =============================================================================

static void flutter_snapshot_value(int value_type, void* value,
    double* out_number, char* out_string, size_t out_string_size,
    intptr_t* out_instance)
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
            if (out_instance) *out_instance = (intptr_t)value;
            break;
        default:
            break;
    }
}

/*
 * Child type of the collection this entry listens on. Resolved on first use:
 * at subscribe time the collection usually hasn't been decoded yet.
 * Returns a colyseus_field_type_t, or FLUTTER_CHILD_SCHEMA for ref children.
 */
static int flutter_resolve_child_type(flutter_callback_entry_t* entry) {
    if (entry->child_type != FLUTTER_CHILD_UNRESOLVED) return entry->child_type;

    colyseus_schema_t* parent = (colyseus_schema_t*)entry->parent_instance;
    if (!parent || !parent->__vtable) return FLUTTER_CHILD_UNRESOLVED;

    void* collection = NULL;
    if (colyseus_vtable_is_dynamic(parent->__vtable)) {
        colyseus_dynamic_value_t* val = colyseus_dynamic_schema_get_by_name(
            (colyseus_dynamic_schema_t*)parent, entry->property);
        if (val) collection = val->data.ptr;
    } else {
        for (int i = 0; i < parent->__vtable->field_count; i++) {
            if (parent->__vtable->fields[i].name &&
                strcmp(parent->__vtable->fields[i].name, entry->property) == 0) {
                collection = *(void**)((char*)parent + parent->__vtable->fields[i].offset);
                break;
            }
        }
    }
    if (!collection) return FLUTTER_CHILD_UNRESOLVED;

    bool has_schema_child;
    const char* primitive;
    if (entry->value_type == COLYSEUS_FIELD_ARRAY) {
        colyseus_array_schema_t* arr = (colyseus_array_schema_t*)collection;
        has_schema_child = arr->has_schema_child;
        primitive = arr->child_primitive_type;
    } else {
        colyseus_map_schema_t* map = (colyseus_map_schema_t*)collection;
        has_schema_child = map->has_schema_child;
        primitive = map->child_primitive_type;
    }

    entry->child_type = has_schema_child
        ? FLUTTER_CHILD_SCHEMA
        : (primitive ? (int)colyseus_field_type_from_string(primitive) : FLUTTER_CHILD_SCHEMA);
    return entry->child_type;
}

// Fill an item event's value slots: instance handle for schema children,
// unboxed number/string for primitives.
static void flutter_snapshot_item(flutter_callback_entry_t* entry, void* value,
    flutter_event_t* event)
{
    if (!value) return;

    int child = flutter_resolve_child_type(entry);
    if (child == FLUTTER_CHILD_SCHEMA || child == FLUTTER_CHILD_UNRESOLVED) {
        event->schema.instance_handle = (intptr_t)value;
        return;
    }

    event->schema.value_type = child;
    flutter_snapshot_value(child, value,
        &event->schema.value_number, event->schema.value_string,
        sizeof(event->schema.value_string), &event->schema.instance_handle);
}

static void flutter_property_change_trampoline(void* value, void* previous_value, void* userdata) {
    flutter_callback_entry_t* entry = (flutter_callback_entry_t*)userdata;
    if (!entry || !entry->active) return;

    flutter_event_t event = {0};
    event.type = FLUTTER_EVENT_PROPERTY_CHANGE;
    event.room_handle = entry->room_handle;
    event.schema.callback_handle = entry->index;
    event.schema.value_type = entry->value_type;

    flutter_snapshot_value(entry->value_type, value,
        &event.schema.value_number, event.schema.value_string,
        sizeof(event.schema.value_string), &event.schema.instance_handle);

    flutter_snapshot_value(entry->value_type, previous_value,
        &event.schema.prev_value_number, event.schema.prev_value_string,
        sizeof(event.schema.prev_value_string), NULL);

    event_queue_push(&event);
}

static void flutter_item_add_trampoline(void* value, void* key, void* userdata) {
    flutter_callback_entry_t* entry = (flutter_callback_entry_t*)userdata;
    if (!entry || !entry->active) return;

    flutter_event_t event = {0};
    event.type = FLUTTER_EVENT_ITEM_ADD;
    event.room_handle = entry->room_handle;
    event.schema.callback_handle = entry->index;
    event.schema.value_type = entry->value_type;

    flutter_snapshot_item(entry, value, &event);

    if (key) {
        if (entry->value_type == COLYSEUS_FIELD_ARRAY) {
            event.schema.key_index = *(int*)key;
            snprintf(event.schema.key_string, sizeof(event.schema.key_string), "%d", *(int*)key);
        } else {
            strncpy(event.schema.key_string, (const char*)key,
                    sizeof(event.schema.key_string) - 1);
        }
    }

    event_queue_push(&event);
}

static void flutter_item_remove_trampoline(void* value, void* key, void* userdata) {
    flutter_callback_entry_t* entry = (flutter_callback_entry_t*)userdata;
    if (!entry || !entry->active) return;

    flutter_event_t event = {0};
    event.type = FLUTTER_EVENT_ITEM_REMOVE;
    event.room_handle = entry->room_handle;
    event.schema.callback_handle = entry->index;
    event.schema.value_type = entry->value_type;

    flutter_snapshot_item(entry, value, &event);

    if (key) {
        if (entry->value_type == COLYSEUS_FIELD_ARRAY) {
            event.schema.key_index = *(int*)key;
            snprintf(event.schema.key_string, sizeof(event.schema.key_string), "%d", *(int*)key);
        } else {
            strncpy(event.schema.key_string, (const char*)key,
                    sizeof(event.schema.key_string) - 1);
        }
    }

    event_queue_push(&event);
}

// =============================================================================
// Room event callback adapters
// =============================================================================

static void on_room_join(void* userdata) {
    int ref = (int)(intptr_t)userdata;
    flutter_event_t event = {0};
    event.type = FLUTTER_EVENT_ROOM_JOIN;
    event.room_handle = ref;
    event_queue_push(&event);
}

static void on_room_state_change(void* userdata) {
    int ref = (int)(intptr_t)userdata;
    flutter_event_t event = {0};
    event.type = FLUTTER_EVENT_ROOM_STATE_CHANGE;
    event.room_handle = ref;
    event_queue_push(&event);
}

static void on_room_message_with_type_encoded(const char* type, const uint8_t* data, size_t length, void* userdata) {
    int ref = (int)(intptr_t)userdata;
    flutter_event_t event = {0};
    event.type = FLUTTER_EVENT_ROOM_MESSAGE;
    event.room_handle = ref;
    strncpy(event.message, type ? type : "", sizeof(event.message) - 1);

    if (data && length > 0) {
        event.msg.data = (uint8_t*)malloc(length);
        if (!event.msg.data) return;  // drop rather than truncate
        memcpy(event.msg.data, data, length);
        event.msg.data_length = length;
    }

    event_queue_push(&event);
}

static void on_room_error(int code, const char* message, void* userdata) {
    int ref = (int)(intptr_t)userdata;
    flutter_event_t event = {0};
    event.type = FLUTTER_EVENT_ROOM_ERROR;
    event.room_handle = ref;
    event.code = code;
    strncpy(event.message, message ? message : "", sizeof(event.message) - 1);
    event_queue_push(&event);
}

static void on_room_leave(int code, const char* reason, void* userdata) {
    int ref = (int)(intptr_t)userdata;
    flutter_event_t event = {0};
    event.type = FLUTTER_EVENT_ROOM_LEAVE;
    event.room_handle = ref;
    event.code = code;
    strncpy(event.message, reason ? reason : "", sizeof(event.message) - 1);
    event_queue_push(&event);
}

static void on_room_drop(int code, const char* reason, void* userdata) {
    int ref = (int)(intptr_t)userdata;
    flutter_event_t event = {0};
    event.type = FLUTTER_EVENT_ROOM_DROP;
    event.room_handle = ref;
    event.code = code;
    strncpy(event.message, reason ? reason : "", sizeof(event.message) - 1);
    event_queue_push(&event);
}

static void on_room_reconnect(void* userdata) {
    int ref = (int)(intptr_t)userdata;
    flutter_event_t event = {0};
    event.type = FLUTTER_EVENT_ROOM_RECONNECT;
    event.room_handle = ref;
    event_queue_push(&event);
}

static void on_client_room_success(colyseus_room_t* room, void* userdata) {
    int ref = (int)(intptr_t)userdata;
    flutter_room_ref_set(ref, room);

    void* ref_as_ptr = (void*)(intptr_t)ref;
    colyseus_room_on_join(room, on_room_join, ref_as_ptr);
    colyseus_room_on_state_change(room, on_room_state_change, ref_as_ptr);
    colyseus_room_on_message_any_with_type_encoded(room, on_room_message_with_type_encoded, ref_as_ptr);
    colyseus_room_on_error(room, on_room_error, ref_as_ptr);
    colyseus_room_on_leave(room, on_room_leave, ref_as_ptr);
    colyseus_room_on_drop(room, on_room_drop, ref_as_ptr);
    colyseus_room_on_reconnect(room, on_room_reconnect, ref_as_ptr);
}

static void on_client_error(int code, const char* message, void* userdata) {
    int ref = (int)(intptr_t)userdata;
    flutter_event_t event = {0};
    event.type = FLUTTER_EVENT_CLIENT_ERROR;
    event.room_handle = ref;
    event.code = code;
    strncpy(event.message, message ? message : "", sizeof(event.message) - 1);
    event_queue_push(&event);

    flutter_room_ref_release(ref);
}

// =============================================================================
// Exported Functions - Client
// =============================================================================

FLUTTER_EXPORT intptr_t colyseus_flutter_client_create(const char* endpoint) {
    colyseus_settings_t* settings = colyseus_settings_create();
    if (!settings) {
        return 0;
    }

    const char* url = endpoint;
    bool secure = false;

    if (strncmp(url, "https://", 8) == 0 || strncmp(url, "wss://", 6) == 0) {
        secure = true;
        url = strchr(url, '/') + 2;
    } else if (strncmp(url, "http://", 7) == 0 || strncmp(url, "ws://", 5) == 0) {
        secure = false;
        url = strchr(url, '/') + 2;
    }

    char* host_port = strdup(url);

    size_t len = strlen(host_port);
    if (len > 0 && host_port[len - 1] == '/') {
        host_port[len - 1] = '\0';
    }

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
        return 0;
    }

    return (intptr_t)client;
}

FLUTTER_EXPORT void colyseus_flutter_client_free(intptr_t client_handle) {
    colyseus_client_t* client = (colyseus_client_t*)client_handle;
    if (client) {
        colyseus_client_free(client);
    }
}

FLUTTER_EXPORT int colyseus_flutter_client_join_or_create(intptr_t client_handle, const char* room_name, const char* options_json) {
    colyseus_client_t* client = (colyseus_client_t*)client_handle;
    if (!client) return 0;

    int ref = flutter_room_ref_alloc();
    if (ref == 0) return 0;

    const char* options = (options_json && strlen(options_json) > 0) ? options_json : "{}";

    colyseus_client_join_or_create(
        client, room_name, options,
        on_client_room_success, on_client_error,
        (void*)(intptr_t)ref
    );

    return ref;
}

FLUTTER_EXPORT int colyseus_flutter_client_create_room(intptr_t client_handle, const char* room_name, const char* options_json) {
    colyseus_client_t* client = (colyseus_client_t*)client_handle;
    if (!client) return 0;

    int ref = flutter_room_ref_alloc();
    if (ref == 0) return 0;

    const char* options = (options_json && strlen(options_json) > 0) ? options_json : "{}";

    colyseus_client_create_room(
        client, room_name, options,
        on_client_room_success, on_client_error,
        (void*)(intptr_t)ref
    );

    return ref;
}

FLUTTER_EXPORT int colyseus_flutter_client_join(intptr_t client_handle, const char* room_name, const char* options_json) {
    colyseus_client_t* client = (colyseus_client_t*)client_handle;
    if (!client) return 0;

    int ref = flutter_room_ref_alloc();
    if (ref == 0) return 0;

    const char* options = (options_json && strlen(options_json) > 0) ? options_json : "{}";

    colyseus_client_join(
        client, room_name, options,
        on_client_room_success, on_client_error,
        (void*)(intptr_t)ref
    );

    return ref;
}

FLUTTER_EXPORT int colyseus_flutter_client_join_by_id(intptr_t client_handle, const char* room_id, const char* options_json) {
    colyseus_client_t* client = (colyseus_client_t*)client_handle;
    if (!client) return 0;

    int ref = flutter_room_ref_alloc();
    if (ref == 0) return 0;

    const char* options = (options_json && strlen(options_json) > 0) ? options_json : "{}";

    colyseus_client_join_by_id(
        client, room_id, options,
        on_client_room_success, on_client_error,
        (void*)(intptr_t)ref
    );

    return ref;
}

FLUTTER_EXPORT int colyseus_flutter_client_reconnect(intptr_t client_handle, const char* reconnection_token) {
    colyseus_client_t* client = (colyseus_client_t*)client_handle;
    if (!client) return 0;

    int ref = flutter_room_ref_alloc();
    if (ref == 0) return 0;

    colyseus_client_reconnect(
        client, reconnection_token,
        on_client_room_success, on_client_error,
        (void*)(intptr_t)ref
    );

    return ref;
}

// =============================================================================
// Exported Functions - Room
// =============================================================================

FLUTTER_EXPORT void colyseus_flutter_room_leave(int room_handle) {
    colyseus_room_t* room = flutter_room_ref_get(room_handle);
    if (room) {
        colyseus_room_leave(room, true);
    }
}

FLUTTER_EXPORT void colyseus_flutter_room_free(int room_handle) {
    colyseus_room_t* room = flutter_room_ref_get(room_handle);
    if (room) {
        colyseus_room_free(room);
    }
    flutter_room_ref_release(room_handle);
}

FLUTTER_EXPORT const char* colyseus_flutter_room_get_id(int room_handle) {
    colyseus_room_t* room = flutter_room_ref_get(room_handle);
    if (room) {
        const char* id = colyseus_room_get_id(room);
        return id ? id : "";
    }
    return "";
}

FLUTTER_EXPORT const char* colyseus_flutter_room_get_session_id(int room_handle) {
    colyseus_room_t* room = flutter_room_ref_get(room_handle);
    if (room) {
        const char* id = colyseus_room_get_session_id(room);
        return id ? id : "";
    }
    return "";
}

FLUTTER_EXPORT const char* colyseus_flutter_room_get_name(int room_handle) {
    colyseus_room_t* room = flutter_room_ref_get(room_handle);
    if (room) {
        const char* name = colyseus_room_get_name(room);
        return name ? name : "";
    }
    return "";
}

FLUTTER_EXPORT const char* colyseus_flutter_room_get_reconnection_token(int room_handle) {
    colyseus_room_t* room = flutter_room_ref_get(room_handle);
    if (room) {
        const char* token = colyseus_room_get_reconnection_token(room);
        return token ? token : "";
    }
    return "";
}

FLUTTER_EXPORT int colyseus_flutter_room_is_connected(int room_handle) {
    colyseus_room_t* room = flutter_room_ref_get(room_handle);
    if (room) {
        return colyseus_room_is_connected(room) ? 1 : 0;
    }
    return 0;
}

FLUTTER_EXPORT int colyseus_flutter_room_is_reconnecting(int room_handle) {
    colyseus_room_t* room = flutter_room_ref_get(room_handle);
    if (room) {
        return colyseus_room_is_reconnecting(room) ? 1 : 0;
    }
    return 0;
}

/*
 * Configure reconnection behaviour. Pass -1 for any int parameter to keep
 * the current value; for `enabled`, 0 = off, 1 = on, -1 = keep current.
 */
FLUTTER_EXPORT void colyseus_flutter_room_set_reconnection_options(int room_handle,
    int enabled,
    int max_retries,
    int min_delay_ms,
    int max_delay_ms,
    int min_uptime_ms,
    int delay_ms,
    int max_enqueued_messages) {
    colyseus_room_t* room = flutter_room_ref_get(room_handle);
    if (!room) return;
    colyseus_reconnection_options_t opts;
    colyseus_room_get_reconnection_options(room, &opts);
    if (enabled >= 0) opts.enabled = enabled > 0;
    if (max_retries >= 0) opts.max_retries = max_retries;
    if (min_delay_ms >= 0) opts.min_delay_ms = min_delay_ms;
    if (max_delay_ms >= 0) opts.max_delay_ms = max_delay_ms;
    if (min_uptime_ms >= 0) opts.min_uptime_ms = min_uptime_ms;
    if (delay_ms >= 0) opts.delay_ms = delay_ms;
    if (max_enqueued_messages >= 0) opts.max_enqueued_messages = max_enqueued_messages;
    colyseus_room_set_reconnection_options(room, &opts);
}

// =============================================================================
// Room Send Functions
// =============================================================================

FLUTTER_EXPORT void colyseus_flutter_room_send_message(int room_handle, const char* type, intptr_t msg_handle) {
    colyseus_room_t* room = flutter_room_ref_get(room_handle);
    colyseus_message_t* msg = (colyseus_message_t*)msg_handle;
    if (room && msg) {
        colyseus_room_send(room, type, msg);
        colyseus_message_free(msg);
    }
}

FLUTTER_EXPORT void colyseus_flutter_room_send_message_int(int room_handle, int type, intptr_t msg_handle) {
    colyseus_room_t* room = flutter_room_ref_get(room_handle);
    colyseus_message_t* msg = (colyseus_message_t*)msg_handle;
    if (room && msg) {
        colyseus_room_send_int(room, type, msg);
        colyseus_message_free(msg);
    }
}

FLUTTER_EXPORT void colyseus_flutter_room_send_bytes(int room_handle, const char* type, const uint8_t* data, int length) {
    colyseus_room_t* room = flutter_room_ref_get(room_handle);
    if (room && data) {
        colyseus_room_send_bytes(room, type, data, (size_t)length);
    }
}

// =============================================================================
// Message Builder Functions
// =============================================================================

FLUTTER_EXPORT intptr_t colyseus_flutter_message_create_map(void) {
    return (intptr_t)colyseus_message_map_create();
}

FLUTTER_EXPORT intptr_t colyseus_flutter_message_create_array(void) {
    return (intptr_t)colyseus_message_array_create();
}

FLUTTER_EXPORT intptr_t colyseus_flutter_message_create_string(const char* value) {
    return (intptr_t)colyseus_message_str_create(value ? value : "");
}

FLUTTER_EXPORT intptr_t colyseus_flutter_message_create_int(int64_t value) {
    return (intptr_t)colyseus_message_int_create(value);
}

FLUTTER_EXPORT intptr_t colyseus_flutter_message_create_float(double value) {
    return (intptr_t)colyseus_message_float_create(value);
}

FLUTTER_EXPORT intptr_t colyseus_flutter_message_create_bool(int value) {
    return (intptr_t)colyseus_message_bool_create(value != 0);
}

FLUTTER_EXPORT intptr_t colyseus_flutter_message_create_nil(void) {
    return (intptr_t)colyseus_message_nil_create();
}

FLUTTER_EXPORT void colyseus_flutter_message_map_put_str(intptr_t msg_handle, const char* key, const char* value) {
    colyseus_message_t* msg = (colyseus_message_t*)msg_handle;
    if (msg && key && value) {
        colyseus_message_map_put_str(msg, key, value);
    }
}

FLUTTER_EXPORT void colyseus_flutter_message_map_put_int(intptr_t msg_handle, const char* key, int64_t value) {
    colyseus_message_t* msg = (colyseus_message_t*)msg_handle;
    if (msg && key) {
        colyseus_message_map_put_int(msg, key, value);
    }
}

FLUTTER_EXPORT void colyseus_flutter_message_map_put_float(intptr_t msg_handle, const char* key, double value) {
    colyseus_message_t* msg = (colyseus_message_t*)msg_handle;
    if (msg && key) {
        colyseus_message_map_put_float(msg, key, value);
    }
}

FLUTTER_EXPORT void colyseus_flutter_message_map_put_bool(intptr_t msg_handle, const char* key, int value) {
    colyseus_message_t* msg = (colyseus_message_t*)msg_handle;
    if (msg && key) {
        colyseus_message_map_put_bool(msg, key, value != 0);
    }
}

FLUTTER_EXPORT void colyseus_flutter_message_map_put_nil(intptr_t msg_handle, const char* key) {
    colyseus_message_t* msg = (colyseus_message_t*)msg_handle;
    if (msg && key) {
        colyseus_message_map_put_nil(msg, key);
    }
}

FLUTTER_EXPORT void colyseus_flutter_message_map_put(intptr_t msg_handle, const char* key, intptr_t value_handle) {
    colyseus_message_t* msg = (colyseus_message_t*)msg_handle;
    colyseus_message_t* val = (colyseus_message_t*)value_handle;
    if (msg && key && val) {
        colyseus_message_map_put_msg(msg, key, val);
    }
}

FLUTTER_EXPORT void colyseus_flutter_message_array_push_str(intptr_t msg_handle, const char* value) {
    colyseus_message_t* msg = (colyseus_message_t*)msg_handle;
    if (msg && value) {
        colyseus_message_array_push_str(msg, value);
    }
}

FLUTTER_EXPORT void colyseus_flutter_message_array_push_int(intptr_t msg_handle, int64_t value) {
    colyseus_message_t* msg = (colyseus_message_t*)msg_handle;
    if (msg) {
        colyseus_message_array_push_int(msg, value);
    }
}

FLUTTER_EXPORT void colyseus_flutter_message_array_push_float(intptr_t msg_handle, double value) {
    colyseus_message_t* msg = (colyseus_message_t*)msg_handle;
    if (msg) {
        colyseus_message_array_push_float(msg, value);
    }
}

FLUTTER_EXPORT void colyseus_flutter_message_array_push_bool(intptr_t msg_handle, int value) {
    colyseus_message_t* msg = (colyseus_message_t*)msg_handle;
    if (msg) {
        colyseus_message_array_push_bool(msg, value != 0);
    }
}

FLUTTER_EXPORT void colyseus_flutter_message_array_push_nil(intptr_t msg_handle) {
    colyseus_message_t* msg = (colyseus_message_t*)msg_handle;
    if (msg) {
        colyseus_message_array_push_nil(msg);
    }
}

FLUTTER_EXPORT void colyseus_flutter_message_array_push(intptr_t msg_handle, intptr_t value_handle) {
    colyseus_message_t* msg = (colyseus_message_t*)msg_handle;
    colyseus_message_t* val = (colyseus_message_t*)value_handle;
    if (msg && val) {
        colyseus_message_array_push_msg(msg, val);
    }
}

FLUTTER_EXPORT void colyseus_flutter_message_free(intptr_t msg_handle) {
    colyseus_message_t* msg = (colyseus_message_t*)msg_handle;
    if (msg) {
        colyseus_message_free(msg);
    }
}

// =============================================================================
// Event Polling Functions
// =============================================================================

FLUTTER_EXPORT int colyseus_flutter_poll_event(void) {
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

    // Clean up previous array element reader
    if (g_current_array_element) {
        colyseus_message_reader_free(g_current_array_element);
        g_current_array_element = NULL;
    }

    // Clean up previous message reader
    if (g_current_message_reader) {
        colyseus_message_reader_free(g_current_message_reader);
        g_current_message_reader = NULL;
    }

    // The previous event owned its payload; the reader above is now gone.
    event_release_payload(&g_current_event);

    if (event_queue_pop(&g_current_event)) {
        return (int)g_current_event.type;
    }

    memset(&g_current_event, 0, sizeof(g_current_event));
    return 0;
}

FLUTTER_EXPORT int colyseus_flutter_event_get_room(void) {
    return g_current_event.room_handle;
}

FLUTTER_EXPORT int colyseus_flutter_event_get_code(void) {
    return g_current_event.code;
}

FLUTTER_EXPORT const char* colyseus_flutter_event_get_message(void) {
    return g_current_event.message;
}

FLUTTER_EXPORT const uint8_t* colyseus_flutter_event_get_data(void) {
    return g_current_event.msg.data;
}

FLUTTER_EXPORT int colyseus_flutter_event_get_data_length(void) {
    return (int)g_current_event.msg.data_length;
}

// Schema event accessors

FLUTTER_EXPORT int colyseus_flutter_event_get_callback_handle(void) {
    return g_current_event.schema.callback_handle;
}

FLUTTER_EXPORT intptr_t colyseus_flutter_event_get_instance(void) {
    return g_current_event.schema.instance_handle;
}

FLUTTER_EXPORT double colyseus_flutter_event_get_value_number(void) {
    return g_current_event.schema.value_number;
}

FLUTTER_EXPORT const char* colyseus_flutter_event_get_value_string(void) {
    return g_current_event.schema.value_string;
}

FLUTTER_EXPORT double colyseus_flutter_event_get_prev_value_number(void) {
    return g_current_event.schema.prev_value_number;
}

FLUTTER_EXPORT const char* colyseus_flutter_event_get_prev_value_string(void) {
    return g_current_event.schema.prev_value_string;
}

FLUTTER_EXPORT const char* colyseus_flutter_event_get_key_string(void) {
    return g_current_event.schema.key_string;
}

FLUTTER_EXPORT int colyseus_flutter_event_get_value_type(void) {
    return g_current_event.schema.value_type;
}

// =============================================================================
// Message Reader Functions
// =============================================================================

static void flutter_ensure_message_reader(void) {
    if (g_current_message_reader) return;
    if (g_current_event.type != FLUTTER_EVENT_ROOM_MESSAGE) return;
    if (g_current_event.msg.data_length == 0) return;
    g_current_message_reader = colyseus_message_reader_create(
        g_current_event.msg.data, g_current_event.msg.data_length);
}

FLUTTER_EXPORT const char* colyseus_flutter_message_get_type_str(void) {
    return g_current_event.message;
}

FLUTTER_EXPORT int colyseus_flutter_message_get_type(void) {
    flutter_ensure_message_reader();
    if (!g_current_message_reader) return 0;
    return (int)colyseus_message_reader_get_type(g_current_message_reader);
}

FLUTTER_EXPORT const char* colyseus_flutter_message_read_string(const char* key) {
    static char buf[4096];
    buf[0] = '\0';
    flutter_ensure_message_reader();
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

FLUTTER_EXPORT double colyseus_flutter_message_read_number(const char* key) {
    flutter_ensure_message_reader();
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

FLUTTER_EXPORT int colyseus_flutter_message_read_bool(const char* key) {
    flutter_ensure_message_reader();
    if (!g_current_message_reader || !key) return 0;
    bool value = false;
    if (colyseus_message_reader_map_get_bool(g_current_message_reader, key, &value)) {
        return value ? 1 : 0;
    }
    return 0;
}

FLUTTER_EXPORT const char* colyseus_flutter_message_read_string_value(void) {
    static char buf[4096];
    buf[0] = '\0';
    flutter_ensure_message_reader();
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

FLUTTER_EXPORT double colyseus_flutter_message_read_number_value(void) {
    flutter_ensure_message_reader();
    if (!g_current_message_reader) return 0.0;
    if (colyseus_message_reader_is_float(g_current_message_reader)) {
        return colyseus_message_reader_get_float(g_current_message_reader);
    }
    if (colyseus_message_reader_is_int(g_current_message_reader)) {
        return (double)colyseus_message_reader_get_int(g_current_message_reader);
    }
    return 0.0;
}

// Map iterator

FLUTTER_EXPORT int colyseus_flutter_message_map_size(void) {
    flutter_ensure_message_reader();
    if (!g_current_message_reader) return 0;
    return (int)colyseus_message_reader_get_map_size(g_current_message_reader);
}

FLUTTER_EXPORT void colyseus_flutter_message_iter_begin(void) {
    if (g_current_iter_key) {
        colyseus_message_reader_free(g_current_iter_key);
        g_current_iter_key = NULL;
    }
    if (g_current_iter_value) {
        colyseus_message_reader_free(g_current_iter_value);
        g_current_iter_value = NULL;
    }

    flutter_ensure_message_reader();
    if (!g_current_message_reader) {
        memset(&g_current_map_iterator, 0, sizeof(g_current_map_iterator));
        return;
    }
    g_current_map_iterator = colyseus_message_reader_map_iterator(g_current_message_reader);
}

FLUTTER_EXPORT int colyseus_flutter_message_iter_next(void) {
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
    ) ? 1 : 0;
}

FLUTTER_EXPORT const char* colyseus_flutter_message_iter_key(void) {
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

FLUTTER_EXPORT int colyseus_flutter_message_iter_value_type(void) {
    if (!g_current_iter_value) return 0;
    return (int)colyseus_message_reader_get_type(g_current_iter_value);
}

FLUTTER_EXPORT const char* colyseus_flutter_message_iter_value_string(void) {
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

FLUTTER_EXPORT double colyseus_flutter_message_iter_value_number(void) {
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

// Array access

FLUTTER_EXPORT int colyseus_flutter_message_array_size(void) {
    flutter_ensure_message_reader();
    if (!g_current_message_reader) return 0;
    return (int)colyseus_message_reader_get_array_size(g_current_message_reader);
}

FLUTTER_EXPORT int colyseus_flutter_message_array_element_type(int index) {
    flutter_ensure_message_reader();
    if (!g_current_message_reader) return 0;

    if (g_current_array_element) {
        colyseus_message_reader_free(g_current_array_element);
        g_current_array_element = NULL;
    }

    g_current_array_element = colyseus_message_reader_get_array_element(g_current_message_reader, (size_t)index);
    if (!g_current_array_element) return 0;
    return (int)colyseus_message_reader_get_type(g_current_array_element);
}

FLUTTER_EXPORT const char* colyseus_flutter_message_array_element_string(int index) {
    static char buf[4096];
    buf[0] = '\0';
    flutter_ensure_message_reader();
    if (!g_current_message_reader) return buf;

    if (g_current_array_element) {
        colyseus_message_reader_free(g_current_array_element);
        g_current_array_element = NULL;
    }

    g_current_array_element = colyseus_message_reader_get_array_element(g_current_message_reader, (size_t)index);
    if (!g_current_array_element) return buf;

    size_t len = 0;
    const char* str = colyseus_message_reader_get_str(g_current_array_element, &len);
    if (str && len > 0) {
        if (len >= sizeof(buf)) len = sizeof(buf) - 1;
        memcpy(buf, str, len);
        buf[len] = '\0';
    }
    return buf;
}

FLUTTER_EXPORT double colyseus_flutter_message_array_element_number(int index) {
    flutter_ensure_message_reader();
    if (!g_current_message_reader) return 0.0;

    if (g_current_array_element) {
        colyseus_message_reader_free(g_current_array_element);
        g_current_array_element = NULL;
    }

    g_current_array_element = colyseus_message_reader_get_array_element(g_current_message_reader, (size_t)index);
    if (!g_current_array_element) return 0.0;

    if (colyseus_message_reader_is_float(g_current_array_element)) {
        return colyseus_message_reader_get_float(g_current_array_element);
    }
    if (colyseus_message_reader_is_int(g_current_array_element)) {
        return (double)colyseus_message_reader_get_int(g_current_array_element);
    }
    return 0.0;
}

// =============================================================================
// State / Schema Access Functions
// =============================================================================

FLUTTER_EXPORT intptr_t colyseus_flutter_room_get_state(int room_handle) {
    colyseus_room_t* room = flutter_room_ref_get(room_handle);
    if (!room) return 0;
    void* state = colyseus_room_get_state(room);
    return (intptr_t)state;
}

FLUTTER_EXPORT const char* colyseus_flutter_schema_get_string(intptr_t instance_handle, const char* field_name) {
    static char buffer[4096];
    buffer[0] = '\0';

    colyseus_schema_t* schema = (colyseus_schema_t*)instance_handle;
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

FLUTTER_EXPORT double colyseus_flutter_schema_get_number(intptr_t instance_handle, const char* field_name) {
    colyseus_schema_t* schema = (colyseus_schema_t*)instance_handle;
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

FLUTTER_EXPORT int colyseus_flutter_schema_get_field_type(intptr_t instance_handle, const char* field_name) {
    colyseus_schema_t* schema = (colyseus_schema_t*)instance_handle;
    if (!schema || !field_name) return -1;

    if (colyseus_vtable_is_dynamic(schema->__vtable)) {
        colyseus_dynamic_schema_t* dyn = (colyseus_dynamic_schema_t*)schema;
        colyseus_dynamic_value_t* val = colyseus_dynamic_schema_get_by_name(dyn, field_name);
        if (val) return (int)val->type;
    } else {
        for (int i = 0; i < schema->__vtable->field_count; i++) {
            if (schema->__vtable->fields[i].name &&
                strcmp(schema->__vtable->fields[i].name, field_name) == 0) {
                return (int)schema->__vtable->fields[i].type;
            }
        }
    }
    return -1;
}

FLUTTER_EXPORT intptr_t colyseus_flutter_map_get(intptr_t instance_handle, const char* field_name, const char* key) {
    colyseus_schema_t* schema = (colyseus_schema_t*)instance_handle;
    if (!schema || !field_name || !key) return 0;

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

    if (!map) return 0;
    void* item = colyseus_map_schema_get(map, key);
    return (intptr_t)item;
}

// =============================================================================
// Callbacks Functions
// =============================================================================

FLUTTER_EXPORT intptr_t colyseus_flutter_callbacks_create(int room_handle) {
    colyseus_room_t* room = flutter_room_ref_get(room_handle);
    if (!room || !room->serializer || !room->serializer->decoder) return 0;

    flutter_callbacks_wrapper_t* wrapper = (flutter_callbacks_wrapper_t*)calloc(1, sizeof(flutter_callbacks_wrapper_t));
    if (!wrapper) return 0;

    wrapper->native = colyseus_callbacks_create(room->serializer->decoder);
    wrapper->room = room;
    wrapper->room_ref = room_handle;

    flutter_room_ref_add_callbacks(room_handle, wrapper);

    return (intptr_t)wrapper;
}

FLUTTER_EXPORT void colyseus_flutter_callbacks_free(intptr_t callbacks_handle) {
    flutter_callbacks_wrapper_t* wrapper = (flutter_callbacks_wrapper_t*)callbacks_handle;
    if (!wrapper) return;

    flutter_room_ref_remove_callbacks(wrapper->room_ref, wrapper);
    flutter_callbacks_wrapper_free(wrapper);
}

FLUTTER_EXPORT void colyseus_flutter_callbacks_remove_handle(intptr_t callbacks_handle, int callback_handle) {
    flutter_callbacks_wrapper_t* wrapper = (flutter_callbacks_wrapper_t*)callbacks_handle;
    int idx = callback_handle;
    if (!wrapper || !wrapper->native || idx < 0 || idx >= MAX_FLUTTER_CALLBACK_ENTRIES) return;

    flutter_callback_entry_t* entry = &g_callback_entries[idx];
    if (!entry->active) return;

    colyseus_callbacks_remove(wrapper->native, entry->native_handle);
    entry->active = false;
}

FLUTTER_EXPORT int colyseus_flutter_callbacks_listen(intptr_t callbacks_handle, intptr_t instance_handle, const char* property) {
    flutter_callbacks_wrapper_t* wrapper = (flutter_callbacks_wrapper_t*)callbacks_handle;
    if (!wrapper || !wrapper->native || !property) return -1;

    void* instance = NULL;
    if (instance_handle == 0) {
        instance = colyseus_room_get_state(wrapper->room);
    } else {
        instance = (void*)instance_handle;
    }
    if (!instance) return -1;

    flutter_callback_entry_t* entry = flutter_find_free_callback_entry();
    if (!entry) return -1;

    entry->active = true;
    entry->room_handle = wrapper->room_ref;
    entry->callback_type = 0;  // LISTEN
    entry->value_type = COLYSEUS_FIELD_STRING;  // default

    flutter_resolve_field_type(instance, property, entry);

    entry->native_handle = colyseus_callbacks_listen(
        wrapper->native,
        instance,
        property,
        flutter_property_change_trampoline,
        entry,
        false  // not immediate
    );

    return entry->index;
}

FLUTTER_EXPORT int colyseus_flutter_callbacks_on_add(intptr_t callbacks_handle, intptr_t instance_handle, const char* property) {
    flutter_callbacks_wrapper_t* wrapper = (flutter_callbacks_wrapper_t*)callbacks_handle;
    if (!wrapper || !wrapper->native || !property) return -1;

    void* instance = NULL;
    if (instance_handle == 0) {
        instance = colyseus_room_get_state(wrapper->room);
    } else {
        instance = (void*)instance_handle;
    }
    if (!instance) return -1;

    flutter_callback_entry_t* entry = flutter_find_free_callback_entry();
    if (!entry) return -1;

    entry->active = true;
    entry->room_handle = wrapper->room_ref;
    entry->callback_type = 1;  // ON_ADD
    entry->value_type = COLYSEUS_FIELD_MAP;  // default for collections
    entry->parent_instance = instance;
    entry->child_type = FLUTTER_CHILD_UNRESOLVED;
    strncpy(entry->property, property, sizeof(entry->property) - 1);

    flutter_resolve_field_type(instance, property, entry);

    entry->native_handle = colyseus_callbacks_on_add(
        wrapper->native,
        instance,
        property,
        flutter_item_add_trampoline,
        entry,
        true  // immediate
    );

    return entry->index;
}

FLUTTER_EXPORT int colyseus_flutter_callbacks_on_remove(intptr_t callbacks_handle, intptr_t instance_handle, const char* property) {
    flutter_callbacks_wrapper_t* wrapper = (flutter_callbacks_wrapper_t*)callbacks_handle;
    if (!wrapper || !wrapper->native || !property) return -1;

    void* instance = NULL;
    if (instance_handle == 0) {
        instance = colyseus_room_get_state(wrapper->room);
    } else {
        instance = (void*)instance_handle;
    }
    if (!instance) return -1;

    flutter_callback_entry_t* entry = flutter_find_free_callback_entry();
    if (!entry) return -1;

    entry->active = true;
    entry->room_handle = wrapper->room_ref;
    entry->callback_type = 2;  // ON_REMOVE
    entry->value_type = COLYSEUS_FIELD_MAP;  // default for collections
    entry->parent_instance = instance;
    entry->child_type = FLUTTER_CHILD_UNRESOLVED;
    strncpy(entry->property, property, sizeof(entry->property) - 1);

    flutter_resolve_field_type(instance, property, entry);

    entry->native_handle = colyseus_callbacks_on_remove(
        wrapper->native,
        instance,
        property,
        flutter_item_remove_trampoline,
        entry
    );

    return entry->index;
}
