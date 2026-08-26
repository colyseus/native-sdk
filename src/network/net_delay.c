#include "colyseus/net_delay.h"

#include "colyseus/room.h"
#include "colyseus/room_clock.h"
#include "colyseus/transport.h"
#include "colyseus/protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* On the web the browser delivers WS events on the one and only thread, so
 * the inbound lock compiles away — same precedent as room.c's reconnection
 * worker being a no-op on Emscripten. Native keeps the pthread mutex (the
 * WS tick thread fills the inbound queue; pump drains it on main). */
#ifdef __EMSCRIPTEN__
#define ND_LOCK()   ((void)0)
#define ND_UNLOCK() ((void)0)
#else
#include <pthread.h>
static pthread_mutex_t g_nd_in_mu = PTHREAD_MUTEX_INITIALIZER;
#define ND_LOCK()   pthread_mutex_lock(&g_nd_in_mu)
#define ND_UNLOCK() pthread_mutex_unlock(&g_nd_in_mu)
#endif

typedef struct nd_packet {
    double deliver_at;
    uint8_t* data;              /* owned */
    size_t length;
    bool unreliable;
    struct nd_packet* next;
} nd_packet_t;

typedef struct {
    /* Wraps live in static storage, never freed: the WS tick thread can hold
     * a wrap pointer (events.userdata) across a main-thread retire, so a
     * heap wrap would be a use-after-free. A retired slot just flips in_use;
     * tramps re-check it under the lock and bail. */
    bool in_use;
    colyseus_transport_t* transport;
    /* the room this wrap belongs to — reconnection replaces the room's
     * transport, and a wrap whose room moved on is retirable (its transport
     * was destroyed by room.c before the new one was built) */
    const colyseus_room_t* room;
    void (*inner_send)(colyseus_transport_t*, const uint8_t*, size_t);
    void (*inner_send_unreliable)(colyseus_transport_t*, const uint8_t*, size_t);
    colyseus_transport_on_message_fn inner_on_message;
    /* events.userdata is SHARED by on_open/on_message/on_close/on_error, and
     * the swap points it at this wrap — so every OTHER handler must be
     * trampolined too, or on_close casts the wrap as a room and crashes. */
    colyseus_transport_on_open_fn inner_on_open;
    colyseus_transport_on_close_fn inner_on_close;
    colyseus_transport_on_error_fn inner_on_error;
    void* inner_userdata;
    /* set on the tick thread by on_close; pump then retires instead of sends */
    volatile bool closed;
    /* queue inbound even at zero delay — the thread-serialization mode */
    bool queue_inbound;
    nd_packet_t *in_head, *in_tail, *out_head, *out_tail;
    double in_last, out_last;
} nd_wrap_t;

#define ND_MAX_WRAPS 32
static nd_wrap_t g_wraps[ND_MAX_WRAPS];
static double g_delay_ms = 0;
static double g_jitter_ms = 0;
static unsigned g_rng = 0x5EED;

/* Half the configured round trip, plus symmetric U[-jitter/2, +jitter/2] —
 * the same split the JS SDK's __net() applies, so a given number means the
 * same RTT on every SDK. Jitter perturbs spacing; nd_enqueue's monotonic
 * clamp keeps the wire from reordering. */
static double nd_one_way(void) {
    g_rng = g_rng * 1664525u + 1013904223u;                    /* LCG */
    double r = (double)(g_rng >> 8) / (double)(1u << 24);
    return (g_delay_ms + (r * 2.0 - 1.0) * g_jitter_ms) / 2.0;
}

static nd_wrap_t* nd_wrap_for(colyseus_transport_t* t) {
    for (int i = 0; i < ND_MAX_WRAPS; i++) {
        /* pointer match alone lies: a reconnect can malloc the fresh
         * transport at a freed one's address — live means swap in place */
        if (g_wraps[i].in_use && g_wraps[i].transport == t
            && t->events.userdata == (void*)&g_wraps[i]) return &g_wraps[i];
    }
    return NULL;
}

static void nd_enqueue(nd_packet_t** head, nd_packet_t** tail, double* last,
    const uint8_t* data, size_t length, bool unreliable) {
    /* OOM drops the packet — for the reliable channel that is a schema
     * desync, and delivering out of queue order would be one too. All that
     * is left is to be loud about it. */
    nd_packet_t* p = malloc(sizeof(nd_packet_t));
    if (!p) { fprintf(stderr, "colyseus: netdelay OOM — packet dropped\n"); return; }
    p->data = malloc(length > 0 ? length : 1);
    if (!p->data) {
        free(p);
        fprintf(stderr, "colyseus: netdelay OOM — packet dropped\n");
        return;
    }
    memcpy(p->data, data, length);
    p->length = length;
    p->unreliable = unreliable;
    p->next = NULL;
    double at = colyseus_room_clock_now(NULL) + nd_one_way();
    if (at < *last) at = *last;   /* the wire never reorders */
    *last = at;
    p->deliver_at = at;
    if (*tail) (*tail)->next = p; else *head = p;
    *tail = p;
}

