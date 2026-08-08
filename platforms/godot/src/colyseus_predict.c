#include "colyseus_predict.h"

#include <colyseus/room.h>
#include <colyseus/schema.h>
#include <colyseus/schema/decoder.h>
#include <colyseus/schema/ref_tracker.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* ── local variant helpers (mirror colyseus_callbacks.c's) ───────────── */

static char* pv_string_to_c_str(GDExtensionConstVariantPtr var) {
    String str;
    constructors.string_from_variant_constructor(&str, (GDExtensionVariantPtr)var);
    int32_t length = api.string_to_utf8_chars(&str, NULL, 0);
    char* buffer = (char*)malloc((size_t)(length > 0 ? length : 0) + 1);
    if (!buffer) { destructors.string_destructor(&str); return NULL; }
    if (length > 0) api.string_to_utf8_chars(&str, buffer, length);
    buffer[length > 0 ? length : 0] = '\0';
    destructors.string_destructor(&str);
    return buffer;
}

static double pv_to_double(GDExtensionConstVariantPtr var) {
    GDExtensionVariantType t = api.variant_get_type(var);
    if (t == GDEXTENSION_VARIANT_TYPE_INT) {
        int64_t v = 0;
        constructors.int_from_variant_constructor(&v, (GDExtensionVariantPtr)var);
        return (double)v;
    }
    double v = 0;
    constructors.float_from_variant_constructor(&v, (GDExtensionVariantPtr)var);
    return v;
}

static bool pv_to_bool(GDExtensionConstVariantPtr var) {
    GDExtensionBool v = 0;
    constructors.bool_from_variant_constructor(&v, (GDExtensionVariantPtr)var);
    return v != 0;
}

/* Object OR Dictionary target — both answer get("__ref_id"). */
static int pv_ref_id(GDExtensionConstVariantPtr target) {
    StringName get_method;
    constructors.string_name_new_with_latin1_chars(&get_method, "get", false);

    String prop_str;
    constructors.string_new_with_utf8_chars(&prop_str, "__ref_id");
    Variant prop_var;
    constructors.variant_from_string_constructor(&prop_var, &prop_str);

    GDExtensionConstVariantPtr args[1] = { &prop_var };
    Variant result;
    GDExtensionCallError error;
    api.variant_call((GDExtensionVariantPtr)target, &get_method, args, 1, &result, &error);

    destructors.string_name_destructor(&get_method);
    destructors.variant_destroy(&prop_var);
    destructors.string_destructor(&prop_str);

    int ref_id = -1;
    if (error.error == GDEXTENSION_CALL_OK) {
        int64_t v = 0;
        constructors.int_from_variant_constructor(&v, &result);
        ref_id = (int)v;
    }
    destructors.variant_destroy(&result);
    return ref_id;
}

/* Resolve a GDScript-side schema reference to the decoded C instance.
 * Exported — the reconciler binding resolves its truth instance through it. */
colyseus_schema_t* gdext_colyseus_predict_resolve_instance(ColyseusPredictWrapper* w, GDExtensionConstVariantPtr target) {
    if (!w || !w->room || !w->room->native_room) return NULL;
    colyseus_room_t* room = w->room->native_room;
    if (!room->serializer || !room->serializer->decoder || !room->serializer->decoder->refs) return NULL;
    int ref_id = pv_ref_id(target);
    if (ref_id < 0) return NULL;
    return (colyseus_schema_t*)colyseus_ref_tracker_get(room->serializer->decoder->refs, ref_id);
}

/* args[mode..angle] -> field options. 0 keeps the reference defaults. */
static colyseus_predict_field_options_t pv_field_options(
    const GDExtensionConstVariantPtr* p_args, int first) {
    colyseus_predict_field_options_t opts = {0};
    opts.mode = (colyseus_predict_mode_t)(int64_t)pv_to_double(p_args[first]);
    opts.delay = pv_to_double(p_args[first + 1]);
    opts.damping = pv_to_double(p_args[first + 2]);
    opts.max_extrapolate = pv_to_double(p_args[first + 3]);
    opts.snap = pv_to_double(p_args[first + 4]);
    opts.angle = pv_to_bool(p_args[first + 5]);
    return opts;
}

static void pv_return_float(GDExtensionVariantPtr r_return, double v) {
    if (r_return) constructors.variant_from_float_constructor(r_return, &v);
}

/* ── class lifecycle ─────────────────────────────────────────────────── */

static ColyseusPredictWrapper* g_last_predict_wrapper = NULL;

GDExtensionObjectPtr gdext_colyseus_predict_constructor(void* p_class_userdata) {
    (void)p_class_userdata;
    StringName parent_class_name;
    constructors.string_name_new_with_latin1_chars(&parent_class_name, "RefCounted", false);
    GDExtensionObjectPtr object = api.classdb_construct_object(&parent_class_name);
    destructors.string_name_destructor(&parent_class_name);
    if (!object) return NULL;

    ColyseusPredictWrapper* wrapper = malloc(sizeof(ColyseusPredictWrapper));
    if (!wrapper) return NULL;
    wrapper->native = NULL;
    wrapper->room = NULL;
    wrapper->reckon_ctxs = NULL;
    wrapper->godot_object = object;

    StringName class_name;
    constructors.string_name_new_with_latin1_chars(&class_name, "_ColyseusPredict", false);
    api.object_set_instance(object, &class_name, wrapper);
    destructors.string_name_destructor(&class_name);

    g_last_predict_wrapper = wrapper;
    return object;
}

