#include "colyseus/room.h"
#include "colyseus/websocket_transport.h"
#include "colyseus/schema.h"
#include "colyseus/messages.h"
#include "colyseus/utils/time.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* Platform-specific threading + sleep */
#ifdef __EMSCRIPTEN__
    /* Reconnection worker is a no-op stub on Emscripten — the browser SDK
     * already handles reconnect through its own event loop, and we cannot
     * block in a worker thread anyway. */
#elif defined(_WIN32)
    #include <windows.h>
#else
    #include <pthread.h>
    #include <errno.h>
    #include <sys/time.h>
    #include <time.h>
#endif

/* Internal helper functions */
static void room_on_transport_open(void* userdata);
static void room_on_transport_message(const uint8_t* data, size_t length, void* userdata);
static void room_on_transport_close(int code, const char* reason, void* userdata);
static void room_on_transport_error(const char* error, void* userdata);
static void room_dispatch_message(colyseus_room_t* room, const char* type, const uint8_t* message, size_t length);
static void room_dispatch_message_bytes(colyseus_room_t* room, const char* type, const uint8_t* message, size_t length);
static char* room_get_message_key_str(const char* type);
static char* room_get_message_key_int(int type);

/* Decode helpers using schema decode functions */
static float decode_number(const uint8_t* bytes, size_t* offset);
static char* decode_string(const uint8_t* bytes, size_t* offset);

/* Request/response helpers */
static void room_reject_all_pending_requests(colyseus_room_t* room, const char* reason);

/* Reconnection helpers */
static void room_enqueue_message(colyseus_room_t* room, const uint8_t* data, size_t length);
static void room_clear_message_queue(colyseus_room_t* room);
static void room_flush_message_queue(colyseus_room_t* room);
static bool room_send_or_enqueue(colyseus_room_t* room, const uint8_t* data, size_t length);
static char* room_build_reconnect_url(const colyseus_room_t* room);
static void room_handle_reconnection(colyseus_room_t* room, int code, const char* reason);
static void room_reconnection_signal_attempt_done(colyseus_room_t* room);
static void room_reconnection_signal_success(colyseus_room_t* room);
static void room_reconnection_cancel(colyseus_room_t* room);
static void room_reconnection_init(colyseus_room_t* room);
static void room_reconnection_teardown(colyseus_room_t* room);

/* Reconnection worker:
 * - On native (pthreads/Win32), a dedicated thread runs the retry loop with
 *   a timed condvar wait. Cancelling sets `cancelled=true` and signals.
 * - On Emscripten, the worker is a no-op: automatic reconnection is not
 *   currently supported in the browser build (the JS event loop driving
 *   `emscripten_fetch` cannot host a blocking retry loop).
 */
typedef struct colyseus_reconnection_worker {
#ifdef __EMSCRIPTEN__
    int _unused;
#elif defined(_WIN32)
    HANDLE thread;
    CRITICAL_SECTION mutex;
    CONDITION_VARIABLE cond;
    bool thread_started;
    bool pending_attempt;
#else
    pthread_t thread;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    bool thread_started;
    bool pending_attempt;
#endif
} colyseus_reconnection_worker_t;

#ifdef __EMSCRIPTEN__

static colyseus_reconnection_worker_t* room_worker_create(void) {
    return NULL;
}
static void room_worker_destroy(colyseus_reconnection_worker_t* w) { (void)w; }

#else

#ifdef _WIN32
    #define WORKER_LOCK(w)   EnterCriticalSection(&(w)->mutex)
    #define WORKER_UNLOCK(w) LeaveCriticalSection(&(w)->mutex)
    #define WORKER_SIGNAL(w) WakeConditionVariable(&(w)->cond)
#else
    #define WORKER_LOCK(w)   pthread_mutex_lock(&(w)->mutex)
    #define WORKER_UNLOCK(w) pthread_mutex_unlock(&(w)->mutex)
    #define WORKER_SIGNAL(w) pthread_cond_signal(&(w)->cond)
#endif

static colyseus_reconnection_worker_t* room_worker_create(void) {
    colyseus_reconnection_worker_t* w = malloc(sizeof(*w));
    if (!w) return NULL;
    memset(w, 0, sizeof(*w));
#ifdef _WIN32
    InitializeCriticalSection(&w->mutex);
    InitializeConditionVariable(&w->cond);
#else
    pthread_mutex_init(&w->mutex, NULL);
    pthread_cond_init(&w->cond, NULL);
#endif
    w->thread_started = false;
    w->pending_attempt = false;
    return w;
}

static void room_worker_destroy(colyseus_reconnection_worker_t* w) {
    if (!w) return;
#ifdef _WIN32
    DeleteCriticalSection(&w->mutex);
#else
    pthread_mutex_destroy(&w->mutex);
    pthread_cond_destroy(&w->cond);
#endif
    free(w);
}

/* Wait on the worker condvar for up to delay_ms milliseconds. Caller holds
 * the worker mutex. */
static void room_worker_timedwait(colyseus_reconnection_worker_t* w, int delay_ms) {
#ifdef _WIN32
    SleepConditionVariableCS(&w->cond, &w->mutex, (DWORD)delay_ms);
#else
    struct timespec ts;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    uint64_t total_ns = (uint64_t)tv.tv_sec * 1000000000ULL
                      + (uint64_t)tv.tv_usec * 1000ULL
                      + (uint64_t)delay_ms * 1000000ULL;
    ts.tv_sec = (time_t)(total_ns / 1000000000ULL);
    ts.tv_nsec = (long)(total_ns % 1000000000ULL);
    pthread_cond_timedwait(&w->cond, &w->mutex, &ts);
#endif
}

/* Block on the worker condvar until signalled. Caller holds the worker mutex. */
static void room_worker_wait(colyseus_reconnection_worker_t* w) {
#ifdef _WIN32
    SleepConditionVariableCS(&w->cond, &w->mutex, INFINITE);
#else
    pthread_cond_wait(&w->cond, &w->mutex);
#endif
}

#endif /* __EMSCRIPTEN__ */

/* ── Reconnection worker (native only) ─────────────────────────── */

#ifndef __EMSCRIPTEN__

#ifdef _WIN32
typedef DWORD worker_return_t;
#define WORKER_THREAD_CALL WINAPI
#else
typedef void* worker_return_t;
#define WORKER_THREAD_CALL
#endif

static int room_compute_backoff_delay(const colyseus_reconnection_options_t* opts, int attempt) {
    /* (1 << attempt) * delay_ms, clamped to [min_delay_ms, max_delay_ms].
     * Cap the shift at 30 to avoid overflow on pathological max_retries. */
    int shift = attempt;
    if (shift > 30) shift = 30;
    long long delay = (long long)(1u << shift) * (long long)opts->delay_ms;
    if (delay > (long long)opts->max_delay_ms) delay = opts->max_delay_ms;
    if (delay < (long long)opts->min_delay_ms) delay = opts->min_delay_ms;
    return (int)delay;
}