static void nd_send_tramp(colyseus_transport_t* t, const uint8_t* data, size_t length) {
    nd_wrap_t* w = nd_wrap_for(t);
    if (!w) return;
    if (g_delay_ms <= 0 && g_jitter_ms <= 0 && !w->out_head) {
        w->inner_send(t, data, length);
        return;
    }
    nd_enqueue(&w->out_head, &w->out_tail, &w->out_last, data, length, false);
}

static void nd_send_unreliable_tramp(colyseus_transport_t* t, const uint8_t* data, size_t length) {
    nd_wrap_t* w = nd_wrap_for(t);
    if (!w) return;
    if (g_delay_ms <= 0 && g_jitter_ms <= 0 && !w->out_head) {
        if (w->inner_send_unreliable) w->inner_send_unreliable(t, data, length);
        return;
    }
    nd_enqueue(&w->out_head, &w->out_tail, &w->out_last, data, length, true);
}

/* close/error/open pass straight through with the ROOM's userdata restored —
 * only messages are delayed. (A delayed close would also strand the queues:
 * nothing pumps a transport the room already tore down.) Each tramp re-checks
 * in_use under the lock: the slot may have been retired (or even reused)
 * between the transport reading userdata and this running. */
static void nd_on_open_tramp(void* userdata) {
    nd_wrap_t* w = (nd_wrap_t*)userdata;
    ND_LOCK();
    colyseus_transport_on_open_fn fn = w->in_use ? w->inner_on_open : NULL;
    void* ud = w->inner_userdata;
    ND_UNLOCK();
    if (fn) fn(ud);
}

static void nd_on_close_tramp(int code, const char* reason, void* userdata) {
    nd_wrap_t* w = (nd_wrap_t*)userdata;
    ND_LOCK();
    colyseus_transport_on_close_fn fn = NULL;
    void* ud = NULL;
    if (w->in_use) {
        w->closed = true;
        fn = w->inner_on_close;
        ud = w->inner_userdata;
    }
    ND_UNLOCK();
    if (fn) fn(code, reason, ud);
}

static void nd_on_error_tramp(const char* error, void* userdata) {
    nd_wrap_t* w = (nd_wrap_t*)userdata;
    ND_LOCK();
    colyseus_transport_on_error_fn fn = w->in_use ? w->inner_on_error : NULL;
    void* ud = w->inner_userdata;
    ND_UNLOCK();
    if (fn) fn(error, ud);
}

static void nd_on_message_tramp(const uint8_t* data, size_t length, void* userdata) {
    nd_wrap_t* w = (nd_wrap_t*)userdata;
    colyseus_transport_on_message_fn direct_fn = NULL;
    void* direct_ud = NULL;
    ND_LOCK();
    if (w->in_use) {
        bool direct = !w->queue_inbound
            && g_delay_ms <= 0 && g_jitter_ms <= 0 && !w->in_head;
        if (direct) {
            direct_fn = w->inner_on_message;
            direct_ud = w->inner_userdata;
        } else {
            nd_enqueue(&w->in_head, &w->in_tail, &w->in_last, data, length, false);
        }
    }
    ND_UNLOCK();
    if (direct_fn) direct_fn(data, length, direct_ud);
}

static void nd_free_queue(nd_packet_t** head, nd_packet_t** tail) {
    while (*head) {
        nd_packet_t* p = *head;
        *head = p->next;
        free(p->data);
        free(p);
    }
    *tail = NULL;
}

/* Main-thread only. The slot's storage stays valid forever (static), so a
 * tick-thread tramp that already holds this wrap sees in_use == false and
 * bails instead of touching freed memory. */
static void nd_retire(nd_wrap_t* w) {
    ND_LOCK();
    w->in_use = false;
    nd_free_queue(&w->in_head, &w->in_tail);
    nd_free_queue(&w->out_head, &w->out_tail);   /* out is main-only; lists are short */
    memset(w, 0, sizeof(*w));
    ND_UNLOCK();
}

static void nd_pump_wrap(nd_wrap_t* w, double now) {
    ND_LOCK();
    bool closed = w->closed;
    ND_UNLOCK();
    if (closed) {
        /* the socket is gone — retire the slot; queued packets die with the
         * connection (that's what a drop means) */
        nd_retire(w);
        return;
    }
    while (w->out_head && w->out_head->deliver_at <= now) {
        nd_packet_t* p = w->out_head;
        w->out_head = p->next;
        if (!w->out_head) w->out_tail = NULL;
        if (p->unreliable && w->inner_send_unreliable) {
            w->inner_send_unreliable(w->transport, p->data, p->length);
        } else {
            w->inner_send(w->transport, p->data, p->length);
        }
        free(p->data);
        free(p);
    }
    for (;;) {
        /* pop under the lock, deliver outside it — decode can take a while */
        nd_packet_t* p = NULL;
        ND_LOCK();
        if (w->in_head && w->in_head->deliver_at <= now) {
            p = w->in_head;
            w->in_head = p->next;
            if (!w->in_head) w->in_tail = NULL;
        }
        ND_UNLOCK();
        if (!p) break;
        w->inner_on_message(p->data, p->length, w->inner_userdata);
        free(p->data);
        free(p);
    }
}

