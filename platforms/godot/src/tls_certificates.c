#include "tls_certificates.h"
#include "godot_colyseus.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* Override certificate storage. This binding only provides an explicit
 * certificate_bundle_override; the bundled Mozilla CA roots are loaded by the
 * core SDK itself, so we leave this NULL when no override is configured. */
static const unsigned char* g_ca_pem_data = NULL;
static size_t g_ca_pem_len = 0;
static unsigned char* g_loaded_pem_data = NULL;  /* Dynamically loaded data (must be freed) */
static bool g_initialized = false;

/* Function pointers for Godot API (set during init) */
static GDExtensionInterfaceGlobalGetSingleton global_get_singleton = NULL;

/* Forward declarations */
static bool load_certificates_from_godot_path(const char* path);
static char* get_project_settings_override_path(void);

void gdext_tls_certificates_set_api(GDExtensionInterfaceGetProcAddress p_get_proc_address) {
    global_get_singleton = (GDExtensionInterfaceGlobalGetSingleton)p_get_proc_address("global_get_singleton");
}

void gdext_tls_certificates_init(void) {
    if (g_initialized) {
        return;
    }
    g_initialized = true;

    /* Try to get override path from ProjectSettings */
    char* override_path = get_project_settings_override_path();

    if (override_path && override_path[0] != '\0') {
        fprintf(stdout, "[Colyseus] Loading TLS certificate override from: %s\n", override_path);
        fflush(stdout);

        if (!load_certificates_from_godot_path(override_path)) {
            fprintf(stderr, "[Colyseus] Failed to load certificate override; falling back to built-in CA roots (hint: copy a packed res:// asset to user:// first)\n");
            fflush(stderr);
        }
    }

    free(override_path);

    /* No override configured (or it failed to load): nothing to provide here.
     * The core SDK always loads the bundled Mozilla CA roots, so WSS still
     * verifies against the standard trust store. */
}

void gdext_tls_certificates_cleanup(void) {
    if (g_loaded_pem_data) {
        free(g_loaded_pem_data);
        g_loaded_pem_data = NULL;
    }
    g_ca_pem_data = NULL;
    g_ca_pem_len = 0;
    g_initialized = false;
}

const unsigned char* gdext_tls_get_ca_certificates(void) {
    return g_ca_pem_data;
}

size_t gdext_tls_get_ca_certificates_len(void) {
    return g_ca_pem_len;
}

/* Call a ProjectSettings method that takes one String argument and returns a
 * String. Returns a malloc'd UTF-8 string (caller frees), or NULL on any error
 * or non-String result. */
static char* call_project_settings_string_method(const char* method_name, const char* arg_utf8) {
    if (!global_get_singleton) {
        return NULL;
    }

    StringName project_settings_name;
    constructors.string_name_new_with_latin1_chars(&project_settings_name, "ProjectSettings", false);

    GDExtensionObjectPtr project_settings = global_get_singleton(&project_settings_name);
    destructors.string_name_destructor(&project_settings_name);

    if (!project_settings) {
        return NULL;
    }

    Variant settings_variant;
    constructors.variant_from_object_constructor(&settings_variant, &project_settings);

    StringName method;
    constructors.string_name_new_with_latin1_chars(&method, method_name, false);

    String arg_str;
    constructors.string_new_with_utf8_chars(&arg_str, arg_utf8);
    Variant arg_variant;
    constructors.variant_from_string_constructor(&arg_variant, &arg_str);

    GDExtensionConstVariantPtr args[1] = { &arg_variant };
    Variant result;
    GDExtensionCallError error;
    api.variant_call(&settings_variant, &method, args, 1, &result, &error);

    char* result_str = NULL;

    if (error.error == GDEXTENSION_CALL_OK &&
        api.variant_get_type(&result) == GDEXTENSION_VARIANT_TYPE_STRING) {
        String result_string;
        constructors.string_from_variant_constructor(&result_string, &result);

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

    destructors.variant_destroy(&result);
    destructors.string_destructor(&arg_str);
    destructors.variant_destroy(&arg_variant);
    destructors.string_name_destructor(&method);
    destructors.variant_destroy(&settings_variant);

    return result_str;
}

/* Get the certificate bundle override path from ProjectSettings */
static char* get_project_settings_override_path(void) {
    return call_project_settings_string_method("get_setting", "network/tls/certificate_bundle_override");
}

/* Load certificates from a Godot resource path (res:// or user://) or an
 * absolute OS path. Godot virtual paths are resolved to a real filesystem path
 * via ProjectSettings.globalize_path() so plain C file I/O can read them; on
 * Android this is what makes a user:// override (the documented workaround)
 * readable. res:// assets packed inside the .pck/.apk have no OS path and won't
 * be loadable this way — copy them to user:// first. */
static bool load_certificates_from_godot_path(const char* path) {
    if (!path || path[0] == '\0') {
        return false;
    }

    /* Resolve res://, user:// (and leave absolute paths effectively unchanged). */
    char* globalized = call_project_settings_string_method("globalize_path", path);
    const char* fs_path = (globalized && globalized[0] != '\0') ? globalized : path;

    /* Try to load as a filesystem path */
    FILE* fp = fopen(fs_path, "rb");
    if (!fp) {
        fprintf(stderr, "[Colyseus] Failed to open certificate file: %s (resolved: %s)\n", path, fs_path);
        free(globalized);
        return false;
    }
    free(globalized);
    
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