static void room_attempt_reconnect(colyseus_room_t* room) {
    /* Tear down the closed transport and start a fresh one with an updated
     * URL. The new transport's tick thread will deliver either an on_open
     * → JOIN_ROOM (success) or an on_close (failure). */
    if (room->transport) {
        colyseus_transport_destroy(room->transport);
        room->transport = NULL;
    }

    colyseus_transport_events_t events = {
        .on_open = room_on_transport_open,
        .on_message = room_on_transport_message,
        .on_close = room_on_transport_close,
        .on_error = room_on_transport_error,
        .userdata = room
    };

    room->transport = room->transport_factory(&events);
    if (!room->transport) {
        /* Treat as an immediate failure; the close path will route us back
         * into the worker for another retry. */
        room_on_transport_close(COLYSEUS_CLOSE_ABNORMAL_CLOSURE,
                                "Failed to create transport for reconnect",
                                room);
        return;
    }

    char* url = room_build_reconnect_url(room);
    if (!url) {
        room_on_transport_close(COLYSEUS_CLOSE_ABNORMAL_CLOSURE,
                                "Failed to build reconnect URL",
                                room);
        return;
    }

    if (room->settings) {
        colyseus_websocket_connect_with_settings(room->transport, url, room->settings);
    } else {
        colyseus_transport_connect(room->transport, url);
    }

    free(url);
}

static worker_return_t WORKER_THREAD_CALL room_reconnect_worker_func(void* arg) {
    colyseus_room_t* room = (colyseus_room_t*)arg;
    colyseus_reconnection_worker_t* w =
        (colyseus_reconnection_worker_t*)room->reconnection.worker;

    WORKER_LOCK(w);
    while (!room->reconnection.cancelled && room->reconnection.is_reconnecting) {
        room->reconnection.retry_count++;

        if (room->reconnection.retry_count > room->reconnection.options.max_retries) {
            room->reconnection.is_reconnecting = false;
            WORKER_UNLOCK(w);
            if (room->serializer) {
                colyseus_schema_serializer_teardown(room->serializer);
            }
            if (room->on_leave) {
                room->on_leave(COLYSEUS_CLOSE_FAILED_TO_RECONNECT,
                               "No more retries. Reconnection failed.",
                               room->on_leave_userdata);
            }
            goto done;
        }

        int delay = room_compute_backoff_delay(&room->reconnection.options,
                                               room->reconnection.retry_count);

        room_worker_timedwait(w, delay);
        if (room->reconnection.cancelled || !room->reconnection.is_reconnecting) {
            break;
        }

        w->pending_attempt = true;
        WORKER_UNLOCK(w);
        room_attempt_reconnect(room);
        WORKER_LOCK(w);

        /* Wait for either a successful JOIN_ROOM (sets is_reconnecting=false
         * and signals) or a close from the failed attempt (clears
         * pending_attempt and signals). */
        while (w->pending_attempt
               && !room->reconnection.cancelled
               && room->reconnection.is_reconnecting) {
            room_worker_wait(w);
        }
    }
    WORKER_UNLOCK(w);

done:
#ifdef _WIN32
    return 0;
#else
    return NULL;
#endif
}

static void room_reconnect_worker_spawn(colyseus_room_t* room) {
    colyseus_reconnection_worker_t* w =
        (colyseus_reconnection_worker_t*)room->reconnection.worker;
    if (!w) return;
    /* Caller must already hold w->mutex. */
    if (w->thread_started) return;
    w->thread_started = true;
#ifdef _WIN32
    w->thread = CreateThread(NULL, 0, room_reconnect_worker_func, room, 0, NULL);
#else
    pthread_create(&w->thread, NULL, room_reconnect_worker_func, room);
#endif
}

static void room_reconnect_worker_join(colyseus_reconnection_worker_t* w) {
    if (!w) return;
    if (!w->thread_started) return;
#ifdef _WIN32
    WaitForSingleObject(w->thread, INFINITE);
    CloseHandle(w->thread);
#else
    pthread_join(w->thread, NULL);
#endif
    w->thread_started = false;
}

#endif /* !__EMSCRIPTEN__ */

/* ── Reconnection state lifecycle ──────────────────────────────── */

void colyseus_reconnection_options_init_defaults(colyseus_reconnection_options_t* options) {
    if (!options) return;
    options->enabled = true;
    options->max_retries = 15;
    options->min_delay_ms = 100;
    options->max_delay_ms = 5000;
    options->min_uptime_ms = 5000;
    options->delay_ms = 100;
    options->max_enqueued_messages = 10;
}

static void room_reconnection_init(colyseus_room_t* room) {
    colyseus_reconnection_options_init_defaults(&room->reconnection.options);
    room->reconnection.retry_count = 0;
    room->reconnection.is_reconnecting = false;
    room->reconnection.cancelled = false;
    room->reconnection.queue_head = NULL;
    room->reconnection.queue_tail = NULL;
    room->reconnection.queue_count = 0;
    room->reconnection.worker = room_worker_create();
}

static void room_reconnection_teardown(colyseus_room_t* room) {
    room_reconnection_cancel(room);
    room_clear_message_queue(room);

    colyseus_reconnection_worker_t* w =
        (colyseus_reconnection_worker_t*)room->reconnection.worker;
#ifndef __EMSCRIPTEN__
    room_reconnect_worker_join(w);
#endif
    room_worker_destroy(w);
    room->reconnection.worker = NULL;
}

static void room_reconnection_cancel(colyseus_room_t* room) {
#ifdef __EMSCRIPTEN__
    (void)room;
#else
    colyseus_reconnection_worker_t* w =
        (colyseus_reconnection_worker_t*)room->reconnection.worker;
    if (!w) return;
    WORKER_LOCK(w);
    room->reconnection.cancelled = true;
    room->reconnection.is_reconnecting = false;
    WORKER_SIGNAL(w);
    WORKER_UNLOCK(w);
#endif
}

static void room_reconnection_signal_success(colyseus_room_t* room) {
#ifdef __EMSCRIPTEN__
    (void)room;
#else
    colyseus_reconnection_worker_t* w =
        (colyseus_reconnection_worker_t*)room->reconnection.worker;
    if (!w) return;
    WORKER_LOCK(w);
    room->reconnection.is_reconnecting = false;
    w->pending_attempt = false;
    room->reconnection.retry_count = 0;
    WORKER_SIGNAL(w);
    WORKER_UNLOCK(w);
#endif
}

static void room_reconnection_signal_attempt_done(colyseus_room_t* room) {
#ifdef __EMSCRIPTEN__
    (void)room;
#else
    colyseus_reconnection_worker_t* w =
        (colyseus_reconnection_worker_t*)room->reconnection.worker;
    if (!w) return;
    WORKER_LOCK(w);
    w->pending_attempt = false;
    WORKER_SIGNAL(w);
    WORKER_UNLOCK(w);
#endif
}

/* ── Pending message queue ─────────────────────────────────────── */

static void room_clear_message_queue(colyseus_room_t* room) {
    colyseus_pending_msg_t* m = room->reconnection.queue_head;
    while (m) {
        colyseus_pending_msg_t* next = m->next;
        free(m->data);
        free(m);
        m = next;
    }
    room->reconnection.queue_head = NULL;
    room->reconnection.queue_tail = NULL;
    room->reconnection.queue_count = 0;
}

