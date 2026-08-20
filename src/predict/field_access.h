#ifndef COLYSEUS_PREDICT_FIELD_ACCESS_H
#define COLYSEUS_PREDICT_FIELD_ACCESS_H

#include "colyseus/schema/types.h"
#include "colyseus/schema/dynamic_schema.h"

#include <string.h>

/*
 * Scalar field access across BOTH storage models.
 *
 * Static (codegen'd) instances store fields at struct offsets; dynamic
 * instances (GDScript / reflection vtables) store them in a per-instance
 * hash keyed by field index. The predict layer treats every field as a
 * double either way, so this is the one seam it needs: resolve a field
 * once into a predict_fref_t, then read/write through it without caring
 * which model the instance uses.
 *
 * Writes on the dynamic path mutate the value cell IN PLACE and never
 * notify the platform userdata shadow — predict only ever writes to
 * mirrors and scratches, which are created bare (no shadow) precisely so
 * rollback replay stays off the host engine's object system.
 */

typedef struct {
    colyseus_field_type_t type;
    size_t offset;      /* static instances: offsetof() into the struct */
    int index;          /* dynamic instances: the field-hash key */
    const char* name;   /* borrowed from the vtable definition */
} predict_fref_t;

static inline bool predict_fref_scalar(const predict_fref_t* f) {
    return f->type != COLYSEUS_FIELD_REF && f->type != COLYSEUS_FIELD_ARRAY
        && f->type != COLYSEUS_FIELD_MAP && f->type != COLYSEUS_FIELD_STRING;
}

/* Declared-field count, either model. */
static inline int predict_vt_count(const colyseus_schema_vtable_t* vt) {
    const colyseus_dynamic_vtable_t* dv = colyseus_vtable_as_dynamic(vt);
    return dv ? dv->dyn_field_count : vt->field_count;
}

/* The i-th declared field. False when out of range / hole. */
static inline bool predict_vt_at(const colyseus_schema_vtable_t* vt, int i, predict_fref_t* out) {
    const colyseus_dynamic_vtable_t* dv = colyseus_vtable_as_dynamic(vt);
    if (dv) {
        if (i < 0 || i >= dv->dyn_field_count || !dv->dyn_fields[i]) return false;
        const colyseus_dynamic_field_t* f = dv->dyn_fields[i];
        out->type = f->type; out->offset = 0; out->index = f->index; out->name = f->name;
        return true;
    }
    if (i < 0 || i >= vt->field_count) return false;
    const colyseus_field_t* f = &vt->fields[i];
    out->type = f->type; out->offset = f->offset; out->index = f->index; out->name = f->name;
    return true;
}

static inline bool predict_vt_find(const colyseus_schema_vtable_t* vt, const char* name, predict_fref_t* out) {
    const colyseus_dynamic_vtable_t* dv = colyseus_vtable_as_dynamic(vt);
    if (dv) {
        const colyseus_dynamic_field_t* f = colyseus_dynamic_vtable_find_field_by_name(dv, name);
        if (!f) return false;
        out->type = f->type; out->offset = 0; out->index = f->index; out->name = f->name;
        return true;
    }
    for (int i = 0; i < vt->field_count; i++) {
        if (strcmp(vt->fields[i].name, name) == 0) {
            const colyseus_field_t* f = &vt->fields[i];
            out->type = f->type; out->offset = f->offset; out->index = f->index; out->name = f->name;
            return true;
        }
    }
    return false;
}

/* Low-level pair, shared by the fref calls and reconciler.c's cached view. */
static inline double predict_scalar_read(const colyseus_schema_t* inst,
    colyseus_field_type_t type, size_t offset, int index) {
    if (colyseus_vtable_is_dynamic(inst->__vtable)) {
        colyseus_dynamic_value_t* v =
            colyseus_dynamic_schema_get((colyseus_dynamic_schema_t*)inst, index);
        if (!v) return 0;   /* never decoded/written — static zero-init parity */
        switch (type) {
            case COLYSEUS_FIELD_BOOLEAN: return v->data.boolean ? 1 : 0;
            case COLYSEUS_FIELD_FLOAT32: return (double)v->data.f32;
            case COLYSEUS_FIELD_INT8:    return (double)v->data.i8;
            case COLYSEUS_FIELD_UINT8:   return (double)v->data.u8;
            case COLYSEUS_FIELD_INT16:   return (double)v->data.i16;
            case COLYSEUS_FIELD_UINT16:  return (double)v->data.u16;
            case COLYSEUS_FIELD_INT32:   return (double)v->data.i32;
            case COLYSEUS_FIELD_UINT32:  return (double)v->data.u32;
            case COLYSEUS_FIELD_INT64:   return (double)v->data.i64;
            case COLYSEUS_FIELD_UINT64:  return (double)v->data.u64;
            default:                     return v->data.num;
        }
    }
    const void* p = (const char*)inst + offset;
    switch (type) {
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
        default:                     return *(const double*)p;
    }
}

