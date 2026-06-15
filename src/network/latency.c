/* Latency measurement / endpoint selection.
 *
 * A "probe" opens a WebSocket to one endpoint, sends a Colyseus protocol PING
 * (byte 18) on open, and measures the round-trip time until the first message
 * (the pong) — mirroring the JS/C#/Lua/Haxe SDKs. Per issue #941, every probe
 * settles exactly once: on pong(s) (success), connection error, a server-side
 * close before the pong, or a timeout — so a single wedged/blackholed endpoint
 * can never stall a selection.
 *
 * Native (pthreads/Win32): each probe runs a coordinator thread that owns the
 * transport lifecycle and enforces the timeout with a condvar timed-wait. The
 * transport's tick thread fires the event callbacks; teardown happens on the
 * coordinator thread (never inside a callback — see websocket_transport.c's
 * in_tick_thread reentrancy contract).
 *
 * Emscripten (single-threaded): no threads; the timeout is armed with
 * emscripten_set_timeout and teardown is deferred to the event loop with
 * emscripten_async_call (the web transport delivers events from a poll loop /
 * the browser loop, and destroying mid-callback would be a use-after-free).
 */

#include "colyseus/latency.h"
#include "colyseus/transport.h"
#include "colyseus/websocket_transport.h"
#include "colyseus/protocol.h"
#include "colyseus/settings.h"
#include "colyseus/utils/time.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef __EMSCRIPTEN__
    #include <emscripten.h>
    #include <emscripten/eventloop.h>
    #define PROBE_LOCK(p)    ((void)0)
    #define PROBE_UNLOCK(p)  ((void)0)
    #define SELECT_LOCK(c)   ((void)0)
    #define SELECT_UNLOCK(c) ((void)0)
#elif defined(_WIN32)
    #include <windows.h>
    #define PROBE_LOCK(p)    EnterCriticalSection(&(p)->mutex)
    #define PROBE_UNLOCK(p)  LeaveCriticalSection(&(p)->mutex)
    #define PROBE_SIGNAL(p)  WakeConditionVariable(&(p)->cond)
    #define SELECT_LOCK(c)   EnterCriticalSection(&(c)->mutex)
    #define SELECT_UNLOCK(c) LeaveCriticalSection(&(c)->mutex)
    typedef DWORD probe_thread_ret;
    #define PROBE_THREAD_CALL WINAPI
#else
    #include <pthread.h>
    #include <sys/time.h>
    #include <time.h>
    #define PROBE_LOCK(p)    pthread_mutex_lock(&(p)->mutex)
    #define PROBE_UNLOCK(p)  pthread_mutex_unlock(&(p)->mutex)
    #define PROBE_SIGNAL(p)  pthread_cond_signal(&(p)->cond)
    #define SELECT_LOCK(c)   pthread_mutex_lock(&(c)->mutex)
    #define SELECT_UNLOCK(c) pthread_mutex_unlock(&(c)->mutex)
    typedef void* probe_thread_ret;
    #define PROBE_THREAD_CALL
#endif

#define LATENCY_DEFAULT_PING_COUNT 1
#define LATENCY_DEFAULT_TIMEOUT_MS 1500

/* ── probe ──────────────────────────────────────────────────────────────── */

typedef struct colyseus_latency_probe colyseus_latency_probe_t;

/* internal completion hook: probe is settled, result fields are final. */
typedef void (*probe_done_fn)(colyseus_latency_probe_t* p, void* ctx);

struct colyseus_latency_probe {
    /* config */
    char*  endpoint;
    int    ping_count;
    int    timeout_ms;
    bool   use_secure;
    bool   tls_skip_verification;
    const unsigned char* ca_pem_data;
    size_t ca_pem_len;

    /* transport (set before connect, never reassigned) */
    colyseus_transport_t* transport;

    /* timing / accumulation */
    uint64_t start_ms;
    double   accum_ms;
    int      pongs;

    /* result — settle exactly once */
    bool   settled;
    bool   ok;
    double latency_ms;
    int    error_code;
    char*  error;

    /* completion */
    probe_done_fn on_done;
    void*         on_done_ctx;

#ifdef __EMSCRIPTEN__
    long timeout_id;
#elif defined(_WIN32)
    CRITICAL_SECTION mutex;
    CONDITION_VARIABLE cond;
#else
    pthread_mutex_t mutex;
    pthread_cond_t  cond;
#endif
};