static void room_enqueue_message(colyseus_room_t* room, const uint8_t* data, size_t length) {
    if (length == 0) return;
    /* Drop oldest if at capacity (parity with TS SDK). */
    while (room->reconnection.queue_count >= room->reconnection.options.max_enqueued_messages) {
        colyseus_pending_msg_t* old = room->reconnection.queue_head;
        if (!old) break;
        room->reconnection.queue_head = old->next;
        if (!room->reconnection.queue_head) room->reconnection.queue_tail = NULL;
        room->reconnection.queue_count--;
        free(old->data);
        free(old);
    }

    colyseus_pending_msg_t* m = malloc(sizeof(*m));
    if (!m) return;
    m->data = malloc(length);
    if (!m->data) { free(m); return; }
    memcpy(m->data, data, length);
    m->length = length;
    m->next = NULL;

    if (room->reconnection.queue_tail) {
        room->reconnection.queue_tail->next = m;
    } else {
        room->reconnection.queue_head = m;
    }
    room->reconnection.queue_tail = m;
    room->reconnection.queue_count++;
}

static void room_flush_message_queue(colyseus_room_t* room) {
    if (!room->transport) return;
    colyseus_pending_msg_t* m = room->reconnection.queue_head;
    while (m) {
        colyseus_pending_msg_t* next = m->next;
        colyseus_transport_send(room->transport, m->data, m->length);
        free(m->data);
        free(m);
        m = next;
    }
    room->reconnection.queue_head = NULL;
    room->reconnection.queue_tail = NULL;
    room->reconnection.queue_count = 0;
}

/* Send `data` over the transport, or enqueue if disconnected and a
 * reconnect is in progress. Returns true if sent or enqueued; false if
 * dropped. */
static bool room_send_or_enqueue(colyseus_room_t* room, const uint8_t* data, size_t length) {
    if (!room) return false;
    if (room->transport && colyseus_transport_is_open(room->transport)) {
        colyseus_transport_send(room->transport, data, length);
        return true;
    }
    if (room->reconnection.is_reconnecting && room->reconnection.options.enabled) {
        room_enqueue_message(room, data, length);
        return true;
    }
    return false;
}

/* ── Reconnect URL builder ─────────────────────────────────────── */

/* Rebuild the WebSocket URL by stripping any pre-existing
 * `reconnectionToken=` and `skipHandshake=` query params from
 * `room->endpoint_url`, then re-appending the current token and
 * `skipHandshake=1`. */
static char* room_build_reconnect_url(const colyseus_room_t* room) {
    if (!room || !room->endpoint_url) return NULL;

    size_t base_len = strlen(room->endpoint_url);
    /* Worst case: original + new params. */
    size_t out_cap = base_len + 256;
    char* out = malloc(out_cap);
    if (!out) return NULL;

    /* Copy original, stripping the params we'll re-set. */
    size_t oi = 0;
    size_t i = 0;
    while (i < base_len) {
        /* Match "reconnectionToken=" or "skipHandshake=" preceded by ? or & */
        bool strip = false;
        if (room->endpoint_url[i] == '?' || room->endpoint_url[i] == '&') {
            const char* tail = room->endpoint_url + i + 1;
            if (strncmp(tail, "reconnectionToken=", 18) == 0) strip = true;
            else if (strncmp(tail, "skipHandshake=", 14) == 0) strip = true;
        }
        if (strip) {
            char sep = room->endpoint_url[i];
            /* Skip up to next & or end-of-string. */
            i++;
            while (i < base_len && room->endpoint_url[i] != '&') i++;
            /* If we stripped a `?param`, the next param (if any) needs to
             * become the new `?param`. If we stripped a `&param`, just
             * continue. */
            if (sep == '?' && i < base_len && room->endpoint_url[i] == '&') {
                out[oi++] = '?';
                i++;
            }
            continue;
        }
        out[oi++] = room->endpoint_url[i++];
    }
    out[oi] = '\0';

    /* Append reconnectionToken + skipHandshake. */
    bool has_q = (strchr(out, '?') != NULL);
    const char* token = room->reconnection_token ? room->reconnection_token : "";
    int written = snprintf(out + oi, out_cap - oi,
                           "%creconnectionToken=%s&skipHandshake=1",
                           has_q ? '&' : '?', token);
    if (written < 0 || (size_t)written >= out_cap - oi) {
        free(out);
        return NULL;
    }
    return out;
}

/* ── Drop handling ─────────────────────────────────────────────── */

static bool room_close_code_is_drop(int code) {
    return code == COLYSEUS_CLOSE_GOING_AWAY
        || code == COLYSEUS_CLOSE_NO_STATUS_RECEIVED
        || code == COLYSEUS_CLOSE_ABNORMAL_CLOSURE
        || code == COLYSEUS_CLOSE_MAY_TRY_RECONNECT;
}

static void room_handle_reconnection(colyseus_room_t* room, int code, const char* reason) {
    (void)code;
    (void)reason;
#ifdef __EMSCRIPTEN__
    /* No worker support on the web build — fall through to on_leave. */
    if (room->on_leave) {
        room->on_leave(code, reason, room->on_leave_userdata);
    }
#else
    colyseus_reconnection_worker_t* w =
        (colyseus_reconnection_worker_t*)room->reconnection.worker;
    if (!w) {
        if (room->on_leave) {
            room->on_leave(code, reason, room->on_leave_userdata);
        }
        return;
    }

    /* Uptime gate. */
    uint64_t now = colyseus_monotonic_ms();
    if (room->joined_at_ms == 0 ||
        (now - room->joined_at_ms) < (uint64_t)room->reconnection.options.min_uptime_ms) {
        if (room->serializer) {
            colyseus_schema_serializer_teardown(room->serializer);
        }
        if (room->on_leave) {
            room->on_leave(COLYSEUS_CLOSE_ABNORMAL_CLOSURE,
                           "Room uptime too short for reconnection.",
                           room->on_leave_userdata);
        }
        return;
    }

    WORKER_LOCK(w);
    if (!room->reconnection.is_reconnecting) {
        room->reconnection.retry_count = 0;
        room->reconnection.is_reconnecting = true;
        room->reconnection.cancelled = false;
        room_reconnect_worker_spawn(room);
    }
    WORKER_UNLOCK(w);
#endif
}

/* ── Room lifecycle ────────────────────────────────────────────── */

colyseus_room_t* colyseus_room_create(const char* name, colyseus_transport_factory_fn transport_factory) {
    colyseus_room_t* room = malloc(sizeof(colyseus_room_t));
    if (!room) return NULL;

    memset(room, 0, sizeof(colyseus_room_t));

    room->name = strdup(name);
    room->has_joined = false;
    room->transport_factory = transport_factory;
    room->transport = NULL;
    room->message_handlers = NULL;
    room->serializer = NULL;
    room->serializer_id = NULL;
    room->endpoint_url = NULL;
    room->settings = NULL;
    room->joined_at_ms = 0;

    room_reconnection_init(room);

    return room;
}

void colyseus_room_free(colyseus_room_t* room) {
    if (!room) return;

    /* Cancel and join the reconnection worker before tearing down the
     * transport — the worker may otherwise try to reconnect against a
     * half-freed room. */
    room_reconnection_teardown(room);

    /* Drop pending requests (no callbacks — the room is going away) */
    {
        colyseus_pending_request_t *entry, *tmp;
        HASH_ITER(hh, room->pending_requests, entry, tmp) {
            HASH_DEL(room->pending_requests, entry);
            free(entry);
        }
    }

    /* Cleanup transport */
    if (room->transport) {
        colyseus_transport_destroy(room->transport);
    }

    /* Cleanup serializer */
    if (room->serializer) {
        colyseus_schema_serializer_free(room->serializer);
    }

    /* Free strings */
    free(room->name);
    free(room->room_id);
    free(room->session_id);
    free(room->reconnection_token);
    free(room->serializer_id);
    free(room->endpoint_url);

    /* Free message handlers */
    colyseus_message_handler_t *handler, *tmp;
    HASH_ITER(hh, room->message_handlers, handler, tmp) {
        HASH_DEL(room->message_handlers, handler);
        free(handler->key);
        free(handler);
    }

    free(room);
}

