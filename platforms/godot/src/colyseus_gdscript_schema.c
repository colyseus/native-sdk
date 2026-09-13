#include "colyseus_gdscript_schema.h"
#include <colyseus/schema/collections.h>
#include <colyseus/schema/quantize.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* ============================================================================
 * Helper Functions
 * ============================================================================ */

/* Helper to create a StringName from a C string */
static void create_string_name(StringName* sn, const char* str) {
    constructors.string_name_new_with_latin1_chars(sn, str, false);
}

/* Helper to call a method on a variant and return result */
static bool variant_call_method(Variant* variant, const char* method_name, 
    GDExtensionConstVariantPtr* args, int arg_count, Variant* result) {
    
    StringName method;
    create_string_name(&method, method_name);
    
    GDExtensionCallError error;
    api.variant_call(variant, &method, args, arg_count, result, &error);
    
    destructors.string_name_destructor(&method);
    
    return error.error == GDEXTENSION_CALL_OK;
}

/* Helper to convert Godot String to C string (caller must free) */
static char* godot_string_to_cstr(const String* str) {
    if (!str) return strdup("");
    
    int32_t length = api.string_to_utf8_chars(str, NULL, 0);
    if (length <= 0) return strdup("");
    
    char* buffer = (char*)malloc(length + 1);
    if (!buffer) return strdup("");
    
    api.string_to_utf8_chars(str, buffer, length);
    buffer[length] = '\0';
    
    return buffer;
}

/* Helper to create a C string from a Variant containing a String */
static char* variant_to_cstr(Variant* variant) {
    String str;
    constructors.string_from_variant_constructor(&str, variant);
    char* result = godot_string_to_cstr(&str);
    destructors.string_destructor(&str);
    return result;
}

/* Helper to get array size from variant */
static int64_t get_array_size_from_variant(Variant* arr_variant) {
    Variant return_val;
    if (!variant_call_method(arr_variant, "size", NULL, 0, &return_val)) {
        return 0;
    }
    
    int64_t size = 0;
    constructors.int_from_variant_constructor(&size, &return_val);
    destructors.variant_destroy(&return_val);
    
    return size;
}

/* Helper to read a named property off an object Variant via Object.get(name).
 * Returns true and fills *out_value on success; on failure returns false and the
 * caller must NOT read or destroy *out_value (mirrors get_array_element_at). */
static bool get_variant_property(Variant* object_variant, const char* property_name, Variant* out_value) {
    String property_string;
    constructors.string_new_with_utf8_chars(&property_string, property_name);

    Variant property_variant;
    constructors.variant_from_string_constructor(&property_variant, &property_string);

    GDExtensionConstVariantPtr args[1] = { &property_variant };
    bool success = variant_call_method(object_variant, "get", args, 1, out_value);

    destructors.variant_destroy(&property_variant);
    destructors.string_destructor(&property_string);

    return success;
}

/* Helper to get array element at index */
static bool get_array_element_at(Variant* arr_variant, int64_t index, Variant* out_element) {
    Variant index_variant;
    constructors.variant_from_int_constructor(&index_variant, &index);

    GDExtensionConstVariantPtr args[1] = { &index_variant };
    bool success = variant_call_method(arr_variant, "get", args, 1, out_element);

    destructors.variant_destroy(&index_variant);
    return success;
}

/* ============================================================================
 * Live collections
 *
 * A typed instance's map/array field holds a plain Dictionary/Array that is
 * handed out once and then mutated in place, so a reference taken from
 * `state.players` or `hero.items` stays current. Keyed by the collection's
 * ref id: the decoder clones a collection when its field is reassigned, but
 * the id (and so the container) stays the same.
 * ============================================================================ */

typedef struct {
    int ref_id;
    void* collection;   /* the current decoder collection */
    bool is_map;
    bool dirty;         /* rebuild after this decode */
    Variant container;
    gdscript_instance_t* instance;  /* set instead for a schema id: whose __ref_id to reset */
} live_entry_t;

static void object_set_ref_id(Variant* instance_variant, int ref_id);

struct gdscript_live {
    live_entry_t** slots;   /* open addressing on ref_id; NULL = empty */
    int capacity;           /* power of two */
    int count;
};

static unsigned live_home(int ref_id, int capacity) {
    return ((unsigned)ref_id * 2654435761u) & (unsigned)(capacity - 1);
}

static live_entry_t* live_find(gdscript_live_t* live, int ref_id) {
    if (!live || live->count == 0) return NULL;
    unsigned mask = (unsigned)live->capacity - 1;
    for (unsigned i = live_home(ref_id, live->capacity); ; i = (i + 1) & mask) {
        live_entry_t* e = live->slots[i];
        if (!e) return NULL;
        if (e->ref_id == ref_id) return e;
    }
}

static void live_place(live_entry_t** slots, int capacity, live_entry_t* e) {
    unsigned mask = (unsigned)capacity - 1;
    unsigned i = live_home(e->ref_id, capacity);
    while (slots[i]) i = (i + 1) & mask;
    slots[i] = e;
}

static bool live_insert(gdscript_live_t* live, live_entry_t* e) {
    if ((live->count + 1) * 4 > live->capacity * 3) {
        int capacity = live->capacity ? live->capacity * 2 : 64;
        live_entry_t** slots = (live_entry_t**)calloc((size_t)capacity, sizeof(live_entry_t*));
        if (!slots) return false;
        for (int i = 0; i < live->capacity; i++) {
            if (live->slots[i]) live_place(slots, capacity, live->slots[i]);
        }
        free(live->slots);
        live->slots = slots;
        live->capacity = capacity;
    }
    live_place(live->slots, live->capacity, e);
    live->count++;
    return true;
}

/* Backward-shift delete: keeps every probe run gap-free, no tombstones. */
static void live_remove(gdscript_live_t* live, int ref_id) {
    if (!live || live->count == 0) return;
    unsigned mask = (unsigned)live->capacity - 1;
    unsigned i = live_home(ref_id, live->capacity);
    while (live->slots[i] && live->slots[i]->ref_id != ref_id) i = (i + 1) & mask;
    if (!live->slots[i]) return;
    live->slots[i] = NULL;
    live->count--;
    for (unsigned j = (i + 1) & mask; live->slots[j]; j = (j + 1) & mask) {
        unsigned k = live_home(live->slots[j]->ref_id, live->capacity);
        bool reachable = (i <= j) ? (i < k && k <= j) : (i < k || k <= j);
        if (!reachable) {
            live->slots[i] = live->slots[j];
            live->slots[j] = NULL;
            i = j;
        }
    }
}

