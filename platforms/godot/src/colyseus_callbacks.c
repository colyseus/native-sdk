#include "colyseus_callbacks.h"
#include "colyseus_state.h"
#include "colyseus_gdscript_schema.h"
#include <colyseus/room.h>
#include <colyseus/schema.h>
#include <colyseus/schema/ref_tracker.h>
#include <colyseus/schema/dynamic_schema.h>
#include <colyseus/schema/collections.h>
#include <stdlib.h>
#include <string.h>

// Storage for the last created wrapper (for factory method)
static ColyseusCallbacksWrapper* g_last_created_callbacks_wrapper = NULL;

// ============================================================================
// Helpers
// ============================================================================

static char* variant_string_to_c_str(GDExtensionConstVariantPtr var) {
    String str;
    constructors.string_from_variant_constructor(&str, (GDExtensionVariantPtr)var);
    int32_t length = api.string_to_utf8_chars(&str, NULL, 0);
    char* buffer = (char*)malloc((size_t)(length > 0 ? length : 0) + 1);
    if (buffer) {
        if (length > 0) api.string_to_utf8_chars(&str, buffer, length);
        buffer[length > 0 ? length : 0] = '\0';
    }
    destructors.string_destructor(&str);
    return buffer;
}

static bool is_string_type(GDExtensionVariantType t) {
    return t == GDEXTENSION_VARIANT_TYPE_STRING || t == GDEXTENSION_VARIANT_TYPE_STRING_NAME;
}

static colyseus_decoder_t* room_decoder(ColyseusRoomWrapper* rw) {
    if (!rw || !rw->native_room || !rw->native_room->serializer) return NULL;
    return rw->native_room->serializer->decoder;
}

/* Object OR Dictionary target — both answer get("__ref_id"). -1 when absent. */
static int variant_ref_id(GDExtensionConstVariantPtr target) {
    static StringName get_sn;
    static bool ready = false;
    if (!ready) {
        constructors.string_name_new_with_latin1_chars(&get_sn, "get", false);
        ready = true;
    }
    String prop_str;
    constructors.string_new_with_utf8_chars(&prop_str, "__ref_id");
    Variant prop_var;
    constructors.variant_from_string_constructor(&prop_var, &prop_str);

    GDExtensionConstVariantPtr args[1] = { &prop_var };
    Variant result;
    GDExtensionCallError error;
    api.variant_call((GDExtensionVariantPtr)target, &get_sn, args, 1, &result, &error);

    destructors.variant_destroy(&prop_var);
    destructors.string_destructor(&prop_str);

    int ref_id = -1;
    GDExtensionVariantType t = api.variant_get_type(&result);
    if (error.error == GDEXTENSION_CALL_OK && (t == GDEXTENSION_VARIANT_TYPE_INT || t == GDEXTENSION_VARIANT_TYPE_FLOAT)) {
        int64_t v = 0;
        constructors.int_from_variant_constructor(&v, &result);
        ref_id = (int)v;
    }
    destructors.variant_destroy(&result);
    return ref_id;
}

colyseus_schema_t* gdext_resolve_schema(colyseus_room_t* room, GDExtensionConstVariantPtr target) {
    if (!room || !room->serializer || !room->serializer->decoder || !room->serializer->decoder->refs) return NULL;
    int ref_id = variant_ref_id(target);
    if (ref_id < 0) return NULL;
    colyseus_ref_entry_t* entry = colyseus_ref_tracker_get_entry(room->serializer->decoder->refs, ref_id);
    if (!entry || !entry->ref || entry->ref_type != COLYSEUS_REF_TYPE_SCHEMA) return NULL;
    colyseus_schema_t* instance = (colyseus_schema_t*)entry->ref;
    if (api.variant_get_type(target) == GDEXTENSION_VARIANT_TYPE_OBJECT
            && instance->__vtable && colyseus_vtable_is_dynamic(instance->__vtable)) {
        colyseus_dynamic_schema_t* dyn = (colyseus_dynamic_schema_t*)instance;
        if (!dyn->userdata) return NULL;
        GDExtensionObjectPtr want = NULL;
        GDExtensionObjectPtr have = NULL;
        constructors.object_from_variant_constructor(&want, (GDExtensionVariantPtr)target);
        constructors.object_from_variant_constructor(&have, (GDExtensionVariantPtr)dyn->userdata);
        if (want != have) return NULL;
    }
    return instance;
}

