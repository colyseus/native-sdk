#include "colyseus/schema/input_encoder.h"
#include "colyseus/schema/dynamic_schema.h"
#include "colyseus/schema/quantize.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * A field op packs as `operation | index`, so index 63 would emit 255 — the
 * byte a decoder reads as SWITCH_TO_STRUCTURE. The server rejects the 64th
 * field where the schema is defined; mirror it here, since this encoder
 * assembles the op byte itself.
 */
#define MAX_FIELDS 63

/*
 * Uniform field view: every flat primitive collapses to a double or a
 * string, which keeps the baseline diff to two comparisons. The wire width
 * still comes from the field's declared type at encode time.
 */
typedef struct {
    int index;                          /* wire field index */
    colyseus_field_type_t type;
    size_t offset;                      /* static instances only */
    const colyseus_quantized_descriptor_t* quantized;
    const char* name;                   /* dynamic instances read/write by name+index */
} input_field_t;

struct colyseus_input_encoder {
    colyseus_schema_t* instance;
    const colyseus_schema_vtable_t* vtable;
    bool is_dynamic;
    bool unreliable;
    int history_size;
    int seq;                            /* monotonic across reset (unreliable) */

    input_field_t* fields;
    int field_count;

    /* last-sent snapshot; has_baseline=false → snapshot mode (post-reset) */
    bool has_baseline;
    double* baseline_num;
    char** baseline_str;                /* owned copies for string fields */

    /* unreliable ring (oldest→newest via head/count arithmetic) */
    colyseus_wbuf_t* slots;
    int slot_head;
    int slot_count;

    colyseus_wbuf_t delta;              /* per-encode scratch */
    colyseus_wbuf_t out;                /* returned packet (unreliable) */
};

/* ── field value access (static offsets or dynamic table) ────────────── */

static double read_num(const colyseus_input_encoder_t* encoder, const input_field_t* field) {
    if (encoder->is_dynamic) {
        colyseus_dynamic_value_t* value = colyseus_dynamic_schema_get(
            (colyseus_dynamic_schema_t*)encoder->instance, field->index);
        if (!value) return 0;
        switch (field->type) {
            case COLYSEUS_FIELD_BOOLEAN: return value->data.boolean ? 1 : 0;
            case COLYSEUS_FIELD_FLOAT32: return (double)value->data.f32;
            case COLYSEUS_FIELD_INT8:    return (double)value->data.i8;
            case COLYSEUS_FIELD_UINT8:   return (double)value->data.u8;
            case COLYSEUS_FIELD_INT16:   return (double)value->data.i16;
            case COLYSEUS_FIELD_UINT16:  return (double)value->data.u16;
            case COLYSEUS_FIELD_INT32:   return (double)value->data.i32;
            case COLYSEUS_FIELD_UINT32:  return (double)value->data.u32;
            case COLYSEUS_FIELD_INT64:   return (double)value->data.i64;
            case COLYSEUS_FIELD_UINT64:  return (double)value->data.u64;
            default:                     return value->data.num;
        }
    }

    const void* p = (const char*)encoder->instance + field->offset;
    switch (field->type) {
        case COLYSEUS_FIELD_BOOLEAN: return *(const bool*)p ? 1 : 0;
        case COLYSEUS_FIELD_FLOAT32: return (double)*(const float*)p;
        case COLYSEUS_FIELD_INT8:    return (double)*(const int8_t*)p;
        case COLYSEUS_FIELD_UINT8:   return (double)*(const uint8_t*)p;
        case COLYSEUS_FIELD_INT16:   return (double)*(const int16_t*)p;
        case COLYSEUS_FIELD_UINT16:  return (double)*(const uint16_t*)p;
        case COLYSEUS_FIELD_INT32:   return (double)*(const int32_t*)p;
        case COLYSEUS_FIELD_UINT32:  return (double)*(const uint32_t*)p;
        case COLYSEUS_FIELD_INT64:   return (double)*(const int64_t*)p;
        case COLYSEUS_FIELD_UINT64:  return (double)*(const uint64_t*)p;
        default:                     return *(const double*)p; /* NUMBER / FLOAT64 / QUANTIZED */
    }
}

