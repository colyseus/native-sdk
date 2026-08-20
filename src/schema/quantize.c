#include "colyseus/schema/quantize.h"
#include <math.h>

/*
 * No FMA contraction: clang defaults to -ffp-contract=on and fuses
 * `min + (q/span)*range` into fmadd on ARM64 — one rounding instead of two,
 * a 1-ULP divergence from the JS reference (which never fuses). Every peer
 * must produce bit-identical doubles.
 */
#pragma STDC FP_CONTRACT OFF

colyseus_quantized_descriptor_t colyseus_quantize_resolve(double min, double max, uint8_t bits, bool wrap) {
    double steps = pow(2.0, (double)bits);
    colyseus_quantized_descriptor_t desc = {
        .min = min,
        .max = max,
        .range = max - min,
        /* wrapping spreads 2^bits steps across [min,max) (top ≡ bottom);
         * clamped maps the endpoints onto 0 and 2^bits-1 inclusive */
        .span = wrap ? steps : steps - 1.0,
        .bits = bits,
        .wrap = wrap,
    };
    return desc;
}

uint32_t colyseus_quantize(const colyseus_quantized_descriptor_t* desc, double value) {
    if (desc->wrap) {
        /* non-finite can't be range-reduced; pin to q=0 so both peers agree */
        if (!isfinite(value)) return 0;

        double range = desc->range;
        /* float-domain range reduction → [0, range) */
        double a = fmod(value - desc->min, range);
        if (a < 0) a += range;
        return (uint32_t)fmod(floor((a / range) * desc->span + 0.5), desc->span);
    }

    if (value != value) return 0; /* NaN → min (±Inf clamps naturally below) */
    double v = value < desc->min ? desc->min : (value > desc->max ? desc->max : value);
    return (uint32_t)floor(((v - desc->min) / desc->range) * desc->span + 0.5);
}

double colyseus_dequantize(const colyseus_quantized_descriptor_t* desc, uint32_t q) {
    return desc->min + ((double)q / desc->span) * desc->range;
}

double colyseus_quantize_snap(const colyseus_quantized_descriptor_t* desc, double value) {
    return colyseus_dequantize(desc, colyseus_quantize(desc, value));
}
