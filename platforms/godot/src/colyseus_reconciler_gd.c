#include "colyseus_reconciler_gd.h"
#include "colyseus_predict.h"
#include "colyseus_input.h"

#include <colyseus/room.h>
#include <predict/field_access.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* ── shared helpers ──────────────────────────────────────────────────── */

static char* rc_string_to_c_str(GDExtensionConstVariantPtr var) {
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

static char* rc_string_name_to_c_str(GDExtensionConstStringNamePtr name) {
    String str;
    constructors.string_from_string_name_constructor(&str, (GDExtensionConstTypePtr[]){ name });
    int32_t length = api.string_to_utf8_chars(&str, NULL, 0);
    char* buffer = (char*)malloc((size_t)(length > 0 ? length : 0) + 1);
    if (!buffer) { destructors.string_destructor(&str); return NULL; }
    if (length > 0) api.string_to_utf8_chars(&str, buffer, length);
    buffer[length > 0 ? length : 0] = '\0';
    destructors.string_destructor(&str);
    return buffer;
}

static double rc_to_double(GDExtensionConstVariantPtr var) {
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

static GDExtensionObjectPtr rc_construct(const char* class_name_str, void* wrapper) {
    StringName parent;
    constructors.string_name_new_with_latin1_chars(&parent, "RefCounted", false);
    GDExtensionObjectPtr object = api.classdb_construct_object(&parent);
    destructors.string_name_destructor(&parent);
    if (!object) return NULL;
    StringName class_name;
    constructors.string_name_new_with_latin1_chars(&class_name, class_name_str, false);
    api.object_set_instance(object, &class_name, wrapper);
    destructors.string_name_destructor(&class_name);
    return object;
}

/* ── _ColyseusSimState ───────────────────────────────────────────────── */

static ColyseusSimStateWrapper* g_last_sim_state = NULL;

GDExtensionObjectPtr gdext_colyseus_sim_state_constructor(void* p_class_userdata) {
    (void)p_class_userdata;
    ColyseusSimStateWrapper* w = calloc(1, sizeof(ColyseusSimStateWrapper));
    if (!w) return NULL;
    w->godot_object = rc_construct("_ColyseusSimState", w);
    if (!w->godot_object) { free(w); return NULL; }
    g_last_sim_state = w;
    return w->godot_object;
}

void gdext_colyseus_sim_state_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    free((ColyseusSimStateWrapper*)p_instance);
}

ColyseusSimStateWrapper* gdext_colyseus_sim_state_last_wrapper(void) { return g_last_sim_state; }

GDExtensionBool gdext_colyseus_sim_state_set(GDExtensionClassInstancePtr p_instance, GDExtensionConstStringNamePtr p_name, GDExtensionConstVariantPtr p_value) {
    ColyseusSimStateWrapper* w = (ColyseusSimStateWrapper*)p_instance;
    if (!w || !w->target || !w->target->__vtable) return false;
    char* name = rc_string_name_to_c_str(p_name);
    if (!name) return false;
    predict_fref_t f;
    bool ok = predict_vt_find(w->target->__vtable, name, &f) && predict_fref_scalar(&f);
    if (ok) predict_fwrite(w->target, &f, rc_to_double(p_value));
    free(name);
    return ok;
}

GDExtensionBool gdext_colyseus_sim_state_get(GDExtensionClassInstancePtr p_instance, GDExtensionConstStringNamePtr p_name, GDExtensionVariantPtr r_ret) {
    ColyseusSimStateWrapper* w = (ColyseusSimStateWrapper*)p_instance;
    if (!w || !w->target || !w->target->__vtable) return false;
    char* name = rc_string_name_to_c_str(p_name);
    if (!name) return false;
    predict_fref_t f;
    bool ok = predict_vt_find(w->target->__vtable, name, &f);
    if (ok && predict_fref_scalar(&f)) {
        double v = predict_fread(w->target, &f);
        constructors.variant_from_float_constructor(r_ret, &v);
    } else if (ok && f.type == COLYSEUS_FIELD_STRING) {
        /* string fields read-only (owner ids etc.) */
        const char* sv = NULL;
        if (colyseus_vtable_is_dynamic(w->target->__vtable)) {
            colyseus_dynamic_value_t* dv =
                colyseus_dynamic_schema_get((colyseus_dynamic_schema_t*)w->target, f.index);
            sv = dv ? dv->data.str : NULL;
        } else {
            sv = *(const char* const*)((const char*)w->target + f.offset);
        }
        String str;
        constructors.string_new_with_utf8_chars(&str, sv ? sv : "");
        constructors.variant_from_string_constructor(r_ret, &str);
        destructors.string_destructor(&str);
    } else {
        ok = false;
    }
    free(name);
    return ok;
}

/* ── _ColyseusStepContext ────────────────────────────────────────────── */

static ColyseusStepCtxWrapper* g_last_step_ctx = NULL;

GDExtensionObjectPtr gdext_colyseus_step_ctx_constructor(void* p_class_userdata) {
    (void)p_class_userdata;
    ColyseusStepCtxWrapper* w = calloc(1, sizeof(ColyseusStepCtxWrapper));
    if (!w) return NULL;
    w->godot_object = rc_construct("_ColyseusStepContext", w);
    if (!w->godot_object) { free(w); return NULL; }
    g_last_step_ctx = w;
    return w->godot_object;
}

void gdext_colyseus_step_ctx_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    free((ColyseusStepCtxWrapper*)p_instance);
}

ColyseusStepCtxWrapper* gdext_colyseus_step_ctx_last_wrapper(void) { return g_last_step_ctx; }

GDExtensionBool gdext_colyseus_step_ctx_get(GDExtensionClassInstancePtr p_instance, GDExtensionConstStringNamePtr p_name, GDExtensionVariantPtr r_ret) {
    ColyseusStepCtxWrapper* w = (ColyseusStepCtxWrapper*)p_instance;
    if (!w || !w->ctx) return false;
    char* name = rc_string_name_to_c_str(p_name);
    if (!name) return false;

    bool ok = true;
    double fv = 0;
    if (strcmp(name, "dt") == 0) fv = w->ctx->dt;
    else if (strcmp(name, "dt_ms") == 0) fv = w->ctx->dt_ms;
    else if (strcmp(name, "sub_dt") == 0) fv = w->ctx->sub_dt;
    else if (strcmp(name, "sub_dt_ms") == 0) fv = w->ctx->sub_dt_ms;
    else if (strcmp(name, "reckon_time") == 0) fv = w->ctx->reckon_time;
    else if (strcmp(name, "tick") == 0) {
        int64_t iv = w->ctx->tick;
        constructors.variant_from_int_constructor(r_ret, &iv);
        free(name);
        return true;
    }
    else if (strcmp(name, "sub_steps") == 0) {
        int64_t iv = w->ctx->sub_steps;
        constructors.variant_from_int_constructor(r_ret, &iv);
        free(name);
        return true;
    }
    else if (strcmp(name, "is_replay") == 0) {
        GDExtensionBool bv = w->ctx->is_replay ? 1 : 0;
        constructors.variant_from_bool_constructor(r_ret, &bv);
        free(name);
        return true;
    }
    else if (strcmp(name, "lag_comp_active") == 0) {
        GDExtensionBool bv = w->ctx->lag_comp_active ? 1 : 0;
        constructors.variant_from_bool_constructor(r_ret, &bv);
        free(name);
        return true;
    }
    else ok = false;

    if (ok) constructors.variant_from_float_constructor(r_ret, &fv);
    free(name);
    return ok;
}

/* ── _ColyseusReconciler ─────────────────────────────────────────────── */

static ColyseusReconcilerWrapper* g_last_recon = NULL;