static void live_entry_free(live_entry_t* e) {
    destructors.variant_destroy(&e->container);
    free(e);
}

static void live_free(gdscript_live_t* live) {
    if (!live) return;
    for (int i = 0; i < live->capacity; i++) {
        if (live->slots[i]) live_entry_free(live->slots[i]);
    }
    free(live->slots);
    free(live);
}

static void container_call(Variant* container, const char* method, GDExtensionConstVariantPtr* args, int argc) {
    Variant ret;
    variant_call_method(container, method, args, argc, &ret);
    destructors.variant_destroy(&ret);
}

static void key_variant_new(Variant* out, String* str, const char* key) {
    constructors.string_new_with_utf8_chars(str, key);
    constructors.variant_from_string_constructor(out, str);
}

static void dict_set(Variant* container, const char* key, Variant* value) {
    Dictionary dict;
    constructors.dictionary_from_variant_constructor(&dict, container);  /* shares the data */
    String key_str;
    Variant key_var;
    key_variant_new(&key_var, &key_str, key);
    Variant* slot = (Variant*)api.dictionary_operator_index(&dict, &key_var);
    if (slot) gdext_variant_assign(slot, value);
    destructors.variant_destroy(&key_var);
    destructors.string_destructor(&key_str);
    destructors.dictionary_destructor(&dict);
}

static void dict_erase(Variant* container, const char* key) {
    String key_str;
    Variant key_var;
    key_variant_new(&key_var, &key_str, key);
    GDExtensionConstVariantPtr args[1] = { &key_var };
    container_call(container, "erase", args, 1);
    destructors.variant_destroy(&key_var);
    destructors.string_destructor(&key_str);
}

static void live_item_to_variant(bool has_schema_child, const char* primitive_type, void* value, Variant* out) {
    if (!value) {
        gdext_variant_new_nil(out);
    } else if (has_schema_child) {
        colyseus_dynamic_schema_t* child = (colyseus_dynamic_schema_t*)value;
        if (child->userdata) api.variant_new_copy(out, (Variant*)child->userdata);
        else gdext_variant_new_nil(out);
    } else {
        gdscript_primitive_to_variant(value, primitive_type, out);
    }
}

typedef struct { Variant* container; const colyseus_map_schema_t* map; } map_fill_t;

static void map_fill_item(const char* key, void* value, void* userdata) {
    map_fill_t* fill = (map_fill_t*)userdata;
    Variant item;
    live_item_to_variant(fill->map->has_schema_child, fill->map->child_primitive_type, value, &item);
    dict_set(fill->container, key, &item);
    destructors.variant_destroy(&item);
}

typedef struct { Array* arr; const colyseus_array_schema_t* src; int64_t next; } array_fill_t;

static void array_fill_item(int index, void* value, void* userdata) {
    (void)index;  /* ascending, holes already compacted: visit order is array order */
    array_fill_t* fill = (array_fill_t*)userdata;
    Variant item;
    live_item_to_variant(fill->src->has_schema_child, fill->src->child_primitive_type, value, &item);
    Variant* slot = (Variant*)api.array_operator_index(fill->arr, fill->next++);
    if (slot) gdext_variant_assign(slot, &item);
    destructors.variant_destroy(&item);
}

/* Replace the container's contents with the collection's, in place. */
static void live_refill(live_entry_t* e) {
    e->dirty = false;
    if (e->is_map) {
        colyseus_map_schema_t* map = (colyseus_map_schema_t*)e->collection;
        container_call(&e->container, "clear", NULL, 0);
        map_fill_t fill = { &e->container, map };
        colyseus_map_schema_foreach(map, map_fill_item, &fill);
        return;
    }
    colyseus_array_schema_t* src = (colyseus_array_schema_t*)e->collection;
    int64_t count = 0;
    for (colyseus_array_item_t* item = src->items; item; item = item->next) count++;
    Variant size_var;
    constructors.variant_from_int_constructor(&size_var, &count);
    GDExtensionConstVariantPtr args[1] = { &size_var };
    container_call(&e->container, "resize", args, 1);
    destructors.variant_destroy(&size_var);

    Array arr;
    constructors.array_from_variant_constructor(&arr, &e->container);
    array_fill_t fill = { &arr, src, 0 };
    colyseus_array_schema_foreach(src, array_fill_item, &fill);
    destructors.array_destructor(&arr);
}

static bool container_is_empty(const Variant* container) {
    Variant ret;
    if (!variant_call_method((Variant*)container, "is_empty", NULL, 0, &ret)) return false;
    GDExtensionBool empty = 0;
    constructors.bool_from_variant_constructor(&empty, &ret);
    destructors.variant_destroy(&ret);
    return empty != 0;
}

/* The container for a collection that was just assigned to a field. `adopt`
 * is what the field holds now: an empty Dictionary/Array (the class default)
 * becomes the container, so a reference taken before the first state stays live. */
static void live_attach(gdscript_live_t* live, void* collection, bool is_map, const Variant* adopt, Variant* out) {
    int ref_id = is_map ? ((colyseus_map_schema_t*)collection)->__refId
                        : ((colyseus_array_schema_t*)collection)->__refId;
    live_entry_t* e = live_find(live, ref_id);
    if (e && (e->instance || e->is_map != is_map)) {
        live_remove(live, ref_id);
        live_entry_free(e);
        e = NULL;
    }
    bool fresh = e == NULL;
    if (fresh) {
        e = (live_entry_t*)calloc(1, sizeof(live_entry_t));
        if (!e) {
            gdext_variant_new_nil(out);
            return;
        }
        e->ref_id = ref_id;
        e->is_map = is_map;
        GDExtensionVariantType want = is_map ? GDEXTENSION_VARIANT_TYPE_DICTIONARY : GDEXTENSION_VARIANT_TYPE_ARRAY;
        if (adopt && api.variant_get_type(adopt) == want && container_is_empty(adopt)) {
            api.variant_new_copy(&e->container, adopt);
        } else if (is_map) {
            Dictionary dict;
            constructors.dictionary_constructor(&dict, NULL);
            constructors.variant_from_dictionary_constructor(&e->container, &dict);
            destructors.dictionary_destructor(&dict);
        } else {
            Array arr;
            constructors.array_constructor(&arr, NULL);
            constructors.variant_from_array_constructor(&e->container, &arr);
            destructors.array_destructor(&arr);
        }
    }
    e->collection = collection;
    live_refill(e);
    api.variant_new_copy(out, &e->container);
    if (fresh && !live_insert(live, e)) live_entry_free(e);  /* out still holds a snapshot */
}

