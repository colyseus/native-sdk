#ifndef COLYSEUS_SCHEMA_REGISTRY_H
#define COLYSEUS_SCHEMA_REGISTRY_H

#include <colyseus/schema/types.h>

// Maximum number of registered vtables
#define COLYSEUS_SCHEMA_REGISTRY_MAX 64

// Register a vtable by name (call at initialization)
void colyseus_schema_register(const char* name, const colyseus_schema_vtable_t* vtable);

// Look up vtable by name (returns NULL if not found)
const colyseus_schema_vtable_t* colyseus_schema_lookup(const char* name);

#endif