GDExtensionObjectPtr gdext_colyseus_reconciler_constructor(void* p_class_userdata) {
    (void)p_class_userdata;
    ColyseusReconcilerWrapper* w = calloc(1, sizeof(ColyseusReconcilerWrapper));
    if (!w) return NULL;
    w->godot_object = rc_construct("_ColyseusReconciler", w);
    if (!w->godot_object) { free(w); return NULL; }
    g_last_recon = w;
    return w->godot_object;
}

void gdext_colyseus_reconciler_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    ColyseusReconcilerWrapper* w = (ColyseusReconcilerWrapper*)p_instance;
    if (!w) return;
    if (w->native) colyseus_reconciler_free(w->native);
    destructors.variant_destroy(&w->step_callable);
    destructors.variant_destroy(&w->ctx_var);
    destructors.variant_destroy(&w->state_var);
    destructors.variant_destroy(&w->cmd_var);
    destructors.variant_destroy(&w->world_var);
    destructors.variant_destroy(&w->predict_ref);
    free(w);
}

/* ── _ColyseusSimWorld ───────────────────────────────────────────────── */

static ColyseusSimWorldWrapper* g_last_sim_world = NULL;

GDExtensionObjectPtr gdext_colyseus_sim_world_constructor(void* p_class_userdata) {
    (void)p_class_userdata;
    ColyseusSimWorldWrapper* w = calloc(1, sizeof(ColyseusSimWorldWrapper));
    if (!w) return NULL;
    w->godot_object = rc_construct("_ColyseusSimWorld", w);
    if (!w->godot_object) { free(w); return NULL; }
    g_last_sim_world = w;
    return w->godot_object;
}

void gdext_colyseus_sim_world_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    ColyseusSimWorldWrapper* w = (ColyseusSimWorldWrapper*)p_instance;
    if (!w) return;
    for (int i = 0; i < w->part_count; i++) {
        free(w->names[i]);
        destructors.variant_destroy(&w->part_vars[i]);
    }
    free(w);
}

GDExtensionBool gdext_colyseus_sim_world_get(GDExtensionClassInstancePtr p_instance, GDExtensionConstStringNamePtr p_name, GDExtensionVariantPtr r_ret) {
    ColyseusSimWorldWrapper* w = (ColyseusSimWorldWrapper*)p_instance;
    if (!w) return false;
    char* name = rc_string_name_to_c_str(p_name);
    if (!name) return false;
    for (int i = 0; i < w->part_count; i++) {
        if (strcmp(w->names[i], name) == 0) {
            api.variant_new_copy(r_ret, &w->part_vars[i]);
            free(name);
            return true;
        }
    }
    free(name);
    return false;
}

/* The step, SHARED with the server, written in GDScript: retarget the three
 * views and invoke the Callable. No allocation on this path beyond what the
 * engine does for the call itself. */
static void recon_step_trampoline(const colyseus_step_ctx_t* ctx, colyseus_schema_t* state,
    const colyseus_schema_t* command, void* userdata) {
    ColyseusReconcilerWrapper* w = (ColyseusReconcilerWrapper*)userdata;
    w->ctx_w->ctx = ctx;
    w->state_w->target = state;
    w->cmd_w->target = (colyseus_schema_t*)command;

    static StringName call_sn;
    static bool call_sn_ready = false;
    if (!call_sn_ready) {
        constructors.string_name_new_with_latin1_chars(&call_sn, "call", false);
        call_sn_ready = true;
    }

    GDExtensionConstVariantPtr args[3] = { &w->ctx_var, &w->state_var, &w->cmd_var };
    Variant ret;
    GDExtensionCallError err;
    api.variant_call(&w->step_callable, &call_sn, args, 3, &ret, &err);
    destructors.variant_destroy(&ret);
}

/* _ColyseusPredict.reconciler(target, input_handle, fields, smooth_ms, snap, step) */
void gdext_colyseus_predict_reconciler_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata;
    if (r_return) gdext_variant_new_nil((Variant*)r_return);
    if (p_argument_count < 6) {
        if (r_error) { r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; r_error->argument = 6; }
        return;
    }
    ColyseusPredictWrapper* pw = (ColyseusPredictWrapper*)p_instance;
    if (!pw || !pw->native) return;

    colyseus_schema_t* truth = gdext_colyseus_predict_resolve_instance(pw, p_args[0]);
    if (!truth || !truth->__vtable) return;

    /* input handle object -> its wrapper (registry by godot object) */
    GDExtensionObjectPtr input_obj = NULL;
    constructors.object_from_variant_constructor(&input_obj, (GDExtensionVariantPtr)p_args[1]);
    ColyseusInputHandleWrapper* input_w = gdext_colyseus_input_wrapper_for_object(input_obj);
    if (!input_w || !input_w->native) return;

    /* fields: Array of String */
    int64_t field_count = 0;
    {
        StringName size_sn;
        constructors.string_name_new_with_latin1_chars(&size_sn, "size", false);
        Variant size_ret;
        GDExtensionCallError err;
        api.variant_call((GDExtensionVariantPtr)p_args[2], &size_sn, NULL, 0, &size_ret, &err);
        destructors.string_name_destructor(&size_sn);
        if (err.error == GDEXTENSION_CALL_OK) constructors.int_from_variant_constructor(&field_count, &size_ret);
        destructors.variant_destroy(&size_ret);
    }
    if (field_count <= 0 || field_count > 64) return;

    Array fields_arr;
    constructors.array_from_variant_constructor(&fields_arr, (GDExtensionVariantPtr)p_args[2]);
    char** fields = calloc((size_t)field_count, sizeof(char*));
    for (int64_t i = 0; i < field_count; i++) {
        GDExtensionVariantPtr element = api.array_operator_index(&fields_arr, i);
        fields[i] = rc_string_to_c_str(element);
    }
    destructors.array_destructor(&fields_arr);

    double smooth_ms = rc_to_double(p_args[3]);
    double snap = rc_to_double(p_args[4]);

    /* the reconciler object + its three view objects */
    GDExtensionObjectPtr recon_obj = gdext_colyseus_reconciler_constructor(NULL);
    ColyseusReconcilerWrapper* w = g_last_recon;
    if (!recon_obj || !w) goto cleanup_fields;

    {
        GDExtensionObjectPtr ctx_obj = gdext_colyseus_step_ctx_constructor(NULL);
        w->ctx_w = gdext_colyseus_step_ctx_last_wrapper();
        GDExtensionObjectPtr state_obj = gdext_colyseus_sim_state_constructor(NULL);
        w->state_w = gdext_colyseus_sim_state_last_wrapper();
        GDExtensionObjectPtr cmd_obj = gdext_colyseus_sim_state_constructor(NULL);
        w->cmd_w = gdext_colyseus_sim_state_last_wrapper();
        if (!ctx_obj || !state_obj || !cmd_obj) goto cleanup_fields;

        constructors.variant_from_object_constructor(&w->ctx_var, &ctx_obj);
        constructors.variant_from_object_constructor(&w->state_var, &state_obj);
        constructors.variant_from_object_constructor(&w->cmd_var, &cmd_obj);
    }
    api.variant_new_copy(&w->step_callable, p_args[5]);
    constructors.variant_from_object_constructor(&w->predict_ref, &pw->godot_object);

    {
        colyseus_reconciler_options_t opts = {0};
        opts.smooth_ms = smooth_ms;
        opts.snap = snap;
        opts.fields = (const char* const*)fields;
        opts.field_count = (int)field_count;
        opts.userdata = w;
        w->native = colyseus_predict_reconciler(pw->native, truth, truth->__vtable,
            input_w->native, recon_step_trampoline, &opts);
    }
    if (!w->native) goto cleanup_fields;   /* wrapper freed by refcount later */

    if (r_return) constructors.variant_from_object_constructor(r_return, &recon_obj);

