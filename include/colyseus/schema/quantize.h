#ifndef COLYSEUS_SCHEMA_QUANTIZE_H
#define COLYSEUS_SCHEMA_QUANTIZE_H

#include "types.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * t.quantized() codec — a bounded float encoded as a fixed-width unsigned
 * integer. Port of @colyseus/schema 5.0 `src/types/quantize.ts`; the math
 * must stay bit-identical to the reference:
 *
 *   - rounding is explicit `floor(x + 0.5)` — NOT the language default
 *     (C's `round` is half-away-from-zero and disagrees on the .5 case)
 *   - wrapping ranges are reduced in the FLOAT domain before the integer
 *     step (a huge-double→int cast is UB in C)
 *   - the wrap top step folds via `fmod(q, span)`, not a bitmask (bits=32
 *     would overflow 32-bit integer math)
 *   - NaN → q=0 (both modes); ±Inf → q=0 for wrap, natural clamp for clamp
 *   - all math in double
 */

/* Precompute range/span for {min, max, bits (8|16|32), wrap}. */
colyseus_quantized_descriptor_t colyseus_quantize_resolve(double min, double max, uint8_t bits, bool wrap);

/* Float → unsigned wire integer. */
uint32_t colyseus_quantize(const colyseus_quantized_descriptor_t* desc, double value);

/* Unsigned wire integer → float. */
double colyseus_dequantize(const colyseus_quantized_descriptor_t* desc, uint32_t q);

/* Wire-exact round-trip — what a quantized field yields after assignment. */
double colyseus_quantize_snap(const colyseus_quantized_descriptor_t* desc, double value);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_SCHEMA_QUANTIZE_H */
