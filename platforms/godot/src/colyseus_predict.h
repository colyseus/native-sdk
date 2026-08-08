#ifndef COLYSEUS_GODOT_PREDICT_H
#define COLYSEUS_GODOT_PREDICT_H

#include "godot_colyseus.h"
#include <colyseus/predict/predict.h>

/*
 * _ColyseusPredict — passive smoothing (predict.h) surfaced to GDScript.
 * Each _ColyseusRoom.predict() call creates a FRESH Predict (Predictor.ts's
 * Predict.For(room) semantics — lab 04 runs four over one room). The wrapper
 * OWNS the native predict and frees it with the object.
 *
 * The raw surface is per-field (attach_field / attach_all_field) — the
 * declarative per-field-map config the reference takes lives in colyseus.gd,
 * which unrolls a Dictionary config into these calls. Instance arguments are
 * GDScript schema objects or state Dictionaries; both resolve through their
 * __ref_id into the decoder's ref tracker.
 */
typedef struct {
    colyseus_predict_t* native;        /* owned */
    ColyseusRoomWrapper* room;         /* borrowed */
    /* reckon attachments: each holds the step Callable + a retargeted state
     * view; owned here and freed with the Predict (list of reckon_ctx_t,
     * defined in colyseus_reconciler_gd.c). */
    void* reckon_ctxs;
    GDExtensionObjectPtr godot_object;
} ColyseusPredictWrapper;

/* Frees the reckon attachment list (implemented in colyseus_reconciler_gd.c). */
void gdext_colyseus_predict_free_reckon_ctxs(ColyseusPredictWrapper* w);

GDExtensionObjectPtr gdext_colyseus_predict_constructor(void* p_class_userdata);
void gdext_colyseus_predict_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance);

/* GDScript schema object / state Dictionary -> the decoded C instance
 * (via __ref_id + the decoder's ref tracker). */
colyseus_schema_t* gdext_colyseus_predict_resolve_instance(ColyseusPredictWrapper* w, GDExtensionConstVariantPtr target);

/* _ColyseusRoom.predict() -> _ColyseusPredict (ptrcall, 0 args, OBJECT ret) */
void gdext_colyseus_room_predict_method(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);

/* tick(now_ms) -> fixed input steps due (ptrcall, 1 FLOAT arg, INT ret) */
void gdext_colyseus_predict_tick(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);

/* Vararg (call convention) methods:
 *   attach_field(target, field, mode, delay, damping, max_extrapolate, snap, angle)
 *   attach_all_field(collection, field, mode, delay, damping, max_extrapolate, snap, angle, except_key)
 *   detach(target)
 *   value(target, field) -> float
 *   value_at(target, field, time_ms) -> float
 */
void gdext_colyseus_predict_attach_field(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_predict_attach_all_field(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_predict_detach(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_predict_value(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_predict_value_at(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);

#endif /* COLYSEUS_GODOT_PREDICT_H */