/* Set the state schema vtable - must be called before connect */
void colyseus_room_set_state_type(colyseus_room_t* room, const colyseus_schema_vtable_t* state_vtable) {
    if (!room) return;
    room->state_vtable = state_vtable;
}

/* Get current state */
void* colyseus_room_get_state(colyseus_room_t* room) {
    if (!room || !room->serializer) return NULL;
    return colyseus_schema_serializer_get_state(room->serializer);
}

/* Connection */
void colyseus_room_connect(
    colyseus_room_t* room,
    const char* endpoint,
    const colyseus_settings_t* settings,
    void (*on_success)(void* userdata),
    void (*on_error)(int code, const char* message, void* userdata),
    void* userdata
) {
    /* Setup transport events */
    colyseus_transport_events_t events = {
        .on_open = room_on_transport_open,
        .on_message = room_on_transport_message,
        .on_close = room_on_transport_close,
        .on_error = room_on_transport_error,
        .userdata = room
    };

    /* Create transport */
    room->transport = room->transport_factory(&events);
    if (!room->transport) {
        if (on_error) {
            on_error(-1, "Failed to create transport", userdata);
        }
        return;
    }

    /* Store connection callbacks */
    room->connect_on_success = on_success;
    room->connect_on_error = on_error;
    room->connect_userdata = userdata;

    /* Save the endpoint + settings so the reconnection worker can rebuild
     * the URL with an updated `reconnectionToken=` on retries. */
    free(room->endpoint_url);
    room->endpoint_url = endpoint ? strdup(endpoint) : NULL;
    room->settings = settings;

    /* Connect (with TLS settings if provided) */
    if (settings) {
        colyseus_websocket_connect_with_settings(room->transport, endpoint, settings);
    } else {
        colyseus_transport_connect(room->transport, endpoint);
    }
}

void colyseus_room_leave(colyseus_room_t* room, bool consented) {
    if (!room) return;

    /* Suppress drop-handling for this room and cancel any in-flight retry. */
    if (consented) {
        room->reconnection.options.enabled = false;
    }
    room_reconnection_cancel(room);

    if (!room->transport) {
        if (room->on_leave) {
            room->on_leave(COLYSEUS_CLOSE_CONSENTED, "Already left", room->on_leave_userdata);
        }
        return;
    }

    if (colyseus_transport_is_open(room->transport)) {
        if (consented) {
            uint8_t leave_msg[] = { COLYSEUS_PROTOCOL_LEAVE_ROOM };
            colyseus_transport_send(room->transport, leave_msg, 1);
        } else {
            colyseus_transport_close(room->transport, 1000, "Leave");
        }
    } else {
        if (room->on_leave) {
            room->on_leave(COLYSEUS_CLOSE_CONSENTED, "Already left", room->on_leave_userdata);
        }
    }
}

/* Getters/Setters */
const char* colyseus_room_get_id(const colyseus_room_t* room) {
    return room ? room->room_id : NULL;
}

void colyseus_room_set_id(colyseus_room_t* room, const char* room_id) {
    if (!room) return;
    free(room->room_id);
    room->room_id = room_id ? strdup(room_id) : NULL;
}

const char* colyseus_room_get_session_id(const colyseus_room_t* room) {
    return room ? room->session_id : NULL;
}

void colyseus_room_set_session_id(colyseus_room_t* room, const char* session_id) {
    if (!room) return;
    free(room->session_id);
    room->session_id = session_id ? strdup(session_id) : NULL;
}

const char* colyseus_room_get_name(const colyseus_room_t* room) {
    return room ? room->name : NULL;
}

bool colyseus_room_is_connected(const colyseus_room_t* room) {
    return room ? room->has_joined && colyseus_transport_is_open(room->transport) : false;
}

const char* colyseus_room_get_reconnection_token(const colyseus_room_t* room) {
    return room ? room->reconnection_token : NULL;
}

/* Event handlers */
void colyseus_room_on_join(colyseus_room_t* room, colyseus_room_on_join_fn callback, void* userdata) {
    if (!room) return;
    room->on_join = callback;
    room->on_join_userdata = userdata;
}

void colyseus_room_on_state_change(colyseus_room_t* room, colyseus_room_on_state_change_fn callback, void* userdata) {
    if (!room) return;
    room->on_state_change = callback;
    room->on_state_change_userdata = userdata;
}

void colyseus_room_on_error(colyseus_room_t* room, colyseus_room_on_error_fn callback, void* userdata) {
    if (!room) return;
    room->on_error = callback;
    room->on_error_userdata = userdata;
}

void colyseus_room_on_leave(colyseus_room_t* room, colyseus_room_on_leave_fn callback, void* userdata) {
    if (!room) return;
    room->on_leave = callback;
    room->on_leave_userdata = userdata;
}

void colyseus_room_on_drop(colyseus_room_t* room, colyseus_room_on_drop_fn callback, void* userdata) {
    if (!room) return;
    room->on_drop = callback;
    room->on_drop_userdata = userdata;
}

void colyseus_room_on_reconnect(colyseus_room_t* room, colyseus_room_on_reconnect_fn callback, void* userdata) {
    if (!room) return;
    room->on_reconnect = callback;
    room->on_reconnect_userdata = userdata;
}

void colyseus_room_set_reconnection_options(colyseus_room_t* room, const colyseus_reconnection_options_t* options) {
    if (!room || !options) return;
    room->reconnection.options = *options;
}

void colyseus_room_get_reconnection_options(const colyseus_room_t* room, colyseus_reconnection_options_t* out_options) {
    if (!room || !out_options) return;
    *out_options = room->reconnection.options;
}

bool colyseus_room_is_reconnecting(const colyseus_room_t* room) {
    return room ? room->reconnection.is_reconnecting : false;
}

/* Helper to find or create a message handler */
static colyseus_message_handler_t* room_find_or_create_handler(colyseus_room_t* room, char* key) {
    colyseus_message_handler_t* handler = NULL;
    HASH_FIND_STR(room->message_handlers, key, handler);

    if (!handler) {
        handler = malloc(sizeof(colyseus_message_handler_t));
        memset(handler, 0, sizeof(colyseus_message_handler_t));
        handler->key = key;
        HASH_ADD_KEYPTR(hh, room->message_handlers, handler->key, strlen(handler->key), handler);
    } else {
        free(key);
    }

    return handler;
}

/* Message handlers - default (msgpack reader) */
void colyseus_room_on_message(colyseus_room_t* room, const char* type, colyseus_room_on_message_fn callback, void* userdata) {
    if (!room) return;
    char* key = room_get_message_key_str(type);
    colyseus_message_handler_t* handler = room_find_or_create_handler(room, key);
    handler->callback = callback;
    handler->userdata = userdata;
}

void colyseus_room_on_message_int(colyseus_room_t* room, int type, colyseus_room_on_message_fn callback, void* userdata) {
    if (!room) return;
    char* key = room_get_message_key_int(type);
    colyseus_message_handler_t* handler = room_find_or_create_handler(room, key);
    handler->callback = callback;
    handler->userdata = userdata;
}

