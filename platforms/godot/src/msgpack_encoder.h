#ifndef MSGPACK_ENCODER_H
#define MSGPACK_ENCODER_H

#include "godot_colyseus.h"
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Encode a Godot Variant to msgpack bytes.
 * 
 * Converts native Godot types to msgpack-encoded data:
 * - Godot null -> msgpack nil
 * - Godot bool -> msgpack bool
 * - Godot int -> msgpack int
 * - Godot float -> msgpack float64
 * - Godot String -> msgpack str
 * - Godot PackedByteArray -> msgpack bin
 * - Godot Array -> msgpack array
 * - Godot Dictionary -> msgpack map
 * 
 * @param variant Pointer to the Variant to encode
 * @param out_length Pointer to store the resulting buffer length
 * @return Allocated buffer containing msgpack data (caller must free), or NULL on error
 * 
 * @note The caller is responsible for freeing the returned buffer
 * @note Returns NULL and sets out_length to 0 on encoding error
 */
uint8_t* godot_variant_to_msgpack(const Variant* variant, size_t* out_length);

#ifdef __cplusplus
}
#endif

#endif /* MSGPACK_ENCODER_H */