static inline void predict_scalar_write(colyseus_schema_t* inst,
    colyseus_field_type_t type, size_t offset, int index, const char* name, double val) {
    if (colyseus_vtable_is_dynamic(inst->__vtable)) {
        (void)name;
        colyseus_dynamic_value_t* v =
            colyseus_dynamic_schema_ensure((colyseus_dynamic_schema_t*)inst, index, type);
        if (!v) return;
        switch (type) {
            case COLYSEUS_FIELD_BOOLEAN: v->data.boolean = val != 0; break;
            case COLYSEUS_FIELD_FLOAT32: v->data.f32 = (float)val; break;
            case COLYSEUS_FIELD_INT8:    v->data.i8 = (int8_t)val; break;
            case COLYSEUS_FIELD_UINT8:   v->data.u8 = (uint8_t)val; break;
            case COLYSEUS_FIELD_INT16:   v->data.i16 = (int16_t)val; break;
            case COLYSEUS_FIELD_UINT16:  v->data.u16 = (uint16_t)val; break;
            case COLYSEUS_FIELD_INT32:   v->data.i32 = (int32_t)val; break;
            case COLYSEUS_FIELD_UINT32:  v->data.u32 = (uint32_t)val; break;
            case COLYSEUS_FIELD_INT64:   v->data.i64 = (int64_t)val; break;
            case COLYSEUS_FIELD_UINT64:  v->data.u64 = (uint64_t)val; break;
            default:                     v->data.num = val; break;
        }
        return;
    }
    void* p = (char*)inst + offset;
    switch (type) {
        case COLYSEUS_FIELD_BOOLEAN: *(bool*)p = val != 0; break;
        case COLYSEUS_FIELD_FLOAT32: *(float*)p = (float)val; break;
        case COLYSEUS_FIELD_INT8:    *(int8_t*)p = (int8_t)val; break;
        case COLYSEUS_FIELD_UINT8:   *(uint8_t*)p = (uint8_t)val; break;
        case COLYSEUS_FIELD_INT16:   *(int16_t*)p = (int16_t)val; break;
        case COLYSEUS_FIELD_UINT16:  *(uint16_t*)p = (uint16_t)val; break;
        case COLYSEUS_FIELD_INT32:   *(int32_t*)p = (int32_t)val; break;
        case COLYSEUS_FIELD_UINT32:  *(uint32_t*)p = (uint32_t)val; break;
        case COLYSEUS_FIELD_INT64:   *(int64_t*)p = (int64_t)val; break;
        case COLYSEUS_FIELD_UINT64:  *(uint64_t*)p = (uint64_t)val; break;
        default:                     *(double*)p = val; break;
    }
}

static inline double predict_fread(const colyseus_schema_t* inst, const predict_fref_t* f) {
    return predict_scalar_read(inst, f->type, f->offset, f->index);
}

static inline void predict_fwrite(colyseus_schema_t* inst, const predict_fref_t* f, double val) {
    predict_scalar_write(inst, f->type, f->offset, f->index, f->name, val);
}

/*
 * Mirror/scratch construction. Static vtables construct normally; dynamic
 * ones construct BARE — no platform userdata shadow, so replay writes never
 * touch the host engine. NULL when the vtable can't construct.
 */
static inline colyseus_schema_t* predict_instance_create(const colyseus_schema_vtable_t* vt) {
    const colyseus_dynamic_vtable_t* dv = colyseus_vtable_as_dynamic(vt);
    if (dv) return (colyseus_schema_t*)colyseus_dynamic_schema_create_bare(dv);
    return vt->create ? vt->create() : NULL;
}

#endif /* COLYSEUS_PREDICT_FIELD_ACCESS_H */
