#ifndef COLYSEUS_STATE_H
#define COLYSEUS_STATE_H

#include "godot_colyseus.h"
#include <colyseus/schema/types.h>
#include <colyseus/schema/collections.h>
#include <colyseus/schema/ref_tracker.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Convert a schema instance to a Godot Dictionary
 * 
 * @param schema The schema instance to convert
 * @param vtable The vtable describing the schema structure
 * @param result Pointer to Dictionary to populate
 */
void colyseus_schema_to_dictionary(
    const colyseus_schema_t* schema,
    const colyseus_schema_vtable_t* vtable,
    Dictionary* result
);

/**
 * Convert an ArraySchema to a Godot Array
 * 
 * @param array The array schema to convert
 * @param result Pointer to Array to populate
 */
void colyseus_array_to_godot_array(
    const colyseus_array_schema_t* array,
    Array* result
);

/**
 * Convert a MapSchema to a Godot Dictionary
 * 
 * @param map The map schema to convert
 * @param result Pointer to Dictionary to populate
 */
void colyseus_map_to_dictionary(
    const colyseus_map_schema_t* map,
    Dictionary* result
);

/**
 * Convert a schema field value to a Godot Variant
 * 
 * @param ptr Pointer to the field value
 * @param field_type The field type enum
 * @param child_vtable For ref/array/map types, the child schema vtable (may be NULL)
 * @param result Pointer to Variant to populate
 */
void colyseus_field_to_variant(
    const void* ptr,
    colyseus_field_type_t field_type,
    const colyseus_schema_vtable_t* child_vtable,
    Variant* result
);

/**
 * Extract __ref_id from a Dictionary variant
 * 
 * @param dict_variant Pointer to the Dictionary variant
 * @return The ref_id, or -1 if not found
 */
int colyseus_extract_ref_id(const Variant* dict_variant);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_STATE_H */