void colyseus_room_on_message_any(colyseus_room_t* room, colyseus_room_on_message_fn callback, void* userdata) {
    if (!room) return;
    room->on_message_any = callback;
    room->on_message_any_userdata = userdata;
}

void colyseus_room_on_message_any_with_type(colyseus_room_t* room, colyseus_room_on_message_with_type_fn callback, void* userdata) {
    if (!room) return;
    room->on_message_any_with_type = callback;
    room->on_message_any_with_type_userdata = userdata;
}

/* Message handlers - encoded (raw msgpack bytes) */
void colyseus_room_on_message_encoded(colyseus_room_t* room, const char* type, colyseus_room_on_message_encoded_fn callback, void* userdata) {
    if (!room) return;
    char* key = room_get_message_key_str(type);
    colyseus_message_handler_t* handler = room_find_or_create_handler(room, key);
    handler->callback_encoded = callback;
    handler->userdata_encoded = userdata;
}

void colyseus_room_on_message_int_encoded(colyseus_room_t* room, int type, colyseus_room_on_message_encoded_fn callback, void* userdata) {
    if (!room) return;
    char* key = room_get_message_key_int(type);
    colyseus_message_handler_t* handler = room_find_or_create_handler(room, key);
    handler->callback_encoded = callback;
    handler->userdata_encoded = userdata;
}

void colyseus_room_on_message_any_encoded(colyseus_room_t* room, colyseus_room_on_message_encoded_fn callback, void* userdata) {
    if (!room) return;
    room->on_message_any_encoded = callback;
    room->on_message_any_encoded_userdata = userdata;
}

void colyseus_room_on_message_any_with_type_encoded(colyseus_room_t* room, colyseus_room_on_message_with_type_encoded_fn callback, void* userdata) {
    if (!room) return;
    room->on_message_any_with_type_encoded = callback;
    room->on_message_any_with_type_encoded_userdata = userdata;
}

/* Message handlers - bytes (raw bytes, ROOM_DATA_BYTES) */
void colyseus_room_on_message_bytes(colyseus_room_t* room, const char* type, colyseus_room_on_message_bytes_fn callback, void* userdata) {
    if (!room) return;
    char* key = room_get_message_key_str(type);
    colyseus_message_handler_t* handler = room_find_or_create_handler(room, key);
    handler->callback_bytes = callback;
    handler->userdata_bytes = userdata;
}

void colyseus_room_on_message_int_bytes(colyseus_room_t* room, int type, colyseus_room_on_message_bytes_fn callback, void* userdata) {
    if (!room) return;
    char* key = room_get_message_key_int(type);
    colyseus_message_handler_t* handler = room_find_or_create_handler(room, key);
    handler->callback_bytes = callback;
    handler->userdata_bytes = userdata;
}

void colyseus_room_on_message_any_bytes(colyseus_room_t* room, colyseus_room_on_message_bytes_fn callback, void* userdata) {
    if (!room) return;
    room->on_message_any_bytes = callback;
    room->on_message_any_bytes_userdata = userdata;
}

void colyseus_room_on_message_any_with_type_bytes(colyseus_room_t* room, colyseus_room_on_message_with_type_bytes_fn callback, void* userdata) {
    if (!room) return;
    room->on_message_any_with_type_bytes = callback;
    room->on_message_any_with_type_bytes_userdata = userdata;
}

/* Helper function to encode msgpack string */
static size_t msgpack_encode_string(uint8_t* dest, const char* str, size_t str_len) {
    if (str_len <= 31) {
        /* fixstr: 0xa0 | length */
        dest[0] = 0xa0 | (uint8_t)str_len;
        memcpy(dest + 1, str, str_len);
        return 1 + str_len;
    } else if (str_len <= 255) {
        /* str8: 0xd9, length (1 byte), string */
        dest[0] = 0xd9;
        dest[1] = (uint8_t)str_len;
        memcpy(dest + 2, str, str_len);
        return 2 + str_len;
    } else if (str_len <= 65535) {
        /* str16: 0xda, length (2 bytes big-endian), string */
        dest[0] = 0xda;
        dest[1] = (uint8_t)(str_len >> 8);
        dest[2] = (uint8_t)(str_len & 0xff);
        memcpy(dest + 3, str, str_len);
        return 3 + str_len;
    } else {
        /* str32: 0xdb, length (4 bytes big-endian), string */
        dest[0] = 0xdb;
        dest[1] = (uint8_t)(str_len >> 24);
        dest[2] = (uint8_t)((str_len >> 16) & 0xff);
        dest[3] = (uint8_t)((str_len >> 8) & 0xff);
        dest[4] = (uint8_t)(str_len & 0xff);
        memcpy(dest + 5, str, str_len);
        return 5 + str_len;
    }
}

/* Helper function to encode msgpack integer */
static size_t msgpack_encode_number(uint8_t* dest, int value) {
    if (value >= 0 && value <= 127) {
        /* Positive fixint: single byte */
        dest[0] = (uint8_t)value;
        return 1;
    } else if (value >= -32 && value < 0) {
        /* Negative fixint: 0xe0 to 0xff */
        dest[0] = (uint8_t)(0xe0 | (value & 0x1f));
        return 1;
    } else if (value >= -128 && value <= 127) {
        /* int8: 0xd0, value */
        dest[0] = 0xd0;
        dest[1] = (uint8_t)value;
        return 2;
    } else if (value >= -32768 && value <= 32767) {
        /* int16: 0xd1, value (2 bytes big-endian) */
        dest[0] = 0xd1;
        dest[1] = (uint8_t)(value >> 8);
        dest[2] = (uint8_t)(value & 0xff);
        return 3;
    } else {
        /* int32: 0xd2, value (4 bytes big-endian) */
        dest[0] = 0xd2;
        dest[1] = (uint8_t)(value >> 24);
        dest[2] = (uint8_t)((value >> 16) & 0xff);
        dest[3] = (uint8_t)((value >> 8) & 0xff);
        dest[4] = (uint8_t)(value & 0xff);
        return 5;
    }
}

/* Decode helpers */
static float decode_number(const uint8_t* bytes, size_t* offset) {
    colyseus_iterator_t it = { .offset = (int)*offset };
    float result = colyseus_decode_number(bytes, &it);
    *offset = (size_t)it.offset;
    return result;
}

static char* decode_string(const uint8_t* bytes, size_t* offset) {
    colyseus_iterator_t it = { .offset = (int)*offset };
    char* result = colyseus_decode_string(bytes, &it);
    *offset = (size_t)it.offset;
    return result;
}

static bool decode_number_check(const uint8_t* bytes, size_t offset) {
    colyseus_iterator_t it = { .offset = (int)offset };
    return colyseus_decode_number_check(bytes, &it);
}

/* Send messages (colyseus message - default, encodes automatically) */
void colyseus_room_send(colyseus_room_t* room, const char* type, colyseus_message_t* payload) {
    if (!room || !type || !payload) return;

    size_t encoded_len = 0;
    uint8_t* encoded_data = colyseus_message_encode(payload, &encoded_len);

    if (encoded_data && encoded_len > 0) {
        colyseus_room_send_encoded(room, type, encoded_data, encoded_len);
    }
}

