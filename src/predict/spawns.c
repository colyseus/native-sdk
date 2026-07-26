#include "colyseus/predict/spawns.h"
#include "uthash.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* Read a scalar field off a decoded instance (mirrors reconciler.c's read_num). */
static double spawns_field_read(const colyseus_schema_t* instance, const colyseus_field_t* f) {
    const void* p = (const char*)instance + f->offset;
    switch (f->type) {
        case COLYSEUS_FIELD_BOOLEAN: return *(const bool*)p ? 1 : 0;
        case COLYSEUS_FIELD_FLOAT32: return (double)*(const float*)p;
        case COLYSEUS_FIELD_INT8:    return (double)*(const int8_t*)p;
        case COLYSEUS_FIELD_UINT8:   return (double)*(const uint8_t*)p;
        case COLYSEUS_FIELD_INT16:   return (double)*(const int16_t*)p;
        case COLYSEUS_FIELD_UINT16:  return (double)*(const uint16_t*)p;
        case COLYSEUS_FIELD_INT32:   return (double)*(const int32_t*)p;
        case COLYSEUS_FIELD_UINT32:  return (double)*(const uint32_t*)p;
        case COLYSEUS_FIELD_INT64:   return (double)*(const int64_t*)p;
        case COLYSEUS_FIELD_UINT64:  return (double)*(const uint64_t*)p;
        case COLYSEUS_FIELD_REF:
        case COLYSEUS_FIELD_ARRAY:
        case COLYSEUS_FIELD_MAP:
        case COLYSEUS_FIELD_STRING:  return NAN;
        default:                     return *(const double*)p;
    }
}

typedef struct spawn_entry_internal {
    colyseus_spawn_entry_t pub;
    double at;                     /* spawn instant; NAN for foreign entries */
    bool accepted;
    struct spawn_entry_internal* next;   /* insertion order (fifo walk) */
    UT_hash_handle hh;             /* by id */
    UT_hash_handle hh_server;      /* by server pointer (confirmed only) */
} spawn_entry_internal_t;

struct colyseus_spawns {
    colyseus_spawns_options_t opts;
    colyseus_room_clock_t* clock;
    spawn_entry_internal_t* by_id;       /* hash by pub.id */
    spawn_entry_internal_t* by_server;   /* hash by pub.server */
    spawn_entry_internal_t* head;        /* insertion order */
    spawn_entry_internal_t* tail;
    int next_id;
    double last_tick_at;
    bool has_last_tick;
};

static double spawns_now(const colyseus_spawns_t* spawns) {
    return spawns->clock
        ? colyseus_room_clock_server_now(spawns->clock)
        : colyseus_room_clock_now(NULL);
}

colyseus_spawns_t* colyseus_spawns_create(
    const colyseus_spawns_options_t* options,
    colyseus_room_clock_t* clock) {
    colyseus_spawns_t* spawns = calloc(1, sizeof(colyseus_spawns_t));
    if (options) spawns->opts = *options;
    spawns->clock = clock;
    spawns->next_id = 1;
    return spawns;
}

static void unlink_entry(colyseus_spawns_t* spawns, spawn_entry_internal_t* entry, bool free_local) {
    HASH_DEL(spawns->by_id, entry);
    if (entry->pub.server) HASH_DELETE(hh_server, spawns->by_server, entry);
    /* insertion-order list */
    spawn_entry_internal_t** cursor = &spawns->head;
    spawns->tail = NULL;
    while (*cursor) {
        if (*cursor == entry) {
            *cursor = entry->next;
            continue;
        }
        spawns->tail = *cursor;
        cursor = &(*cursor)->next;
    }
    if (free_local && entry->pub.local && spawns->opts.local_free) {
        spawns->opts.local_free(entry->pub.local);
    }
    free(entry);
}

void colyseus_spawns_clear(colyseus_spawns_t* spawns) {
    if (!spawns) return;
    spawn_entry_internal_t *entry, *tmp;
    HASH_ITER(hh, spawns->by_id, entry, tmp) {
        unlink_entry(spawns, entry, true);
    }
}

