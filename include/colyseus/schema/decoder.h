#ifndef COLYSEUS_SCHEMA_DECODER_H
#define COLYSEUS_SCHEMA_DECODER_H

#include "types.h"
#include "decode.h"
#include "collections.h"
#include "ref_tracker.h"
#include "uthash.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Schema Decoder
 * 
 * Decodes binary state updates from Colyseus server.
 */

/* Type context - maps type IDs to vtables */
typedef struct colyseus_type_entry {
    int type_id;
    const colyseus_schema_vtable_t* vtable;
    UT_hash_handle hh;
} colyseus_type_entry_t;

typedef struct colyseus_type_context {
    colyseus_type_entry_t* types;
} colyseus_type_context_t;

/* Callback for triggering changes after decode */
typedef void (*colyseus_trigger_changes_fn)(colyseus_changes_t* changes, void* userdata);

#define COLYSEUS_DECODER_MAX_TRIGGERS 8

/*
 * Resync ("full-snapshot reconciliation") bookkeeping — identities visited
 * per collection refId during a colyseus_decoder_decode_resync() walk.
 * Map entries are identified by string key, array entries by their resolved
 * client-side index. See PORTING_RESYNC.md in @colyseus/schema.
 */
typedef struct colyseus_resync_str_id {
    char* key;                          /* owned copy */
    UT_hash_handle hh;
} colyseus_resync_str_id_t;

typedef struct colyseus_resync_int_id {
    int index;
    UT_hash_handle hh;
} colyseus_resync_int_id_t;

typedef struct colyseus_resync_visited_entry {
    int ref_id;
    colyseus_resync_str_id_t* keys;     /* map string keys */
    colyseus_resync_int_id_t* indexes;  /* array resolved indexes */
    UT_hash_handle hh;
} colyseus_resync_visited_entry_t;

/* Decoder structure */
struct colyseus_decoder {
    colyseus_ref_tracker_t* refs;
    colyseus_type_context_t* context;
    colyseus_schema_t* state;
    const colyseus_schema_vtable_t* state_vtable;

    /* Changes accumulated during decode */
    colyseus_changes_t* changes;

    /* Change listeners, fired in registration order. Several can coexist: a
     * room's predict layer and the app's own callbacks each hook in. */
    colyseus_trigger_changes_fn trigger_changes[COLYSEUS_DECODER_MAX_TRIGGERS];
    void* trigger_userdata[COLYSEUS_DECODER_MAX_TRIGGERS];
    int trigger_count;
    int trigger_index;  /* listener being dispatched; -1 between patches */

    /* Resync mode — an empty uthash is NULL, so the explicit bool is the
     * mode flag; `resync_visited` holds the per-collection identities. */
    colyseus_resync_visited_entry_t* resync_visited;
    bool resync_active;
    bool resync_damaged;
};

/* Type context functions */
colyseus_type_context_t* colyseus_type_context_create(void);
void colyseus_type_context_free(colyseus_type_context_t* ctx);
void colyseus_type_context_set(colyseus_type_context_t* ctx, int type_id, const colyseus_schema_vtable_t* vtable);
const colyseus_schema_vtable_t* colyseus_type_context_get(colyseus_type_context_t* ctx, int type_id);

/* Create decoder for a specific state type */
colyseus_decoder_t* colyseus_decoder_create(const colyseus_schema_vtable_t* state_vtable);
void colyseus_decoder_free(colyseus_decoder_t* decoder);

/*
 * Adds a change listener; every decoded patch is handed to each listener in
 * registration order. Re-adding a registered pair is a no-op. Returns false
 * (and logs) when COLYSEUS_DECODER_MAX_TRIGGERS listeners are already in —
 * the listener would otherwise never fire.
 */
bool colyseus_decoder_set_trigger_callback(colyseus_decoder_t* decoder,
    colyseus_trigger_changes_fn callback, void* userdata);

/* Removes the listener registered with this exact callback + userdata. Safe
 * from inside a dispatch: listeners after it still run for that patch. */
void colyseus_decoder_remove_trigger_callback(colyseus_decoder_t* decoder,
    colyseus_trigger_changes_fn callback, void* userdata);

/*
 * True while a patch is being dispatched and this listener has not finished
 * it yet (it is running, or queued behind the current one). Whatever it
 * registers now will still see this patch's changes through it — which is
 * how the callbacks layer decides to skip an `immediate` call.
 */
bool colyseus_decoder_trigger_pending(const colyseus_decoder_t* decoder,
    colyseus_trigger_changes_fn callback, void* userdata);

/* Decode state update */
void colyseus_decoder_decode(colyseus_decoder_t* decoder, const uint8_t* bytes, size_t length, colyseus_iterator_t* it);

/*
 * Full-snapshot reconciliation ("resync") decode.
 *
 * Behaves exactly like colyseus_decoder_decode(), plus: every collection
 * entry the payload does NOT mention is removed through the regular DELETE
 * path — on-remove callbacks fire with the real previous value and released
 * refs are garbage-collected. Use it to apply a rejoin/reconnect full state
 * over an existing decoded tree.
 *
 * ONLY valid for full-snapshot payloads. Calling it on an incremental patch
 * would prune everything the patch doesn't touch.
 */
void colyseus_decoder_decode_resync(colyseus_decoder_t* decoder, const uint8_t* bytes, size_t length, colyseus_iterator_t* it);

/* Get current state */
colyseus_schema_t* colyseus_decoder_get_state(colyseus_decoder_t* decoder);

/* Teardown - clear all refs */
void colyseus_decoder_teardown(colyseus_decoder_t* decoder);

/*
 * Destroy the decoded tree below the root for a schema-codegen'd state, whose
 * generated destroy() reaches its own strings and `t.ref()` children but never
 * a map or array. Terminal: the root's child pointers dangle afterwards. Only
 * the room's state serializer calls this — hand-written vtables (the
 * handshake's reflection types) own their children outright and would be
 * double-freed by it.
 */
void colyseus_decoder_release_codegen_tree(colyseus_decoder_t* decoder);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_SCHEMA_DECODER_H */