void colyseus_room_send_int(colyseus_room_t* room, int type, colyseus_message_t* payload) {
    if (!room || !payload) return;

    size_t encoded_len = 0;
    uint8_t* encoded_data = colyseus_message_encode(payload, &encoded_len);

    if (encoded_data && encoded_len > 0) {
        colyseus_room_send_int_encoded(room, type, encoded_data, encoded_len);
    }
}

/* Send messages (pre-encoded msgpack bytes) */
void colyseus_room_send_encoded(colyseus_room_t* room, const char* type, const uint8_t* message, size_t length) {
    if (!room || !type) return;

    /* Build message: [PROTOCOL][msgpack-encoded type string][message] */
    size_t type_len = strlen(type);

    /* Calculate msgpack encoding size */
    size_t msgpack_size = (type_len <= 31) ? (1 + type_len) :
                          (type_len <= 255) ? (2 + type_len) :
                          (type_len <= 65535) ? (3 + type_len) :
                          (5 + type_len);

    size_t total_len = 1 + msgpack_size + length;
    uint8_t* data = malloc(total_len);
    if (!data) return;

    /* Protocol byte */
    data[0] = COLYSEUS_PROTOCOL_ROOM_DATA;

    /* Msgpack-encoded type string */
    size_t encoded_len = msgpack_encode_string(data + 1, type, type_len);

    /* Message payload */
    if (message && length > 0) {
        memcpy(data + 1 + encoded_len, message, length);
    }

    room_send_or_enqueue(room, data, total_len);
    free(data);
}

void colyseus_room_send_int_encoded(colyseus_room_t* room, int type, const uint8_t* message, size_t length) {
    if (!room) return;

    /* Build message: [PROTOCOL][msgpack-encoded type integer][message] */
    uint8_t type_buffer[5];  /* Max size for int32 msgpack encoding */
    size_t type_encoded_size = msgpack_encode_number(type_buffer, type);

    size_t total_len = 1 + type_encoded_size + length;
    uint8_t* data = malloc(total_len);
    if (!data) return;

    /* Protocol byte */
    data[0] = COLYSEUS_PROTOCOL_ROOM_DATA;

    /* Msgpack-encoded type integer */
    memcpy(data + 1, type_buffer, type_encoded_size);

    /* Message payload */
    if (message && length > 0) {
        memcpy(data + 1 + type_encoded_size, message, length);
    }

    room_send_or_enqueue(room, data, total_len);
    free(data);
}

/* ============================================================================
 * Request/response (ROOM_REQUEST / ROOM_RESPONSE)
 * ============================================================================ */

uint32_t colyseus_room_request_encoded(colyseus_room_t* room, const char* type,
    const uint8_t* payload, size_t payload_length,
    colyseus_room_on_response_fn callback, void* userdata)
{
    if (!room || !type || !callback) return 0;

    uint32_t request_id = room->next_request_id++;

    /* Build frame: [ROOM_REQUEST][requestId varint][type string][payload?] */
    uint8_t request_id_buffer[5];
    size_t request_id_size = msgpack_encode_number(request_id_buffer, (int)request_id);

    size_t type_len = strlen(type);
    size_t type_size = (type_len <= 31) ? (1 + type_len) :
                       (type_len <= 255) ? (2 + type_len) :
                       (type_len <= 65535) ? (3 + type_len) :
                       (5 + type_len);

    size_t total_len = 1 + request_id_size + type_size + payload_length;
    uint8_t* data = malloc(total_len);
    if (!data) return 0;

    data[0] = COLYSEUS_PROTOCOL_ROOM_REQUEST;
    memcpy(data + 1, request_id_buffer, request_id_size);
    size_t encoded_type_len = msgpack_encode_string(data + 1 + request_id_size, type, type_len);

    if (payload && payload_length > 0) {
        memcpy(data + 1 + request_id_size + encoded_type_len, payload, payload_length);
    }

    colyseus_pending_request_t* entry = malloc(sizeof(colyseus_pending_request_t));
    if (!entry) { free(data); return 0; }
    entry->request_id = request_id;
    entry->callback = callback;
    entry->userdata = userdata;
    HASH_ADD(hh, room->pending_requests, request_id, sizeof(uint32_t), entry);

    /* reliable + offline: buffered frames flush on (re)connect */
    room_send_or_enqueue(room, data, total_len);
    free(data);

    return request_id;
}

uint32_t colyseus_room_request(colyseus_room_t* room, const char* type, colyseus_message_t* payload,
    colyseus_room_on_response_fn callback, void* userdata)
{
    if (!room || !type || !callback) return 0;

    size_t encoded_len = 0;
    uint8_t* encoded_data = payload ? colyseus_message_encode(payload, &encoded_len) : NULL;

    return colyseus_room_request_encoded(room, type, encoded_data, encoded_len, callback, userdata);
}

void colyseus_room_cancel_request(colyseus_room_t* room, uint32_t request_id) {
    if (!room) return;

    colyseus_pending_request_t* entry = NULL;
    HASH_FIND(hh, room->pending_requests, &request_id, sizeof(uint32_t), entry);
    if (entry) {
        HASH_DEL(room->pending_requests, entry);
        free(entry);
    }
}

static void room_reject_all_pending_requests(colyseus_room_t* room, const char* reason) {
    colyseus_pending_request_t *entry, *tmp;
    HASH_ITER(hh, room->pending_requests, entry, tmp) {
        HASH_DEL(room->pending_requests, entry);
        entry->callback(false, NULL, reason, entry->userdata);
        free(entry);
    }
}

/* Send raw bytes (ROOM_DATA_BYTES protocol) */
void colyseus_room_send_bytes(colyseus_room_t* room, const char* type, const uint8_t* message, size_t length) {
    if (!room || !type) return;

    /* Build message: [PROTOCOL][msgpack-encoded type string][raw bytes] */
    size_t type_len = strlen(type);

    /* Calculate msgpack encoding size */
    size_t msgpack_size = (type_len <= 31) ? (1 + type_len) :
                          (type_len <= 255) ? (2 + type_len) :
                          (type_len <= 65535) ? (3 + type_len) :
                          (5 + type_len);

    size_t total_len = 1 + msgpack_size + length;
    uint8_t* data = malloc(total_len);
    if (!data) return;

    /* Protocol byte */
    data[0] = COLYSEUS_PROTOCOL_ROOM_DATA_BYTES;

    /* Msgpack-encoded type string */
    size_t encoded_len = msgpack_encode_string(data + 1, type, type_len);

    /* Raw bytes payload */
    if (message && length > 0) {
        memcpy(data + 1 + encoded_len, message, length);
    }

    room_send_or_enqueue(room, data, total_len);
    free(data);
}

void colyseus_room_send_int_bytes(colyseus_room_t* room, int type, const uint8_t* message, size_t length) {
    if (!room) return;

    /* Build message: [PROTOCOL][msgpack-encoded type integer][raw bytes] */
    uint8_t type_buffer[5];  /* Max size for int32 msgpack encoding */
    size_t type_encoded_size = msgpack_encode_number(type_buffer, type);

    size_t total_len = 1 + type_encoded_size + length;
    uint8_t* data = malloc(total_len);
    if (!data) return;

    /* Protocol byte */
    data[0] = COLYSEUS_PROTOCOL_ROOM_DATA_BYTES;

    /* Msgpack-encoded type integer */
    memcpy(data + 1, type_buffer, type_encoded_size);

    /* Raw bytes payload */
    if (message && length > 0) {
        memcpy(data + 1 + type_encoded_size, message, length);
    }

    room_send_or_enqueue(room, data, total_len);
    free(data);
}