static bool live_still_there(live_entry_t* e, colyseus_ref_tracker_t* refs) {
    colyseus_ref_entry_t* ref = colyseus_ref_tracker_get_entry(refs, e->ref_id);
    return ref && ref->ref
        && ref->ref_type == (e->is_map ? COLYSEUS_REF_TYPE_MAP : COLYSEUS_REF_TYPE_ARRAY);
}

void gdscript_live_apply(gdscript_schema_context_t* ctx, colyseus_ref_tracker_t* refs, colyseus_changes_t* changes) {
    gdscript_live_t* live = ctx ? ctx->live : NULL;
    if (!live || live->count == 0 || !refs || !changes) return;

    bool any_dirty = false;
    for (int i = 0; i < changes->count; i++) {
        colyseus_data_change_t* change = &changes->items[i];
        live_entry_t* e = live_find(live, change->ref_id);
        if (!e || !live_still_there(e, refs)) continue;
        e->collection = colyseus_ref_tracker_get(refs, e->ref_id);

        /* arrays shift and compact: cheaper to rebuild once than to replay */
        if (!e->is_map || !change->dynamic_index) {
            e->dirty = true;
            any_dirty = true;
            continue;
        }
        const char* key = (const char*)change->dynamic_index;
        unsigned op = (unsigned)change->op;
        bool deleted = (op & COLYSEUS_OP_DELETE) == COLYSEUS_OP_DELETE;
        bool added = (op & COLYSEUS_OP_ADD) == COLYSEUS_OP_ADD;
        colyseus_map_schema_t* map = (colyseus_map_schema_t*)e->collection;
        void* value = colyseus_map_schema_get(map, key);  /* end-of-decode truth */
        if (!value || (deleted && !added)) {
            dict_erase(&e->container, key);
            continue;
        }
        /* delete+add re-inserts at the back, like a JS Map */
        if (deleted) dict_erase(&e->container, key);
        Variant item;
        live_item_to_variant(map->has_schema_child, map->child_primitive_type, value, &item);
        dict_set(&e->container, key, &item);
        destructors.variant_destroy(&item);
    }

    if (!any_dirty) return;
    for (int i = 0; i < live->capacity; i++) {
        live_entry_t* e = live->slots[i];
        if (e && e->dirty) live_refill(e);
    }
}

/* A decoded instance under its ref id, so collection can find it by id alone. */
static void live_track_instance(gdscript_live_t* live, int ref_id, gdscript_instance_t* inst) {
    live_entry_t* e = live_find(live, ref_id);
    if (e && e->instance == inst) return;
    if (e) {
        live_remove(live, ref_id);
        live_entry_free(e);
    }
    e = (live_entry_t*)calloc(1, sizeof(live_entry_t));
    if (!e) return;
    e->ref_id = ref_id;
    e->instance = inst;
    gdext_variant_new_nil(&e->container);
    if (!live_insert(live, e)) free(e);
}

static void live_untrack_instance(gdscript_instance_t* inst) {
    if (!inst->live || inst->ref_id < 0) return;
    live_entry_t* e = live_find(inst->live, inst->ref_id);
    if (e && e->instance == inst) {
        live_remove(inst->live, inst->ref_id);
        live_entry_free(e);
    }
}

void gdscript_live_collect(gdscript_schema_context_t* ctx, int ref_id) {
    gdscript_live_t* live = ctx ? ctx->live : NULL;
    live_entry_t* e = live_find(live, ref_id);
    if (!e) return;
    gdscript_instance_t* inst = e->instance;
    live_remove(live, ref_id);
    live_entry_free(e);  /* a collection's container keeps its last contents for whoever holds it */
    if (!inst) return;
    inst->ref_id = -1;
    /* the decoder is done with it (and never frees it): give GDScript the object back */
    if (!inst->released && gdext_on_main_thread()) {
        object_set_ref_id(&inst->instance, -1);
        destructors.variant_destroy(&inst->instance);
        gdext_variant_new_nil(&inst->instance);
        inst->released = true;
    }
}

bool gdscript_live_container(gdscript_schema_context_t* ctx, int ref_id, Variant* r_container) {
    live_entry_t* e = live_find(ctx ? ctx->live : NULL, ref_id);
    if (!e || e->instance) return false;
    api.variant_new_copy(r_container, &e->container);
    return true;
}

/* ============================================================================
 * Field Parsing
 * ============================================================================ */

/*
 * Parse a colyseus.Field object from a Variant.
 * The Field object has: name (String), type (String), child_type (class or null)
 */
static gdscript_schema_context_t* context_create(GDExtensionConstVariantPtr script_variant, gdscript_live_t* live);
static void gdscript_schema_context_cleanup(gdscript_schema_context_t* ctx);

/* options[key] as a number; false when absent or not numeric */
static bool options_number(Variant* options, const char* key, double* out) {
    Variant value;
    if (!get_variant_property(options, key, &value)) return false;
    GDExtensionVariantType t = api.variant_get_type(&value);
    bool ok = t == GDEXTENSION_VARIANT_TYPE_INT || t == GDEXTENSION_VARIANT_TYPE_FLOAT;
    if (t == GDEXTENSION_VARIANT_TYPE_INT) {
        int64_t i = 0;
        constructors.int_from_variant_constructor(&i, &value);
        *out = (double)i;
    } else if (t == GDEXTENSION_VARIANT_TYPE_FLOAT) {
        constructors.float_from_variant_constructor(out, &value);
    }
    destructors.variant_destroy(&value);
    return ok;
}

/* Field.new(name, QUANTIZED, {min, max, bits?, mode?}) -> the wire descriptor
 * (the decoder has no other source for it on a typed schema). */