void colyseus_spawns_free(colyseus_spawns_t* spawns) {
    if (!spawns) return;
    colyseus_spawns_clear(spawns);
    free(spawns);
}

static spawn_entry_internal_t* append_entry(colyseus_spawns_t* spawns) {
    spawn_entry_internal_t* entry = calloc(1, sizeof(spawn_entry_internal_t));
    entry->pub.id = spawns->next_id++;
    HASH_ADD(hh, spawns->by_id, pub.id, sizeof(int), entry);
    if (spawns->tail) spawns->tail->next = entry;
    else spawns->head = entry;
    spawns->tail = entry;
    return entry;
}

int colyseus_spawns_spawn(colyseus_spawns_t* spawns, void* local) {
    spawn_entry_internal_t* entry = append_entry(spawns);
    entry->pub.local = local;
    entry->at = spawns_now(spawns);
    return entry->pub.id;
}

static spawn_entry_internal_t* find_by_id(colyseus_spawns_t* spawns, int id) {
    spawn_entry_internal_t* entry = NULL;
    HASH_FIND(hh, spawns->by_id, &id, sizeof(int), entry);
    return entry;
}

void colyseus_spawns_cancel(colyseus_spawns_t* spawns, int id) {
    spawn_entry_internal_t* entry = find_by_id(spawns, id);
    /* pending-safe: a confirmed entry is owned by the authoritative entity */
    if (entry && !entry->pub.confirmed) unlink_entry(spawns, entry, true);
}

void colyseus_spawns_accept(colyseus_spawns_t* spawns, int id) {
    spawn_entry_internal_t* entry = find_by_id(spawns, id);
    if (entry) entry->accepted = true;
}

void colyseus_spawns_handle_add(colyseus_spawns_t* spawns, colyseus_schema_t* server) {
    if (!spawns || !server) return;
    spawn_entry_internal_t* existing = NULL;
    HASH_FIND(hh_server, spawns->by_server, &server, sizeof(void*), existing);
    if (existing) return;   /* decoder re-fire for an instance already tracked */

    bool owned = spawns->opts.owned == NULL
        || spawns->opts.owned(server, spawns->opts.userdata);

    spawn_entry_internal_t* matched = NULL;
    if (owned) {
        for (spawn_entry_internal_t* entry = spawns->head; entry; entry = entry->next) {
            if (entry->pub.confirmed || entry->pub.local == NULL) continue;
            if (spawns->opts.correlate == NULL
                || spawns->opts.correlate(entry->pub.local, server, spawns->opts.userdata)) {
                matched = entry;
                break;
            }
        }
    }

    if (matched) {
        /* transition IN PLACE (same id — the handoff contract) */
        matched->pub.server = server;
        matched->pub.confirmed = true;
        if (spawns->opts.has_spawn_time && spawns->opts.spawn_time) {
            matched->pub.lead_ms = spawns->opts.spawn_time(server, spawns->opts.userdata) - matched->at;
        }
        HASH_ADD(hh_server, spawns->by_server, pub.server, sizeof(void*), matched);
    } else {
        /* foreign entity, or mine-without-a-prediction */
        spawn_entry_internal_t* entry = append_entry(spawns);
        entry->pub.server = server;
        entry->pub.confirmed = true;
        entry->at = 0.0 / 0.0;   /* NAN — no prediction, no TTL */
        HASH_ADD(hh_server, spawns->by_server, pub.server, sizeof(void*), entry);
    }
}

void colyseus_spawns_handle_remove(colyseus_spawns_t* spawns, colyseus_schema_t* server) {
    if (!spawns || !server) return;
    spawn_entry_internal_t* entry = NULL;
    HASH_FIND(hh_server, spawns->by_server, &server, sizeof(void*), entry);
    if (entry) unlink_entry(spawns, entry, true);
}