cleanup_fields:
    for (int64_t i = 0; i < field_count; i++) free(fields[i]);
    free(fields);
}

/* The composite step: world views target stable mirrors, so only ctx and the
 * command need retargeting before the Callable fires. */
static void sim_step_trampoline(const colyseus_step_ctx_t* ctx, colyseus_sim_world_t* world,
    const colyseus_schema_t* command, void* userdata) {
    (void)world;
    ColyseusReconcilerWrapper* w = (ColyseusReconcilerWrapper*)userdata;
    w->ctx_w->ctx = ctx;
    w->cmd_w->target = (colyseus_schema_t*)command;

    static StringName call_sn;
    static bool call_sn_ready = false;
    if (!call_sn_ready) {
        constructors.string_name_new_with_latin1_chars(&call_sn, "call", false);
        call_sn_ready = true;
    }

    GDExtensionConstVariantPtr args[3] = { &w->ctx_var, &w->world_var, &w->cmd_var };
    Variant ret;
    GDExtensionCallError err;
    api.variant_call(&w->step_callable, &call_sn, args, 3, &ret, &err);
    destructors.variant_destroy(&ret);
}

/* _ColyseusPredict.sim(world_dict, input_handle, smooth_ms, snap, step) */
void gdext_colyseus_predict_sim_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata;
    if (r_return) gdext_variant_new_nil((Variant*)r_return);
    if (p_argument_count < 5) {
        if (r_error) { r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; r_error->argument = 5; }
        return;
    }
    ColyseusPredictWrapper* pw = (ColyseusPredictWrapper*)p_instance;
    if (!pw || !pw->native) return;

    GDExtensionObjectPtr input_obj = NULL;
    constructors.object_from_variant_constructor(&input_obj, (GDExtensionVariantPtr)p_args[1]);
    ColyseusInputHandleWrapper* input_w = gdext_colyseus_input_wrapper_for_object(input_obj);
    if (!input_w || !input_w->native) return;

    static StringName keys_sn, size_sn, get_sn;
    static bool sns_ready = false;
    if (!sns_ready) {
        constructors.string_name_new_with_latin1_chars(&keys_sn, "keys", false);
        constructors.string_name_new_with_latin1_chars(&size_sn, "size", false);
        constructors.string_name_new_with_latin1_chars(&get_sn, "get", false);
        sns_ready = true;
    }

    /* world dict -> named bound parts */
    GDExtensionCallError err;
    Variant keys_var;
    api.variant_call((GDExtensionVariantPtr)p_args[0], &keys_sn, NULL, 0, &keys_var, &err);
    if (err.error != GDEXTENSION_CALL_OK) { destructors.variant_destroy(&keys_var); return; }

    int64_t part_count = 0;
    {
        Variant size_ret;
        api.variant_call(&keys_var, &size_sn, NULL, 0, &size_ret, &err);
        if (err.error == GDEXTENSION_CALL_OK) constructors.int_from_variant_constructor(&part_count, &size_ret);
        destructors.variant_destroy(&size_ret);
    }
    if (part_count <= 0 || part_count > COLYSEUS_GD_MAX_PARTS) {
        destructors.variant_destroy(&keys_var);
        return;
    }

    Array keys_arr;
    constructors.array_from_variant_constructor(&keys_arr, &keys_var);

    char* names[COLYSEUS_GD_MAX_PARTS] = {0};
    colyseus_sim_part_t parts[COLYSEUS_GD_MAX_PARTS];
    bool parts_ok = true;
    for (int64_t i = 0; i < part_count; i++) {
        GDExtensionVariantPtr key_var = api.array_operator_index(&keys_arr, i);
        names[i] = rc_string_to_c_str(key_var);
        Variant inst_var;
        GDExtensionConstVariantPtr get_args[1] = { key_var };
        api.variant_call((GDExtensionVariantPtr)p_args[0], &get_sn, get_args, 1, &inst_var, &err);
        colyseus_schema_t* source =
            err.error == GDEXTENSION_CALL_OK
                ? gdext_colyseus_predict_resolve_instance(pw, &inst_var)
                : NULL;
        destructors.variant_destroy(&inst_var);
        if (!names[i] || !source || !source->__vtable) { parts_ok = false; }
        parts[i] = (colyseus_sim_part_t){
            .name = names[i],
            .source = source,
            .vtable = source ? source->__vtable : NULL,
            .opaque = NULL,
        };
    }
    destructors.array_destructor(&keys_arr);
    destructors.variant_destroy(&keys_var);
    if (!parts_ok) goto cleanup_names;

    {
        GDExtensionObjectPtr recon_obj = gdext_colyseus_reconciler_constructor(NULL);
        ColyseusReconcilerWrapper* w = g_last_recon;
        if (!recon_obj || !w) goto cleanup_names;

        GDExtensionObjectPtr ctx_obj = gdext_colyseus_step_ctx_constructor(NULL);
        w->ctx_w = gdext_colyseus_step_ctx_last_wrapper();
        GDExtensionObjectPtr cmd_obj = gdext_colyseus_sim_state_constructor(NULL);
        w->cmd_w = gdext_colyseus_sim_state_last_wrapper();
        GDExtensionObjectPtr world_obj = gdext_colyseus_sim_world_constructor(NULL);
        w->world_w = g_last_sim_world;
        if (!ctx_obj || !cmd_obj || !world_obj) goto cleanup_names;

        constructors.variant_from_object_constructor(&w->ctx_var, &ctx_obj);
        constructors.variant_from_object_constructor(&w->cmd_var, &cmd_obj);
        constructors.variant_from_object_constructor(&w->world_var, &world_obj);
        api.variant_new_copy(&w->step_callable, p_args[4]);
        constructors.variant_from_object_constructor(&w->predict_ref, &pw->godot_object);

        colyseus_sim_reconciler_options_t opts = {0};
        opts.parts = parts;
        opts.part_count = (int)part_count;
        opts.smooth_ms = rc_to_double(p_args[2]);
        opts.snap = rc_to_double(p_args[3]);
        opts.userdata = w;
        w->native = colyseus_predict_sim_reconciler(pw->native, input_w->native,
            sim_step_trampoline, &opts);
        if (!w->native) goto cleanup_names;

        /* part views over the stable mirrors */
        colyseus_sim_world_t* world = colyseus_sim_reconciler_world(w->native);
        w->world_w->part_count = (int)part_count;
        for (int64_t i = 0; i < part_count; i++) {
            GDExtensionObjectPtr part_obj = gdext_colyseus_sim_state_constructor(NULL);
            ColyseusSimStateWrapper* part_w = gdext_colyseus_sim_state_last_wrapper();
            if (!part_obj || !part_w) { w->world_w->part_count = (int)i; goto cleanup_names; }
            part_w->target = (colyseus_schema_t*)colyseus_sim_world_part(world, names[i]);
            constructors.variant_from_object_constructor(&w->world_w->part_vars[i], &part_obj);
            w->world_w->names[i] = names[i];   /* ownership moves to the world view */
            names[i] = NULL;
        }

        if (r_return) constructors.variant_from_object_constructor(r_return, &recon_obj);
    }

cleanup_names:
    for (int64_t i = 0; i < part_count; i++) free(names[i]);
}

void gdext_colyseus_recon_world(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_args;
    ColyseusReconcilerWrapper* w = (ColyseusReconcilerWrapper*)p_instance;
    *(GDExtensionObjectPtr*)r_ret = NULL;
    if (w && w->world_w) *(GDExtensionObjectPtr*)r_ret = w->world_w->godot_object;
}