static colyseus_quantized_descriptor_t* parse_quantize_options(Variant* options, const char* field_name) {
    double min = 0, max = 0, bits = 16;
    if (api.variant_get_type(options) != GDEXTENSION_VARIANT_TYPE_DICTIONARY
            || !options_number(options, "min", &min) || !options_number(options, "max", &max)) {
        gdext_push_error("Colyseus.Schema field '%s': QUANTIZED needs the server's options, "
                         "e.g. Field.new(\"%s\", Colyseus.Schema.QUANTIZED, {\"min\": 0.0, \"max\": 1.0})",
                         field_name, field_name);
        return NULL;
    }
    options_number(options, "bits", &bits);
    if (bits != 8 && bits != 16 && bits != 32) {
        gdext_push_error("Colyseus.Schema field '%s': QUANTIZED bits must be 8, 16 or 32", field_name);
        return NULL;
    }
    bool wrap = false;
    Variant mode;
    if (get_variant_property(options, "mode", &mode)) {
        if (api.variant_get_type(&mode) == GDEXTENSION_VARIANT_TYPE_STRING) {
            char* mode_str = variant_to_cstr(&mode);
            wrap = mode_str && strcmp(mode_str, "wrap") == 0;
            free(mode_str);
        }
        destructors.variant_destroy(&mode);
    }
    colyseus_quantized_descriptor_t* desc = (colyseus_quantized_descriptor_t*)malloc(sizeof(*desc));
    if (desc) *desc = colyseus_quantize_resolve(min, max, (uint8_t)bits, wrap);
    return desc;
}

static colyseus_dynamic_field_t* parse_field_from_variant(Variant* field_variant, int field_index,
    gdscript_schema_context_t** child_contexts, int* child_context_count, gdscript_live_t* live, bool* failed) {
    
    /* Read required 'name' property. Bail cleanly (rather than operate on an
     * unchecked/uninitialized Variant) if it cannot be read — this is what
     * tripped Android release builds during Room.set_state_type(). */
    Variant field_name_variant;
    if (!get_variant_property(field_variant, "name", &field_name_variant)) {
        fprintf(stderr, "[colyseus] schema field %d: could not read 'name'; skipping\n", field_index);
        return NULL;
    }
    char* field_name = variant_to_cstr(&field_name_variant);
    destructors.variant_destroy(&field_name_variant);

    /* Read required 'type' property */
    Variant field_type_variant;
    if (!get_variant_property(field_variant, "type", &field_type_variant)) {
        fprintf(stderr, "[colyseus] schema field '%s': could not read 'type'; skipping\n", field_name);
        free(field_name);
        return NULL;
    }
    char* field_type_str = variant_to_cstr(&field_type_variant);
    destructors.variant_destroy(&field_type_variant);

    /* Determine the field type enum */
    colyseus_field_type_t field_type = colyseus_field_type_from_string(field_type_str);

    /* Create the dynamic field */
    colyseus_dynamic_field_t* field = colyseus_dynamic_field_create(
        field_index, field_name, field_type, field_type_str);

    if (field && field_type == COLYSEUS_FIELD_QUANTIZED) {
        Variant options;
        bool have_options = get_variant_property(field_variant, "child_type", &options);
        field->quantized = have_options ? parse_quantize_options(&options, field_name) : NULL;
        if (have_options) destructors.variant_destroy(&options);
        if (!field->quantized) {
            if (!have_options) {
                gdext_push_error("Colyseus.Schema field '%s': QUANTIZED needs the server's options", field_name);
            }
            if (failed) *failed = true;
        }
    }

    /* For collection types (map/array) or ref, read the optional 'child_type'.
     * Only inspect/destroy the returned Variant if the read actually succeeded. */
    if (field_type == COLYSEUS_FIELD_MAP || field_type == COLYSEUS_FIELD_ARRAY ||
        field_type == COLYSEUS_FIELD_REF) {

        Variant child_type_variant;
        if (get_variant_property(field_variant, "child_type", &child_type_variant)) {
            GDExtensionVariantType child_variant_type = api.variant_get_type(&child_type_variant);

            if (child_variant_type == GDEXTENSION_VARIANT_TYPE_OBJECT) {
                /* Child type is a GDScript class - parse it recursively */
                gdscript_schema_context_t* child_ctx = context_create(&child_type_variant, live);
                if (child_ctx && child_ctx->vtable) {
                    field->child_vtable = child_ctx->vtable;

                    /* Store child context for cleanup (moved by value) */
                    gdscript_schema_context_t* grown = child_contexts && child_context_count
                        ? realloc(*child_contexts, (*child_context_count + 1) * sizeof(gdscript_schema_context_t))
                        : NULL;
                    if (grown) {
                        *child_contexts = grown;
                        (*child_contexts)[*child_context_count] = *child_ctx;
                        (*child_context_count)++;
                    } else {
                        gdscript_schema_context_cleanup(child_ctx);
                        field->child_vtable = NULL;
                    }
                }
                free(child_ctx);
            } else if (child_variant_type == GDEXTENSION_VARIANT_TYPE_STRING) {
                /* Child type is a primitive type string */
                char* child_primitive = variant_to_cstr(&child_type_variant);
                field->child_primitive_type = child_primitive;
            }

            destructors.variant_destroy(&child_type_variant);
        }
    }

    free(field_name);
    free(field_type_str);

    return field;
}

/* ============================================================================
 * Schema Context Creation
 * ============================================================================ */

gdscript_schema_context_t* gdscript_schema_context_create(GDExtensionConstVariantPtr script_variant) {
    gdscript_live_t* live = (gdscript_live_t*)calloc(1, sizeof(gdscript_live_t));
    if (!live) return NULL;
    gdscript_schema_context_t* ctx = context_create(script_variant, live);
    if (!ctx) {
        live_free(live);
        return NULL;
    }
    ctx->owns_live = true;
    return ctx;
}