static colyseus_latency_probe_t* probe_create(const char* endpoint,
                                              const colyseus_latency_options_t* o) {
    colyseus_latency_probe_t* p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    p->endpoint = strdup(endpoint ? endpoint : "");
    p->ping_count = (o && o->ping_count > 0) ? o->ping_count : LATENCY_DEFAULT_PING_COUNT;
    p->timeout_ms = (o && o->timeout_ms > 0) ? o->timeout_ms : LATENCY_DEFAULT_TIMEOUT_MS;
    p->use_secure = o ? o->use_secure : false;
    p->tls_skip_verification = o ? o->tls_skip_verification : false;
    p->ca_pem_data = o ? o->ca_pem_data : NULL;
    p->ca_pem_len = o ? o->ca_pem_len : 0;
    p->latency_ms = -1.0;
#if !defined(__EMSCRIPTEN__) && defined(_WIN32)
    InitializeCriticalSection(&p->mutex);
    InitializeConditionVariable(&p->cond);
#elif !defined(__EMSCRIPTEN__)
    pthread_mutex_init(&p->mutex, NULL);
    pthread_cond_init(&p->cond, NULL);
#endif
    return p;
}

static void probe_free(colyseus_latency_probe_t* p) {
    if (!p) return;
#if !defined(__EMSCRIPTEN__) && defined(_WIN32)
    DeleteCriticalSection(&p->mutex);
#elif !defined(__EMSCRIPTEN__)
    pthread_mutex_destroy(&p->mutex);
    pthread_cond_destroy(&p->cond);
#endif
    free(p->endpoint);
    free(p->error);
    free(p);
}

#ifdef __EMSCRIPTEN__
static void probe_finish(void* arg);  /* fwd */
#endif

/* The single settle-once transition. On native the caller MUST hold the probe
 * mutex; on Emscripten there is no mutex (single-threaded). */
static void probe_settle(colyseus_latency_probe_t* p, bool ok, double latency_ms,
                         int code, const char* err) {
    if (p->settled) return;
    p->settled = true;
    p->ok = ok;
    p->latency_ms = ok ? latency_ms : -1.0;
    p->error_code = code;
    if (err && !p->error) p->error = strdup(err);
#ifdef __EMSCRIPTEN__
    if (p->timeout_id) { emscripten_clear_timeout(p->timeout_id); p->timeout_id = 0; }
    emscripten_async_call(probe_finish, p, 0);  /* defer teardown off the callback */
#else
    PROBE_SIGNAL(p);
#endif
}

static void probe_send_ping(colyseus_latency_probe_t* p) {
    uint8_t ping = (uint8_t)COLYSEUS_PROTOCOL_PING;
    colyseus_transport_send(p->transport, &ping, 1);
}

/* ── transport event callbacks (tick thread on native, event loop on web) ── */

static void probe_on_open(void* userdata) {
    colyseus_latency_probe_t* p = (colyseus_latency_probe_t*)userdata;
    PROBE_LOCK(p);
    bool go = !p->settled;
    if (go) p->start_ms = colyseus_monotonic_ms();
    PROBE_UNLOCK(p);
    if (go) probe_send_ping(p);
}

static void probe_on_message(const uint8_t* data, size_t length, void* userdata) {
    (void)data; (void)length;
    colyseus_latency_probe_t* p = (colyseus_latency_probe_t*)userdata;
    bool send_next = false;
    PROBE_LOCK(p);
    if (!p->settled) {
        p->accum_ms += (double)(colyseus_monotonic_ms() - p->start_ms);
        p->pongs++;
        if (p->pongs < p->ping_count) {
            p->start_ms = colyseus_monotonic_ms();
            send_next = true;
        } else {
            probe_settle(p, true, p->accum_ms / (double)p->pongs, 0, NULL);
        }
    }
    PROBE_UNLOCK(p);
    if (send_next) probe_send_ping(p);
}

static void probe_on_close(int code, const char* reason, void* userdata) {
    colyseus_latency_probe_t* p = (colyseus_latency_probe_t*)userdata;
    PROBE_LOCK(p);
    /* a clean close before the pong is a failure; after success it's a no-op */
    probe_settle(p, false, -1.0, code, reason && reason[0] ? reason : "connection closed before pong");
    PROBE_UNLOCK(p);
}

static void probe_on_error(const char* error, void* userdata) {
    colyseus_latency_probe_t* p = (colyseus_latency_probe_t*)userdata;
    PROBE_LOCK(p);
    probe_settle(p, false, -1.0, COLYSEUS_CLOSE_ABNORMAL_CLOSURE,
                 error && error[0] ? error : "connection error");
    PROBE_UNLOCK(p);
}

