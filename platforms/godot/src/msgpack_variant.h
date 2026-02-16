#ifndef MSGPACK_VARIANT_H
#define MSGPACK_VARIANT_H

#include "godot_colyseus.h"
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Convert msgpack data to a Godot Variant.
 * 
 * Decodes msgpack-encoded data and converts it directly to native Godot types:
 * - msgpack nil -> Godot null
 * - msgpack bool -> Godot bool
 * - msgpack int/uint -> Godot int
 * - msgpack float -> Godot float
 * - msgpack str -> Godot String
 * - msgpack bin -> Godot PackedByteArray
 * - msgpack array -> Godot Array
 * - msgpack map -> Godot Dictionary
 * 
 * @param data Pointer to msgpack-encoded data
 * @param length Length of the data in bytes
 * @param out_variant Pointer to Variant to store the result (must be valid)
 * @return true on success, false on decode error
 * 
 * @note The caller is responsible for destroying the variant when done
 *       using destructors.variant_destroy()
 * @note Empty data (length == 0) returns nil and is considered valid
 */
bool msgpack_to_godot_variant(const uint8_t* data, size_t length, Variant* out_variant);

#ifdef __cplusplus
}
#endif

#endif /* MSGPACK_VARIANT_H */