static gdscript_schema_context_t* context_create(GDExtensionConstVariantPtr script_variant, gdscript_live_t* live) {
    if (!script_variant) return NULL;

    gdscript_schema_context_t* ctx = calloc(1, sizeof(gdscript_schema_context_t));
    if (!ctx) return NULL;
    ctx->live = live;
    
    /* Store the script class reference */
    /* For a GDScript class passed as argument, it's typically a Script object */
    GDExtensionVariantType var_type = api.variant_get_type((GDExtensionVariantPtr)script_variant);
    
    if (var_type != GDEXTENSION_VARIANT_TYPE_OBJECT) {
        free(ctx);
        return NULL;
    }
    
    /* Get the Object pointer from the variant */
    GDExtensionObjectPtr script_obj = NULL;
    constructors.object_from_variant_constructor(&script_obj, (GDExtensionVariantPtr)script_variant);
    ctx->script_class = script_obj;
    
    /* Call the static definition() method to get field definitions */
    /* In GDScript, static methods are called on the class/script object */
    Variant script_as_variant;
    constructors.variant_from_object_constructor(&script_as_variant, &script_obj);
    
    /* Call definition() - this should return an Array of Field objects */
    Variant definition_result;
    StringName definition_method;
    create_string_name(&definition_method, "definition");
    
    GDExtensionCallError error;
    api.variant_call(&script_as_variant, &definition_method, NULL, 0, &definition_result, &error);
    
    destructors.string_name_destructor(&definition_method);
    
    if (error.error != GDEXTENSION_CALL_OK) {
        /* Try calling new() first and then definition() on instance */
        Variant instance_result;
        if (variant_call_method(&script_as_variant, "new", NULL, 0, &instance_result)) {
            if (variant_call_method(&instance_result, "definition", NULL, 0, &definition_result)) {
                error.error = GDEXTENSION_CALL_OK;
            }
            destructors.variant_destroy(&instance_result);
        }
    }
    
    destructors.variant_destroy(&script_as_variant);
    
    if (error.error != GDEXTENSION_CALL_OK) {
        free(ctx);
        return NULL;
    }
    
    /* Parse the definition array */
    int64_t field_count = get_array_size_from_variant(&definition_result);
    
    /* Create dynamic vtable */
    ctx->vtable = colyseus_dynamic_vtable_create("GDScriptSchema");
    if (!ctx->vtable) {
        destructors.variant_destroy(&definition_result);
        free(ctx);
        return NULL;
    }
    
    /* Parse each field */
    gdscript_schema_context_t* child_contexts = NULL;
    int child_context_count = 0;
    bool failed = false;

    for (int64_t i = 0; i < field_count; i++) {
        Variant field_variant;
        if (get_array_element_at(&definition_result, i, &field_variant)) {
            colyseus_dynamic_field_t* field = parse_field_from_variant(
                &field_variant, (int)i, &child_contexts, &child_context_count, live, &failed);

            if (field) {
                colyseus_dynamic_vtable_add_field(ctx->vtable, field);
            }

            destructors.variant_destroy(&field_variant);
        }
    }

    /* Store child contexts */
    ctx->children = child_contexts;
    ctx->child_count = child_context_count;

    /* a field the decoder can't read would corrupt everything after it */
    if (failed) {
        destructors.variant_destroy(&definition_result);
        gdscript_schema_context_cleanup(ctx);
        free(ctx);
        return NULL;
    }
    
    /* Set up callbacks for GDScript instance creation */
    ctx->binding = (gdscript_class_binding_t*)malloc(sizeof(gdscript_class_binding_t));
    if (ctx->binding) {
        ctx->binding->script_class = ctx->script_class;
        ctx->binding->live = live;
    }
    colyseus_dynamic_vtable_set_callbacks(ctx->vtable,
        gdscript_create_instance,
        gdscript_free_instance,
        gdscript_set_field,
        gdscript_set_ref_id,
        ctx->binding);
    
    destructors.variant_destroy(&definition_result);
    
    return ctx;
}

/* Internal helper to clean up context contents without freeing the struct itself */
static void gdscript_schema_context_cleanup(gdscript_schema_context_t* ctx) {
    if (!ctx) return;
    
    /* Clean up child contexts (recursively) */
    if (ctx->children) {
        for (int i = 0; i < ctx->child_count; i++) {
            gdscript_schema_context_cleanup(&ctx->children[i]);
        }
        free(ctx->children);
        ctx->children = NULL;
        ctx->child_count = 0;
    }
    
    /* Free vtable */
    if (ctx->vtable) {
        colyseus_dynamic_vtable_free(ctx->vtable);
        ctx->vtable = NULL;
    }

    free(ctx->binding);
    ctx->binding = NULL;
    if (ctx->owns_live) live_free(ctx->live);
    ctx->live = NULL;

    /* Free name */
    free(ctx->name);
    ctx->name = NULL;
    
    /* Note: script_class is owned by Godot, don't free it */
}

void gdscript_schema_context_free(gdscript_schema_context_t* ctx) {
    if (!ctx) return;
    
    /* Clean up all contents */
    gdscript_schema_context_cleanup(ctx);
    
    /* Free the struct itself (only for top-level contexts) */
    free(ctx);
}

colyseus_dynamic_vtable_t* gdscript_schema_parse_class(GDExtensionConstVariantPtr script_variant) {
    gdscript_schema_context_t* ctx = gdscript_schema_context_create(script_variant);
    if (!ctx) return NULL;
    
    colyseus_dynamic_vtable_t* vtable = ctx->vtable;

    /* Transfer ownership of vtable, free context without vtable; the vtable
     * keeps calling back with its binding and live table, so those stay too */
    ctx->vtable = NULL;
    ctx->binding = NULL;
    ctx->owns_live = false;
    gdscript_schema_context_free(ctx);
    
    return vtable;
}

/* ============================================================================
 * Instance Creation Callbacks
 * ============================================================================ */

void* gdscript_create_instance(const colyseus_dynamic_vtable_t* vtable, void* context) {
    (void)vtable;
    gdscript_class_binding_t* binding = (gdscript_class_binding_t*)context;
    if (!binding || !binding->script_class) return NULL;

    GDExtensionObjectPtr script_class = binding->script_class;
    
    /* Create a variant from the script class */
    Variant script_variant;
    constructors.variant_from_object_constructor(&script_variant, &script_class);
    
    /* Call new() to create an instance */
    Variant instance_variant;
    if (!variant_call_method(&script_variant, "new", NULL, 0, &instance_variant)) {
        destructors.variant_destroy(&script_variant);
        return NULL;
    }
    
    destructors.variant_destroy(&script_variant);
    
    /* the userdata holds the reference that keeps the object alive */
    gdscript_instance_t* result = (gdscript_instance_t*)malloc(sizeof(gdscript_instance_t));
    if (result) {
        api.variant_new_copy(&result->instance, &instance_variant);
        result->live = binding->live;
        result->ref_id = -1;
        result->released = false;
    }

    destructors.variant_destroy(&instance_variant);

    return result;
}

