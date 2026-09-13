#ifndef COLYSEUS_GDSCRIPT_SCHEMA_H
#define COLYSEUS_GDSCRIPT_SCHEMA_H

#include "godot_colyseus.h"
#include <colyseus/schema/dynamic_schema.h>
#include <colyseus/schema/decoder.h>
#include <colyseus/schema/ref_tracker.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * GDScript Schema Bridge
 *
 * Provides integration between GDScript Schema classes and the C decoder.
 * Allows GDScript users to define their state schema as GDScript classes
 * that extend colyseus.Schema.
 */

/* Forward declarations */
typedef struct gdscript_schema_context gdscript_schema_context_t;

/*
 * Live collections of one room: every map/array field of a typed instance is
 * a plain Dictionary/Array that the decoder keeps current, keyed by the
 * collection's ref id. Shared by a context tree, owned by its root.
 */
typedef struct gdscript_live gdscript_live_t;

/* A vtable's callback_context: which class to instantiate, and for which room. */
typedef struct gdscript_class_binding {
    GDExtensionObjectPtr script_class;
    gdscript_live_t* live;
} gdscript_class_binding_t;

/*
 * The decoder-side handle of a GDScript instance (dynamic schema userdata).
 * `instance` comes first so the rest of the binding keeps reading userdata
 * as a Variant*.
 */
typedef struct {
    Variant instance;
    gdscript_live_t* live;
    int ref_id;          /* -1 until decoded, and again once collected */
    bool released;       /* collected: the decoder no longer holds the object */
} gdscript_instance_t;

/*
 * GDScript schema context - holds references to GDScript classes
 * and provides vtable integration.
 */
struct gdscript_schema_context {
    GDExtensionObjectPtr script_class;     /* The GDScript class (Script resource) */
    colyseus_dynamic_vtable_t* vtable;     /* Dynamic vtable built from definition() */
    gdscript_schema_context_t* children;   /* Child schema contexts */
    int child_count;
    char* name;                            /* Schema name for debugging */
    gdscript_class_binding_t* binding;     /* the vtable's callback_context (owned) */
    gdscript_live_t* live;                 /* shared with the children */
    bool owns_live;
};

/*
 * Parse a GDScript Schema class and create a dynamic vtable from it.
 *
 * The GDScript class should extend colyseus.Schema and implement:
 * - static func definition() -> Array[Field]
 *
 * @param script_variant Variant containing the GDScript class reference
 * @return Dynamic vtable built from the class definition, or NULL on error
 */
colyseus_dynamic_vtable_t* gdscript_schema_parse_class(GDExtensionConstVariantPtr script_variant);

/*
 * Create a GDScript schema context from a class.
 * This handles the full hierarchy of nested schemas.
 *
 * @param script_variant Variant containing the GDScript class
 * @return Schema context, or NULL on error
 */
gdscript_schema_context_t* gdscript_schema_context_create(GDExtensionConstVariantPtr script_variant);

/*
 * Free a GDScript schema context and all its children.
 */
void gdscript_schema_context_free(gdscript_schema_context_t* ctx);

/*
 * Callback: Create a GDScript instance for a schema.
 * Called by the decoder when creating new schema instances.
 *
 * @param vtable The dynamic vtable
 * @param context The callback context (gdscript_class_binding_t*)
 * @return New gdscript_instance_t as userdata
 */
void* gdscript_create_instance(const colyseus_dynamic_vtable_t* vtable, void* context);

/*
 * Callback: Free a GDScript instance. The object outlives this when GDScript
 * still holds it; its __ref_id is reset to -1 so it never passes for whatever
 * entity is decoded under that id next.
 *
 * @param userdata The gdscript_instance_t to free
 */
void gdscript_free_instance(void* userdata);

/*
 * Callback: Set a field value on a GDScript instance.
 *
 * @param userdata The gdscript_instance_t
 * @param name Field name
 * @param value The value to set
 */
void gdscript_set_field(void* userdata, const char* name, colyseus_dynamic_value_t* value);

/*
 * Callback: Set the __ref_id on a GDScript instance.
 * Called when the decoder assigns a ref_id to a schema instance.
 *
 * @param userdata The gdscript_instance_t
 * @param ref_id The reference ID assigned by the decoder
 */
void gdscript_set_ref_id(void* userdata, int ref_id);

/*
 * Convert a colyseus_dynamic_value_t to a Godot Variant.
 *
 * @param value The dynamic value
 * @param r_variant Pointer to store the result variant
 */
void gdscript_value_to_variant(colyseus_dynamic_value_t* value, Variant* r_variant);

/* A primitive collection item (as the decoder stores it) -> Variant; ints for
 * integer types, floats for number/float types. Nil for unknown types. */
void gdscript_primitive_to_variant(void* value, const char* primitive_type, Variant* r_variant);

/*
 * Live collections — driven by the room's decoder listeners:
 *   apply: after a decode, bring every tracked container in line with it
 *   collect: the decoder's GC let go of this ref id (the server will reuse it):
 *            forget its container, or reset its instance's __ref_id to -1 and
 *            leave the object to whoever in GDScript still holds it
 *   container: the live Dictionary/Array for a collection ref id
 */
void gdscript_live_apply(gdscript_schema_context_t* ctx, colyseus_ref_tracker_t* refs, colyseus_changes_t* changes);
void gdscript_live_collect(gdscript_schema_context_t* ctx, int ref_id);
bool gdscript_live_container(gdscript_schema_context_t* ctx, int ref_id, Variant* r_container);

/*
 * Create a colyseus.Map instance in GDScript.
 *
 * @param child_class The child type class (or NULL for primitives)
 * @return New GDScript Map object as Variant* (caller owns memory)
 */
Variant* gdscript_create_map_instance(GDExtensionObjectPtr child_class);

/*
 * Create a colyseus.ArraySchema instance in GDScript.
 *
 * @param child_class The child type class (or NULL for primitives)
 * @return New GDScript ArraySchema object as Variant* (caller owns memory)
 */
Variant* gdscript_create_array_instance(GDExtensionObjectPtr child_class);

/*
 * Set an item in a GDScript Map instance.
 *
 * @param map_variant The Map object as Variant*
 * @param key The key
 * @param value_variant The value as a Variant
 */
void gdscript_map_set_item(Variant* map_variant, const char* key, Variant* value_variant);

/*
 * Remove an item from a GDScript Map instance.
 *
 * @param map_variant The Map object as Variant*
 * @param key The key
 */
void gdscript_map_remove_item(Variant* map_variant, const char* key);

/*
 * Set an item in a GDScript ArraySchema instance.
 *
 * @param array_variant The ArraySchema object as Variant*
 * @param index The index
 * @param value_variant The value as a Variant
 */
void gdscript_array_set_at(Variant* array_variant, int index, Variant* value_variant);

/*
 * Push an item to a GDScript ArraySchema instance.
 *
 * @param array_variant The ArraySchema object as Variant*
 * @param value_variant The value as a Variant
 */
void gdscript_array_push(Variant* array_variant, Variant* value_variant);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_GDSCRIPT_SCHEMA_H */
