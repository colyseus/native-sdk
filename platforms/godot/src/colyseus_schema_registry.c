#include "colyseus_schema_registry.h"
#include <string.h>
#include <stdio.h>

// Registry entry
typedef struct {
    const char* name;
    const colyseus_schema_vtable_t* vtable;
} schema_registry_entry_t;

// Static registry storage
static schema_registry_entry_t g_registry[COLYSEUS_SCHEMA_REGISTRY_MAX];
static int g_registry_count = 0;

void colyseus_schema_register(const char* name, const colyseus_schema_vtable_t* vtable) {
    if (!name || !vtable) {
        return;
    }
    
    if (g_registry_count >= COLYSEUS_SCHEMA_REGISTRY_MAX) {
        fprintf(stderr, "[ColyseusSchemaRegistry] Registry full, cannot register '%s'\n", name);
        return;
    }
    
    // Check if already registered
    for (int i = 0; i < g_registry_count; i++) {
        if (strcmp(g_registry[i].name, name) == 0) {
            // Update existing entry
            g_registry[i].vtable = vtable;
            printf("[ColyseusSchemaRegistry] Updated vtable for '%s'\n", name);
            fflush(stdout);
            return;
        }
    }
    
    // Add new entry
    g_registry[g_registry_count].name = name;
    g_registry[g_registry_count].vtable = vtable;
    g_registry_count++;
    
    printf("[ColyseusSchemaRegistry] Registered vtable for '%s' (%d fields)\n", 
           name, vtable->field_count);
    fflush(stdout);
}

const colyseus_schema_vtable_t* colyseus_schema_lookup(const char* name) {
    if (!name) {
        return NULL;
    }
    
    for (int i = 0; i < g_registry_count; i++) {
        if (strcmp(g_registry[i].name, name) == 0) {
            return g_registry[i].vtable;
        }
    }
    
    fprintf(stderr, "[ColyseusSchemaRegistry] Vtable not found for '%s'\n", name);
    return NULL;
}