static const char* read_str(const colyseus_input_encoder_t* encoder, const input_field_t* field) {
    if (encoder->is_dynamic) {
        colyseus_dynamic_value_t* value = colyseus_dynamic_schema_get(
            (colyseus_dynamic_schema_t*)encoder->instance, field->index);
        return value ? value->data.str : NULL;
    }
    return *(const char* const*)((const char*)encoder->instance + field->offset);
}

static int compare_field_index(const void* a, const void* b) {
    return ((const input_field_t*)a)->index - ((const input_field_t*)b)->index;
}

/* ── construction ────────────────────────────────────────────────────── */

colyseus_input_encoder_t* colyseus_input_encoder_create(
    colyseus_schema_t* instance,
    const colyseus_schema_vtable_t* vtable,
    bool unreliable,
    int history_size) {
    if (!instance || !vtable) return NULL;

    colyseus_input_encoder_t* encoder = calloc(1, sizeof(colyseus_input_encoder_t));
    encoder->instance = instance;
    encoder->vtable = vtable;
    encoder->is_dynamic = colyseus_vtable_is_dynamic(vtable);
    encoder->unreliable = unreliable;
    encoder->history_size = unreliable ? (history_size > 1 ? history_size : 3) : 1;

    /* resolve the flat field list from either vtable flavor */
    if (encoder->is_dynamic) {
        const colyseus_dynamic_vtable_t* dyn = (const colyseus_dynamic_vtable_t*)vtable;
        encoder->field_count = dyn->dyn_field_count;
        encoder->fields = calloc(encoder->field_count, sizeof(input_field_t));
        for (int i = 0; i < encoder->field_count; i++) {
            const colyseus_dynamic_field_t* field = dyn->dyn_fields[i];
            if (field->type == COLYSEUS_FIELD_REF || field->type == COLYSEUS_FIELD_ARRAY
                || field->type == COLYSEUS_FIELD_MAP) {
                goto unsupported;
            }
            encoder->fields[i].index = field->index;
            encoder->fields[i].type = field->type;
            encoder->fields[i].quantized = field->quantized;
            encoder->fields[i].name = field->name;
        }
    } else {
        encoder->field_count = vtable->field_count;
        encoder->fields = calloc(encoder->field_count, sizeof(input_field_t));
        for (int i = 0; i < encoder->field_count; i++) {
            const colyseus_field_t* field = &vtable->fields[i];
            if (field->type == COLYSEUS_FIELD_REF || field->type == COLYSEUS_FIELD_ARRAY
                || field->type == COLYSEUS_FIELD_MAP) {
                goto unsupported;
            }
            encoder->fields[i].index = field->index;
            encoder->fields[i].type = field->type;
            encoder->fields[i].offset = field->offset;
            encoder->fields[i].quantized = field->quantized;
            encoder->fields[i].name = field->name;
        }
    }

    for (int i = 0; i < encoder->field_count; i++) {
        if (encoder->fields[i].index < MAX_FIELDS) continue;
        fprintf(stderr, "colyseus: colyseus_input_encoder_create(): field '%s' is at index %d; "
            "a Schema may only have %d fields.\n",
            encoder->fields[i].name, encoder->fields[i].index, MAX_FIELDS);
        goto unsupported;
    }

    /* wire order is FIELD-INDEX order — dynamic vtables don't guarantee it */
    qsort(encoder->fields, encoder->field_count, sizeof(input_field_t), compare_field_index);

    encoder->baseline_num = calloc(encoder->field_count, sizeof(double));
    encoder->baseline_str = calloc(encoder->field_count, sizeof(char*));

    if (encoder->unreliable) {
        encoder->slots = calloc(encoder->history_size, sizeof(colyseus_wbuf_t));
    }
    colyseus_wbuf_init(&encoder->delta);
    colyseus_wbuf_init(&encoder->out);

    /* diff against construction defaults from the start — an unassigned
     * field is not dirty (the JS ChangeTree behaves the same way) */
    encoder->has_baseline = true;
    for (int i = 0; i < encoder->field_count; i++) {
        if (encoder->fields[i].type == COLYSEUS_FIELD_STRING) {
            const char* s = read_str(encoder, &encoder->fields[i]);
            encoder->baseline_str[i] = s ? strdup(s) : NULL;
        } else {
            encoder->baseline_num[i] = read_num(encoder, &encoder->fields[i]);
        }
    }

    return encoder;

unsupported:
    free(encoder->fields);
    free(encoder);
    return NULL;
}