/* ── event channels ──────────────────────────────────────────────────── */

#define MAX_EVENT_CHANNELS 32
static ColyseusEventChannelWrapper* g_event_channels[MAX_EVENT_CHANNELS];
static ColyseusEventChannelWrapper* g_last_event_channel = NULL;

static StringName* rc_call_sn(void) {
    static StringName call_sn;
    static bool ready = false;
    if (!ready) {
        constructors.string_name_new_with_latin1_chars(&call_sn, "call", false);
        ready = true;
    }
    return &call_sn;
}

/* Fire a stored Callable with the event key (payload) as its one argument. */
static void event_fire(Variant* callable, void* payload) {
    if (api.variant_get_type(callable) != GDEXTENSION_VARIANT_TYPE_CALLABLE) return;
    String key_str;
    constructors.string_new_with_utf8_chars(&key_str, payload ? (const char*)payload : "");
    Variant key_var;
    constructors.variant_from_string_constructor(&key_var, &key_str);
    GDExtensionConstVariantPtr args[1] = { &key_var };
    Variant ret;
    GDExtensionCallError err;
    api.variant_call(callable, rc_call_sn(), args, 1, &ret, &err);
    destructors.variant_destroy(&ret);
    destructors.variant_destroy(&key_var);
    destructors.string_destructor(&key_str);
}

static void event_on_predict(void* payload, void* userdata) {
    event_fire(&((ColyseusEventChannelWrapper*)userdata)->on_predict, payload);
}
static void event_on_confirm(void* payload, void* userdata) {
    event_fire(&((ColyseusEventChannelWrapper*)userdata)->on_confirm, payload);
}
static void event_on_reject(void* payload, void* userdata) {
    event_fire(&((ColyseusEventChannelWrapper*)userdata)->on_reject, payload);
}

GDExtensionObjectPtr gdext_colyseus_event_channel_constructor(void* p_class_userdata) {
    (void)p_class_userdata;
    ColyseusEventChannelWrapper* w = calloc(1, sizeof(ColyseusEventChannelWrapper));
    if (!w) return NULL;
    w->godot_object = rc_construct("_ColyseusEventChannel", w);
    if (!w->godot_object) { free(w); return NULL; }
    for (int i = 0; i < MAX_EVENT_CHANNELS; i++) {
        if (!g_event_channels[i]) { g_event_channels[i] = w; break; }
    }
    g_last_event_channel = w;
    return w->godot_object;
}

void gdext_colyseus_event_channel_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    ColyseusEventChannelWrapper* w = (ColyseusEventChannelWrapper*)p_instance;
    if (!w) return;
    for (int i = 0; i < MAX_EVENT_CHANNELS; i++) {
        if (g_event_channels[i] == w) g_event_channels[i] = NULL;
    }
    if (w->native) colyseus_event_channel_free(w->native);
    destructors.variant_destroy(&w->on_predict);
    destructors.variant_destroy(&w->on_confirm);
    destructors.variant_destroy(&w->on_reject);
    destructors.variant_destroy(&w->predict_ref);
    free(w);
}

/* Accept either the raw _ColyseusEventChannel or a GDScript wrapper exposing
 * `_native` — resolved through the registry either way. */
static ColyseusEventChannelWrapper* event_channel_from_variant(GDExtensionConstVariantPtr var) {
    GDExtensionObjectPtr obj = NULL;
    constructors.object_from_variant_constructor(&obj, (GDExtensionVariantPtr)var);
    for (int i = 0; i < MAX_EVENT_CHANNELS; i++) {
        if (g_event_channels[i] && g_event_channels[i]->godot_object == obj) return g_event_channels[i];
    }
    /* try wrapper._native */
    static StringName get_sn;
    static bool get_ready = false;
    if (!get_ready) {
        constructors.string_name_new_with_latin1_chars(&get_sn, "get", false);
        get_ready = true;
    }
    String prop_str;
    constructors.string_new_with_utf8_chars(&prop_str, "_native");
    Variant prop_var;
    constructors.variant_from_string_constructor(&prop_var, &prop_str);
    GDExtensionConstVariantPtr args[1] = { &prop_var };
    Variant inner;
    GDExtensionCallError err;
    api.variant_call((GDExtensionVariantPtr)var, &get_sn, args, 1, &inner, &err);
    ColyseusEventChannelWrapper* found = NULL;
    if (err.error == GDEXTENSION_CALL_OK) {
        GDExtensionObjectPtr inner_obj = NULL;
        constructors.object_from_variant_constructor(&inner_obj, &inner);
        for (int i = 0; i < MAX_EVENT_CHANNELS; i++) {
            if (g_event_channels[i] && g_event_channels[i]->godot_object == inner_obj) {
                found = g_event_channels[i];
                break;
            }
        }
    }
    destructors.variant_destroy(&inner);
    destructors.variant_destroy(&prop_var);
    destructors.string_destructor(&prop_str);
    return found;
}

void gdext_colyseus_predict_define_event_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata;
    if (r_return) gdext_variant_new_nil((Variant*)r_return);
    if (p_argument_count < 6) {
        if (r_error) { r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; r_error->argument = 6; }
        return;
    }
    ColyseusPredictWrapper* pw = (ColyseusPredictWrapper*)p_instance;
    if (!pw || !pw->native) return;

    GDExtensionObjectPtr obj = gdext_colyseus_event_channel_constructor(NULL);
    ColyseusEventChannelWrapper* w = g_last_event_channel;
    if (!obj || !w) return;

    api.variant_new_copy(&w->on_predict, p_args[0]);
    api.variant_new_copy(&w->on_confirm, p_args[1]);
    api.variant_new_copy(&w->on_reject, p_args[2]);
    constructors.variant_from_object_constructor(&w->predict_ref, &pw->godot_object);

    colyseus_event_channel_options_t opts = {0};
    opts.on_predict = event_on_predict;
    opts.on_confirm = event_on_confirm;
    opts.on_reject = event_on_reject;
    opts.payload_free = free;
    opts.grace_ticks = (int)rc_to_double(p_args[3]);
    opts.ttl_ms = rc_to_double(p_args[4]);
    opts.cooldown_ms = rc_to_double(p_args[5]);
    opts.userdata = w;

    colyseus_room_clock_t* clock = pw->room && pw->room->native_room
        ? colyseus_room_get_clock(pw->room->native_room) : NULL;
    w->native = colyseus_event_channel_create(&opts, clock);
    if (!w->native) return;
    colyseus_predict_drive_events(pw->native, w->native);

    if (r_return) constructors.variant_from_object_constructor(r_return, &obj);
}

static char* rc_string_ptrarg_to_c_str(const GDExtensionConstTypePtr arg) {
    const String* s = (const String*)arg;
    int32_t length = api.string_to_utf8_chars(s, NULL, 0);
    char* buffer = malloc((size_t)(length > 0 ? length : 0) + 1);
    if (!buffer) return NULL;
    if (length > 0) api.string_to_utf8_chars(s, buffer, length);
    buffer[length > 0 ? length : 0] = '\0';
    return buffer;
}

void gdext_colyseus_event_confirm(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    ColyseusEventChannelWrapper* w = (ColyseusEventChannelWrapper*)p_instance;
    *(int64_t*)r_ret = 0;
    if (!w || !w->native) return;
    char* key = rc_string_ptrarg_to_c_str(p_args[0]);
    *(int64_t*)r_ret = colyseus_event_channel_confirm(w->native, key && key[0] ? key : NULL);
    free(key);
}