/* Transport event handlers */
static void room_on_transport_open(void* userdata) {
    (void)userdata;
    /* Connection established, wait for JOIN_ROOM from server */
}

static void room_on_transport_message(const uint8_t* data, size_t length, void* userdata) {
    colyseus_room_t* room = (colyseus_room_t*)userdata;

    if (length == 0) return;

    {
        const char* dbg = getenv("COLYSEUS_WS_DEBUG");
        if (dbg && dbg[0] && dbg[0] != '0') {
            size_t max = length < 64 ? length : 64;
            fprintf(stderr, "[ROOM] transport_message len=%zu bytes:", length);
            for (size_t i = 0; i < max; i++) fprintf(stderr, " %02x", data[i]);
            if (length > max) fprintf(stderr, " ...");
            fprintf(stderr, "\n");
            fflush(stderr);
        }
    }

    /* Strip modifier bits (bits 5..7) so the dispatch below stays
     * modifier-agnostic; consume any modifier-attached prefix bytes here. */
    uint8_t raw_byte = data[0];
    colyseus_protocol_t code = (colyseus_protocol_t)(raw_byte & COLYSEUS_PROTOCOL_CODE_MASK);
    size_t offset = 1;

    if (raw_byte & COLYSEUS_PROTOCOL_MODIFIER_TIMED) {
        /* [uint32 sNow][uint32 inputSeq] — server time (ms since room start)
         * + last PROCESSED input seq. Consumed here; feeds the room clock +
         * input ack once the input layer is ported. */
        offset += 8;
    }

    switch (code) {
        case COLYSEUS_PROTOCOL_JOIN_ROOM: {
            /* Decode reconnection token (string with length prefix) */
            if (offset < length) {
                uint8_t token_len = data[offset];
                offset++;

                if (offset + token_len <= length) {
                    free(room->reconnection_token);
                    room->reconnection_token = malloc(token_len + 1);
                    if (room->reconnection_token) {
                        memcpy(room->reconnection_token, data + offset, token_len);
                        room->reconnection_token[token_len] = '\0';
                    }
                    offset += token_len;
                }
            }

            /* Decode serializer ID (string with length prefix) */
            if (offset < length) {
                uint8_t serializer_len = data[offset];
                offset++;

                if (offset + serializer_len <= length) {
                    free(room->serializer_id);
                    room->serializer_id = malloc(serializer_len + 1);
                    if (room->serializer_id) {
                        memcpy(room->serializer_id, data + offset, serializer_len);
                        room->serializer_id[serializer_len] = '\0';
                    }
                    offset += serializer_len;
                }
            }

            bool is_reconnect = room->has_joined;

            /* State reflection is length-prefixed: the schema handshake must
             * not read past it into the trailing tagged-section bytes. A
             * zero length means reconnect (the serializer already has state). */
            size_t state_reflection_len = (offset < length)
                ? (size_t)decode_number(data, &offset)
                : 0;
            size_t reflection_end = offset + state_reflection_len;

            /* On first join only: instantiate serializer + apply handshake.
             * On reconnect, the server replays JOIN_ROOM with just the
             * reconnection token + serializer ID (skipHandshake=1) and we
             * keep the existing serializer state intact. */
            if (!is_reconnect) {
                if (room->serializer_id && strcmp(room->serializer_id, "schema") == 0) {
                    /* Create serializer - pass NULL if no vtable, handshake will auto-detect */
                    room->serializer = colyseus_schema_serializer_create(room->state_vtable);

                    if (state_reflection_len > 0 && room->serializer) {
                        /* bounded: the reflection decoder reads until `length` */
                        colyseus_schema_serializer_handshake(room->serializer, data, reflection_end, (int)offset);

                        /* If auto-detection happened, copy the vtable reference to room */
                        if (!room->state_vtable) {
                            const colyseus_schema_vtable_t* detected_vtable =
                                colyseus_schema_serializer_get_vtable(room->serializer);
                            if (detected_vtable) {
                                room->state_vtable = detected_vtable;
                            }
                        }
                    }
                } else if (room->serializer_id && strcmp(room->serializer_id, "fossil-delta") == 0) {
                    fprintf(stderr, "Error: FossilDelta serialization has been deprecated.\n");
                }
                /* else: "none" serializer or unknown - no state handling */

                room->has_joined = true;
                room->joined_at_ms = colyseus_monotonic_ms();

                if (room->on_join) {
                    room->on_join(room->on_join_userdata);
                }
            }

            offset = reflection_end;

            /* Trailing tagged sections: [tag byte][length varint][payload].
             * Unknown tags are skipped via length (forward-compatible).
             * INPUT_REFLECTION / INPUT_OPTIONS are consumed by the input
             * layer once ported. */
            while (offset < length) {
                offset++; /* tag (see colyseus_handshake_section_t) */
                size_t section_len = (size_t)decode_number(data, &offset);
                offset += section_len;
            }

            /* Acknowledge JOIN_ROOM */
            uint8_t ack[] = { COLYSEUS_PROTOCOL_JOIN_ROOM };
            colyseus_transport_send(room->transport, ack, 1);

            if (is_reconnect) {
                /* Tell the worker the attempt succeeded, flush any buffered
                 * messages, then fire on_reconnect. */
                room_reconnection_signal_success(room);
                room_flush_message_queue(room);
                if (room->on_reconnect) {
                    room->on_reconnect(room->on_reconnect_userdata);
                }
            }
            break;
        }

        case COLYSEUS_PROTOCOL_ERROR: {
            /* Decode error code and message */
            int error_code = (int)decode_number(data, &offset);
            char* error_message = decode_string(data, &offset);

            if (room->on_error) {
                room->on_error(error_code, error_message ? error_message : "Unknown error", room->on_error_userdata);
            }

            free(error_message);
            break;
        }

        case COLYSEUS_PROTOCOL_LEAVE_ROOM: {
            colyseus_room_leave(room, false);
            break;
        }

        case COLYSEUS_PROTOCOL_ROOM_STATE: {
            /* Handle full state */
            if (room->serializer) {
                colyseus_schema_serializer_set_state(room->serializer, data, length, (int)offset);
            }

            if (room->on_state_change) {
                room->on_state_change(room->on_state_change_userdata);
            }
            break;
        }

        case COLYSEUS_PROTOCOL_ROOM_STATE_PATCH: {
            /* Handle state patch */
            if (room->serializer) {
                colyseus_schema_serializer_patch(room->serializer, data, length, (int)offset);
            }

            if (room->on_state_change) {
                room->on_state_change(room->on_state_change_userdata);
            }
            break;
        }

        case COLYSEUS_PROTOCOL_ROOM_DATA: {
            /* Decode message type and msgpack data */
            if (length > offset) {
                char type_str[256] = {0};

                if (decode_number_check(data, offset)) {
                    /* Numeric type */
                    int type_num = (int)decode_number(data, &offset);
                    snprintf(type_str, sizeof(type_str), "i%d", type_num);
                } else {
                    /* String type */
                    char* decoded_type = decode_string(data, &offset);
                    if (decoded_type) {
                        strncpy(type_str, decoded_type, sizeof(type_str) - 1);
                        free(decoded_type);
                    }
                }

                /* Dispatch the msgpack message */
                if (strlen(type_str) > 0) {
                    room_dispatch_message(room, type_str, data + offset, length - offset);
                }
            }
            break;
        }

        case COLYSEUS_PROTOCOL_ROOM_DATA_BYTES: {
            /* Decode message type and raw bytes data */
            if (length > offset) {
                char type_str[256] = {0};

                if (decode_number_check(data, offset)) {
                    /* Numeric type */
                    int type_num = (int)decode_number(data, &offset);
                    snprintf(type_str, sizeof(type_str), "i%d", type_num);
                } else {
                    /* String type */
                    char* decoded_type = decode_string(data, &offset);
                    if (decoded_type) {
                        strncpy(type_str, decoded_type, sizeof(type_str) - 1);
                        free(decoded_type);
                    }
                }

                /* Dispatch the raw bytes message */
                if (strlen(type_str) > 0) {
                    room_dispatch_message_bytes(room, type_str, data + offset, length - offset);
                }
            }
            break;
        }

        case COLYSEUS_PROTOCOL_ROOM_RESPONSE: {
            /* reply to a pending colyseus_room_request() */
            uint32_t request_id = (uint32_t)decode_number(data, &offset);
            if (offset >= length) break;
            uint8_t status = data[offset++];

            colyseus_pending_request_t* entry = NULL;
            HASH_FIND(hh, room->pending_requests, &request_id, sizeof(uint32_t), entry);

            /* already answered (e.g. cancelled) or unknown id — ignore */
            if (entry) {
                HASH_DEL(room->pending_requests, entry);

                colyseus_message_reader_t* reader = (length > offset)
                    ? colyseus_message_reader_create(data + offset, length - offset)
                    : NULL;

                /* the ONE place the wire's three statuses collapse into the
                 * (ok, reader, error) outcome — see colyseus_room_on_response_fn */
                entry->callback(
                    status == COLYSEUS_RESPONSE_OK,
                    reader,
                    status == COLYSEUS_RESPONSE_ERROR ? "request faulted" : NULL,
                    entry->userdata);

                if (reader) colyseus_message_reader_free(reader);
                free(entry);
            }
            break;
        }

        default:
            fprintf(stderr, "Unknown protocol message: %d\n", code);
            break;
    }
}

