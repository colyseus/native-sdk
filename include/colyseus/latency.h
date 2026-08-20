#ifndef COLYSEUS_LATENCY_H
#define COLYSEUS_LATENCY_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Options for a latency measurement. Pass NULL to colyseus_get_latency /
 * colyseus_select_by_latency to use the defaults documented below.
 */
typedef struct {
    int ping_count;   /* number of pings to send; result is the average. Default: 1 */
    int timeout_ms;   /* fail the measurement after this many ms. Default: 1500 */

    /* TLS configuration, used when the endpoint is wss:// (ignored on web). */
    bool use_secure;            /* connect over TLS (wss://) */
    bool tls_skip_verification; /* skip certificate verification */
    const unsigned char* ca_pem_data;  /* CA chain (PEM); borrowed, not owned */
    size_t ca_pem_len;
} colyseus_latency_options_t;

/**
 * Result of measuring a single endpoint, passed to colyseus_get_latency's
 * callback. The pointers are valid only for the duration of the callback.
 */
typedef struct {
    char*  endpoint;     /* the measured ws:// / wss:// URL */
    double latency_ms;   /* averaged round-trip time, or -1.0 on failure/timeout */
    bool   ok;           /* true on success */
    int    error_code;   /* close/error code on failure, 0 on success */
    char*  error;        /* failure message, or NULL */
} colyseus_latency_result_t;

/** Single-endpoint result callback. Invoked exactly once. */
typedef void (*colyseus_get_latency_cb_t)(
    const colyseus_latency_result_t* result, void* userdata);

/**
 * Selection result callback. Invoked exactly once with the lowest-latency
 * endpoint and its round-trip time, or best_endpoint == NULL (and
 * best_latency_ms < 0) when every endpoint failed.
 */
typedef void (*colyseus_select_by_latency_cb_t)(
    const char* best_endpoint, double best_latency_ms, void* userdata);

/**
 * Measure the round-trip latency to a single endpoint. Returns immediately;
 * `cb` fires once (from a worker thread on native, the event loop on web) on
 * success, connection error, server-side close before the pong, or timeout.
 *
 * @param endpoint ws:// or wss:// URL of the server's matchmaking endpoint
 * @param options  measurement options, or NULL for defaults
 */
void colyseus_get_latency(const char* endpoint,
                          const colyseus_latency_options_t* options,
                          colyseus_get_latency_cb_t cb,
                          void* userdata);

/**
 * Measure all endpoints in parallel and select the lowest-latency one. Returns
 * immediately; `cb` fires once when every probe has settled (each bounded by
 * options->timeout_ms). The `endpoints` array and its strings are borrowed and
 * may be freed by the caller as soon as this function returns.
 */
void colyseus_select_by_latency(const char* const* endpoints, size_t count,
                                const colyseus_latency_options_t* options,
                                colyseus_select_by_latency_cb_t cb,
                                void* userdata);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_LATENCY_H */
