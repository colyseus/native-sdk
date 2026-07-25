#include "colyseus/predict/events.h"
#include "uthash.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* colyseus_reconciler internals we reach through the step ctx backing */
colyseus_input_handle_t* colyseus_reconciler_input_(const void* reconciler);

typedef struct {
    char* key;                      /* owned */
    void* payload;
    int seq;                        /* birth seq; -1 = UI-born */
    colyseus_input_handle_t* acked; /* sim-born: the emitting handle (watermark) */
    double at;                      /* birth instant (serverNow axis) */
    UT_hash_handle hh;
} event_entry_t;

struct colyseus_event_channel {
    colyseus_event_channel_options_t opts;
    colyseus_room_clock_t* clock;
    event_entry_t* entries;
    double cooldown_until;
};

static double channel_now(const colyseus_event_channel_t* channel) {
    return channel->clock
        ? colyseus_room_clock_server_now(channel->clock)
        : colyseus_room_clock_now(NULL);
}

colyseus_event_channel_t* colyseus_event_channel_create(
    const colyseus_event_channel_options_t* options,
    colyseus_room_clock_t* clock) {
    colyseus_event_channel_t* channel = calloc(1, sizeof(colyseus_event_channel_t));
    if (options) channel->opts = *options;
    if (channel->opts.grace_ticks <= 0) channel->opts.grace_ticks = 10;
    channel->clock = clock;
    channel->cooldown_until = -INFINITY;
    return channel;
}

static void drop_entry(colyseus_event_channel_t* channel, event_entry_t* entry, bool free_payload) {
    HASH_DEL(channel->entries, entry);
    if (free_payload && channel->opts.payload_free) channel->opts.payload_free(entry->payload);
    free(entry->key);
    free(entry);
}

void colyseus_event_channel_free(colyseus_event_channel_t* channel) {
    if (!channel) return;
    colyseus_event_channel_clear(channel);
    free(channel);
}

static bool channel_add(colyseus_event_channel_t* channel, const char* key,
    void* payload, int seq, colyseus_input_handle_t* acked) {
    event_entry_t* existing = NULL;
    HASH_FIND_STR(channel->entries, key, existing);
    if (existing) return false;   /* already pending — re-derivations don't re-fire */

    double t = channel_now(channel);
    if (channel->opts.cooldown_ms > 0) {
        if (t < channel->cooldown_until) return false;
        channel->cooldown_until = t + channel->opts.cooldown_ms;
    }

    event_entry_t* entry = calloc(1, sizeof(event_entry_t));
    entry->key = strdup(key);
    entry->payload = payload;
    entry->seq = seq;
    entry->acked = acked;
    entry->at = t;
    HASH_ADD_KEYPTR(hh, channel->entries, entry->key, strlen(entry->key), entry);

    if (channel->opts.on_predict) channel->opts.on_predict(payload, channel->opts.userdata);
    return true;
}

bool colyseus_event_channel_predict(colyseus_event_channel_t* channel,
    const char* key, void* payload) {
    if (!channel || !key) return false;
    return channel_add(channel, key, payload, -1, NULL);
}

void colyseus_step_predict(const colyseus_step_ctx_t* ctx,
    colyseus_event_channel_t* channel, const char* key, void* payload) {
    if (!ctx || !channel || !key) return;
    if (ctx->is_replay) return;   /* live-only by construction */
    colyseus_input_handle_t* handle = ctx->_memo_backing
        ? colyseus_reconciler_input_(ctx->_memo_backing)
        : NULL;
    channel_add(channel, key, payload, ctx->tick, handle);
}

bool colyseus_event_channel_has(const colyseus_event_channel_t* channel, const char* key) {
    if (!channel) return false;
    if (!key) return channel->entries != NULL;
    event_entry_t* entry = NULL;
    HASH_FIND_STR(((colyseus_event_channel_t*)channel)->entries, key, entry);
    return entry != NULL;
}

int colyseus_event_channel_pending_count(const colyseus_event_channel_t* channel) {
    return channel ? (int)HASH_COUNT(channel->entries) : 0;
}

int colyseus_event_channel_confirm(colyseus_event_channel_t* channel, const char* key) {
    if (!channel) return 0;
    int settled = 0;
    event_entry_t *entry, *tmp;
    HASH_ITER(hh, channel->entries, entry, tmp) {
        if (key != NULL && strcmp(entry->key, key) != 0) continue;
        void* payload = entry->payload;
        drop_entry(channel, entry, false);   /* removed BEFORE the callback */
        if (channel->opts.on_confirm) channel->opts.on_confirm(payload, channel->opts.userdata);
        if (channel->opts.payload_free) channel->opts.payload_free(payload);
        settled++;
    }
    if (settled == 0 && channel->opts.on_unpredicted) {
        channel->opts.on_unpredicted(key, channel->opts.userdata);
    }
    return settled;
}

static void reject_entry(colyseus_event_channel_t* channel, event_entry_t* entry) {
    void* payload = entry->payload;
    drop_entry(channel, entry, false);
    if (channel->opts.on_reject) channel->opts.on_reject(payload, channel->opts.userdata);
    if (channel->opts.payload_free) channel->opts.payload_free(payload);
}

int colyseus_event_channel_reject(colyseus_event_channel_t* channel, const char* key) {
    if (!channel) return 0;
    int rejected = 0;
    event_entry_t *entry, *tmp;
    HASH_ITER(hh, channel->entries, entry, tmp) {
        if (key != NULL && strcmp(entry->key, key) != 0) continue;
        reject_entry(channel, entry);
        rejected++;
    }
    return rejected;
}

void colyseus_event_channel_clear(colyseus_event_channel_t* channel) {
    if (!channel) return;
    event_entry_t *entry, *tmp;
    HASH_ITER(hh, channel->entries, entry, tmp) {
        drop_entry(channel, entry, true);
    }
}

void colyseus_event_channel_prune(colyseus_event_channel_t* channel) {
    if (!channel || channel->entries == NULL) return;

    /* sim-born grace auto-reject: the server processed grace ticks past the
     * prediction without confirming — the event didn't happen */
    event_entry_t *entry, *tmp;
    HASH_ITER(hh, channel->entries, entry, tmp) {
        if (entry->acked == NULL) continue;
        if (colyseus_input_handle_last_processed(entry->acked) >= entry->seq + channel->opts.grace_ticks) {
            reject_entry(channel, entry);
        }
    }

    /* wall-clock TTL — UI-born entries only (sim-born settle by progress) */
    double rtt = channel->clock ? colyseus_room_clock_smoothed_rtt(channel->clock) : 0;
    double ttl = channel->opts.ttl_ms > 0 ? channel->opts.ttl_ms : (rtt * 2 > 600 ? rtt * 2 : 600);
    double now = channel_now(channel);
    HASH_ITER(hh, channel->entries, entry, tmp) {
        if (entry->acked != NULL) continue;   /* sim-born: progress-settled */
        if (now - entry->at > ttl) reject_entry(channel, entry);
    }
}