void gdscript_free_instance(void* userdata) {
    if (!userdata) return;

    gdscript_instance_t* inst = (gdscript_instance_t*)userdata;
    live_untrack_instance(inst);
    /* the id is about to be recycled; GDScript may still hold the object.
     * Main thread only: a failed reconnect tears the tree down from its worker. */
    if (!inst->released && gdext_on_main_thread()) object_set_ref_id(&inst->instance, -1);
    destructors.variant_destroy(&inst->instance);
    free(inst);
}

void gdscript_set_field(void* userdata, const char* name, colyseus_dynamic_value_t* value) {
    if (!userdata || !name || !value) return;

    gdscript_instance_t* inst = (gdscript_instance_t*)userdata;
    Variant* instance_variant = &inst->instance;

    /* Convert the dynamic value to a Godot Variant */
    Variant value_variant;
    if ((value->type == COLYSEUS_FIELD_MAP || value->type == COLYSEUS_FIELD_ARRAY) && inst->live) {
        void* collection = value->type == COLYSEUS_FIELD_MAP ? (void*)value->data.map : (void*)value->data.array;
        if (collection) {
            Variant current;
            bool have_current = get_variant_property(instance_variant, name, &current);
            live_attach(inst->live, collection, value->type == COLYSEUS_FIELD_MAP,
                        have_current ? &current : NULL, &value_variant);
            if (have_current) destructors.variant_destroy(&current);
        } else {
            gdext_variant_new_nil(&value_variant);
        }
    } else {
        gdscript_value_to_variant(value, &value_variant);
    }
    
    /* Call _set_field(name, value) on the GDScript instance */
    String name_str;
    constructors.string_new_with_utf8_chars(&name_str, name);
    Variant name_variant;
    constructors.variant_from_string_constructor(&name_variant, &name_str);
    
    GDExtensionConstVariantPtr args[2] = { &name_variant, &value_variant };
    Variant result;
    
    variant_call_method(instance_variant, "_set_field", args, 2, &result);
    
    destructors.variant_destroy(&result);
    destructors.variant_destroy(&name_variant);
    destructors.string_destructor(&name_str);
    destructors.variant_destroy(&value_variant);
}

void gdscript_set_ref_id(void* userdata, int ref_id) {
    if (!userdata) return;
    gdscript_instance_t* inst = (gdscript_instance_t*)userdata;
    if (inst->live && ref_id >= 0) {
        live_untrack_instance(inst);
        live_track_instance(inst->live, ref_id, inst);
    }
    inst->ref_id = ref_id;
    object_set_ref_id(&inst->instance, ref_id);
}

static void object_set_ref_id(Variant* instance_variant, int ref_id) {
    /* Set __ref_id property on the GDScript instance */
    String prop_str;
    constructors.string_new_with_utf8_chars(&prop_str, "__ref_id");
    Variant prop_name_variant;
    constructors.variant_from_string_constructor(&prop_name_variant, &prop_str);
    
    int64_t ref_id_val = ref_id;
    Variant ref_id_variant;
    constructors.variant_from_int_constructor(&ref_id_variant, &ref_id_val);
    
    /* Call set("__ref_id", ref_id) on the GDScript instance */
    GDExtensionConstVariantPtr args[2] = { &prop_name_variant, &ref_id_variant };
    Variant result;
    
    variant_call_method(instance_variant, "set", args, 2, &result);
    
    destructors.variant_destroy(&result);
    destructors.variant_destroy(&prop_name_variant);
    destructors.string_destructor(&prop_str);
    destructors.variant_destroy(&ref_id_variant);
}

/* ============================================================================
 * Value Conversion
 * ============================================================================ */

/* Forward declare helper to convert a raw value to variant based on vtable */
static void raw_value_to_variant(void* raw_value, bool has_schema_child, 
    const colyseus_schema_vtable_t* child_vtable, const char* child_primitive_type,
    Variant* r_variant);

/* Callback context for map iteration */
typedef struct {
    Variant* map_instance;
    bool has_schema_child;
    const char* child_primitive_type;
} map_populate_ctx_t;

/* Helper to convert a primitive void* value to a Variant (GDScript path) */
void gdscript_primitive_to_variant(void* value, const char* primitive_type, Variant* r_variant) {
    if (!value || !primitive_type) {
        memset(r_variant, 0, sizeof(*r_variant));
        return;
    }

    colyseus_field_type_t ft = colyseus_field_type_from_string(primitive_type);
    switch (ft) {
        case COLYSEUS_FIELD_STRING: {
            String str;
            constructors.string_new_with_utf8_chars(&str, (const char*)value);
            constructors.variant_from_string_constructor(r_variant, &str);
            destructors.string_destructor(&str);
            break;
        }
        case COLYSEUS_FIELD_NUMBER:
        case COLYSEUS_FIELD_FLOAT64: {
            double d = *(double*)value;
            constructors.variant_from_float_constructor(r_variant, &d);
            break;
        }
        case COLYSEUS_FIELD_FLOAT32: {
            double d = (double)*(float*)value;
            constructors.variant_from_float_constructor(r_variant, &d);
            break;
        }
        case COLYSEUS_FIELD_BOOLEAN: {
            GDExtensionBool b = *(bool*)value ? 1 : 0;
            constructors.variant_from_bool_constructor(r_variant, &b);
            break;
        }
        case COLYSEUS_FIELD_INT8: {
            int64_t i = (int64_t)*(int8_t*)value;
            constructors.variant_from_int_constructor(r_variant, &i);
            break;
        }
        case COLYSEUS_FIELD_UINT8: {
            int64_t i = (int64_t)*(uint8_t*)value;
            constructors.variant_from_int_constructor(r_variant, &i);
            break;
        }
        case COLYSEUS_FIELD_INT16: {
            int64_t i = (int64_t)*(int16_t*)value;
            constructors.variant_from_int_constructor(r_variant, &i);
            break;
        }
        case COLYSEUS_FIELD_UINT16: {
            int64_t i = (int64_t)*(uint16_t*)value;
            constructors.variant_from_int_constructor(r_variant, &i);
            break;
        }
        case COLYSEUS_FIELD_INT32: {
            int64_t i = (int64_t)*(int32_t*)value;
            constructors.variant_from_int_constructor(r_variant, &i);
            break;
        }
        case COLYSEUS_FIELD_UINT32: {
            int64_t i = (int64_t)*(uint32_t*)value;
            constructors.variant_from_int_constructor(r_variant, &i);
            break;
        }
        case COLYSEUS_FIELD_INT64: {
            constructors.variant_from_int_constructor(r_variant, &(*(int64_t*)value));
            break;
        }
        case COLYSEUS_FIELD_UINT64: {
            int64_t i = (int64_t)*(uint64_t*)value;
            constructors.variant_from_int_constructor(r_variant, &i);
            break;
        }
        default:
            memset(r_variant, 0, sizeof(*r_variant));
            break;
    }
}

