#ifndef COLYSEUS_SCHEMA_INPUT_ENCODER_H
#define COLYSEUS_SCHEMA_INPUT_ENCODER_H

#include "colyseus/schema/types.h"
#include "colyseus/schema/encode.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Bound single-struct encoder for client→server input packets. Port of
 * @colyseus/schema src/input/InputEncoder.ts (flat primitive fields only —
 * ref/array/map fields are a construction-time error). Works with both
 * static vtables (values read via field offsets) and dynamic vtables
 * (values read via the dynamic field table).
 *
 * Delta tracking differs from the JS reference by design: the reference
 * uses setter-populated ChangeTrees; this port diffs the instance against
 * the last-sent snapshot (seeded from construction defaults, so an
 * unassigned field is not dirty). Benign divergence: re-assigning an
 * identical value emits nothing — the server decodes to the same state.
 *
 * "reliable" mode: one delta per encode() — only changed fields, empty when
 * nothing changed. "unreliable" mode: ring of the last `history_size`
 * deltas in one packet: [baseSeq][len][slot]… oldest→newest; a no-change
 * tick still pushes an empty carry-forward slot.
 */
typedef struct colyseus_input_encoder colyseus_input_encoder_t;

/*
 * Create an encoder bound to `instance` (whose vtable is `vtable` — pass
 * the dynamic vtable cast to colyseus_schema_vtable_t* for reflection-built
 * input schemas). Returns NULL when the schema has non-primitive fields.
 */
colyseus_input_encoder_t* colyseus_input_encoder_create(
    colyseus_schema_t* instance,
    const colyseus_schema_vtable_t* vtable,
    bool unreliable,
    int history_size);

void colyseus_input_encoder_free(colyseus_input_encoder_t* encoder);

/*
 * Encode the bound instance's delta. The returned pointer is owned by the
 * encoder and valid until the next call. `*out_length` receives the size
 * (0 = no-change tick in reliable mode).
 */
const uint8_t* colyseus_input_encoder_encode(colyseus_input_encoder_t* encoder, size_t* out_length);

/*
 * Reset: drops the ring and the diff baseline, so the next encode() emits a
 * full snapshot. The unreliable seq is kept (monotonic across reset).
 */
void colyseus_input_encoder_reset(colyseus_input_encoder_t* encoder);

/* Copy the bound instance's field values into `target` (same-type instance). */
void colyseus_input_encoder_copy_into(colyseus_input_encoder_t* encoder, colyseus_schema_t* target);

/* Framework input seq of the most recent tick (unreliable mode). */
int colyseus_input_encoder_seq(const colyseus_input_encoder_t* encoder);

bool colyseus_input_encoder_is_unreliable(const colyseus_input_encoder_t* encoder);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_SCHEMA_INPUT_ENCODER_H */