void gdext_colyseus_event_reject(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    ColyseusEventChannelWrapper* w = (ColyseusEventChannelWrapper*)p_instance;
    *(int64_t*)r_ret = 0;
    if (!w || !w->native) return;
    char* key = rc_string_ptrarg_to_c_str(p_args[0]);
    *(int64_t*)r_ret = colyseus_event_channel_reject(w->native, key && key[0] ? key : NULL);
    free(key);
}

void gdext_colyseus_event_predict_ui(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    ColyseusEventChannelWrapper* w = (ColyseusEventChannelWrapper*)p_instance;
    *(GDExtensionBool*)r_ret = 0;
    if (!w || !w->native) return;
    char* key = rc_string_ptrarg_to_c_str(p_args[0]);
    if (key) {
        *(GDExtensionBool*)r_ret =
            colyseus_event_channel_predict(w->native, key, strdup(key)) ? 1 : 0;
    }
    free(key);
}

void gdext_colyseus_event_pending_count(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_args;
    ColyseusEventChannelWrapper* w = (ColyseusEventChannelWrapper*)p_instance;
    *(int64_t*)r_ret = w && w->native ? colyseus_event_channel_pending_count(w->native) : 0;
}

void gdext_colyseus_event_clear(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_args; (void)r_ret;
    ColyseusEventChannelWrapper* w = (ColyseusEventChannelWrapper*)p_instance;
    if (w && w->native) colyseus_event_channel_clear(w->native);
}

/* ── step-context memo / predict ─────────────────────────────────────── */

typedef struct { GDExtensionConstVariantPtr callable; } memo_call_t;

static double memo_compute_tramp(void* userdata) {
    memo_call_t* mc = (memo_call_t*)userdata;
    Variant ret;
    GDExtensionCallError err;
    api.variant_call((GDExtensionVariantPtr)mc->callable, rc_call_sn(), NULL, 0, &ret, &err);
    double v = NAN;
    if (err.error == GDEXTENSION_CALL_OK) constructors.float_from_variant_constructor(&v, &ret);
    destructors.variant_destroy(&ret);
    return v;
}

static int memo_vec_compute_tramp(double* out, void* userdata) {
    memo_call_t* mc = (memo_call_t*)userdata;
    Variant ret;
    GDExtensionCallError err;
    api.variant_call((GDExtensionVariantPtr)mc->callable, rc_call_sn(), NULL, 0, &ret, &err);
    int count = 0;
    if (err.error == GDEXTENSION_CALL_OK
        && api.variant_get_type(&ret) == GDEXTENSION_VARIANT_TYPE_ARRAY) {
        Array arr;
        constructors.array_from_variant_constructor(&arr, &ret);
        static StringName size_sn;
        static bool size_ready = false;
        if (!size_ready) {
            constructors.string_name_new_with_latin1_chars(&size_sn, "size", false);
            size_ready = true;
        }
        Variant size_ret;
        int64_t n = 0;
        api.variant_call(&ret, &size_sn, NULL, 0, &size_ret, &err);
        if (err.error == GDEXTENSION_CALL_OK) constructors.int_from_variant_constructor(&n, &size_ret);
        destructors.variant_destroy(&size_ret);
        if (n > COLYSEUS_MEMO_VEC_MAX) n = COLYSEUS_MEMO_VEC_MAX;
        for (int64_t i = 0; i < n; i++) {
            double v = 0;
            constructors.float_from_variant_constructor(&v, api.array_operator_index(&arr, i));
            out[count++] = v;
        }
        destructors.array_destructor(&arr);
    }
    destructors.variant_destroy(&ret);
    return count;
}

void gdext_colyseus_step_ctx_memo(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata;
    double nanv = NAN;
    if (r_return) constructors.variant_from_float_constructor(r_return, &nanv);
    if (p_argument_count < 2) {
        if (r_error) { r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; r_error->argument = 2; }
        return;
    }
    ColyseusStepCtxWrapper* w = (ColyseusStepCtxWrapper*)p_instance;
    if (!w || !w->ctx) return;
    char* key = rc_string_to_c_str(p_args[0]);
    if (!key) return;
    memo_call_t mc = { p_args[1] };
    double v = colyseus_step_memo(w->ctx, key, memo_compute_tramp, &mc);
    if (r_return) constructors.variant_from_float_constructor(r_return, &v);
    free(key);
}

void gdext_colyseus_step_ctx_memo_vec(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata;
    if (r_return) gdext_variant_new_nil((Variant*)r_return);
    if (p_argument_count < 2) {
        if (r_error) { r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; r_error->argument = 2; }
        return;
    }
    ColyseusStepCtxWrapper* w = (ColyseusStepCtxWrapper*)p_instance;
    if (!w || !w->ctx || !r_return) return;
    char* key = rc_string_to_c_str(p_args[0]);
    if (!key) return;
    memo_call_t mc = { p_args[1] };
    double out[COLYSEUS_MEMO_VEC_MAX];
    int count = colyseus_step_memo_vec(w->ctx, key, memo_vec_compute_tramp, &mc, out);
    free(key);

    /* results as a Godot Array of floats (empty = nothing this seq) */
    Array arr;
    constructors.array_constructor((GDExtensionTypePtr)&arr, NULL);
    Variant arr_var;
    constructors.variant_from_array_constructor(&arr_var, &arr);
    static StringName append_sn;
    static bool append_ready = false;
    if (!append_ready) {
        constructors.string_name_new_with_latin1_chars(&append_sn, "append", false);
        append_ready = true;
    }
    for (int i = 0; i < count; i++) {
        Variant v;
        constructors.variant_from_float_constructor(&v, &out[i]);
        GDExtensionConstVariantPtr args[1] = { &v };
        Variant ret;
        GDExtensionCallError err;
        api.variant_call(&arr_var, &append_sn, args, 1, &ret, &err);
        destructors.variant_destroy(&ret);
        destructors.variant_destroy(&v);
    }
    gdext_variant_move_assign((Variant*)r_return, &arr_var);
    destructors.array_destructor(&arr);
}

void gdext_colyseus_step_ctx_predict_event(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata; (void)r_return;
    if (p_argument_count < 2) {
        if (r_error) { r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; r_error->argument = 2; }
        return;
    }
    ColyseusStepCtxWrapper* w = (ColyseusStepCtxWrapper*)p_instance;
    if (!w || !w->ctx) return;
    ColyseusEventChannelWrapper* ch = event_channel_from_variant(p_args[0]);
    if (!ch || !ch->native) return;
    char* key = rc_string_to_c_str(p_args[1]);
    if (!key) return;
    colyseus_step_predict(w->ctx, ch->native, key, strdup(key));
    free(key);
}

/* ── spawn stores ────────────────────────────────────────────────────── */

/* reckon machinery lives below; the spawns factory arms it optionally */
typedef struct reckon_ctx reckon_ctx_t;
static reckon_ctx_t* reckon_ctx_create(ColyseusPredictWrapper* pw, GDExtensionConstVariantPtr step_callable);
static int reckon_parse_fields(GDExtensionConstVariantPtr fields_var, char** out, int max);
static void reckon_step_trampoline(colyseus_schema_t* state, double dt, double elapsed_ms, void* userdata);

static ColyseusSpawnsWrapper* g_last_spawns = NULL;

GDExtensionObjectPtr gdext_colyseus_spawns_constructor(void* p_class_userdata) {
    (void)p_class_userdata;
    ColyseusSpawnsWrapper* w = calloc(1, sizeof(ColyseusSpawnsWrapper));
    if (!w) return NULL;
    w->godot_object = rc_construct("_ColyseusSpawns", w);
    if (!w->godot_object) { free(w); return NULL; }
    g_last_spawns = w;
    return w->godot_object;
}

