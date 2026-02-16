#ifndef COLYSEUS_GDSCRIPT_SCHEMA_H
#define COLYSEUS_GDSCRIPT_SCHEMA_H

#include "godot_colyseus.h"
#include <colyseus/schema/dynamic_schema.h>

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
 * GDScript schema context - holds references to GDScript classes
 * and provides vtable integration.
 */
struct gdscript_schema_context {
    GDExtensionObjectPtr script_class;     /* The GDScript class (Script resource) */
    colyseus_dynamic_vtable_t* vtable;     /* Dynamic vtable built from definition() */
    gdscript_schema_context_t* children;   /* Child schema contexts */
    int child_count;
    char* name;                            /* Schema name for debugging */
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
 * @param context The callback context (script class pointer)
 * @return New GDScript object instance as userdata
 */
void* gdscript_create_instance(const colyseus_dynamic_vtable_t* vtable, void* context);

/*
 * Callback: Free a GDScript instance.
 * 
 * @param userdata The GDScript object to free
 */
void gdscript_free_instance(void* userdata);

/*
 * Callback: Set a field value on a GDScript instance.
 * 
 * @param userdata The GDScript object
 * @param name Field name
 * @param value The value to set
 */
void gdscript_set_field(void* userdata, const char* name, colyseus_dynamic_value_t* value);

/*
 * Convert a colyseus_dynamic_value_t to a Godot Variant.
 * 
 * @param value The dynamic value
 * @param r_variant Pointer to store the result variant
 */
void gdscript_value_to_variant(colyseus_dynamic_value_t* value, Variant* r_variant);

/*
 * Create a colyseus.Map instance in GDScript.
 * 
 * @param child_class The child type class (or NULL for primitives)
 * @return New GDScript Map object
 */
GDExtensionObjectPtr gdscript_create_map_instance(GDExtensionObjectPtr child_class);

/*
 * Create a colyseus.ArraySchema instance in GDScript.
 * 
 * @param child_class The child type class (or NULL for primitives)
 * @return New GDScript ArraySchema object
 */
GDExtensionObjectPtr gdscript_create_array_instance(GDExtensionObjectPtr child_class);

/*
 * Set an item in a GDScript Map instance.
 * 
 * @param map_obj The Map object
 * @param key The key
 * @param value_variant The value as a Variant
 */
void gdscript_map_set_item(GDExtensionObjectPtr map_obj, const char* key, Variant* value_variant);

/*
 * Remove an item from a GDScript Map instance.
 * 
 * @param map_obj The Map object
 * @param key The key
 */
void gdscript_map_remove_item(GDExtensionObjectPtr map_obj, const char* key);

/*
 * Set an item in a GDScript ArraySchema instance.
 * 
 * @param array_obj The ArraySchema object
 * @param index The index
 * @param value_variant The value as a Variant
 */
void gdscript_array_set_at(GDExtensionObjectPtr array_obj, int index, Variant* value_variant);

/*
 * Push an item to a GDScript ArraySchema instance.
 * 
 * @param array_obj The ArraySchema object
 * @param value_variant The value as a Variant
 */
void gdscript_array_push(GDExtensionObjectPtr array_obj, Variant* value_variant);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_GDSCRIPT_SCHEMA_H */