void colyseus_input_encoder_free(colyseus_input_encoder_t* encoder) {
    if (!encoder) return;
    for (int i = 0; i < encoder->field_count; i++) free(encoder->baseline_str[i]);
    free(encoder->baseline_str);
    free(encoder->baseline_num);
    free(encoder->fields);
    if (encoder->slots) {
        for (int i = 0; i < encoder->history_size; i++) colyseus_wbuf_free(&encoder->slots[i]);
        free(encoder->slots);
    }
    colyseus_wbuf_free(&encoder->delta);
    colyseus_wbuf_free(&encoder->out);
    free(encoder);
}

int colyseus_input_encoder_seq(const colyseus_input_encoder_t* encoder) {
    return encoder->seq;
}

bool colyseus_input_encoder_is_unreliable(const colyseus_input_encoder_t* encoder) {
    return encoder->unreliable;
}

/* ── delta producer ──────────────────────────────────────────────────── */

static void encode_field_value(colyseus_input_encoder_t* encoder, const input_field_t* field) {
    colyseus_wbuf_t* buf = &encoder->delta;
    switch (field->type) {
        case COLYSEUS_FIELD_STRING:  colyseus_encode_string(buf, read_str(encoder, field)); break;
        case COLYSEUS_FIELD_BOOLEAN: colyseus_encode_boolean(buf, read_num(encoder, field) != 0); break;
        case COLYSEUS_FIELD_INT8:    colyseus_encode_int8(buf, (int8_t)read_num(encoder, field)); break;
        case COLYSEUS_FIELD_UINT8:   colyseus_encode_uint8(buf, (uint8_t)read_num(encoder, field)); break;
        case COLYSEUS_FIELD_INT16:   colyseus_encode_int16(buf, (int16_t)read_num(encoder, field)); break;
        case COLYSEUS_FIELD_UINT16:  colyseus_encode_uint16(buf, (uint16_t)read_num(encoder, field)); break;
        case COLYSEUS_FIELD_INT32:   colyseus_encode_int32(buf, (int32_t)read_num(encoder, field)); break;
        case COLYSEUS_FIELD_UINT32:  colyseus_encode_uint32(buf, (uint32_t)read_num(encoder, field)); break;
        case COLYSEUS_FIELD_INT64:   colyseus_encode_int64(buf, (int64_t)read_num(encoder, field)); break;
        case COLYSEUS_FIELD_UINT64:  colyseus_encode_uint64(buf, (uint64_t)read_num(encoder, field)); break;
        case COLYSEUS_FIELD_FLOAT32: colyseus_encode_float32(buf, (float)read_num(encoder, field)); break;
        case COLYSEUS_FIELD_FLOAT64: colyseus_encode_float64(buf, read_num(encoder, field)); break;
        case COLYSEUS_FIELD_QUANTIZED: {
            uint32_t q = colyseus_quantize(field->quantized, read_num(encoder, field));
            if (field->quantized->bits == 8) colyseus_encode_uint8(buf, (uint8_t)q);
            else if (field->quantized->bits == 16) colyseus_encode_uint16(buf, (uint16_t)q);
            else colyseus_encode_uint32(buf, q);
            break;
        }
        default: /* NUMBER */
            colyseus_encode_number(buf, read_num(encoder, field));
            break;
    }
}

static void produce_delta(colyseus_input_encoder_t* encoder) {
    colyseus_wbuf_reset(&encoder->delta);
    bool snapshot = !encoder->has_baseline; /* post-reset */
    encoder->has_baseline = true;

    for (int i = 0; i < encoder->field_count; i++) {
        const input_field_t* field = &encoder->fields[i];
        bool changed;

        if (field->type == COLYSEUS_FIELD_STRING) {
            const char* current = read_str(encoder, field);
            changed = snapshot
                ? (current != NULL)                     /* snapshot: every populated field */
                : !((current == NULL && encoder->baseline_str[i] == NULL) ||
                    (current != NULL && encoder->baseline_str[i] != NULL &&
                     strcmp(current, encoder->baseline_str[i]) == 0));
            if (!changed) continue;
            free(encoder->baseline_str[i]);
            encoder->baseline_str[i] = current ? strdup(current) : NULL;
        } else {
            double current = read_num(encoder, field);
            /* scalars are always populated in C (0 is a value, matching the
             * defaults the other SDKs snapshot after reset) */
            changed = snapshot || current != encoder->baseline_num[i];
            if (!changed) continue;
            encoder->baseline_num[i] = current;
        }

        colyseus_wbuf_push(&encoder->delta, (uint8_t)(0x80 | field->index));
        encode_field_value(encoder, field);
    }
}

