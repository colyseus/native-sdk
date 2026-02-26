#ifndef COLYSEUS_SCHEMA_CALLBACKS_H
#define COLYSEUS_SCHEMA_CALLBACKS_H

#include "types.h"
#include "decoder.h"
#include "collections.h"
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Colyseus Schema Callbacks
 * 
 * Provides a callback-based API for listening to state changes,
 * similar to the TypeScript StateCallbackStrategy.
 * 
 * Usage:
 * 
 *   colyseus_callbacks_t* cb = colyseus_callbacks_create(decoder);
 *   
 *   // Listen to property changes on root state
 *   colyseus_callback_handle_t h1 = colyseus_callbacks_listen(
 *       cb, state, "currentTurn", on_turn_change, userdata, true);
 *   
 *   // Listen to collection additions
 *   colyseus_callback_handle_t h2 = colyseus_callbacks_on_add(
 *       cb, state, "players", on_player_add, userdata, true);
 *   
 *   // Unsubscribe when done
 *   colyseus_callbacks_remove(cb, h1);
 *   colyseus_callbacks_remove(cb, h2);
 *   
 *   colyseus_callbacks_free(cb);
 */

/* Forward declarations */
typedef struct colyseus_callbacks colyseus_callbacks_t;

/* Callback handle for unsubscription */
typedef int colyseus_callback_handle_t;

/* Invalid handle constant */
#define COLYSEUS_INVALID_CALLBACK_HANDLE (-1)

/* ============================================================================
 * Callback function signatures
 * ============================================================================ */

/**
 * Property change callback
 * @param value Current value (may be primitive pointer or schema pointer)
 * @param previous_value Previous value (may be NULL on first call)
 * @param userdata User-provided context
 */
typedef void (*colyseus_property_callback_fn)(void* value, void* previous_value, void* userdata);

/**
 * Collection item callback (for onAdd/onRemove)
 * @param value The item value
 * @param key The key (int* for arrays, char* for maps)
 * @param userdata User-provided context
 */
typedef void (*colyseus_item_callback_fn)(void* value, void* key, void* userdata);

/**
 * Instance change callback (for onChange on schema instances)
 * Called when any property on the instance changes
 * @param userdata User-provided context
 */
typedef void (*colyseus_instance_change_callback_fn)(void* userdata);

/**
 * Collection change callback (for onChange on collections)
 * @param key The key that changed (int* for arrays, char* for maps)
 * @param value The new value
 * @param userdata User-provided context
 */
typedef void (*colyseus_collection_change_callback_fn)(void* key, void* value, void* userdata);

/* ============================================================================
 * Callbacks Manager
 * ============================================================================ */

/**
 * Create a callbacks manager for a decoder
 * @param decoder The schema decoder to attach callbacks to
 * @return New callbacks manager (caller owns)
 */
colyseus_callbacks_t* colyseus_callbacks_create(colyseus_decoder_t* decoder);

/**
 * Free a callbacks manager and all registered callbacks
 * @param callbacks The callbacks manager to free
 */
void colyseus_callbacks_free(colyseus_callbacks_t* callbacks);

/**
 * Remove a registered callback by handle
 * @param callbacks The callbacks manager
 * @param handle The callback handle returned from registration
 */
void colyseus_callbacks_remove(colyseus_callbacks_t* callbacks, colyseus_callback_handle_t handle);

/* ============================================================================
 * Property Listening (listen)
 * ============================================================================ */

/**
 * Listen to property changes on a schema instance
 * 
 * @param callbacks The callbacks manager
 * @param instance The schema instance to listen on (use decoder state for root)
 * @param property The property name to listen for
 * @param handler Callback function
 * @param userdata User context passed to callback
 * @param immediate If true, call handler immediately with current value
 * @return Callback handle for unsubscription
 */
colyseus_callback_handle_t colyseus_callbacks_listen(
    colyseus_callbacks_t* callbacks,
    void* instance,
    const char* property,
    colyseus_property_callback_fn handler,
    void* userdata,
    bool immediate
);

/* ============================================================================
 * Collection Callbacks (onAdd, onRemove, onChange)
 * ============================================================================ */