/* Callback for populating GDScript Map */
static void populate_map_callback(const char* key, void* value, void* userdata) {
    map_populate_ctx_t* ctx = (map_populate_ctx_t*)userdata;
    if (!ctx || !ctx->map_instance || !key) return;

    Variant value_variant;
    if (ctx->has_schema_child && value) {
        colyseus_dynamic_schema_t* dyn_schema = (colyseus_dynamic_schema_t*)value;
        if (dyn_schema->userdata) {
            /* Schema child - get the GDScript instance */
            api.variant_new_copy(&value_variant, (Variant*)dyn_schema->userdata);
        } else {
            memset(&value_variant, 0, sizeof(value_variant));
        }
    } else if (value) {
        gdscript_primitive_to_variant(value, ctx->child_primitive_type, &value_variant);
    } else {
        memset(&value_variant, 0, sizeof(value_variant));
    }

    gdscript_map_set_item(ctx->map_instance, key, &value_variant);
    destructors.variant_destroy(&value_variant);
}

/* Callback context for array iteration */
typedef struct {
    Variant* array_instance;
    bool has_schema_child;
    const char* child_primitive_type;
} array_populate_ctx_t;

/* Callback for populating GDScript ArraySchema */
static void populate_array_callback(int index, void* value, void* userdata) {
    array_populate_ctx_t* ctx = (array_populate_ctx_t*)userdata;
    if (!ctx || !ctx->array_instance) return;

    Variant value_variant;
    if (ctx->has_schema_child && value) {
        colyseus_dynamic_schema_t* dyn_schema = (colyseus_dynamic_schema_t*)value;
        if (dyn_schema->userdata) {
            /* Schema child - get the GDScript instance */
            api.variant_new_copy(&value_variant, (Variant*)dyn_schema->userdata);
        } else {
            memset(&value_variant, 0, sizeof(value_variant));
        }
    } else if (value) {
        gdscript_primitive_to_variant(value, ctx->child_primitive_type, &value_variant);
    } else {
        memset(&value_variant, 0, sizeof(value_variant));
    }

    gdscript_array_set_at(ctx->array_instance, index, &value_variant);
    destructors.variant_destroy(&value_variant);
}

void gdscript_value_to_variant(colyseus_dynamic_value_t* value, Variant* r_variant) {
    if (!value || !r_variant) return;
    
    switch (value->type) {
        case COLYSEUS_FIELD_STRING: {
            String str;
            constructors.string_new_with_utf8_chars(&str, value->data.str ? value->data.str : "");
            constructors.variant_from_string_constructor(r_variant, &str);
            destructors.string_destructor(&str);
            break;
        }
        
        case COLYSEUS_FIELD_NUMBER:
        case COLYSEUS_FIELD_QUANTIZED: /* dequantized */
        case COLYSEUS_FIELD_FLOAT64: {
            constructors.variant_from_float_constructor(r_variant, &value->data.num);
            break;
        }
        
        case COLYSEUS_FIELD_FLOAT32: {
            double d = (double)value->data.f32;
            constructors.variant_from_float_constructor(r_variant, &d);
            break;
        }
        
        case COLYSEUS_FIELD_BOOLEAN: {
            GDExtensionBool b = value->data.boolean ? 1 : 0;
            constructors.variant_from_bool_constructor(r_variant, &b);
            break;
        }
        
        case COLYSEUS_FIELD_INT8:
        case COLYSEUS_FIELD_INT16:
        case COLYSEUS_FIELD_INT32: {
            int64_t i = value->data.i32;
            constructors.variant_from_int_constructor(r_variant, &i);
            break;
        }
        
        case COLYSEUS_FIELD_INT64: {
            constructors.variant_from_int_constructor(r_variant, &value->data.i64);
            break;
        }
        
        case COLYSEUS_FIELD_UINT8:
        case COLYSEUS_FIELD_UINT16:
        case COLYSEUS_FIELD_UINT32: {
            int64_t i = value->data.u32;
            constructors.variant_from_int_constructor(r_variant, &i);
            break;
        }
        
        case COLYSEUS_FIELD_UINT64: {
            int64_t i = (int64_t)value->data.u64;
            constructors.variant_from_int_constructor(r_variant, &i);
            break;
        }
        
        case COLYSEUS_FIELD_REF: {
            /* For ref types, the value is a dynamic schema with a GDScript userdata */
            if (value->data.ref && value->data.ref->userdata) {
                Variant* instance_variant = (Variant*)value->data.ref->userdata;
                api.variant_new_copy(r_variant, instance_variant);
            } else {
                /* Null ref */
                gdext_variant_new_nil(r_variant);
            }
            break;
        }
        
        case COLYSEUS_FIELD_MAP: {
            /* Create a GDScript Map and populate it */
            colyseus_map_schema_t* map = value->data.map;
            if (!map) {
                gdext_variant_new_nil(r_variant);
                break;
            }
            
            Variant* map_instance = gdscript_create_map_instance(NULL);
            if (!map_instance) {
                gdext_variant_new_nil(r_variant);
                break;
            }
            
            /* Populate the map with items */
            map_populate_ctx_t ctx = {
                .map_instance = map_instance,
                .has_schema_child = map->has_schema_child,
                .child_primitive_type = map->child_primitive_type
            };
            colyseus_map_schema_foreach(map, populate_map_callback, &ctx);
            
            /* Return the map instance */
            api.variant_new_copy(r_variant, map_instance);
            
            /* Free the temporary map instance holder */
            destructors.variant_destroy(map_instance);
            free(map_instance);
            break;
        }
        
        case COLYSEUS_FIELD_ARRAY: {
            /* Create a GDScript ArraySchema and populate it */
            colyseus_array_schema_t* arr = value->data.array;
            if (!arr) {
                gdext_variant_new_nil(r_variant);
                break;
            }
            
            Variant* array_instance = gdscript_create_array_instance(NULL);
            if (!array_instance) {
                gdext_variant_new_nil(r_variant);
                break;
            }
            
            /* Populate the array with items */
            array_populate_ctx_t ctx = {
                .array_instance = array_instance,
                .has_schema_child = arr->has_schema_child,
                .child_primitive_type = arr->child_primitive_type
            };
            colyseus_array_schema_foreach(arr, populate_array_callback, &ctx);
            
            /* Return the array instance */
            api.variant_new_copy(r_variant, array_instance);
            
            /* Free the temporary array instance holder */
            destructors.variant_destroy(array_instance);
            free(array_instance);
            break;
        }
        
        default: {
            /* Unknown type - return nil */
            gdext_variant_new_nil(r_variant);
            break;
        }
    }
}