void gdext_colyseus_spawns_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    ColyseusSpawnsWrapper* w = (ColyseusSpawnsWrapper*)p_instance;
    if (!w) return;
    if (w->native) colyseus_spawns_free(w->native);
    destructors.variant_destroy(&w->owned_cb);
    destructors.variant_destroy(&w->spawn_time_cb);
    destructors.variant_destroy(&w->step_cb);
    destructors.variant_destroy(&w->server_view_var);
    destructors.variant_destroy(&w->predict_ref);
    free(w);
}

/* locals are malloc'd Variants holding the GDScript Dictionary */
static void spawns_local_free(void* local) {
    if (!local) return;
    destructors.variant_destroy((Variant*)local);
    free(local);
}

static bool spawns_owned_tramp(colyseus_schema_t* server, void* userdata) {
    ColyseusSpawnsWrapper* w = (ColyseusSpawnsWrapper*)userdata;
    if (api.variant_get_type(&w->owned_cb) != GDEXTENSION_VARIANT_TYPE_CALLABLE) return true;
    w->server_view_w->target = server;
    GDExtensionConstVariantPtr args[1] = { &w->server_view_var };
    Variant ret;
    GDExtensionCallError err;
    api.variant_call(&w->owned_cb, rc_call_sn(), args, 1, &ret, &err);
    GDExtensionBool b = 0;
    if (err.error == GDEXTENSION_CALL_OK) constructors.bool_from_variant_constructor(&b, &ret);
    destructors.variant_destroy(&ret);
    return b != 0;
}

static double spawns_spawn_time_tramp(colyseus_schema_t* server, void* userdata) {
    ColyseusSpawnsWrapper* w = (ColyseusSpawnsWrapper*)userdata;
    w->server_view_w->target = server;
    GDExtensionConstVariantPtr args[1] = { &w->server_view_var };
    Variant ret;
    GDExtensionCallError err;
    api.variant_call(&w->spawn_time_cb, rc_call_sn(), args, 1, &ret, &err);
    double v = 0;
    if (err.error == GDEXTENSION_CALL_OK) constructors.float_from_variant_constructor(&v, &ret);
    destructors.variant_destroy(&ret);
    return v;
}

static void spawns_step_tramp(void* local, double dt, void* userdata) {
    ColyseusSpawnsWrapper* w = (ColyseusSpawnsWrapper*)userdata;
    if (api.variant_get_type(&w->step_cb) != GDEXTENSION_VARIANT_TYPE_CALLABLE) return;
    Variant dt_var;
    constructors.variant_from_float_constructor(&dt_var, &dt);
    GDExtensionConstVariantPtr args[2] = { (Variant*)local, &dt_var };
    Variant ret;
    GDExtensionCallError err;
    api.variant_call(&w->step_cb, rc_call_sn(), args, 2, &ret, &err);
    destructors.variant_destroy(&ret);
    destructors.variant_destroy(&dt_var);
}

/* pending locals read through Dictionary.get(field) */
static double spawns_local_read(void* local, const char* field, void* userdata) {
    (void)userdata;
    if (!local) return NAN;
    static StringName get_sn;
    static bool get_ready = false;
    if (!get_ready) {
        constructors.string_name_new_with_latin1_chars(&get_sn, "get", false);
        get_ready = true;
    }
    String field_str;
    constructors.string_new_with_utf8_chars(&field_str, field);
    Variant field_var;
    constructors.variant_from_string_constructor(&field_var, &field_str);
    GDExtensionConstVariantPtr args[1] = { &field_var };
    Variant ret;
    GDExtensionCallError err;
    api.variant_call((Variant*)local, &get_sn, args, 1, &ret, &err);
    double v = NAN;
    if (err.error == GDEXTENSION_CALL_OK
        && api.variant_get_type(&ret) != GDEXTENSION_VARIANT_TYPE_NIL) {
        constructors.float_from_variant_constructor(&v, &ret);
    }
    destructors.variant_destroy(&ret);
    destructors.variant_destroy(&field_var);
    destructors.string_destructor(&field_str);
    return v;
}

/* _ColyseusPredict.spawns(collection, owned, spawn_time, step, ttl_ms
 *                        [, fields, reckon_step])
 * The optional pair arms confirmed-entity dead reckoning: each correlated
 * server entity forwards by snapshot age + its measured input lead, so an
 * owned projectile keeps flying the shooter's timeline through the handoff
 * instead of snapping back by lead x velocity. */
void gdext_colyseus_predict_spawns_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata;
    if (r_return) gdext_variant_new_nil((Variant*)r_return);
    if (p_argument_count < 5) {
        if (r_error) { r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; r_error->argument = 5; }
        return;
    }
    ColyseusPredictWrapper* pw = (ColyseusPredictWrapper*)p_instance;
    if (!pw || !pw->native || !pw->room || !pw->room->native_room) return;
    colyseus_schema_t* state = colyseus_room_get_state(pw->room->native_room);
    if (!state) return;

    char* collection = rc_string_to_c_str(p_args[0]);
    if (!collection) return;

    GDExtensionObjectPtr obj = gdext_colyseus_spawns_constructor(NULL);
    ColyseusSpawnsWrapper* w = g_last_spawns;
    if (!obj || !w) { free(collection); return; }

    api.variant_new_copy(&w->owned_cb, p_args[1]);
    api.variant_new_copy(&w->spawn_time_cb, p_args[2]);
    api.variant_new_copy(&w->step_cb, p_args[3]);
    constructors.variant_from_object_constructor(&w->predict_ref, &pw->godot_object);

    GDExtensionObjectPtr view_obj = gdext_colyseus_sim_state_constructor(NULL);
    w->server_view_w = gdext_colyseus_sim_state_last_wrapper();
    if (!view_obj || !w->server_view_w) { free(collection); return; }
    constructors.variant_from_object_constructor(&w->server_view_var, &view_obj);

    colyseus_spawns_options_t opts = {0};
    opts.owned = spawns_owned_tramp;
    if (api.variant_get_type(&w->spawn_time_cb) == GDEXTENSION_VARIANT_TYPE_CALLABLE) {
        opts.spawn_time = spawns_spawn_time_tramp;
        opts.has_spawn_time = true;
    }
    opts.step = spawns_step_tramp;
    opts.local_read = spawns_local_read;
    opts.ttl_ms = rc_to_double(p_args[4]);
    opts.local_free = spawns_local_free;
    opts.userdata = w;

    colyseus_room_clock_t* clock = colyseus_room_get_clock(pw->room->native_room);
    w->native = colyseus_spawns_create(&opts, clock);
    if (!w->native) { free(collection); return; }

    /* optional reckon arm: args 5 = fields Array, 6 = step Callable */
    colyseus_spawns_reckon_t reckon = {0};
    const colyseus_spawns_reckon_t* reckon_ptr = NULL;
    char* rfields[16] = {0};
    int rcount = 0;
    if (p_argument_count >= 7
        && api.variant_get_type(p_args[6]) == GDEXTENSION_VARIANT_TYPE_CALLABLE) {
        rcount = reckon_parse_fields(p_args[5], rfields, 16);
        if (rcount > 0) {
            reckon_ctx_t* rc = reckon_ctx_create(pw, p_args[6]);
            if (rc) {
                reckon.entry_vtable = NULL;   /* resolved per entry (dynamic) */
                reckon.fields = (const char* const*)rfields;
                reckon.field_count = rcount;
                reckon.step = reckon_step_trampoline;
                reckon.smooth_ms = 0;         /* raw projection — deterministic
                                               * constant-step motion rebases
                                               * exactly; smoothing only lags */
                reckon.substep_ms = 0;
                reckon.userdata = rc;
                reckon_ptr = &reckon;
            }
        }
    }

    /* route the collection's adds/removes here + drive from tick() */
    colyseus_predict_bind_spawns(pw->native, w->native, state, collection, reckon_ptr);
    free(collection);
    for (int i = 0; i < rcount; i++) free(rfields[i]);

    if (r_return) constructors.variant_from_object_constructor(r_return, &obj);
}

