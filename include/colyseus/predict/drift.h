#ifndef COLYSEUS_PREDICT_DRIFT_H
#define COLYSEUS_PREDICT_DRIFT_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Rolling reconcile-drift telemetry (port of predict/drift.ts).
 *
 * Each reconcile feeds the max |correction| into the pair:
 *   - ema  — persistent component (steady nonzero = genuine divergence)
 *   - peak — decaying max (spike over a low ema = network jitter)
 */
typedef struct {
    double ema;
    double peak;
} colyseus_drift_t;

typedef enum {
    COLYSEUS_DRIFT_MATCHED,
    COLYSEUS_DRIFT_JITTER,
    COLYSEUS_DRIFT_DIVERGING,
} colyseus_drift_status_t;

static inline void colyseus_drift_reset(colyseus_drift_t* d) {
    d->ema = 0;
    d->peak = 0;
}

/* Fold one reconcile's max |correction| into the telemetry. */
static inline void colyseus_drift_update(colyseus_drift_t* d, double mag) {
    d->ema += (mag - d->ema) * 0.1;
    d->peak = mag > d->peak * 0.9 ? mag : d->peak * 0.9;
}

/*
 * Actionable read: matched / jitter / diverging. `tolerance <= 0` uses the
 * float-noise floor (1e-3) — deterministic replay reproduces the server
 * exactly, so anything at that level is rounding, not disagreement.
 */
static inline colyseus_drift_status_t colyseus_drift_classify(
    const colyseus_drift_t* d, double tolerance) {
    double floor_v = tolerance > 1e-3 ? tolerance : 1e-3;
    if (d->ema >= floor_v) return COLYSEUS_DRIFT_DIVERGING;
    if (d->peak >= floor_v) return COLYSEUS_DRIFT_JITTER;
    return COLYSEUS_DRIFT_MATCHED;
}

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_PREDICT_DRIFT_H */