/* ============================================================================
 * Collection Helpers
 * 
 * For collections (Map and ArraySchema), we use native Godot Dictionary and Array
 * instead of trying to instantiate GDScript classes from C. This gives good 
 * interoperability while avoiding the complexity of loading GDScript modules
 * from C code.
 * ============================================================================ */

Variant* gdscript_create_map_instance(GDExtensionObjectPtr child_class) {
    (void)child_class;  /* Reserved for future typed map support */
    
    /* Create a Godot Dictionary to hold map items */
    Dictionary dict;
    constructors.dictionary_constructor(&dict, NULL);
    
    /* Wrap in a Variant and return */
    Variant* result = malloc(sizeof(Variant));
    if (result) {
        constructors.variant_from_dictionary_constructor(result, &dict);
    }
    destructors.dictionary_destructor(&dict);
    
    return result;
}

Variant* gdscript_create_array_instance(GDExtensionObjectPtr child_class) {
    (void)child_class;  /* Reserved for future typed array support */
    
    /* Create a Godot Array to hold array items */
    Array arr;
    constructors.array_constructor(&arr, NULL);
    
    /* Wrap in a Variant and return */
    Variant* result = malloc(sizeof(Variant));
    if (result) {
        constructors.variant_from_array_constructor(result, &arr);
    }
    destructors.array_destructor(&arr);
    
    return result;
}

void gdscript_map_set_item(Variant* map_variant, const char* key, Variant* value_variant) {
    if (!map_variant || !key || !value_variant) return;
    
    /* Get Dictionary from variant */
    Dictionary dict;
    constructors.dictionary_from_variant_constructor(&dict, map_variant);
    
    /* Create key variant */
    String key_str;
    constructors.string_new_with_utf8_chars(&key_str, key);
    Variant key_var;
    constructors.variant_from_string_constructor(&key_var, &key_str);
    
    /* Set item using dictionary_operator_index */
    Variant* slot = api.dictionary_operator_index(&dict, &key_var);
    if (slot) {
        api.variant_new_copy(slot, value_variant);
    }
    
    /* Update the original variant with the modified dictionary */
    constructors.variant_from_dictionary_constructor(map_variant, &dict);
    
    destructors.variant_destroy(&key_var);
    destructors.string_destructor(&key_str);
    destructors.dictionary_destructor(&dict);
}

void gdscript_map_remove_item(Variant* map_variant, const char* key) {
    if (!map_variant || !key) return;
    
    /* Get Dictionary from variant and call erase */
    String key_str;
    constructors.string_new_with_utf8_chars(&key_str, key);
    Variant key_var;
    constructors.variant_from_string_constructor(&key_var, &key_str);
    
    GDExtensionConstVariantPtr args[1] = { &key_var };
    Variant result;
    
    variant_call_method(map_variant, "erase", args, 1, &result);
    
    destructors.variant_destroy(&result);
    destructors.variant_destroy(&key_var);
    destructors.string_destructor(&key_str);
}

void gdscript_array_set_at(Variant* array_variant, int index, Variant* value_variant) {
    if (!array_variant || !value_variant) return;
    
    /* Get Array from variant */
    Array arr;
    constructors.array_from_variant_constructor(&arr, array_variant);
    
    /* Resize array if needed and set the value */
    /* First, get current size */
    Variant size_result;
    variant_call_method(array_variant, "size", NULL, 0, &size_result);
    int64_t current_size = 0;
    constructors.int_from_variant_constructor(&current_size, &size_result);
    destructors.variant_destroy(&size_result);
    
    /* Resize if index is beyond current size */
    if (index >= current_size) {
        int64_t new_size = index + 1;
        Variant new_size_var;
        constructors.variant_from_int_constructor(&new_size_var, &new_size);
        GDExtensionConstVariantPtr resize_args[1] = { &new_size_var };
        Variant resize_result;
        variant_call_method(array_variant, "resize", resize_args, 1, &resize_result);
        destructors.variant_destroy(&resize_result);
        destructors.variant_destroy(&new_size_var);
    }
    
    /* Set the value at index using operator[] */
    int64_t idx = index;
    Variant* slot = api.array_operator_index(&arr, idx);
    if (slot) {
        api.variant_new_copy(slot, value_variant);
    }
    
    /* Update the original variant */
    constructors.variant_from_array_constructor(array_variant, &arr);
    
    destructors.array_destructor(&arr);
}

void gdscript_array_push(Variant* array_variant, Variant* value_variant) {
    if (!array_variant || !value_variant) return;
    
    /* Call push_back on the array */
    GDExtensionConstVariantPtr args[1] = { value_variant };
    Variant result;
    
    variant_call_method(array_variant, "push_back", args, 1, &result);
    
    destructors.variant_destroy(&result);
}
