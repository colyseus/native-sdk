#ifndef COLYSEUS_GODOT_RECONCILER_H
#define COLYSEUS_GODOT_RECONCILER_H

#include "godot_colyseus.h"
#include <colyseus/predict/reconciler.h>
#include <colyseus/predict/sim_reconciler.h>
#include <colyseus/predict/events.h>
#include <colyseus/predict/spawns.h>

/*
 * The rollback face for GDScript — three classes:
 *
 *   _ColyseusSimState    a view over ONE schema instance (the predicted
 *                        mirror, or the step's command). Property access
 *                        (`s.x`, `cmd.moveX`) goes through class set/get
 *                        hooks straight into C storage — a GDScript step
 *                        mutates the mirror with plain assignments and
 *                        rollback replay never touches Godot's object system
 *                        beyond these hooks.
 *   _ColyseusStepContext a read-only view over colyseus_step_ctx_t
 *                        (`ctx.dt`, `ctx.is_replay`, `ctx.reckon_time`).
 *   _ColyseusReconciler  owns the native reconciler; the step Callable is
 *                        invoked per predicted/replayed input with the SAME
 *                        three view objects each time (zero allocation on
 *                        the step path).
 */

typedef struct {
    colyseus_schema_t* target;         /* retargeted by the trampoline */
    GDExtensionObjectPtr godot_object;
} ColyseusSimStateWrapper;

typedef struct {
    const colyseus_step_ctx_t* ctx;
    GDExtensionObjectPtr godot_object;
} ColyseusStepCtxWrapper;

#define COLYSEUS_GD_MAX_PARTS 8

/* The composite face's world: named part views (`w.paddle`, `w.puck`). Part
 * mirrors are stable for the reconciler's lifetime, so the views never
 * retarget — the get hook just hands back the prebuilt object. */
typedef struct {
    int part_count;
    char* names[COLYSEUS_GD_MAX_PARTS];          /* owned */
    Variant part_vars[COLYSEUS_GD_MAX_PARTS];    /* SimState view objects */
    GDExtensionObjectPtr godot_object;
} ColyseusSimWorldWrapper;

typedef struct {
    colyseus_reconciler_t* native;     /* owned */
    Variant step_callable;             /* owned copy of the user's Callable */
    Variant predict_ref;               /* keeps the Predict (and via it the room) alive */
    Variant ctx_var, state_var, cmd_var; /* prebuilt Callable args */
    Variant world_var;                 /* composite face only (else nil) */
    ColyseusSimStateWrapper* state_w;
    ColyseusSimStateWrapper* cmd_w;
    ColyseusStepCtxWrapper* ctx_w;
    ColyseusSimWorldWrapper* world_w;  /* composite face only */
    GDExtensionObjectPtr godot_object;
} ColyseusReconcilerWrapper;

/* _ColyseusSimState */
GDExtensionObjectPtr gdext_colyseus_sim_state_constructor(void* p_class_userdata);
void gdext_colyseus_sim_state_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance);
GDExtensionBool gdext_colyseus_sim_state_set(GDExtensionClassInstancePtr p_instance, GDExtensionConstStringNamePtr p_name, GDExtensionConstVariantPtr p_value);
GDExtensionBool gdext_colyseus_sim_state_get(GDExtensionClassInstancePtr p_instance, GDExtensionConstStringNamePtr p_name, GDExtensionVariantPtr r_ret);
ColyseusSimStateWrapper* gdext_colyseus_sim_state_last_wrapper(void);

/* _ColyseusStepContext */
GDExtensionObjectPtr gdext_colyseus_step_ctx_constructor(void* p_class_userdata);
void gdext_colyseus_step_ctx_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance);
GDExtensionBool gdext_colyseus_step_ctx_get(GDExtensionClassInstancePtr p_instance, GDExtensionConstStringNamePtr p_name, GDExtensionVariantPtr r_ret);
ColyseusStepCtxWrapper* gdext_colyseus_step_ctx_last_wrapper(void);

/* _ColyseusReconciler */
GDExtensionObjectPtr gdext_colyseus_reconciler_constructor(void* p_class_userdata);
void gdext_colyseus_reconciler_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance);