void colyseus_room_process_message(colyseus_room_t* room, const uint8_t* data, size_t length) {
    if (!room || !data || length == 0) return;
    room_on_transport_message(data, length, room);
}

static void room_on_transport_close(int code, const char* reason, void* userdata) {
    colyseus_room_t* room = (colyseus_room_t*)userdata;

    /* in-flight requests can't be answered on a closed socket */
    room_reject_all_pending_requests(room, "connection closed before a response was received.");

    if (!room->has_joined) {
        /* Connection died before the first JOIN_ROOM — report as error to the
         * original matchmake caller. Tear down the serializer if any. */
        if (room->serializer) {
            colyseus_schema_serializer_teardown(room->serializer);
        }
        fprintf(stderr, "Room connection closed unexpectedly: %s\n", reason);
        if (room->on_error) {
            room->on_error(code, reason, room->on_error_userdata);
        }
        return;
    }

    /* A reconnect attempt failed — wake the worker so it can try again or
     * give up. Don't fire on_drop/on_leave here; the worker drives that. */
    if (room->reconnection.is_reconnecting) {
        room_reconnection_signal_attempt_done(room);
        return;
    }

    bool reconnectable = room->reconnection.options.enabled
                      && room_close_code_is_drop(code);

    if (reconnectable) {
        if (room->on_drop) {
            room->on_drop(code, reason, room->on_drop_userdata);
        }
        room_handle_reconnection(room, code, reason);
        return;
    }

    /* Final close — tear down state and notify. */
    if (room->serializer) {
        colyseus_schema_serializer_teardown(room->serializer);
    }
    if (room->on_leave) {
        room->on_leave(code, reason, room->on_leave_userdata);
    }
}

static void room_on_transport_error(const char* error, void* userdata) {
    colyseus_room_t* room = (colyseus_room_t*)userdata;

    fprintf(stderr, "Room transport error: %s\n", error);
    if (room->on_error) {
        room->on_error(-1, error, room->on_error_userdata);
    }
}

/* Helper functions */
static void room_dispatch_message(colyseus_room_t* room, const char* type, const uint8_t* message, size_t length) {
    char* key = room_get_message_key_str(type);

    colyseus_message_handler_t* handler = NULL;
    HASH_FIND_STR(room->message_handlers, key, handler);

    colyseus_message_reader_t* reader = NULL;
    bool reader_created = false;

    /* Call type-specific handler if registered */
    if (handler) {
        /* Default callback (msgpack reader) */
        if (handler->callback) {
            if (!reader_created) {
                reader = colyseus_message_reader_create(message, length);
                reader_created = true;
            }
            handler->callback(reader, handler->userdata);
        }

        /* Encoded callback (raw msgpack bytes) */
        if (handler->callback_encoded) {
            handler->callback_encoded(message, length, handler->userdata_encoded);
        }
    }

    /* Call wildcard handlers */

    /* Default wildcard (msgpack reader) */
    if (room->on_message_any) {
        if (!reader_created) {
            reader = colyseus_message_reader_create(message, length);
            reader_created = true;
        }
        room->on_message_any(reader, room->on_message_any_userdata);
    }

    /* Default wildcard with type (msgpack reader) */
    if (room->on_message_any_with_type) {
        if (!reader_created) {
            reader = colyseus_message_reader_create(message, length);
            reader_created = true;
        }
        room->on_message_any_with_type(type, reader, room->on_message_any_with_type_userdata);
    }

    /* Encoded wildcard (raw msgpack bytes) */
    if (room->on_message_any_encoded) {
        room->on_message_any_encoded(message, length, room->on_message_any_encoded_userdata);
    }

    /* Encoded wildcard with type (raw msgpack bytes) */
    if (room->on_message_any_with_type_encoded) {
        room->on_message_any_with_type_encoded(type, message, length, room->on_message_any_with_type_encoded_userdata);
    }

    /* Free reader if created */
    if (reader) {
        colyseus_message_reader_free(reader);
    }

    free(key);
}

/* Dispatch raw bytes message (ROOM_DATA_BYTES protocol) */
static void room_dispatch_message_bytes(colyseus_room_t* room, const char* type, const uint8_t* message, size_t length) {
    char* key = room_get_message_key_str(type);

    colyseus_message_handler_t* handler = NULL;
    HASH_FIND_STR(room->message_handlers, key, handler);

    /* Call type-specific bytes handler if registered */
    if (handler && handler->callback_bytes) {
        handler->callback_bytes(message, length, handler->userdata_bytes);
    }

    /* Call wildcard bytes handlers */
    if (room->on_message_any_bytes) {
        room->on_message_any_bytes(message, length, room->on_message_any_bytes_userdata);
    }

    if (room->on_message_any_with_type_bytes) {
        room->on_message_any_with_type_bytes(type, message, length, room->on_message_any_with_type_bytes_userdata);
    }

    free(key);
}

static char* room_get_message_key_str(const char* type) {
    return strdup(type);
}

static char* room_get_message_key_int(int type) {
    char buf[32];
    snprintf(buf, sizeof(buf), "i%d", type);
    return strdup(buf);
}
