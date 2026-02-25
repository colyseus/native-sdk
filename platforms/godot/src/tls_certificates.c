#include "tls_certificates.h"
#include "godot_colyseus.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* Include the bundled CA certificates */
#include "certs/ca_bundle.h"

/* Global certificate storage */
static const unsigned char* g_ca_pem_data = NULL;
static size_t g_ca_pem_len = 0;
static unsigned char* g_loaded_pem_data = NULL;  /* Dynamically loaded data (must be freed) */

/* Function pointers for Godot API (set during init) */
static GDExtensionInterfaceGlobalGetSingleton global_get_singleton = NULL;

/* Forward declarations */
static bool load_certificates_from_godot_path(const char* path);
static char* get_project_settings_override_path(void);

void gdext_tls_certificates_set_api(GDExtensionInterfaceGetProcAddress p_get_proc_address) {
    global_get_singleton = (GDExtensionInterfaceGlobalGetSingleton)p_get_proc_address("global_get_singleton");
}

void gdext_tls_certificates_init(void) {
    /* Already initialized? */
    if (g_ca_pem_data != NULL) {
        return;
    }
    
    /* Try to get override path from ProjectSettings */
    char* override_path = get_project_settings_override_path();
    
    if (override_path && override_path[0] != '\0') {
        fprintf(stdout, "[Colyseus] Loading TLS certificates from: %s\n", override_path);
        fflush(stdout);
        
        if (load_certificates_from_godot_path(override_path)) {
            free(override_path);
            return;
        }
        
        fprintf(stderr, "[Colyseus] Failed to load certificates from override path, using bundled certificates\n");
        fflush(stderr);
    }
    
    free(override_path);
    
    /* Use bundled Mozilla CA certificates */
    fprintf(stdout, "[Colyseus] Using bundled Mozilla CA certificates (%zu bytes)\n", colyseus_ca_bundle_pem_len);
    fflush(stdout);
    
    g_ca_pem_data = colyseus_ca_bundle_pem;
    g_ca_pem_len = colyseus_ca_bundle_pem_len;
}

void gdext_tls_certificates_cleanup(void) {
    if (g_loaded_pem_data) {
        free(g_loaded_pem_data);
        g_loaded_pem_data = NULL;
    }
    g_ca_pem_data = NULL;
    g_ca_pem_len = 0;
}

const unsigned char* gdext_tls_get_ca_certificates(void) {
    return g_ca_pem_data;
}

size_t gdext_tls_get_ca_certificates_len(void) {
    return g_ca_pem_len;
}

/* Get the certificate bundle override path from ProjectSettings */
static char* get_project_settings_override_path(void) {
    if (!global_get_singleton) {
        return NULL;
    }
    
    /* Get ProjectSettings singleton */
    StringName project_settings_name;
    constructors.string_name_new_with_latin1_chars(&project_settings_name, "ProjectSettings", false);
    
    GDExtensionObjectPtr project_settings = global_get_singleton(&project_settings_name);
    destructors.string_name_destructor(&project_settings_name);
    
    if (!project_settings) {
        return NULL;
    }
    
    /* Create Variant from object for calling methods */
    Variant settings_variant;
    constructors.variant_from_object_constructor(&settings_variant, &project_settings);
    
    /* Prepare method name "get_setting" */
    StringName get_setting_method;
    constructors.string_name_new_with_latin1_chars(&get_setting_method, "get_setting", false);
    
    /* Prepare argument: setting path */
    String setting_path;
    constructors.string_new_with_utf8_chars(&setting_path, "network/tls/certificate_bundle_override");
    Variant path_variant;
    constructors.variant_from_string_constructor(&path_variant, &setting_path);
    
    /* Call get_setting */
    GDExtensionConstVariantPtr args[1] = { &path_variant };
    Variant result;
    GDExtensionCallError error;
    api.variant_call(&settings_variant, &get_setting_method, args, 1, &result, &error);
    
    char* result_str = NULL;
    
    if (error.error == GDEXTENSION_CALL_OK) {
        /* Check if result is a string */
        GDExtensionVariantType type = api.variant_get_type(&result);
        if (type == GDEXTENSION_VARIANT_TYPE_STRING) {
            String result_string;
            constructors.string_from_variant_constructor(&result_string, &result);
            
            /* Get string length */
            int32_t length = api.string_to_utf8_chars(&result_string, NULL, 0);
            if (length > 0) {
                result_str = (char*)malloc(length + 1);
                if (result_str) {
                    api.string_to_utf8_chars(&result_string, result_str, length);
                    result_str[length] = '\0';
                }
            }
            
            destructors.string_destructor(&result_string);
        }
    }
    
    /* Cleanup */
    destructors.variant_destroy(&result);
    destructors.string_destructor(&setting_path);
    destructors.variant_destroy(&path_variant);
    destructors.string_name_destructor(&get_setting_method);
    destructors.variant_destroy(&settings_variant);
    
    return result_str;
}

