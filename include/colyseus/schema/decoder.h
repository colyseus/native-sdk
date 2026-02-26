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

/* Decoder structure */
struct colyseus_decoder {
    colyseus_ref_tracker_t* refs;
    colyseus_type_context_t* context;
    colyseus_schema_t* state;
    const colyseus_schema_vtable_t* state_vtable;
    
    /* Changes accumulated during decode */
    colyseus_changes_t* changes;
    
    /* Callback for triggering changes */
    colyseus_trigger_changes_fn trigger_changes;
    void* trigger_userdata;
};

/* Type context functions */
colyseus_type_context_t* colyseus_type_context_create(void);
void colyseus_type_context_free(colyseus_type_context_t* ctx);
void colyseus_type_context_set(colyseus_type_context_t* ctx, int type_id, const colyseus_schema_vtable_t* vtable);
const colyseus_schema_vtable_t* colyseus_type_context_get(colyseus_type_context_t* ctx, int type_id);

/* Create decoder for a specific state type */
colyseus_decoder_t* colyseus_decoder_create(const colyseus_schema_vtable_t* state_vtable);
void colyseus_decoder_free(colyseus_decoder_t* decoder);

/* Set change callback */
void colyseus_decoder_set_trigger_callback(colyseus_decoder_t* decoder, 
    colyseus_trigger_changes_fn callback, void* userdata);

/* Decode state update */
void colyseus_decoder_decode(colyseus_decoder_t* decoder, const uint8_t* bytes, size_t length, colyseus_iterator_t* it);

/* Get current state */
colyseus_schema_t* colyseus_decoder_get_state(colyseus_decoder_t* decoder);

/* Teardown - clear all refs */
void colyseus_decoder_teardown(colyseus_decoder_t* decoder);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_SCHEMA_DECODER_H */