/* The collection currently in `property`, or NULL (unset, or not a collection). */
static void* collection_of(colyseus_schema_t* schema, const char* property) {
    if (!schema || !schema->__vtable || !property) return NULL;
    if (colyseus_vtable_is_dynamic(schema->__vtable)) {
        const colyseus_dynamic_field_t* f = colyseus_dynamic_vtable_find_field_by_name(
            colyseus_vtable_as_dynamic(schema->__vtable), property);
        if (!f) return NULL;
        colyseus_dynamic_value_t* v = colyseus_dynamic_schema_get((colyseus_dynamic_schema_t*)schema, f->index);
        if (!v) return NULL;
        if (f->type == COLYSEUS_FIELD_MAP) return v->data.map;
        if (f->type == COLYSEUS_FIELD_ARRAY) return v->data.array;
        return NULL;
    }
    for (int i = 0; i < schema->__vtable->field_count; i++) {
        const colyseus_field_t* f = &schema->__vtable->fields[i];
        if (f->name && strcmp(f->name, property) == 0) {
            if (f->type != COLYSEUS_FIELD_MAP && f->type != COLYSEUS_FIELD_ARRAY) return NULL;
            return *(void**)((char*)schema + f->offset);
        }
    }
    return NULL;
}

/* Field type + what its items are. False when the schema has no such field. */
static bool lookup_field(GodotCallbackEntry* e, colyseus_schema_t* schema, const char* property) {
    if (!schema || !schema->__vtable) return false;
    e->item_vtable = NULL;
    e->item_primitive = NULL;
    if (colyseus_vtable_is_dynamic(schema->__vtable)) {
        const colyseus_dynamic_field_t* f = colyseus_dynamic_vtable_find_field_by_name(
            colyseus_vtable_as_dynamic(schema->__vtable), property);
        if (!f) return false;
        e->field_type = f->type;
        e->item_vtable = f->child_vtable ? &f->child_vtable->base : NULL;
        e->item_primitive = f->child_primitive_type;
    } else {
        bool found = false;
        for (int i = 0; i < schema->__vtable->field_count; i++) {
            const colyseus_field_t* f = &schema->__vtable->fields[i];
            if (f->name && strcmp(f->name, property) == 0) {
                e->field_type = f->type;
                e->item_vtable = f->child_vtable;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    /* a decoded collection knows its own child type, whichever vtable model */
    void* collection = collection_of(schema, property);
    if (collection && !e->item_vtable && !e->item_primitive) {
        if (e->field_type == COLYSEUS_FIELD_ARRAY) {
            colyseus_array_schema_t* arr = (colyseus_array_schema_t*)collection;
            e->item_vtable = arr->has_schema_child ? arr->child_vtable : NULL;
            e->item_primitive = arr->has_schema_child ? NULL : arr->child_primitive_type;
        } else if (e->field_type == COLYSEUS_FIELD_MAP) {
            colyseus_map_schema_t* map = (colyseus_map_schema_t*)collection;
            e->item_vtable = map->has_schema_child ? map->child_vtable : NULL;
            e->item_primitive = map->has_schema_child ? NULL : map->child_primitive_type;
        }
    }
    return true;
}

// ============================================================================
// Value conversion
// ============================================================================

static void schema_to_variant(void* value, const colyseus_schema_vtable_t* vtable_hint, Variant* out) {
    colyseus_schema_t* schema = (colyseus_schema_t*)value;
    const colyseus_schema_vtable_t* vtable = schema->__vtable ? schema->__vtable : vtable_hint;
    if (!vtable) {
        gdext_variant_new_nil(out);
        return;
    }
    if (colyseus_vtable_is_dynamic(vtable) && ((colyseus_dynamic_schema_t*)schema)->userdata) {
        api.variant_new_copy(out, (Variant*)((colyseus_dynamic_schema_t*)schema)->userdata);
        return;
    }
    Dictionary dict;
    constructors.dictionary_constructor(&dict, NULL);
    colyseus_schema_to_dictionary(schema, vtable, &dict);
    constructors.variant_from_dictionary_constructor(out, &dict);
    destructors.dictionary_destructor(&dict);
}

/* A collection field's value: the live container on typed rooms, else a snapshot. */
static void collection_to_variant(GodotCallbackEntry* e, void* collection, Variant* out) {
    ColyseusRoomWrapper* rw = e->owner ? e->owner->room_wrapper : NULL;
    int ref_id = *(int*)collection;  /* __refId leads both collection structs */
    if (rw && rw->gdscript_schema_ctx && gdscript_live_container(rw->gdscript_schema_ctx, ref_id, out)) {
        return;
    }
    if (e->field_type == COLYSEUS_FIELD_ARRAY) {
        Array arr;
        constructors.array_constructor(&arr, NULL);
        colyseus_array_to_godot_array((colyseus_array_schema_t*)collection, &arr);
        constructors.variant_from_array_constructor(out, &arr);
        destructors.array_destructor(&arr);
    } else {
        Dictionary dict;
        constructors.dictionary_constructor(&dict, NULL);
        colyseus_map_to_dictionary((colyseus_map_schema_t*)collection, &dict);
        constructors.variant_from_dictionary_constructor(out, &dict);
        destructors.dictionary_destructor(&dict);
    }
}

/* A field value as the core hands it to listen(): primitives by pointer,
 * strings as char*, refs/collections as the instance pointer. */
static void field_value_to_variant(GodotCallbackEntry* e, void* value, Variant* out) {
    if (!value) {
        gdext_variant_new_nil(out);
        return;
    }
    int64_t i = 0;
    double d = 0;
    switch (e->field_type) {
        case COLYSEUS_FIELD_STRING: {
            String str;
            constructors.string_new_with_utf8_chars(&str, (const char*)value);
            constructors.variant_from_string_constructor(out, &str);
            destructors.string_destructor(&str);
            return;
        }
        case COLYSEUS_FIELD_INT8:   i = *(int8_t*)value; break;
        case COLYSEUS_FIELD_INT16:  i = *(int16_t*)value; break;
        case COLYSEUS_FIELD_INT32:  i = *(int32_t*)value; break;
        case COLYSEUS_FIELD_INT64:  i = *(int64_t*)value; break;
        case COLYSEUS_FIELD_UINT8:  i = *(uint8_t*)value; break;
        case COLYSEUS_FIELD_UINT16: i = *(uint16_t*)value; break;
        case COLYSEUS_FIELD_UINT32: i = *(uint32_t*)value; break;
        case COLYSEUS_FIELD_UINT64: i = (int64_t)*(uint64_t*)value; break;
        case COLYSEUS_FIELD_FLOAT32:
            d = *(float*)value;
            constructors.variant_from_float_constructor(out, &d);
            return;
        case COLYSEUS_FIELD_NUMBER:
        case COLYSEUS_FIELD_QUANTIZED: /* dequantized */
        case COLYSEUS_FIELD_FLOAT64:
            d = *(double*)value;
            constructors.variant_from_float_constructor(out, &d);
            return;
        case COLYSEUS_FIELD_BOOLEAN: {
            GDExtensionBool b = *(bool*)value ? 1 : 0;
            constructors.variant_from_bool_constructor(out, &b);
            return;
        }
        case COLYSEUS_FIELD_REF:
            schema_to_variant(value, e->item_vtable, out);
            return;
        case COLYSEUS_FIELD_ARRAY:
        case COLYSEUS_FIELD_MAP:
            collection_to_variant(e, value, out);
            return;
        default:
            gdext_variant_new_nil(out);
            return;
    }
    constructors.variant_from_int_constructor(out, &i);
}

/* A collection item: schema children by instance, primitives by their type. */
static void item_to_variant(GodotCallbackEntry* e, void* value, Variant* out) {
    if (!value) {
        gdext_variant_new_nil(out);
    } else if (e->item_vtable) {
        schema_to_variant(value, e->item_vtable, out);
    } else if (e->item_primitive) {
        gdscript_primitive_to_variant(value, e->item_primitive, out);
    } else {
        gdext_variant_new_nil(out);
    }
}

static void key_to_variant(GodotCallbackEntry* e, void* key, Variant* out) {
    if (!key) {
        gdext_variant_new_nil(out);
    } else if (e->field_type == COLYSEUS_FIELD_ARRAY) {
        int64_t index = *(int*)key;
        constructors.variant_from_int_constructor(out, &index);
    } else {
        String str;
        constructors.string_new_with_utf8_chars(&str, (const char*)key);
        constructors.variant_from_string_constructor(out, &str);
        destructors.string_destructor(&str);
    }
}

// ============================================================================
// Trampolines — called by the core, invoke the GDScript Callable
// ============================================================================

/* Now: inside Colyseus.poll() (wire order), or on the main thread while no
 * decode is open (a registration's immediate replay, like TS). Deferred: a
 * decode outside poll — web socket events arrive from the browser's event
 * loop, between engine frames — or any other thread. */
static bool deliver_now(GodotCallbackEntry* entry) {
    if (gdext_in_dispatch()) return true;
    ColyseusRoomWrapper* rw = entry->owner ? entry->owner->room_wrapper : NULL;
    return gdext_on_main_thread() && !(rw && rw->decoding);
}

static void invoke_entry(GodotCallbackEntry* entry, const GDExtensionConstVariantPtr* args, int argc) {
    if (!entry || !entry->active) return;

    static StringName call_sn, deferred_sn;
    static bool ready = false;
    if (!ready) {
        constructors.string_name_new_with_latin1_chars(&call_sn, "call", false);
        constructors.string_name_new_with_latin1_chars(&deferred_sn, "call_deferred", false);
        ready = true;
    }

    /* a copy: remove() from inside the callback must not free what's running */
    Variant callable;
    api.variant_new_copy(&callable, &entry->callable);
    Variant ret;
    GDExtensionCallError err;
    api.variant_call(&callable, deliver_now(entry) ? &call_sn : &deferred_sn, args, argc, &ret, &err);
    destructors.variant_destroy(&ret);
    destructors.variant_destroy(&callable);
}

static void property_change_trampoline(void* value, void* previous_value, void* userdata) {
    GodotCallbackEntry* entry = (GodotCallbackEntry*)userdata;
    if (!entry || !entry->active) return;
    Variant current, previous;
    field_value_to_variant(entry, value, &current);
    field_value_to_variant(entry, previous_value, &previous);
    GDExtensionConstVariantPtr args[2] = { &current, &previous };
    invoke_entry(entry, args, 2);
    destructors.variant_destroy(&current);
    destructors.variant_destroy(&previous);
}

static void item_trampoline(void* value, void* key, void* userdata) {
    GodotCallbackEntry* entry = (GodotCallbackEntry*)userdata;
    if (!entry || !entry->active) return;
    Variant value_variant, key_variant;
    item_to_variant(entry, value, &value_variant);
    key_to_variant(entry, key, &key_variant);
    GDExtensionConstVariantPtr args[2] = { &value_variant, &key_variant };
    invoke_entry(entry, args, 2);
    destructors.variant_destroy(&value_variant);
    destructors.variant_destroy(&key_variant);
}

static void instance_change_trampoline(void* userdata) {
    GodotCallbackEntry* entry = (GodotCallbackEntry*)userdata;
    if (!entry || !entry->active) return;
    invoke_entry(entry, NULL, 0);
}

static void collection_change_trampoline(void* key, void* value, void* userdata) {
    GodotCallbackEntry* entry = (GodotCallbackEntry*)userdata;
    if (!entry || !entry->active) return;
    Variant key_variant, value_variant;
    key_to_variant(entry, key, &key_variant);
    item_to_variant(entry, value, &value_variant);
    GDExtensionConstVariantPtr args[2] = { &key_variant, &value_variant };
    invoke_entry(entry, args, 2);
    destructors.variant_destroy(&key_variant);
    destructors.variant_destroy(&value_variant);
}

// ============================================================================
// Entry table + lifetime
// ============================================================================

static void wrapper_release(void* data);
static void reap_now(void* data);

static GodotCallbackEntry* entry_new(ColyseusCallbacksWrapper* w) {
    if (w->entry_count == w->entry_capacity) {
        int capacity = w->entry_capacity ? w->entry_capacity * 2 : 32;
        GodotCallbackEntry** grown = (GodotCallbackEntry**)realloc(w->entries, (size_t)capacity * sizeof(GodotCallbackEntry*));
        if (!grown) {
            gdext_push_error("Colyseus.Callbacks: out of memory registering callback #%d", w->entry_count + 1);
            return NULL;
        }
        w->entries = grown;
        w->entry_capacity = capacity;
    }
    GodotCallbackEntry* e = (GodotCallbackEntry*)calloc(1, sizeof(GodotCallbackEntry));
    if (!e) return NULL;
    e->handle = ++w->next_handle;
    e->native = COLYSEUS_INVALID_CALLBACK_HANDLE;
    e->target_ref_id = -1;
    e->owner = w;
    gdext_variant_new_nil(&e->callable);
    w->entries[w->entry_count++] = e;
    return e;
}

static void entry_free(GodotCallbackEntry* e) {
    free(e->property);
    destructors.variant_destroy(&e->callable);
    free(e);
}

static GodotCallbackEntry* find_entry(ColyseusCallbacksWrapper* w, int handle) {
    for (int i = 0; i < w->entry_count; i++) {
        if (w->entries[i]->handle == handle && w->entries[i]->active) return w->entries[i];
    }
    return NULL;
}

static void wrapper_enter(ColyseusCallbacksWrapper* w) { w->busy++; }

static void wrapper_leave(ColyseusCallbacksWrapper* w) {
    if (--w->busy > 0) return;
    if (w->dead) {
        gdext_after_dispatch(wrapper_release, w);
    } else if (w->reap_scheduled) {
        gdext_after_dispatch(reap_now, w);
    }
}

/* Removed entries leave the core once no decode is walking its lists. */
static void schedule_reap(ColyseusCallbacksWrapper* w) {
    if (w->reap_scheduled) return;
    w->reap_scheduled = true;
    if (w->busy == 0) gdext_after_dispatch(reap_now, w);
}

static void reap_now(void* data) {
    ColyseusCallbacksWrapper* w = (ColyseusCallbacksWrapper*)data;
    if (!w->reap_scheduled || w->busy > 0) return;
    w->reap_scheduled = false;
    int kept = 0;
    for (int i = 0; i < w->entry_count; i++) {
        GodotCallbackEntry* e = w->entries[i];
        if (e->active) {
            w->entries[kept++] = e;
            continue;
        }
        /* the handle survives a waiting on_add binding to its collection;
         * a no-op once the core dropped it with a collected ref */
        if (e->native != COLYSEUS_INVALID_CALLBACK_HANDLE && w->native_callbacks) {
            colyseus_callbacks_remove(w->native_callbacks, e->native);
        }
        entry_free(e);
    }
    w->entry_count = kept;
}

static void wrapper_release(void* data) {
    ColyseusCallbacksWrapper* w = (ColyseusCallbacksWrapper*)data;
    if (w->native_callbacks) colyseus_callbacks_free(w->native_callbacks);
    for (int i = 0; i < w->entry_count; i++) entry_free(w->entries[i]);
    free(w->entries);
    free(w);
}

static void unlink_from_room(ColyseusCallbacksWrapper* w) {
    ColyseusRoomWrapper* rw = w->room_wrapper;
    if (!rw) return;
    for (ColyseusCallbacksWrapper** p = &rw->callbacks; *p; p = &(*p)->next_in_room) {
        if (*p == w) {
            *p = w->next_in_room;  /* w keeps its own next: a walk standing on it can move on */
            break;
        }
    }
}

// ============================================================================
// Registration
// ============================================================================

/* The core callbacks object, created once the decoder exists and no decode is
 * open — one added mid-decode would get this decode's changes AND replay them. */
static bool ensure_native(ColyseusCallbacksWrapper* w) {
    if (w->native_callbacks) return true;
    ColyseusRoomWrapper* rw = w->room_wrapper;
    colyseus_decoder_t* decoder = room_decoder(rw);
    if (!decoder || rw->decoding) return false;
    w->native_callbacks = colyseus_callbacks_create(decoder);
    if (!w->native_callbacks && !w->slot_error_reported) {
        w->slot_error_reported = true;
        gdext_push_error("Colyseus.Callbacks: the room's decoder has no change-listener slot left "
                         "(COLYSEUS_DECODER_MAX_TRIGGERS); each Predict takes one — reuse Predict objects");
    }
    return w->native_callbacks != NULL;
}

/* The decoder exists and no decode is open, yet there's no core object: out of slots. */
static bool native_unavailable(ColyseusCallbacksWrapper* w) {
    ColyseusRoomWrapper* rw = w->room_wrapper;
    return !w->native_callbacks && rw && room_decoder(rw) && !rw->decoding;
}

static const char* callback_type_name(ColyseusGodotCallbackType type) {
    switch (type) {
        case COLYSEUS_GDCB_LISTEN: return "listen";
        case COLYSEUS_GDCB_ON_ADD: return "on_add";
        case COLYSEUS_GDCB_ON_REMOVE: return "on_remove";
        default: return "on_change";
    }
}

/* Hands an entry to the core. Immediate replays (listen's current value,
 * on_add's existing items) run inside, so GDScript may re-enter here. */
static bool attach_entry(ColyseusCallbacksWrapper* w, GodotCallbackEntry* e, colyseus_schema_t* instance) {
    const char* prop = e->property;
    if (prop && !lookup_field(e, instance, prop)) {
        gdext_push_error("Colyseus.Callbacks.%s(): '%s' is not a field of this schema",
                         callback_type_name(e->type), prop);
        return false;
    }
    bool is_collection = e->field_type == COLYSEUS_FIELD_ARRAY || e->field_type == COLYSEUS_FIELD_MAP;
    if (prop && e->type != COLYSEUS_GDCB_LISTEN && !is_collection) {
        gdext_push_error("Colyseus.Callbacks.%s(): '%s' is not a map or array field",
                         callback_type_name(e->type), prop);
        return false;
    }
    colyseus_callbacks_t* nc = w->native_callbacks;
    colyseus_callback_handle_t native = COLYSEUS_INVALID_CALLBACK_HANDLE;
    e->pending = false;
    e->attaching = true;
    wrapper_enter(w);
    switch (e->type) {
        case COLYSEUS_GDCB_LISTEN:
            native = colyseus_callbacks_listen(nc, instance, prop, property_change_trampoline, e, true);
            break;
        case COLYSEUS_GDCB_ON_ADD:
            native = colyseus_callbacks_on_add(nc, instance, prop, item_trampoline, e, true);
            break;
        case COLYSEUS_GDCB_ON_REMOVE:
            native = colyseus_callbacks_on_remove(nc, instance, prop, item_trampoline, e);
            break;
        case COLYSEUS_GDCB_ON_CHANGE:
            native = prop
                ? colyseus_callbacks_on_change_collection(nc, instance, prop, collection_change_trampoline, e)
                : colyseus_callbacks_on_change_instance(nc, instance, instance_change_trampoline, e);
            break;
    }
    e->attaching = false;
    e->native = native;
    if (native == COLYSEUS_INVALID_CALLBACK_HANDLE) {
        wrapper_leave(w);
        gdext_push_error("Colyseus.Callbacks.%s(): the SDK refused '%s'",
                         callback_type_name(e->type), prop ? prop : "(instance)");
        return false;
    }
    if (!e->active) schedule_reap(w);  /* removed from inside its own replay */
    wrapper_leave(w);
    return true;
}

static colyseus_schema_t* pending_target(ColyseusCallbacksWrapper* w, GodotCallbackEntry* e) {
    ColyseusRoomWrapper* rw = w->room_wrapper;
    if (!rw || !rw->native_room) return NULL;
    if (e->target_ref_id < 0) return colyseus_room_get_state(rw->native_room);
    colyseus_decoder_t* decoder = room_decoder(rw);
    if (!decoder) return NULL;
    /* still the same instance (ids get recycled) */
    return colyseus_ref_tracker_get(decoder->refs, e->target_ref_id) == e->target ? e->target : NULL;
}

static void register_callback(ColyseusCallbacksWrapper* w, ColyseusGodotCallbackType type,
    const GDExtensionConstVariantPtr* args, GDExtensionInt argc,
    GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    int64_t result = -1;
    GDExtensionConstVariantPtr target = NULL;
    GDExtensionConstVariantPtr prop_arg = NULL;
    GDExtensionConstVariantPtr callable_arg = NULL;

    if (argc < 1) {
        if (r_error) { r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; r_error->argument = 2; }
        goto done;
    }
    GDExtensionVariantType t0 = api.variant_get_type(args[0]);
    if (type == COLYSEUS_GDCB_ON_CHANGE && t0 == GDEXTENSION_VARIANT_TYPE_CALLABLE) {
        callable_arg = args[0];
    } else if (is_string_type(t0)) {
        if (argc < 2) {
            if (r_error) { r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; r_error->argument = 2; }
            goto done;
        }
        prop_arg = args[0];
        callable_arg = args[1];
    } else if (t0 == GDEXTENSION_VARIANT_TYPE_OBJECT || t0 == GDEXTENSION_VARIANT_TYPE_DICTIONARY) {
        target = args[0];
        if (argc >= 2 && type == COLYSEUS_GDCB_ON_CHANGE
                && api.variant_get_type(args[1]) == GDEXTENSION_VARIANT_TYPE_CALLABLE) {
            callable_arg = args[1];
        } else if (argc >= 3) {
            prop_arg = args[1];
            callable_arg = args[2];
        } else {
            if (r_error) { r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; r_error->argument = 3; }
            goto done;
        }
    } else {
        if (r_error) { r_error->error = GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT; r_error->argument = 0; }
        goto done;
    }
    if (api.variant_get_type(callable_arg) != GDEXTENSION_VARIANT_TYPE_CALLABLE) {
        gdext_push_error("Colyseus.Callbacks.%s(): the last argument must be a Callable", callback_type_name(type));
        goto done;
    }

    colyseus_schema_t* instance = NULL;
    if (target) {
        ColyseusRoomWrapper* rw = w->room_wrapper;
        instance = rw && rw->native_room ? gdext_resolve_schema(rw->native_room, target) : NULL;
        if (!instance) {
            gdext_push_error("Colyseus.Callbacks.%s(): the target is not a live schema instance of this room "
                             "(removed, or from another room)", callback_type_name(type));
            goto done;
        }
    } else if (!w->room_wrapper) {
        gdext_push_error("Colyseus.Callbacks.%s(): the room is gone", callback_type_name(type));
        goto done;
    }

    bool live_now = ensure_native(w);
    if (!live_now && native_unavailable(w)) goto done;  /* reported by ensure_native */

    GodotCallbackEntry* e = entry_new(w);
    if (!e) goto done;
    e->type = type;
    e->active = true;
    e->property = prop_arg ? variant_string_to_c_str(prop_arg) : NULL;
    api.variant_new_copy(&e->callable, callable_arg);
    /* nested targets are watched: the core drops their registrations on release */
    e->target = instance;
    e->target_ref_id = instance ? instance->__refId : -1;
    result = e->handle;

    if (!target && live_now) {
        instance = colyseus_room_get_state(w->room_wrapper->native_room);
    }
    if (instance && live_now) {
        if (!attach_entry(w, e, instance)) {
            e->active = false;
            schedule_reap(w);
            result = -1;
        }
    } else {
        /* not joined yet, or a decode is open: goes live after `joined` / state_changed */
        e->pending = true;
    }

done:
    if (r_return) constructors.variant_from_int_constructor(r_return, &result);
}

static void flush_wrapper(ColyseusCallbacksWrapper* w) {
    bool any = false;
    for (int i = 0; i < w->entry_count && !any; i++) any = w->entries[i]->pending && w->entries[i]->active;
    if (!any || !ensure_native(w)) return;

    wrapper_enter(w);
    /* by index: replays may register more (appended) — they're live already */
    for (int i = 0; i < w->entry_count; i++) {
        GodotCallbackEntry* e = w->entries[i];
        if (!e->pending || !e->active) continue;
        colyseus_schema_t* instance = pending_target(w, e);
        if (!instance) {
            gdext_push_error("Colyseus.Callbacks.%s(): the target was removed before it could be registered",
                             callback_type_name(e->type));
            e->pending = false;
            e->active = false;
            schedule_reap(w);
            continue;
        }
        if (!attach_entry(w, e, instance)) {
            e->active = false;
            schedule_reap(w);
        }
    }
    wrapper_leave(w);
}

void gdext_callbacks_flush_room(ColyseusRoomWrapper* room_wrapper) {
    if (!room_wrapper || room_wrapper->decoding) return;
    ColyseusCallbacksWrapper* w = room_wrapper->callbacks;
    while (w) {
        ColyseusCallbacksWrapper* next = w->next_in_room;
        if (!w->dead) flush_wrapper(w);
        w = next;
    }
}

void gdext_callbacks_ref_collected(ColyseusRoomWrapper* room_wrapper, int ref_id) {
    if (!room_wrapper || ref_id < 0) return;
    for (ColyseusCallbacksWrapper* w = room_wrapper->callbacks; w; w = w->next_in_room) {
        bool retired = false;
        for (int i = 0; i < w->entry_count; i++) {
            GodotCallbackEntry* e = w->entries[i];
            if (!e->active || e->target_ref_id != ref_id) continue;
            e->active = false;
            e->pending = false;
            destructors.variant_destroy(&e->callable);
            gdext_variant_new_nil(&e->callable);
            retired = true;
        }
        if (retired) schedule_reap(w);
    }
}

void gdext_callbacks_detach_room(ColyseusRoomWrapper* room_wrapper) {
    if (!room_wrapper) return;
    for (ColyseusCallbacksWrapper* w = room_wrapper->callbacks; w; w = w->next_in_room) {
        if (w->native_callbacks) {
            colyseus_callbacks_free(w->native_callbacks);
            w->native_callbacks = NULL;
        }
        for (int i = 0; i < w->entry_count; i++) {
            w->entries[i]->native = COLYSEUS_INVALID_CALLBACK_HANDLE;
        }
        w->room_wrapper = NULL;
    }
    room_wrapper->callbacks = NULL;
}

// ============================================================================
// Constructor/Destructor
// ============================================================================

GDExtensionObjectPtr gdext_colyseus_callbacks_constructor(void* p_class_userdata) {
    (void)p_class_userdata;

    StringName parent_class_name;
    constructors.string_name_new_with_latin1_chars(&parent_class_name, "RefCounted", false);
    GDExtensionObjectPtr object = api.classdb_construct_object(&parent_class_name);
    destructors.string_name_destructor(&parent_class_name);
    if (!object) return NULL;

    ColyseusCallbacksWrapper* wrapper = (ColyseusCallbacksWrapper*)calloc(1, sizeof(ColyseusCallbacksWrapper));
    if (!wrapper) return NULL;
    wrapper->godot_object = object;

    StringName class_name;
    constructors.string_name_new_with_latin1_chars(&class_name, "_ColyseusCallbacks", false);
    api.object_set_instance(object, &class_name, wrapper);
    destructors.string_name_destructor(&class_name);

    g_last_created_callbacks_wrapper = wrapper;
    return object;
}

void gdext_colyseus_callbacks_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;

    ColyseusCallbacksWrapper* wrapper = (ColyseusCallbacksWrapper*)p_instance;
    if (!wrapper) return;

    unlink_from_room(wrapper);
    wrapper->dead = true;
    wrapper->godot_object = NULL;
    for (int i = 0; i < wrapper->entry_count; i++) wrapper->entries[i]->active = false;
    /* a decode may be walking the core's lists (dropped from a callback) */
    if (wrapper->busy == 0) gdext_after_dispatch(wrapper_release, wrapper);
}

ColyseusCallbacksWrapper* gdext_colyseus_callbacks_get_last_wrapper(void) {
    ColyseusCallbacksWrapper* wrapper = g_last_created_callbacks_wrapper;
    g_last_created_callbacks_wrapper = NULL;
    return wrapper;
}

void gdext_colyseus_callbacks_init_with_room(ColyseusCallbacksWrapper* wrapper, ColyseusRoomWrapper* room_wrapper) {
    if (!wrapper || !room_wrapper) return;
    wrapper->room_wrapper = room_wrapper;
    wrapper->next_in_room = room_wrapper->callbacks;
    room_wrapper->callbacks = wrapper;
    ensure_native(wrapper);
}

// ============================================================================
// Static factory method: ColyseusCallbacks.get(room)
// ============================================================================

void gdext_colyseus_callbacks_get(
    void* p_method_userdata,
    GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args,
    GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return,
    GDExtensionCallError* r_error
) {
    (void)p_method_userdata;
    (void)p_instance;

    if (p_argument_count < 1) {
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
        return;
    }

    GDExtensionObjectPtr room_obj = NULL;
    constructors.object_from_variant_constructor(&room_obj, (GDExtensionVariantPtr)p_args[0]);
    if (!room_obj) {
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT;
        return;
    }
    ColyseusRoomWrapper* room_wrapper = gdext_colyseus_room_get_wrapper_by_id(api.object_get_instance_id(room_obj));

    /* one per room: every core callbacks object takes one of the decoder's few listener slots */
    if (room_wrapper && room_wrapper->callbacks && room_wrapper->callbacks->godot_object) {
        GDExtensionObjectPtr existing = room_wrapper->callbacks->godot_object;
        if (r_return) constructors.variant_from_object_constructor(r_return, &existing);
        return;
    }

    StringName class_name;
    constructors.string_name_new_with_latin1_chars(&class_name, "_ColyseusCallbacks", false);
    GDExtensionObjectPtr callbacks_obj = api.classdb_construct_object(&class_name);
    destructors.string_name_destructor(&class_name);
    if (!callbacks_obj) {
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_INVALID_METHOD;
        return;
    }

    ColyseusCallbacksWrapper* wrapper = gdext_colyseus_callbacks_get_last_wrapper();
    if (wrapper && room_wrapper) {
        gdext_colyseus_callbacks_init_with_room(wrapper, room_wrapper);
    }

    if (r_return) {
        constructors.variant_from_object_constructor(r_return, &callbacks_obj);
    }
}

// ============================================================================
// Instance methods
// ============================================================================

#define CALLBACKS_METHOD(NAME, TYPE) \
    void NAME(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, \
        const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, \
        GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) { \
        (void)p_method_userdata; \
        ColyseusCallbacksWrapper* wrapper = (ColyseusCallbacksWrapper*)p_instance; \
        if (!wrapper) { \
            if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_INSTANCE_IS_NULL; \
            return; \
        } \
        register_callback(wrapper, TYPE, p_args, p_argument_count, r_return, r_error); \
    }

CALLBACKS_METHOD(gdext_colyseus_callbacks_listen, COLYSEUS_GDCB_LISTEN)
CALLBACKS_METHOD(gdext_colyseus_callbacks_on_add, COLYSEUS_GDCB_ON_ADD)
CALLBACKS_METHOD(gdext_colyseus_callbacks_on_remove, COLYSEUS_GDCB_ON_REMOVE)
CALLBACKS_METHOD(gdext_colyseus_callbacks_on_change, COLYSEUS_GDCB_ON_CHANGE)

void gdext_colyseus_callbacks_remove(
    void* p_method_userdata,
    GDExtensionClassInstancePtr p_instance,
    const GDExtensionConstVariantPtr* p_args,
    GDExtensionInt p_argument_count,
    GDExtensionVariantPtr r_return,
    GDExtensionCallError* r_error
) {
    (void)p_method_userdata;
    (void)r_return;

    ColyseusCallbacksWrapper* wrapper = (ColyseusCallbacksWrapper*)p_instance;
    if (!wrapper) {
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_INSTANCE_IS_NULL;
        return;
    }
    if (p_argument_count < 1) {
        if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
        return;
    }

    int64_t handle = 0;
    constructors.int_from_variant_constructor(&handle, (GDExtensionVariantPtr)p_args[0]);
    GodotCallbackEntry* entry = find_entry(wrapper, (int)handle);
    if (!entry) return;

    entry->active = false;
    entry->pending = false;
    destructors.variant_destroy(&entry->callable);
    gdext_variant_new_nil(&entry->callable);
    if (!entry->attaching) schedule_reap(wrapper);
}