void colyseus_spawns_tick(colyseus_spawns_t* spawns, double now) {
    if (!spawns) return;
    double t = spawns->clock ? colyseus_room_clock_server_now(spawns->clock) : now;
    if (spawns->opts.step && spawns->has_last_tick) {
        double dt = (t - spawns->last_tick_at) / 1000;
        if (dt > 0) {
            for (spawn_entry_internal_t* entry = spawns->head; entry; entry = entry->next) {
                if (!entry->pub.confirmed && entry->pub.local) {
                    spawns->opts.step(entry->pub.local, dt, spawns->opts.userdata);
                }
            }
        }
    }
    spawns->last_tick_at = t;
    spawns->has_last_tick = true;
}

void colyseus_spawns_prune(colyseus_spawns_t* spawns) {
    if (!spawns || spawns->by_id == NULL) return;
    double now = spawns_now(spawns);
    double rtt = spawns->clock ? colyseus_room_clock_smoothed_rtt(spawns->clock) : 0;
    double ttl = spawns->opts.ttl_ms > 0 ? spawns->opts.ttl_ms : (rtt * 2 > 600 ? rtt * 2 : 600);
    spawn_entry_internal_t *entry, *tmp;
    HASH_ITER(hh, spawns->by_id, entry, tmp) {
        if (entry->pub.confirmed || entry->accepted || entry->at != entry->at) continue;
        if (now - entry->at > ttl) {
            void* local = entry->pub.local;
            int id = entry->pub.id;
            entry->pub.local = NULL;   /* the reject callback owns the handoff */
            unlink_entry(spawns, entry, false);
            if (spawns->opts.on_reject) spawns->opts.on_reject(local, id, spawns->opts.userdata);
            if (local && spawns->opts.local_free) spawns->opts.local_free(local);
        }
    }
}

const colyseus_spawn_entry_t* colyseus_spawns_entry_for(colyseus_spawns_t* spawns, colyseus_schema_t* server) {
    spawn_entry_internal_t* entry = NULL;
    HASH_FIND(hh_server, spawns->by_server, &server, sizeof(void*), entry);
    return entry ? &entry->pub : NULL;
}

const colyseus_spawn_entry_t* colyseus_spawns_entry(colyseus_spawns_t* spawns, int id) {
    spawn_entry_internal_t* entry = find_by_id(spawns, id);
    return entry ? &entry->pub : NULL;
}

bool colyseus_spawns_alive(colyseus_spawns_t* spawns, int id) {
    return find_by_id(spawns, id) != NULL;
}

const colyseus_spawn_entry_t* colyseus_spawns_first(colyseus_spawns_t* spawns) {
    return spawns && spawns->head ? &spawns->head->pub : NULL;
}

const colyseus_spawn_entry_t* colyseus_spawns_next(colyseus_spawns_t* spawns,
    const colyseus_spawn_entry_t* entry) {
    if (!spawns || !entry) return NULL;
    /* Re-find by id: the caller may have freed entries since the last step. */
    spawn_entry_internal_t* cur = find_by_id(spawns, entry->id);
    if (!cur) return NULL;
    return cur->next ? &cur->next->pub : NULL;
}

double colyseus_spawns_value(colyseus_spawns_t* spawns,
    const colyseus_spawn_entry_t* entry, const char* field) {
    if (!spawns || !entry || !field) return NAN;
    if (entry->confirmed && entry->server) {
        const colyseus_schema_vtable_t* vt = entry->server->__vtable;
        if (!vt) return NAN;
        for (int i = 0; i < vt->field_count; i++) {
            if (strcmp(vt->fields[i].name, field) != 0) continue;
            return spawns_field_read(entry->server, &vt->fields[i]);
        }
        return NAN;
    }
    if (entry->local && spawns->opts.local_read) {
        return spawns->opts.local_read(entry->local, field, spawns->opts.userdata);
    }
    return NAN;
}

int colyseus_spawns_size(const colyseus_spawns_t* spawns) {
    return spawns ? (int)HASH_COUNT(spawns->by_id) : 0;
}
