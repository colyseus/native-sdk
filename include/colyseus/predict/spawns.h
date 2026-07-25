#ifndef COLYSEUS_PREDICT_SPAWNS_H
#define COLYSEUS_PREDICT_SPAWNS_H

#include "colyseus/room_clock.h"
#include "colyseus/schema/types.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Predicted-spawn store (port of predict/predictedSpawns.ts) — optimistic,
 * server-reconciled ENTITIES (a fired bullet, a dropped item). Predicted
 * locals live OUTSIDE the schema collection; when the authoritative entity
 * arrives its onAdd is routed here and a pending local is correlated to it —
 * the two collapse onto ONE logical entry with a stable id (key sprites on
 * it; the handoff is invisible).
 *
 * Locals are opaque pointers owned by the app; local_free (optional) runs
 * when an entry that still holds a local dies.
 */
typedef struct colyseus_spawns colyseus_spawns_t;

typedef struct {
    int id;                        /* stable across the handoff */
    colyseus_schema_t* server;     /* authoritative instance; NULL while pending */
    void* local;                   /* predicted local; NULL for foreign entries */
    bool confirmed;
    double lead_ms;                /* measured input lead (owned + spawnTime only) */
} colyseus_spawn_entry_t;

typedef struct {
    /* which incoming server entities are this client's to correlate (NULL =
     * every entity is correlatable) */
    bool (*owned)(colyseus_schema_t* server, void* userdata);
    /* pairing: NULL = fifo (oldest pending); else first pending for which
     * this returns true */
    bool (*correlate)(void* local, colyseus_schema_t* server, void* userdata);
    /* server-clock spawn instant of an authoritative entity — enables the
     * measured input lead (lead = spawn_time(server) − entry.at) */
    double (*spawn_time)(colyseus_schema_t* server, void* userdata);
    bool has_spawn_time;
    /* advance a pending local by dt seconds (serverNow axis when clocked) */
    void (*step)(void* local, double dt, void* userdata);
    /* eviction window (ms) for unmatched predictions; 0 = max(2·rtt, 600) */
    double ttl_ms;
    void (*on_reject)(void* local, int id, void* userdata);
    void (*local_free)(void* local);
    void* userdata;
} colyseus_spawns_options_t;

colyseus_spawns_t* colyseus_spawns_create(
    const colyseus_spawns_options_t* options,
    colyseus_room_clock_t* clock /* nullable */);

void colyseus_spawns_free(colyseus_spawns_t* spawns);

/* Record an optimistic local spawn; returns its stable id. */
int colyseus_spawns_spawn(colyseus_spawns_t* spawns, void* local);

/* Drop a still-pending prediction (no-op once confirmed). */
void colyseus_spawns_cancel(colyseus_spawns_t* spawns, int id);

/* Exempt a still-pending entry from TTL eviction (server said yes; the
 * authoritative patch is in flight). */
void colyseus_spawns_accept(colyseus_spawns_t* spawns, int id);

/* Route the collection's onAdd/onRemove here (from the callbacks layer). */
void colyseus_spawns_handle_add(colyseus_spawns_t* spawns, colyseus_schema_t* server);
void colyseus_spawns_handle_remove(colyseus_spawns_t* spawns, colyseus_schema_t* server);

/* Advance pending locals (serverNow axis when clocked; `now` paces without). */
void colyseus_spawns_tick(colyseus_spawns_t* spawns, double now);

/* Drop pending locals older than the TTL — mispredicts. */
void colyseus_spawns_prune(colyseus_spawns_t* spawns);

/* Reads. Entries iterate in insertion order via _next (NULL id-cursor = start). */
const colyseus_spawn_entry_t* colyseus_spawns_entry_for(colyseus_spawns_t* spawns, colyseus_schema_t* server);
const colyseus_spawn_entry_t* colyseus_spawns_entry(colyseus_spawns_t* spawns, int id);
bool colyseus_spawns_alive(colyseus_spawns_t* spawns, int id);
int colyseus_spawns_size(const colyseus_spawns_t* spawns);

/* Drop everything (keeps the subscription wiring). */
void colyseus_spawns_clear(colyseus_spawns_t* spawns);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_PREDICT_SPAWNS_H */