/* _ColyseusSimWorld */
GDExtensionObjectPtr gdext_colyseus_sim_world_constructor(void* p_class_userdata);
void gdext_colyseus_sim_world_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance);
GDExtensionBool gdext_colyseus_sim_world_get(GDExtensionClassInstancePtr p_instance, GDExtensionConstStringNamePtr p_name, GDExtensionVariantPtr r_ret);

/* _ColyseusPredict.reconciler(target, input_handle, fields, smoothing, snap, step) — vararg */
void gdext_colyseus_predict_reconciler_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);

/* _ColyseusPredict.sim(world_dict, input_handle, smoothing, snap, step) — vararg.
 * World values are decoded instances (bound parts); mirrors are read back as
 * `w.<name>.<field>` in the step and via predict.value(instance, field). */
void gdext_colyseus_predict_sim_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);

/* world() -> _ColyseusSimWorld (composite face; null on the flat face) */
void gdext_colyseus_recon_world(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);

/*
 * _ColyseusEventChannel — typed optimistic events (events.h). Payloads are
 * the KEY string: on_predict/on_confirm/on_reject Callables receive it.
 * Settlement is driven by the owning Predict's tick().
 */
typedef struct {
    colyseus_event_channel_t* native;  /* owned */
    Variant on_predict, on_confirm, on_reject;
    Variant predict_ref;               /* keeps the driving Predict alive */
    GDExtensionObjectPtr godot_object;
} ColyseusEventChannelWrapper;

GDExtensionObjectPtr gdext_colyseus_event_channel_constructor(void* p_class_userdata);
void gdext_colyseus_event_channel_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance);

/* _ColyseusPredict.define_event(on_predict, on_confirm, on_reject, grace_ticks, ttl_ms, cooldown_ms) — vararg */
void gdext_colyseus_predict_define_event_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);

/* channel methods */
void gdext_colyseus_event_confirm(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_event_reject(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_event_predict_ui(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_event_pending_count(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_event_clear(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);

/* step-context extras (vararg):
 *   memo(key, compute) -> float        — frozen on the live step, replayed after
 *   memo_vec(key, compute) -> Array    — one derivation for a whole tuple
 *   predict(channel, key)              — sim-born optimistic event (live-only)
 */
void gdext_colyseus_step_ctx_memo(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_step_ctx_memo_vec(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_step_ctx_predict_event(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);

/*
 * _ColyseusSpawns — the predicted-spawn store (spawns.h). Locals are GDScript
 * Dictionaries; pending reads go through Dictionary.get(field), confirmed
 * reads through the schema instance, so `value(id, field)` spans the handoff.
 */
typedef struct {
    colyseus_spawns_t* native;         /* owned */
    Variant owned_cb, spawn_time_cb, step_cb;
    Variant predict_ref;
    Variant server_view_var;           /* SimState view for owned/spawn_time args */
    ColyseusSimStateWrapper* server_view_w;
    GDExtensionObjectPtr godot_object;
} ColyseusSpawnsWrapper;

GDExtensionObjectPtr gdext_colyseus_spawns_constructor(void* p_class_userdata);
void gdext_colyseus_spawns_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance);

/* _ColyseusPredict.spawns(collection, owned, spawn_time, step, ttl_ms) — vararg */
void gdext_colyseus_predict_spawns_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);

/* store methods (vararg unless noted) */
void gdext_colyseus_spawns_spawn_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_spawns_value_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_spawns_server_string_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_spawns_entries_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_spawns_size(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);   /* ptrcall */
void gdext_colyseus_spawns_clear(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);  /* ptrcall */

/* Dead reckoning with a GDScript step — Callable(state_view, dt, elapsed_ms):
 *   _ColyseusPredict.attach_reckon(target, fields, step, smoothing, substep_ms, snap)
 *   _ColyseusPredict.attach_all_reckon(collection, fields, step, smoothing, substep_ms, snap)
 */
void gdext_colyseus_predict_attach_reckon_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_predict_attach_all_reckon_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);

/* _ColyseusReconciler methods (ptrcall signatures) */
void gdext_colyseus_recon_value(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_recon_state(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_recon_pending_count(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_recon_reconcile_seq(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_recon_last_correction_mag(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_recon_drift_ema(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_recon_reset(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);

#endif /* COLYSEUS_GODOT_RECONCILER_H */