static colyseus_transport_events_t probe_events(colyseus_latency_probe_t* p) {
    colyseus_transport_events_t ev;
    ev.on_open = probe_on_open;
    ev.on_message = probe_on_message;
    ev.on_close = probe_on_close;
    ev.on_error = probe_on_error;
    ev.userdata = p;
    return ev;
}

/* Hand the final result to the completion hook, tear down, and free. */
static void probe_complete(colyseus_latency_probe_t* p) {
    if (p->transport) {
        colyseus_transport_destroy(p->transport);  /* joins tick thread on native */
        p->transport = NULL;
    }
    if (p->on_done) p->on_done(p, p->on_done_ctx);
    probe_free(p);
}

/* ── platform launch ──────────────────────────────────────────────────────── */

#ifdef __EMSCRIPTEN__

static void probe_finish(void* arg) {
    probe_complete((colyseus_latency_probe_t*)arg);
}

static void probe_timeout_cb(void* arg) {
    colyseus_latency_probe_t* p = (colyseus_latency_probe_t*)arg;
    p->timeout_id = 0;
    probe_settle(p, false, -1.0, COLYSEUS_CLOSE_ABNORMAL_CLOSURE, "latency probe timed out");
}

static void probe_launch(colyseus_latency_probe_t* p) {
    colyseus_transport_events_t ev = probe_events(p);
    p->transport = colyseus_websocket_transport_create(&ev);
    if (!p->transport) {
        probe_settle(p, false, -1.0, COLYSEUS_CLOSE_ABNORMAL_CLOSURE, "failed to create transport");
        return;
    }
    /* browser handles TLS; plain connect via the transport vtable */
    p->timeout_id = emscripten_set_timeout(probe_timeout_cb, (double)p->timeout_ms, p);
    colyseus_transport_connect(p->transport, p->endpoint);
}

#else  /* native (pthreads / Win32) */

/* Wait on the probe condvar for up to delay_ms. Caller holds the probe mutex. */
static void probe_timedwait(colyseus_latency_probe_t* p, int delay_ms) {
#ifdef _WIN32
    SleepConditionVariableCS(&p->cond, &p->mutex, (DWORD)delay_ms);
#else
    struct timespec ts;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    uint64_t total_ns = (uint64_t)tv.tv_sec * 1000000000ULL
                      + (uint64_t)tv.tv_usec * 1000ULL
                      + (uint64_t)delay_ms * 1000000ULL;
    ts.tv_sec = (time_t)(total_ns / 1000000000ULL);
    ts.tv_nsec = (long)(total_ns % 1000000000ULL);
    pthread_cond_timedwait(&p->cond, &p->mutex, &ts);
#endif
}

static probe_thread_ret PROBE_THREAD_CALL probe_coordinator(void* arg) {
    colyseus_latency_probe_t* p = (colyseus_latency_probe_t*)arg;

    colyseus_transport_events_t ev = probe_events(p);
    p->transport = colyseus_websocket_transport_create(&ev);

    if (!p->transport) {
        PROBE_LOCK(p);
        probe_settle(p, false, -1.0, COLYSEUS_CLOSE_ABNORMAL_CLOSURE, "failed to create transport");
        PROBE_UNLOCK(p);
    } else {
        /* stack settings view carries only the TLS config that connect reads */
        colyseus_settings_t s;
        memset(&s, 0, sizeof(s));
        s.use_secure_protocol = p->use_secure;
        s.tls_skip_verification = p->tls_skip_verification;
        s.ca_pem_data = p->ca_pem_data;
        s.ca_pem_len = p->ca_pem_len;
        colyseus_websocket_connect_with_settings(p->transport, p->endpoint, &s);

        PROBE_LOCK(p);
        uint64_t deadline = colyseus_monotonic_ms() + (uint64_t)p->timeout_ms;
        while (!p->settled) {
            uint64_t now = colyseus_monotonic_ms();
            if (now >= deadline) {
                probe_settle(p, false, -1.0, COLYSEUS_CLOSE_ABNORMAL_CLOSURE,
                             "latency probe timed out");
                break;
            }
            probe_timedwait(p, (int)(deadline - now));
        }
        PROBE_UNLOCK(p);
    }

    probe_complete(p);  /* teardown happens here, off the tick thread */
    return (probe_thread_ret)0;
}

static void probe_launch(colyseus_latency_probe_t* p) {
#ifdef _WIN32
    HANDLE th = CreateThread(NULL, 0, probe_coordinator, p, 0, NULL);
    if (th) CloseHandle(th);
#else
    pthread_t th;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&th, &attr, probe_coordinator, p);
    pthread_attr_destroy(&attr);