const uint8_t* colyseus_input_encoder_encode(colyseus_input_encoder_t* encoder, size_t* out_length) {
    produce_delta(encoder);

    if (!encoder->unreliable) {
        *out_length = encoder->delta.length;
        return encoder->delta.data ? encoder->delta.data : (const uint8_t*)"";
    }

    /* push EVERY tick (even empty) so ring seqs stay consecutive: the packet
     * carries one base seq; the decoder derives slot seqs by position */
    encoder->seq++;
    colyseus_wbuf_t* slot = &encoder->slots[encoder->slot_head];
    colyseus_wbuf_reset(slot);
    colyseus_wbuf_append(slot, encoder->delta.data, encoder->delta.length);
    encoder->slot_head = (encoder->slot_head + 1) % encoder->history_size;
    if (encoder->slot_count < encoder->history_size) encoder->slot_count++;

    /* [baseSeq][len][slot]… oldest→newest */
    colyseus_wbuf_reset(&encoder->out);
    int base_seq = encoder->seq - encoder->slot_count + 1;
    colyseus_encode_number(&encoder->out, (double)base_seq);
    int oldest = (encoder->slot_head - encoder->slot_count + encoder->history_size) % encoder->history_size;
    for (int i = 0; i < encoder->slot_count; i++) {
        colyseus_wbuf_t* s = &encoder->slots[(oldest + i) % encoder->history_size];
        colyseus_encode_number(&encoder->out, (double)s->length);
        colyseus_wbuf_append(&encoder->out, s->data, s->length);
    }
    *out_length = encoder->out.length;
    return encoder->out.data;
}

void colyseus_input_encoder_reset(colyseus_input_encoder_t* encoder) {
    encoder->has_baseline = false;
    encoder->slot_head = 0;
    encoder->slot_count = 0;
}

void colyseus_input_encoder_copy_into(colyseus_input_encoder_t* encoder, colyseus_schema_t* target) {
    for (int i = 0; i < encoder->field_count; i++) {
        const input_field_t* field = &encoder->fields[i];
        if (encoder->is_dynamic) {
            colyseus_dynamic_value_t* value = colyseus_dynamic_schema_get(
                (colyseus_dynamic_schema_t*)encoder->instance, field->index);
            if (value) {
                /* set() takes ownership — hand it a clone */
                colyseus_dynamic_schema_set((colyseus_dynamic_schema_t*)target,
                    field->index, field->name, colyseus_dynamic_value_clone(value));
            }
            continue;
        }

        void* dst = (char*)target + field->offset;
        const void* src = (const char*)encoder->instance + field->offset;
        switch (field->type) {
            case COLYSEUS_FIELD_STRING: {
                char** dstr = (char**)dst;
                const char* sstr = *(const char* const*)src;
                free(*dstr);
                *dstr = sstr ? strdup(sstr) : NULL;
                break;
            }
            case COLYSEUS_FIELD_BOOLEAN: *(bool*)dst = *(const bool*)src; break;
            case COLYSEUS_FIELD_FLOAT32: *(float*)dst = *(const float*)src; break;
            case COLYSEUS_FIELD_INT8:    *(int8_t*)dst = *(const int8_t*)src; break;
            case COLYSEUS_FIELD_UINT8:   *(uint8_t*)dst = *(const uint8_t*)src; break;
            case COLYSEUS_FIELD_INT16:   *(int16_t*)dst = *(const int16_t*)src; break;
            case COLYSEUS_FIELD_UINT16:  *(uint16_t*)dst = *(const uint16_t*)src; break;
            case COLYSEUS_FIELD_INT32:   *(int32_t*)dst = *(const int32_t*)src; break;
            case COLYSEUS_FIELD_UINT32:  *(uint32_t*)dst = *(const uint32_t*)src; break;
            case COLYSEUS_FIELD_INT64:   *(int64_t*)dst = *(const int64_t*)src; break;
            case COLYSEUS_FIELD_UINT64:  *(uint64_t*)dst = *(const uint64_t*)src; break;
            default:                     *(double*)dst = *(const double*)src; break;
        }
    }
}