void gdext_colyseus_predict_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    ColyseusPredictWrapper* wrapper = (ColyseusPredictWrapper*)p_instance;
    if (wrapper) {
        if (wrapper->native) colyseus_predict_free(wrapper->native);
        gdext_colyseus_predict_free_reckon_ctxs(wrapper);
        free(wrapper);
    }
}

/* ── _ColyseusRoom.predict() ─────────────────────────────────────────── */

void gdext_colyseus_room_predict_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_args;
    ColyseusRoomWrapper* rw = (ColyseusRoomWrapper*)p_instance;
    *(GDExtensionObjectPtr*)r_ret = NULL;
    if (!rw || !rw->native_room) return;

    colyseus_predict_t* native = colyseus_predict_for_room(rw->native_room);
    if (!native) return;

    GDExtensionObjectPtr object = gdext_colyseus_predict_constructor(NULL);
    if (!object || !g_last_predict_wrapper) {
        colyseus_predict_free(native);
        return;
    }
    g_last_predict_wrapper->native = native;
    g_last_predict_wrapper->room = rw;
    *(GDExtensionObjectPtr*)r_ret = object;
}

/* ── methods ─────────────────────────────────────────────────────────── */

void gdext_colyseus_predict_tick(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    ColyseusPredictWrapper* w = (ColyseusPredictWrapper*)p_instance;
    double now = *(const double*)p_args[0];
    *(int64_t*)r_ret = w && w->native ? colyseus_predict_tick(w->native, now) : 0;
}

void gdext_colyseus_predict_attach_field(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata; (void)r_return;
    if (p_argument_count < 8) {
        if (r_error) { r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; r_error->argument = 8; }
        return;
    }
    ColyseusPredictWrapper* w = (ColyseusPredictWrapper*)p_instance;
    if (!w || !w->native) return;

    colyseus_schema_t* instance = gdext_colyseus_predict_resolve_instance(w, p_args[0]);
    char* field = pv_string_to_c_str(p_args[1]);
    if (instance && field) {
        colyseus_predict_field_options_t opts = pv_field_options(p_args, 2);
        colyseus_attach_field_t cfg = { field, &opts };
        colyseus_predict_attach(w->native, instance, &cfg, 1);
    }
    free(field);
}

void gdext_colyseus_predict_attach_all_field(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata; (void)r_return;
    if (p_argument_count < 9) {
        if (r_error) { r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; r_error->argument = 9; }
        return;
    }
    ColyseusPredictWrapper* w = (ColyseusPredictWrapper*)p_instance;
    if (!w || !w->native || !w->room || !w->room->native_room) return;
    colyseus_schema_t* state = colyseus_room_get_state(w->room->native_room);
    if (!state) return;

    char* collection = pv_string_to_c_str(p_args[0]);
    char* field = pv_string_to_c_str(p_args[1]);
    char* except_key = pv_string_to_c_str(p_args[8]);
    if (collection && field) {
        colyseus_predict_field_options_t opts = pv_field_options(p_args, 2);
        colyseus_attach_field_t cfg = { field, &opts };
        colyseus_predict_attach_all(w->native, state, collection, &cfg, 1,
            except_key && except_key[0] ? except_key : NULL, NULL);
    }
    free(collection);
    free(field);
    free(except_key);
}

void gdext_colyseus_predict_detach(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata; (void)r_return;
    if (p_argument_count < 1) {
        if (r_error) { r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; r_error->argument = 1; }
        return;
    }
    ColyseusPredictWrapper* w = (ColyseusPredictWrapper*)p_instance;
    if (!w || !w->native) return;
    colyseus_schema_t* instance = gdext_colyseus_predict_resolve_instance(w, p_args[0]);
    if (instance) colyseus_predict_detach(w->native, instance);
}

void gdext_colyseus_predict_value(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata;
    pv_return_float(r_return, NAN);
    if (p_argument_count < 2) {
        if (r_error) { r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; r_error->argument = 2; }
        return;
    }
    ColyseusPredictWrapper* w = (ColyseusPredictWrapper*)p_instance;
    if (!w || !w->native) return;
    colyseus_schema_t* instance = gdext_colyseus_predict_resolve_instance(w, p_args[0]);
    if (!instance) return;
    char* field = pv_string_to_c_str(p_args[1]);
    if (!field) return;
    pv_return_float(r_return, colyseus_predict_value(w->native, instance, field));
    free(field);
}

void gdext_colyseus_predict_value_at(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata;
    pv_return_float(r_return, NAN);
    if (p_argument_count < 3) {
        if (r_error) { r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; r_error->argument = 3; }
        return;
    }
    ColyseusPredictWrapper* w = (ColyseusPredictWrapper*)p_instance;
    if (!w || !w->native) return;
    colyseus_schema_t* instance = gdext_colyseus_predict_resolve_instance(w, p_args[0]);
    if (!instance) return;
    char* field = pv_string_to_c_str(p_args[1]);
    if (!field) return;
    double time = pv_to_double(p_args[2]);
    pv_return_float(r_return, colyseus_predict_value_at(w->native, instance, field, time));
    free(field);
}