void gdext_colyseus_spawns_spawn_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata;
    int64_t id = 0;
    if (p_argument_count >= 1) {
        ColyseusSpawnsWrapper* w = (ColyseusSpawnsWrapper*)p_instance;
        if (w && w->native) {
            Variant* local = malloc(sizeof(Variant));
            if (local) {
                api.variant_new_copy(local, p_args[0]);
                id = colyseus_spawns_spawn(w->native, local);
            }
        }
    } else if (r_error) {
        r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
        r_error->argument = 1;
    }
    if (r_return) constructors.variant_from_int_constructor(r_return, &id);
}

void gdext_colyseus_spawns_value_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata;
    double v = NAN;
    ColyseusSpawnsWrapper* w = (ColyseusSpawnsWrapper*)p_instance;
    if (p_argument_count >= 2 && w && w->native) {
        int64_t id = (int64_t)rc_to_double(p_args[0]);
        char* field = rc_string_to_c_str(p_args[1]);
        const colyseus_spawn_entry_t* entry = colyseus_spawns_entry(w->native, (int)id);
        if (entry && field) v = colyseus_spawns_value(w->native, entry, field);
        free(field);
    } else if (r_error && p_argument_count < 2) {
        r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
        r_error->argument = 2;
    }
    if (r_return) constructors.variant_from_float_constructor(r_return, &v);
}

void gdext_colyseus_spawns_server_string_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata;
    const char* sv = "";
    ColyseusSpawnsWrapper* w = (ColyseusSpawnsWrapper*)p_instance;
    if (p_argument_count >= 2 && w && w->native) {
        int64_t id = (int64_t)rc_to_double(p_args[0]);
        char* field = rc_string_to_c_str(p_args[1]);
        const colyseus_spawn_entry_t* entry = colyseus_spawns_entry(w->native, (int)id);
        if (entry && entry->server && entry->server->__vtable && field) {
            predict_fref_t f;
            if (predict_vt_find(entry->server->__vtable, field, &f) && f.type == COLYSEUS_FIELD_STRING) {
                if (colyseus_vtable_is_dynamic(entry->server->__vtable)) {
                    colyseus_dynamic_value_t* dv =
                        colyseus_dynamic_schema_get((colyseus_dynamic_schema_t*)entry->server, f.index);
                    if (dv && dv->data.str) sv = dv->data.str;
                } else {
                    const char* s = *(const char* const*)((const char*)entry->server + f.offset);
                    if (s) sv = s;
                }
            }
        }
        free(field);
    } else if (r_error && p_argument_count < 2) {
        r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
        r_error->argument = 2;
    }
    if (r_return) {
        String str;
        constructors.string_new_with_utf8_chars(&str, sv);
        constructors.variant_from_string_constructor(r_return, &str);
        destructors.string_destructor(&str);
    }
}

void gdext_colyseus_spawns_entries_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata; (void)p_args; (void)p_argument_count; (void)r_error;
    if (!r_return) return;
    Array arr;
    constructors.array_constructor((GDExtensionTypePtr)&arr, NULL);
    Variant arr_var;
    constructors.variant_from_array_constructor(&arr_var, &arr);

    ColyseusSpawnsWrapper* w = (ColyseusSpawnsWrapper*)p_instance;
    if (w && w->native) {
        static StringName append_sn;
        static bool append_ready = false;
        if (!append_ready) {
            constructors.string_name_new_with_latin1_chars(&append_sn, "append", false);
            append_ready = true;
        }
        for (const colyseus_spawn_entry_t* e = colyseus_spawns_first(w->native);
             e != NULL; e = colyseus_spawns_next(w->native, e)) {
            Dictionary dict;
            constructors.dictionary_constructor((GDExtensionTypePtr)&dict, NULL);
            Variant dict_var;
            constructors.variant_from_dictionary_constructor(&dict_var, &dict);

            #define ENTRY_SET(k, make_val)                                        \
                {                                                                 \
                    String key_str;                                               \
                    constructors.string_new_with_utf8_chars(&key_str, k);         \
                    Variant key_var;                                              \
                    constructors.variant_from_string_constructor(&key_var, &key_str); \
                    Variant val_var;                                              \
                    make_val;                                                     \
                    gdext_variant_set_keyed(&dict_var, &key_var, &val_var);       \
                    destructors.variant_destroy(&val_var);                        \
                    destructors.variant_destroy(&key_var);                        \
                    destructors.string_destructor(&key_str);                      \
                }
            int64_t idv = e->id;
            ENTRY_SET("id", constructors.variant_from_int_constructor(&val_var, &idv));
            GDExtensionBool cb = e->confirmed ? 1 : 0;
            ENTRY_SET("confirmed", constructors.variant_from_bool_constructor(&val_var, &cb));
            double lm = e->lead_ms;
            ENTRY_SET("lead_ms", constructors.variant_from_float_constructor(&val_var, &lm));
            GDExtensionBool hl = e->local != NULL ? 1 : 0;
            ENTRY_SET("has_local", constructors.variant_from_bool_constructor(&val_var, &hl));
            #undef ENTRY_SET

            GDExtensionConstVariantPtr args[1] = { &dict_var };
            Variant ret;
            GDExtensionCallError err;
            api.variant_call(&arr_var, &append_sn, args, 1, &ret, &err);
            destructors.variant_destroy(&ret);
            destructors.variant_destroy(&dict_var);
            destructors.dictionary_destructor(&dict);
        }
    }
    gdext_variant_move_assign((Variant*)r_return, &arr_var);
    destructors.array_destructor(&arr);
}

void gdext_colyseus_spawns_size(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_args;
    ColyseusSpawnsWrapper* w = (ColyseusSpawnsWrapper*)p_instance;
    *(int64_t*)r_ret = w && w->native ? colyseus_spawns_size(w->native) : 0;
}

void gdext_colyseus_spawns_clear(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_args; (void)r_ret;
    ColyseusSpawnsWrapper* w = (ColyseusSpawnsWrapper*)p_instance;
    if (w && w->native) colyseus_spawns_clear(w->native);
}

/* ── reckon attachments (Callable step over the scratch) ─────────────── */

/* One per attach_reckon/attach_all_reckon call: the Callable plus a state
 * view retargeted onto the scratch each substep. Owned by the Predict
 * wrapper; freed with it (the native attachments die with the Predict too). */
struct reckon_ctx {
    Variant step_callable;
    Variant state_var;
    ColyseusSimStateWrapper* state_w;
    struct reckon_ctx* next;
};

void gdext_colyseus_predict_free_reckon_ctxs(ColyseusPredictWrapper* w) {
    reckon_ctx_t* rc = (reckon_ctx_t*)w->reckon_ctxs;
    while (rc) {
        reckon_ctx_t* next = rc->next;
        destructors.variant_destroy(&rc->step_callable);
        destructors.variant_destroy(&rc->state_var);
        free(rc);
        rc = next;
    }
    w->reckon_ctxs = NULL;
}