void colyseus_netdelay_wrap(struct colyseus_room* room, bool always_queue_inbound) {
    if (!room || !room->transport) return;
    colyseus_transport_t* t = room->transport;

    /* Reconnection built THIS room a new transport: wraps still pointing at
     * the old generation are inert (their transport is destroyed) — retire
     * them so the room re-wraps cleanly and slots don't leak. */
    for (int i = 0; i < ND_MAX_WRAPS; i++) {
        nd_wrap_t* stale = &g_wraps[i];
        if (!stale->in_use || stale->room != room) continue;
        /* live = same transport AND the swap still in place — the address
         * alone can belong to a NEW transport reusing the freed one's block */
        if (stale->transport == t && t->events.userdata == (void*)stale) continue;
        nd_retire(stale);   /* the dead transport can't fire events or sends */
    }

    if (nd_wrap_for(t)) return;   /* idempotent — keep the existing queues */

    nd_wrap_t* w = NULL;
    for (int i = 0; i < ND_MAX_WRAPS; i++) {
        if (!g_wraps[i].in_use) { w = &g_wraps[i]; break; }
    }
    if (!w) {
        /* Loud: for GameMaker always_queue_inbound is the thread-safety seam,
         * and silently leaving the transport direct would move decode back to
         * the WS thread. */
        fprintf(stderr, "colyseus: netdelay wrap table full (%d) — transport "
            "left direct%s\n", ND_MAX_WRAPS,
            always_queue_inbound ? " (INBOUND SERIALIZATION LOST)" : "");
        return;
    }
    memset(w, 0, sizeof(*w));
    w->transport = t;
    w->room = room;
    w->queue_inbound = always_queue_inbound;
    w->inner_send = t->send;
    w->inner_send_unreliable = t->send_unreliable;
    w->inner_on_message = t->events.on_message;
    w->inner_on_open = t->events.on_open;
    w->inner_on_close = t->events.on_close;
    w->inner_on_error = t->events.on_error;
    w->inner_userdata = t->events.userdata;
    t->send = nd_send_tramp;
    if (t->send_unreliable) t->send_unreliable = nd_send_unreliable_tramp;
    t->events.on_message = nd_on_message_tramp;
    t->events.on_open = nd_on_open_tramp;
    t->events.on_close = nd_on_close_tramp;
    t->events.on_error = nd_on_error_tramp;
    ND_LOCK();
    t->events.userdata = w;
    w->in_use = true;
    ND_UNLOCK();
}

void colyseus_netdelay_set(struct colyseus_room* room, double delay_ms, double jitter_ms) {
    g_delay_ms = delay_ms < 0 ? 0 : delay_ms;
    g_jitter_ms = jitter_ms < 0 ? 0 : jitter_ms;
    colyseus_netdelay_wrap(room, false);
}

void colyseus_netdelay_pump(void) {
    double now = colyseus_room_clock_now(NULL);
    for (int i = 0; i < ND_MAX_WRAPS; i++) {
        if (g_wraps[i].in_use) nd_pump_wrap(&g_wraps[i], now);
    }
}

int64_t colyseus_netdelay_in_flight(void) {
    int64_t n = 0;
    ND_LOCK();
    for (int i = 0; i < ND_MAX_WRAPS; i++) {
        nd_wrap_t* w = &g_wraps[i];
        if (!w->in_use) continue;
        for (nd_packet_t* p = w->in_head; p; p = p->next) n++;
        for (nd_packet_t* p = w->out_head; p; p = p->next) n++;
    }
    ND_UNLOCK();
    return n;
}

void colyseus_netdelay_unwrap(struct colyseus_transport* t) {
    for (int i = 0; i < ND_MAX_WRAPS; i++) {
        nd_wrap_t* w = &g_wraps[i];
        if (!w->in_use || w->transport != t) continue;
        t->send = w->inner_send;
        t->send_unreliable = w->inner_send_unreliable;
        t->events.on_message = w->inner_on_message;
        t->events.on_open = w->inner_on_open;
        t->events.on_close = w->inner_on_close;
        t->events.on_error = w->inner_on_error;
        t->events.userdata = w->inner_userdata;
        nd_retire(w);
        return;
    }
}

void colyseus_netdelay_drop(struct colyseus_room* room) {
    if (!room || !room->transport) return;
    /* 4010 is in the room's reconnectable set: the SDK sees a DROP, not a
     * consented leave, and its auto-reconnect engages (thread-driven on
     * native, colyseus_reconnect_poll-driven on the web build). */
    colyseus_transport_close(room->transport,
        COLYSEUS_CLOSE_MAY_TRY_RECONNECT, "injected drop");
}