/**
 * Listen to items added to a collection property
 * 
 * @param callbacks The callbacks manager
 * @param instance The schema instance containing the collection
 * @param property The collection property name
 * @param handler Callback function (value, key, userdata)
 * @param userdata User context passed to callback
 * @param immediate If true, call handler for all existing items
 * @return Callback handle for unsubscription
 */
colyseus_callback_handle_t colyseus_callbacks_on_add(
    colyseus_callbacks_t* callbacks,
    void* instance,
    const char* property,
    colyseus_item_callback_fn handler,
    void* userdata,
    bool immediate
);

/**
 * Listen to items removed from a collection property
 * 
 * @param callbacks The callbacks manager
 * @param instance The schema instance containing the collection
 * @param property The collection property name
 * @param handler Callback function (value, key, userdata)
 * @param userdata User context passed to callback
 * @return Callback handle for unsubscription
 */
colyseus_callback_handle_t colyseus_callbacks_on_remove(
    colyseus_callbacks_t* callbacks,
    void* instance,
    const char* property,
    colyseus_item_callback_fn handler,
    void* userdata
);

/**
 * Listen to any property change on a schema instance
 * 
 * @param callbacks The callbacks manager
 * @param instance The schema instance to listen on
 * @param handler Callback function (userdata only)
 * @param userdata User context passed to callback
 * @return Callback handle for unsubscription
 */
colyseus_callback_handle_t colyseus_callbacks_on_change_instance(
    colyseus_callbacks_t* callbacks,
    void* instance,
    colyseus_instance_change_callback_fn handler,
    void* userdata
);

/**
 * Listen to item changes in a collection property
 * 
 * @param callbacks The callbacks manager
 * @param instance The schema instance containing the collection
 * @param property The collection property name
 * @param handler Callback function (key, value, userdata)
 * @param userdata User context passed to callback
 * @return Callback handle for unsubscription
 */
colyseus_callback_handle_t colyseus_callbacks_on_change_collection(
    colyseus_callbacks_t* callbacks,
    void* instance,
    const char* property,
    colyseus_collection_change_callback_fn handler,
    void* userdata
);

/* ============================================================================
 * Direct Collection Callbacks (for collections already obtained)
 * ============================================================================ */

/**
 * Listen to items added to an array collection directly
 * 
 * @param callbacks The callbacks manager
 * @param array The array schema collection
 * @param handler Callback function (value, key, userdata)
 * @param userdata User context passed to callback
 * @param immediate If true, call handler for all existing items
 * @return Callback handle for unsubscription
 */
colyseus_callback_handle_t colyseus_callbacks_array_on_add(
    colyseus_callbacks_t* callbacks,
    colyseus_array_schema_t* array,
    colyseus_item_callback_fn handler,
    void* userdata,
    bool immediate
);

/**
 * Listen to items removed from an array collection directly
 */
colyseus_callback_handle_t colyseus_callbacks_array_on_remove(
    colyseus_callbacks_t* callbacks,
    colyseus_array_schema_t* array,
    colyseus_item_callback_fn handler,
    void* userdata
);

/**
 * Listen to item changes in an array collection directly
 */
colyseus_callback_handle_t colyseus_callbacks_array_on_change(
    colyseus_callbacks_t* callbacks,
    colyseus_array_schema_t* array,
    colyseus_collection_change_callback_fn handler,
    void* userdata
);

/**
 * Listen to items added to a map collection directly
 */
colyseus_callback_handle_t colyseus_callbacks_map_on_add(
    colyseus_callbacks_t* callbacks,
    colyseus_map_schema_t* map,
    colyseus_item_callback_fn handler,
    void* userdata,
    bool immediate
);

/**
 * Listen to items removed from a map collection directly
 */
colyseus_callback_handle_t colyseus_callbacks_map_on_remove(
    colyseus_callbacks_t* callbacks,
    colyseus_map_schema_t* map,
    colyseus_item_callback_fn handler,
    void* userdata
);

/**
 * Listen to item changes in a map collection directly
 */
colyseus_callback_handle_t colyseus_callbacks_map_on_change(
    colyseus_callbacks_t* callbacks,
    colyseus_map_schema_t* map,
    colyseus_collection_change_callback_fn handler,
    void* userdata
);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_SCHEMA_CALLBACKS_H */