static void reckon_step_trampoline(colyseus_schema_t* state, double dt, double elapsed_ms, void* userdata) {
    reckon_ctx_t* rc = (reckon_ctx_t*)userdata;
    rc->state_w->target = state;

    static StringName call_sn;
    static bool call_sn_ready = false;
    if (!call_sn_ready) {
        constructors.string_name_new_with_latin1_chars(&call_sn, "call", false);
        call_sn_ready = true;
    }

    Variant dt_var, elapsed_var;
    constructors.variant_from_float_constructor(&dt_var, &dt);
    constructors.variant_from_float_constructor(&elapsed_var, &elapsed_ms);
    GDExtensionConstVariantPtr args[3] = { &rc->state_var, &dt_var, &elapsed_var };
    Variant ret;
    GDExtensionCallError err;
    api.variant_call(&rc->step_callable, &call_sn, args, 3, &ret, &err);
    destructors.variant_destroy(&ret);
    destructors.variant_destroy(&dt_var);
    destructors.variant_destroy(&elapsed_var);
}

/* Shared tail: build the ctx, parse fields, dispatch to single/all. */
static reckon_ctx_t* reckon_ctx_create(ColyseusPredictWrapper* pw, GDExtensionConstVariantPtr step_callable) {
    reckon_ctx_t* rc = calloc(1, sizeof(reckon_ctx_t));
    if (!rc) return NULL;
    GDExtensionObjectPtr view_obj = gdext_colyseus_sim_state_constructor(NULL);
    rc->state_w = gdext_colyseus_sim_state_last_wrapper();
    if (!view_obj || !rc->state_w) { free(rc); return NULL; }
    constructors.variant_from_object_constructor(&rc->state_var, &view_obj);
    api.variant_new_copy(&rc->step_callable, step_callable);
    rc->next = (reckon_ctx_t*)pw->reckon_ctxs;
    pw->reckon_ctxs = rc;
    return rc;
}

static int reckon_parse_fields(GDExtensionConstVariantPtr fields_var, char** out, int max) {
    int64_t count = 0;
    static StringName size_sn;
    static bool size_ready = false;
    if (!size_ready) {
        constructors.string_name_new_with_latin1_chars(&size_sn, "size", false);
        size_ready = true;
    }
    Variant size_ret;
    GDExtensionCallError err;
    api.variant_call((GDExtensionVariantPtr)fields_var, &size_sn, NULL, 0, &size_ret, &err);
    if (err.error == GDEXTENSION_CALL_OK) constructors.int_from_variant_constructor(&count, &size_ret);
    destructors.variant_destroy(&size_ret);
    if (count <= 0 || count > max) return 0;

    Array arr;
    constructors.array_from_variant_constructor(&arr, (GDExtensionVariantPtr)fields_var);
    for (int64_t i = 0; i < count; i++) {
        out[i] = rc_string_to_c_str(api.array_operator_index(&arr, i));
    }
    destructors.array_destructor(&arr);
    return (int)count;
}

void gdext_colyseus_predict_attach_reckon_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata; (void)r_return;
    if (p_argument_count < 6) {
        if (r_error) { r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; r_error->argument = 6; }
        return;
    }
    ColyseusPredictWrapper* pw = (ColyseusPredictWrapper*)p_instance;
    if (!pw || !pw->native) return;
    colyseus_schema_t* instance = gdext_colyseus_predict_resolve_instance(pw, p_args[0]);
    if (!instance || !instance->__vtable) return;

    char* fields[16] = {0};
    int count = reckon_parse_fields(p_args[1], fields, 16);
    if (count > 0) {
        reckon_ctx_t* rc = reckon_ctx_create(pw, p_args[2]);
        if (rc) {
            colyseus_predict_attach_reckon(pw->native, instance, instance->__vtable,
                (const char* const*)fields, count, reckon_step_trampoline,
                rc_to_double(p_args[3]), rc_to_double(p_args[4]), rc_to_double(p_args[5]), rc);
        }
    }
    for (int i = 0; i < count; i++) free(fields[i]);
}

void gdext_colyseus_predict_attach_all_reckon_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error) {
    (void)p_method_userdata; (void)r_return;
    if (p_argument_count < 6) {
        if (r_error) { r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; r_error->argument = 6; }
        return;
    }
    ColyseusPredictWrapper* pw = (ColyseusPredictWrapper*)p_instance;
    if (!pw || !pw->native || !pw->room || !pw->room->native_room) return;
    colyseus_schema_t* state = colyseus_room_get_state(pw->room->native_room);
    if (!state) return;

    char* collection = rc_string_to_c_str(p_args[0]);
    char* fields[16] = {0};
    int count = reckon_parse_fields(p_args[1], fields, 16);
    if (collection && count > 0) {
        reckon_ctx_t* rc = reckon_ctx_create(pw, p_args[2]);
        if (rc) {
            /* NULL entry vtable: each entry reckons with its own (dynamic). */
            colyseus_predict_attach_all_reckon(pw->native, state, collection, NULL,
                (const char* const*)fields, count, reckon_step_trampoline,
                rc_to_double(p_args[3]), rc_to_double(p_args[4]), rc_to_double(p_args[5]), rc);
        }
    }
    free(collection);
    for (int i = 0; i < count; i++) free(fields[i]);
}

/* ── reconciler methods ──────────────────────────────────────────────── */

void gdext_colyseus_recon_value(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata;
    ColyseusReconcilerWrapper* w = (ColyseusReconcilerWrapper*)p_instance;
    *(double*)r_ret = NAN;
    if (!w || !w->native) return;
    const String* field_str = (const String*)p_args[0];
    int32_t length = api.string_to_utf8_chars(field_str, NULL, 0);
    char* field = malloc((size_t)length + 1);
    if (!field) return;
    api.string_to_utf8_chars(field_str, field, length);
    field[length] = '\0';
    *(double*)r_ret = colyseus_reconciler_value(w->native, field);
    free(field);
}

void gdext_colyseus_recon_state(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_args;
    ColyseusReconcilerWrapper* w = (ColyseusReconcilerWrapper*)p_instance;
    *(GDExtensionObjectPtr*)r_ret = NULL;
    if (!w || !w->native || !w->state_w) return;
    /* Outside a step the view shows the live mirror. */
    w->state_w->target = colyseus_reconciler_state(w->native);
    *(GDExtensionObjectPtr*)r_ret = w->state_w->godot_object;
}

#define RECON_INT_GETTER(fn_name, call_expr)                                          \
    void fn_name(void* p_method_userdata, GDExtensionClassInstancePtr p_instance,      \
        const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {             \
        (void)p_method_userdata; (void)p_args;                                         \
        ColyseusReconcilerWrapper* w = (ColyseusReconcilerWrapper*)p_instance;         \
        *(int64_t*)r_ret = w && w->native ? (int64_t)(call_expr) : 0;                  \
    }

RECON_INT_GETTER(gdext_colyseus_recon_pending_count, colyseus_reconciler_pending_count(w->native))
RECON_INT_GETTER(gdext_colyseus_recon_reconcile_seq, colyseus_reconciler_reconcile_seq(w->native))

void gdext_colyseus_recon_last_correction_mag(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_args;
    ColyseusReconcilerWrapper* w = (ColyseusReconcilerWrapper*)p_instance;
    *(double*)r_ret = w && w->native ? colyseus_reconciler_last_correction_mag(w->native) : 0;
}

void gdext_colyseus_recon_drift_ema(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_args;
    ColyseusReconcilerWrapper* w = (ColyseusReconcilerWrapper*)p_instance;
    const colyseus_drift_t* d = w && w->native ? colyseus_reconciler_drift(w->native) : NULL;
    *(double*)r_ret = d ? d->ema : 0;
}

void gdext_colyseus_recon_reset(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret) {
    (void)p_method_userdata; (void)p_args; (void)r_ret;
    ColyseusReconcilerWrapper* w = (ColyseusReconcilerWrapper*)p_instance;
    if (w && w->native) colyseus_reconciler_reset(w->native);
}