#endif
}

#endif /* __EMSCRIPTEN__ */

/* ── colyseus_get_latency ─────────────────────────────────────────────────── */

typedef struct {
    colyseus_get_latency_cb_t cb;
    void* userdata;
} get_latency_call_t;

static void get_latency_done(colyseus_latency_probe_t* p, void* ctx) {
    get_latency_call_t* call = (get_latency_call_t*)ctx;
    if (call->cb) {
        colyseus_latency_result_t r;
        r.endpoint = p->endpoint;
        r.latency_ms = p->latency_ms;
        r.ok = p->ok;
        r.error_code = p->error_code;
        r.error = p->error;
        call->cb(&r, call->userdata);
    }
    free(call);
}

void colyseus_get_latency(const char* endpoint,
                          const colyseus_latency_options_t* options,
                          colyseus_get_latency_cb_t cb,
                          void* userdata) {
    colyseus_latency_probe_t* p = probe_create(endpoint, options);
    if (!p) {
        if (cb) {
            colyseus_latency_result_t r = { NULL, -1.0, false, COLYSEUS_CLOSE_ABNORMAL_CLOSURE,
                                            (char*)"out of memory" };
            cb(&r, userdata);
        }
        return;
    }
    get_latency_call_t* call = (get_latency_call_t*)malloc(sizeof(*call));
    call->cb = cb;
    call->userdata = userdata;
    p->on_done = get_latency_done;
    p->on_done_ctx = call;
    probe_launch(p);
}

/* ── colyseus_select_by_latency ───────────────────────────────────────────── */

typedef struct {
    int    remaining;
    char*  best_endpoint;   /* owned; NULL until the first successful probe */
    double best_latency_ms;
    colyseus_select_by_latency_cb_t cb;
    void*  userdata;
#if !defined(__EMSCRIPTEN__) && defined(_WIN32)
    CRITICAL_SECTION mutex;
#elif !defined(__EMSCRIPTEN__)
    pthread_mutex_t mutex;
#endif
} select_ctx_t;

static void select_ctx_finish(select_ctx_t* ctx) {
    if (ctx->cb) {
        ctx->cb(ctx->best_endpoint, ctx->best_endpoint ? ctx->best_latency_ms : -1.0, ctx->userdata);
    }
    free(ctx->best_endpoint);
#if !defined(__EMSCRIPTEN__) && defined(_WIN32)
    DeleteCriticalSection(&ctx->mutex);
#elif !defined(__EMSCRIPTEN__)
    pthread_mutex_destroy(&ctx->mutex);
#endif
    free(ctx);
}

static void select_done(colyseus_latency_probe_t* p, void* arg) {
    select_ctx_t* ctx = (select_ctx_t*)arg;

    SELECT_LOCK(ctx);
    if (p->ok && (ctx->best_endpoint == NULL || p->latency_ms < ctx->best_latency_ms)) {
        free(ctx->best_endpoint);
        ctx->best_endpoint = strdup(p->endpoint ? p->endpoint : "");
        ctx->best_latency_ms = p->latency_ms;
    }
    int remaining = --ctx->remaining;
    SELECT_UNLOCK(ctx);

    if (remaining == 0) select_ctx_finish(ctx);  /* last probe to settle fires cb */
}

void colyseus_select_by_latency(const char* const* endpoints, size_t count,
                                const colyseus_latency_options_t* options,
                                colyseus_select_by_latency_cb_t cb,
                                void* userdata) {
    if (count == 0 || !endpoints) {
        if (cb) cb(NULL, -1.0, userdata);
        return;
    }

    select_ctx_t* ctx = (select_ctx_t*)calloc(1, sizeof(*ctx));
    ctx->remaining = (int)count;
    ctx->best_latency_ms = -1.0;
    ctx->cb = cb;
    ctx->userdata = userdata;
#if !defined(__EMSCRIPTEN__) && defined(_WIN32)
    InitializeCriticalSection(&ctx->mutex);
#elif !defined(__EMSCRIPTEN__)
    pthread_mutex_init(&ctx->mutex, NULL);
#endif

    for (size_t i = 0; i < count; i++) {
        colyseus_latency_probe_t* p = probe_create(endpoints[i], options);
        if (!p) {
            /* count this endpoint as failed-to-launch */
            SELECT_LOCK(ctx);
            int remaining = --ctx->remaining;
            SELECT_UNLOCK(ctx);
            if (remaining == 0) select_ctx_finish(ctx);
            continue;
        }
        p->on_done = select_done;
        p->on_done_ctx = ctx;
        probe_launch(p);
    }
}