/* Load certificates from a Godot resource path (res://) or file path */
static bool load_certificates_from_godot_path(const char* path) {
    if (!global_get_singleton || !path || path[0] == '\0') {
        return false;
    }
    
    /* Get FileAccess singleton to open the file */
    StringName file_access_name;
    constructors.string_name_new_with_latin1_chars(&file_access_name, "FileAccess", false);
    
    /* Call FileAccess.open(path, FileAccess.READ) static method */
    /* FileAccess.READ = 1 */
    
    /* First, we need to call FileAccess.open() which is a static method */
    /* Use classdb_get_method_bind to get the method, then call it */
    
    /* For simplicity, let's use a different approach: 
       Call the method via ClassDB or use variant_call on the class */
    
    /* Actually, let's use the Godot way: construct a FileAccess via ClassDB */
    GDExtensionObjectPtr file = api.classdb_construct_object(&file_access_name);
    destructors.string_name_destructor(&file_access_name);
    
    if (!file) {
        return false;
    }
    
    /* Create variant for calling methods */
    Variant file_variant;
    constructors.variant_from_object_constructor(&file_variant, &file);
    
    /* Call open(path, READ) - but wait, FileAccess.open is a static method that returns a new FileAccess */
    /* We need to use a different approach */
    
    /* Let's use the static open method properly */
    /* For now, since static method calls are complex in GDExtension C, 
       let's fall back to just reading with standard C file I/O for absolute paths */
    
    destructors.variant_destroy(&file_variant);
    
    /* Check if it's a res:// path - if so, we can't easily load it in C */
    if (strncmp(path, "res://", 6) == 0) {
        fprintf(stderr, "[Colyseus] Warning: res:// paths for certificate override not yet supported\n");
        return false;
    }
    
    /* Try to load as absolute file path */
    FILE* fp = fopen(path, "rb");
    if (!fp) {
        fprintf(stderr, "[Colyseus] Failed to open certificate file: %s\n", path);
        return false;
    }
    
    /* Get file size */
    fseek(fp, 0, SEEK_END);
    long file_size = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    
    if (file_size <= 0) {
        fclose(fp);
        return false;
    }
    
    /* Allocate buffer (+ 1 for null terminator) */
    g_loaded_pem_data = (unsigned char*)malloc(file_size + 1);
    if (!g_loaded_pem_data) {
        fclose(fp);
        return false;
    }
    
    /* Read file */
    size_t bytes_read = fread(g_loaded_pem_data, 1, file_size, fp);
    fclose(fp);
    
    if (bytes_read != (size_t)file_size) {
        free(g_loaded_pem_data);
        g_loaded_pem_data = NULL;
        return false;
    }
    
    /* Null terminate */
    g_loaded_pem_data[file_size] = '\0';
    
    g_ca_pem_data = g_loaded_pem_data;
    g_ca_pem_len = file_size + 1;
    
    fprintf(stdout, "[Colyseus] Loaded %ld bytes of certificates from: %s\n", file_size, path);
    fflush(stdout);
    
    return true;
}
