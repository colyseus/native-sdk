#include "godot_colyseus.h"
#include "colyseus_callbacks.h"
#include "colyseus_schema_registry.h"
#include <gdextension_interface.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#ifndef GDE_EXPORT
#ifdef _WIN32
#define GDE_EXPORT __declspec(dllexport)
#else
#define GDE_EXPORT __attribute__((visibility("default")))
#endif
#endif

// Global GDExtension interface and library
GDExtensionInterface api = {0};
GDExtensionClassLibraryPtr class_library = NULL;

// Global constructors and destructors
struct Constructors constructors = {0};
struct Destructors destructors = {0};

GDExtensionPropertyInfo make_property_full(
    GDExtensionVariantType type,
    const char *name,
    uint32_t hint,
    const char *hint_string,
    const char *class_name,
    uint32_t usage_flags)
{

    StringName *prop_name = api.mem_alloc(sizeof(StringName));
    constructors.string_name_new_with_latin1_chars(prop_name, name, false);
    String *prop_hint_string = api.mem_alloc(sizeof(String));
    constructors.string_new_with_utf8_chars(prop_hint_string, hint_string);
    StringName *prop_class_name = api.mem_alloc(sizeof(StringName));
    constructors.string_name_new_with_latin1_chars(prop_class_name, class_name, false);

    GDExtensionPropertyInfo info = {
        .name = prop_name,
        .type = type,
        .hint = hint,
        .hint_string = prop_hint_string,
        .class_name = prop_class_name,
        .usage = usage_flags,
    };

    return info;
}

// Helper function to create property info
GDExtensionPropertyInfo make_property(
    GDExtensionVariantType type,
    const char *name)
{
    return make_property_full(type, name, PROPERTY_HINT_NONE, "", "", PROPERTY_USAGE_DEFAULT);
}


// Helper function to destruct property info
void destruct_property(GDExtensionPropertyInfo *info)
{
    destructors.string_name_destructor(info->name);
    destructors.string_destructor(info->hint_string);
    destructors.string_name_destructor(info->class_name);
    api.mem_free(info->name);
    api.mem_free(info->hint_string);
    api.mem_free(info->class_name);
}

// Generic call/ptrcall implementations

// 0 arguments, no return
static void call_0_args_no_ret(void *method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr *p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError *r_error)
{
    void (*function)(void *, GDExtensionClassInstancePtr, const GDExtensionConstVariantPtr *, GDExtensionInt, GDExtensionVariantPtr, GDExtensionCallError *) = method_userdata;
    function(method_userdata, p_instance, p_args, p_argument_count, r_return, r_error);
}

static void ptrcall_0_args_no_ret(void *method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr *p_args, GDExtensionTypePtr r_ret)
{
    void (*function)(void *, GDExtensionClassInstancePtr, const GDExtensionConstTypePtr *, GDExtensionTypePtr) = method_userdata;
    function(method_userdata, p_instance, p_args, r_ret);
}

// 0 arguments, with return
static void call_0_args_with_ret(void *method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr *p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError *r_error)
{
    void (*function)(void *, GDExtensionClassInstancePtr, const GDExtensionConstVariantPtr *, GDExtensionInt, GDExtensionVariantPtr, GDExtensionCallError *) = method_userdata;
    function(method_userdata, p_instance, p_args, p_argument_count, r_return, r_error);
}

static void ptrcall_0_args_with_ret(void *method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr *p_args, GDExtensionTypePtr r_ret)
{
    void (*function)(void *, GDExtensionClassInstancePtr, const GDExtensionConstTypePtr *, GDExtensionTypePtr) = method_userdata;
    function(method_userdata, p_instance, p_args, r_ret);
}

// 1 argument, no return
static void call_1_arg_no_ret(void *method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr *p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError *r_error)
{
    void (*function)(void *, GDExtensionClassInstancePtr, const GDExtensionConstVariantPtr *, GDExtensionInt, GDExtensionVariantPtr, GDExtensionCallError *) = method_userdata;
    function(method_userdata, p_instance, p_args, p_argument_count, r_return, r_error);
}

static void ptrcall_1_arg_no_ret(void *method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr *p_args, GDExtensionTypePtr r_ret)
{
    void (*function)(void *, GDExtensionClassInstancePtr, const GDExtensionConstTypePtr *, GDExtensionTypePtr) = method_userdata;
    function(method_userdata, p_instance, p_args, r_ret);
}

// 2 arguments, no return
static void call_2_args_no_ret(void *method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr *p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError *r_error)
{
    void (*function)(void *, GDExtensionClassInstancePtr, const GDExtensionConstVariantPtr *, GDExtensionInt, GDExtensionVariantPtr, GDExtensionCallError *) = method_userdata;
    function(method_userdata, p_instance, p_args, p_argument_count, r_return, r_error);
}

static void ptrcall_2_args_no_ret(void *method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr *p_args, GDExtensionTypePtr r_ret)
{
    void (*function)(void *, GDExtensionClassInstancePtr, const GDExtensionConstTypePtr *, GDExtensionTypePtr) = method_userdata;
    function(method_userdata, p_instance, p_args, r_ret);
}

// Generic method binding: 0 arguments, no return
static void bind_method_0_no_ret(
    const char *class_name,
    const char *method_name,
    void *function)
{
    StringName method_name_string;
    constructors.string_name_new_with_latin1_chars(&method_name_string, method_name, false);

    GDExtensionClassMethodCall call_func = call_0_args_no_ret;
    GDExtensionClassMethodPtrCall ptrcall_func = ptrcall_0_args_no_ret;

    GDExtensionClassMethodInfo method_info = {
        .name = &method_name_string,
        .method_userdata = function,
        .call_func = call_func,
        .ptrcall_func = ptrcall_func,
        .method_flags = GDEXTENSION_METHOD_FLAGS_DEFAULT,
        .has_return_value = false,
        .argument_count = 0,
    };

    StringName class_name_string;
    constructors.string_name_new_with_latin1_chars(&class_name_string, class_name, false);

    api.classdb_register_extension_class_method(class_library, &class_name_string, &method_info);

    // Destruct things
    destructors.string_name_destructor(&method_name_string);
    destructors.string_name_destructor(&class_name_string);
}

// Generic method binding: 0 arguments, with return
static void bind_method_0_with_ret(
    const char *class_name,
    const char *method_name,
    void *function,
    GDExtensionVariantType return_type)
{
    StringName method_name_string;
    constructors.string_name_new_with_latin1_chars(&method_name_string, method_name, false);

    GDExtensionClassMethodCall call_func = call_0_args_with_ret;
    GDExtensionClassMethodPtrCall ptrcall_func = ptrcall_0_args_with_ret;

    GDExtensionPropertyInfo return_info = make_property(return_type, "");

    GDExtensionClassMethodInfo method_info = {
        .name = &method_name_string,
        .method_userdata = function,
        .call_func = call_func,
        .ptrcall_func = ptrcall_func,
        .method_flags = GDEXTENSION_METHOD_FLAGS_DEFAULT,
        .has_return_value = true,
        .return_value_info = &return_info,
        .return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
        .argument_count = 0,
    };

    StringName class_name_string;
    constructors.string_name_new_with_latin1_chars(&class_name_string, class_name, false);

    api.classdb_register_extension_class_method(class_library, &class_name_string, &method_info);

    // Destruct things.
    destructors.string_name_destructor(&method_name_string);
    destructors.string_name_destructor(&class_name_string);
    destruct_property(&return_info);
}

// Generic method binding: 1 argument, no return
static void bind_method_1_no_ret(
    const char *class_name,
    const char *method_name,
    void *function,
    const char *arg1_name,
    GDExtensionVariantType arg1_type)
{
    StringName method_name_string;
    constructors.string_name_new_with_latin1_chars(&method_name_string, method_name, false);

    GDExtensionPropertyInfo args_info[] = {
        make_property(arg1_type, arg1_name),
    };
    GDExtensionClassMethodArgumentMetadata args_metadata[] = {
        GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
    };

    GDExtensionClassMethodInfo method_info = {
        .name = &method_name_string,
        .method_userdata = function,
        .call_func = call_1_arg_no_ret,
        .ptrcall_func = ptrcall_1_arg_no_ret,
        .method_flags = GDEXTENSION_METHOD_FLAG_NORMAL,
        .has_return_value = false,
        .return_value_info = NULL,
        .return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
        .argument_count = 1,
        .arguments_info = args_info,
        .arguments_metadata = args_metadata,
        .default_argument_count = 0,
        .default_arguments = NULL
    };

    StringName class_name_string;
    constructors.string_name_new_with_latin1_chars(&class_name_string, class_name, false);

    api.classdb_register_extension_class_method(class_library, &class_name_string, &method_info);

    destructors.string_name_destructor(&method_name_string);
    destructors.string_name_destructor(&class_name_string);
    destruct_property(&args_info[0]);
}

// 1 argument, with return
static void call_1_arg_with_ret(void *method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr *p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError *r_error)
{
    void (*function)(void *, GDExtensionClassInstancePtr, const GDExtensionConstVariantPtr *, GDExtensionInt, GDExtensionVariantPtr, GDExtensionCallError *) = method_userdata;
    function(method_userdata, p_instance, p_args, p_argument_count, r_return, r_error);
}

static void ptrcall_1_arg_with_ret(void *method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr *p_args, GDExtensionTypePtr r_ret)
{
    void (*function)(void *, GDExtensionClassInstancePtr, const GDExtensionConstTypePtr *, GDExtensionTypePtr) = method_userdata;
    function(method_userdata, p_instance, p_args, r_ret);
}

// Generic method binding: 1 argument, with return
static void bind_method_1_with_ret(
    const char *class_name,
    const char *method_name,
    void *function,
    const char *arg1_name,
    GDExtensionVariantType arg1_type,
    GDExtensionVariantType return_type)
{
    StringName method_name_string;
    constructors.string_name_new_with_latin1_chars(&method_name_string, method_name, false);

    GDExtensionPropertyInfo args_info[] = {
        make_property(arg1_type, arg1_name),
    };
    GDExtensionClassMethodArgumentMetadata args_metadata[] = {
        GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
    };

    GDExtensionPropertyInfo return_info = make_property(return_type, "");

    GDExtensionClassMethodInfo method_info = {
        .name = &method_name_string,
        .method_userdata = function,
        .call_func = call_1_arg_with_ret,
        .ptrcall_func = ptrcall_1_arg_with_ret,
        .method_flags = GDEXTENSION_METHOD_FLAG_NORMAL,
        .has_return_value = true,
        .return_value_info = &return_info,
        .return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
        .argument_count = 1,
        .arguments_info = args_info,
        .arguments_metadata = args_metadata,
        .default_argument_count = 0,
        .default_arguments = NULL
    };

    StringName class_name_string;
    constructors.string_name_new_with_latin1_chars(&class_name_string, class_name, false);

    api.classdb_register_extension_class_method(class_library, &class_name_string, &method_info);

    destructors.string_name_destructor(&method_name_string);
    destructors.string_name_destructor(&class_name_string);
    destruct_property(&args_info[0]);
    destruct_property(&return_info);
}

// Generic method binding: 2 arguments, no return
static void bind_method_2_no_ret(
    const char *class_name,
    const char *method_name,
    void *function,
    const char *arg1_name,
    GDExtensionVariantType arg1_type,
    const char *arg2_name,
    GDExtensionVariantType arg2_type)
{
    StringName method_name_string;
    constructors.string_name_new_with_latin1_chars(&method_name_string, method_name, false);

    GDExtensionPropertyInfo args_info[] = {
        make_property(arg1_type, arg1_name),
        make_property(arg2_type, arg2_name),
    };
    GDExtensionClassMethodArgumentMetadata args_metadata[] = {
        GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
        GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
    };

    GDExtensionClassMethodInfo method_info = {
        .name = &method_name_string,
        .method_userdata = function,
        .call_func = call_2_args_no_ret,
        .ptrcall_func = ptrcall_2_args_no_ret,
        .method_flags = GDEXTENSION_METHOD_FLAG_NORMAL,
        .has_return_value = false,
        .return_value_info = NULL,
        .return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
        .argument_count = 2,
        .arguments_info = args_info,
        .arguments_metadata = args_metadata,
        .default_argument_count = 0,
        .default_arguments = NULL
    };

    StringName class_name_string;
    constructors.string_name_new_with_latin1_chars(&class_name_string, class_name, false);

    api.classdb_register_extension_class_method(class_library, &class_name_string, &method_info);

    destructors.string_name_destructor(&method_name_string);
    destructors.string_name_destructor(&class_name_string);
    destruct_property(&args_info[0]);
    destruct_property(&args_info[1]);
}

// Signal binding helpers
static void bind_signal_0(
    const char *class_name,
    const char *signal_name)
{
    StringName class_string_name;
    constructors.string_name_new_with_latin1_chars(&class_string_name, class_name, false);
    StringName signal_string_name;
    constructors.string_name_new_with_latin1_chars(&signal_string_name, signal_name, false);

    api.classdb_register_extension_class_signal(class_library, &class_string_name, &signal_string_name, NULL, 0);

    // Destruct things.
    destructors.string_name_destructor(&class_string_name);
    destructors.string_name_destructor(&signal_string_name);
}

static void bind_signal_1(
    const char *class_name,
    const char *signal_name,
    const char *arg1_name,
    GDExtensionVariantType arg1_type)
{
    StringName class_string_name;
    constructors.string_name_new_with_latin1_chars(&class_string_name, class_name, false);
    StringName signal_string_name;
    constructors.string_name_new_with_latin1_chars(&signal_string_name, signal_name, false);

    GDExtensionPropertyInfo args_info[] = {
        make_property(arg1_type, arg1_name),
    };

    api.classdb_register_extension_class_signal(class_library, &class_string_name, &signal_string_name, args_info, 1);

    // Destruct things.
    destructors.string_name_destructor(&class_string_name);
    destructors.string_name_destructor(&signal_string_name);
    destruct_property(&args_info[0]);
}

static void bind_signal_2(
    const char *class_name,
    const char *signal_name,
    const char *arg1_name,
    GDExtensionVariantType arg1_type,
    const char *arg2_name,
    GDExtensionVariantType arg2_type)
{
    StringName class_string_name;
    constructors.string_name_new_with_latin1_chars(&class_string_name, class_name, false);
    StringName signal_string_name;
    constructors.string_name_new_with_latin1_chars(&signal_string_name, signal_name, false);

    GDExtensionPropertyInfo args_info[] = {
        make_property(arg1_type, arg1_name),
        make_property(arg2_type, arg2_name),
    };

    api.classdb_register_extension_class_signal(class_library, &class_string_name, &signal_string_name, args_info, 2);

    // Destruct things.
    destructors.string_name_destructor(&class_string_name);
    destructors.string_name_destructor(&signal_string_name);
    destruct_property(&args_info[0]);
    destruct_property(&args_info[1]);
}

static void register_colyseus_client(void) {
    GDExtensionClassCreationInfo2 class_info = {
        .is_virtual = false,
        .is_abstract = false,
        .is_exposed = true,
        .set_func = NULL,
        .get_func = NULL,
        .get_property_list_func = NULL,
        .free_property_list_func = NULL,
        .property_can_revert_func = NULL,
        .property_get_revert_func = NULL,
        .validate_property_func = NULL,
        .notification_func = NULL,
        .to_string_func = NULL,
        .reference_func = NULL,  // Let Godot handle RefCounted reference counting
        .unreference_func = NULL,
        .create_instance_func = gdext_colyseus_client_constructor,
        .free_instance_func = gdext_colyseus_client_destructor,
        .recreate_instance_func = NULL,
        .get_virtual_func = NULL,
        .get_virtual_call_data_func = NULL,
        .call_virtual_with_data_func = NULL,
        .get_rid_func = NULL,
        .class_userdata = NULL,
    };

    // Initialize StringNames
    StringName class_name;
    StringName parent_class_name;

    constructors.string_name_new_with_latin1_chars(&class_name, "ColyseusClient", false);
    constructors.string_name_new_with_latin1_chars(&parent_class_name, "RefCounted", false);

    api.classdb_register_extension_class2(class_library, &class_name, &parent_class_name, &class_info);

    // Register methods using generic helpers
    bind_method_1_no_ret(
        "ColyseusClient",
        "connect_to",
        gdext_colyseus_client_connect_to,
        "endpoint",
        GDEXTENSION_VARIANT_TYPE_STRING
    );

    // Manual registration for get_endpoint (needs separate call/ptrcall functions)
    {
        StringName method_name_string;
        constructors.string_name_new_with_latin1_chars(&method_name_string, "get_endpoint", false);

        GDExtensionPropertyInfo return_info = make_property(GDEXTENSION_VARIANT_TYPE_STRING, "");

        GDExtensionClassMethodInfo method_info = {
            .name = &method_name_string,
            .method_userdata = NULL,
            .call_func = (GDExtensionClassMethodCall)gdext_colyseus_client_get_endpoint_call,
            .ptrcall_func = (GDExtensionClassMethodPtrCall)gdext_colyseus_client_get_endpoint_ptrcall,
            .method_flags = GDEXTENSION_METHOD_FLAG_NORMAL,
            .has_return_value = true,
            .return_value_info = &return_info,
            .return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
            .argument_count = 0,
            .arguments_info = NULL,
            .arguments_metadata = NULL,
            .default_argument_count = 0,
            .default_arguments = NULL
        };

        StringName class_name_string;
        constructors.string_name_new_with_latin1_chars(&class_name_string, "ColyseusClient", false);

        api.classdb_register_extension_class_method(class_library, &class_name_string, &method_info);

        destructors.string_name_destructor(&method_name_string);
        destructors.string_name_destructor(&class_name_string);
        destruct_property(&return_info);
    }

    // Manual registration for join_or_create (needs separate call/ptrcall functions)
    {
        StringName method_name_string;
        constructors.string_name_new_with_latin1_chars(&method_name_string, "join_or_create", false);

        GDExtensionPropertyInfo args_info[] = {
            make_property(GDEXTENSION_VARIANT_TYPE_STRING, "room_name"),
        };
        GDExtensionClassMethodArgumentMetadata args_metadata[] = {
            GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
        };

        GDExtensionPropertyInfo return_info = make_property(GDEXTENSION_VARIANT_TYPE_OBJECT, "");

        GDExtensionClassMethodInfo method_info = {
            .name = &method_name_string,
            .method_userdata = NULL,  // Not used since we provide direct function pointers
            .call_func = (GDExtensionClassMethodCall)gdext_colyseus_client_join_or_create,
            .ptrcall_func = (GDExtensionClassMethodPtrCall)gdext_colyseus_client_join_or_create_ptrcall,
            .method_flags = GDEXTENSION_METHOD_FLAG_NORMAL,
            .has_return_value = true,
            .return_value_info = &return_info,
            .return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
            .argument_count = 1,
            .arguments_info = args_info,
            .arguments_metadata = args_metadata,
            .default_argument_count = 0,
            .default_arguments = NULL
        };

        StringName class_name_string;
        constructors.string_name_new_with_latin1_chars(&class_name_string, "ColyseusClient", false);

        api.classdb_register_extension_class_method(class_library, &class_name_string, &method_info);

        destructors.string_name_destructor(&method_name_string);
        destructors.string_name_destructor(&class_name_string);
        destruct_property(&args_info[0]);
        destruct_property(&return_info);
    }
}

// Forward declaration for vararg call wrapper (defined later)
static void call_vararg(void *method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr *p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError *r_error);

static void register_colyseus_room(void) {
    GDExtensionClassCreationInfo2 class_info = {
        .is_virtual = false,
        .is_abstract = false,
        .is_exposed = true,
        .set_func = NULL,
        .get_func = NULL,
        .get_property_list_func = NULL,
        .free_property_list_func = NULL,
        .property_can_revert_func = NULL,
        .property_get_revert_func = NULL,
        .validate_property_func = NULL,
        .notification_func = NULL,
        .to_string_func = NULL,
        .reference_func = NULL,  // Let Godot handle RefCounted reference counting
        .unreference_func = NULL,
        .create_instance_func = gdext_colyseus_room_constructor,
        .free_instance_func = gdext_colyseus_room_destructor,
        .recreate_instance_func = NULL,
        .get_virtual_func = NULL,
        .get_virtual_call_data_func = NULL,
        .call_virtual_with_data_func = NULL,
        .get_rid_func = NULL,
        .class_userdata = NULL
    };

    // Initialize StringNames
    StringName class_name;
    StringName parent_class_name;

    constructors.string_name_new_with_latin1_chars(&class_name, "ColyseusRoom", false);
    constructors.string_name_new_with_latin1_chars(&parent_class_name, "RefCounted", false);

    api.classdb_register_extension_class2(class_library, &class_name, &parent_class_name, &class_info);

    // Register signals using helper functions
    bind_signal_0("ColyseusRoom", "joined");
    bind_signal_0("ColyseusRoom", "state_changed");
    bind_signal_2("ColyseusRoom", "message_received", "type", GDEXTENSION_VARIANT_TYPE_NIL, "data", GDEXTENSION_VARIANT_TYPE_NIL);
    bind_signal_2("ColyseusRoom", "error", "code", GDEXTENSION_VARIANT_TYPE_INT, "message", GDEXTENSION_VARIANT_TYPE_STRING);
    bind_signal_2("ColyseusRoom", "left", "code", GDEXTENSION_VARIANT_TYPE_INT, "reason", GDEXTENSION_VARIANT_TYPE_STRING);

    // Register send_message methods using vararg interface (accepts any Variant type for data)
    {
        StringName method_name_string;
        constructors.string_name_new_with_latin1_chars(&method_name_string, "send_message", false);

        GDExtensionPropertyInfo args_info[] = {
            make_property(GDEXTENSION_VARIANT_TYPE_STRING, "type"),
            make_property(GDEXTENSION_VARIANT_TYPE_NIL, "data"),  // NIL = any Variant type
        };
        GDExtensionClassMethodArgumentMetadata args_metadata[] = {
            GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
            GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
        };

        GDExtensionClassMethodInfo method_info = {
            .name = &method_name_string,
            .method_userdata = (void*)gdext_colyseus_room_send_message,
            .call_func = call_vararg,
            .ptrcall_func = NULL,  // Vararg methods don't support ptrcall
            .method_flags = GDEXTENSION_METHOD_FLAG_NORMAL,
            .has_return_value = false,
            .return_value_info = NULL,
            .return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
            .argument_count = 2,
            .arguments_info = args_info,
            .arguments_metadata = args_metadata,
            .default_argument_count = 0,
            .default_arguments = NULL
        };

        StringName class_name_string;
        constructors.string_name_new_with_latin1_chars(&class_name_string, "ColyseusRoom", false);

        api.classdb_register_extension_class_method(class_library, &class_name_string, &method_info);

        destructors.string_name_destructor(&method_name_string);
        destructors.string_name_destructor(&class_name_string);
        destruct_property(&args_info[0]);
        destruct_property(&args_info[1]);
    }

    {
        StringName method_name_string;
        constructors.string_name_new_with_latin1_chars(&method_name_string, "send_message_int", false);

        GDExtensionPropertyInfo args_info[] = {
            make_property(GDEXTENSION_VARIANT_TYPE_INT, "type"),
            make_property(GDEXTENSION_VARIANT_TYPE_NIL, "data"),  // NIL = any Variant type
        };
        GDExtensionClassMethodArgumentMetadata args_metadata[] = {
            GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
            GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
        };

        GDExtensionClassMethodInfo method_info = {
            .name = &method_name_string,
            .method_userdata = (void*)gdext_colyseus_room_send_message_int,
            .call_func = call_vararg,
            .ptrcall_func = NULL,  // Vararg methods don't support ptrcall
            .method_flags = GDEXTENSION_METHOD_FLAG_NORMAL,
            .has_return_value = false,
            .return_value_info = NULL,
            .return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
            .argument_count = 2,
            .arguments_info = args_info,
            .arguments_metadata = args_metadata,
            .default_argument_count = 0,
            .default_arguments = NULL
        };

        StringName class_name_string;
        constructors.string_name_new_with_latin1_chars(&class_name_string, "ColyseusRoom", false);

        api.classdb_register_extension_class_method(class_library, &class_name_string, &method_info);

        destructors.string_name_destructor(&method_name_string);
        destructors.string_name_destructor(&class_name_string);
        destruct_property(&args_info[0]);
        destruct_property(&args_info[1]);
    }

    bind_method_0_no_ret(
        "ColyseusRoom",
        "leave",
        gdext_colyseus_room_leave
    );

    bind_method_0_with_ret(
        "ColyseusRoom",
        "get_id",
        gdext_colyseus_room_get_id,
        GDEXTENSION_VARIANT_TYPE_STRING
    );

    bind_method_0_with_ret(
        "ColyseusRoom",
        "get_session_id",
        gdext_colyseus_room_get_session_id,
        GDEXTENSION_VARIANT_TYPE_STRING
    );

    bind_method_0_with_ret(
        "ColyseusRoom",
        "get_name",
        gdext_colyseus_room_get_name,
        GDEXTENSION_VARIANT_TYPE_STRING
    );

    bind_method_0_with_ret(
        "ColyseusRoom",
        "has_joined",
        gdext_colyseus_room_has_joined,
        GDEXTENSION_VARIANT_TYPE_BOOL
    );

    // get_state - returns Dictionary (always dictionary for now to avoid variant issues)
    bind_method_0_with_ret(
        "ColyseusRoom",
        "get_state",
        gdext_colyseus_room_get_state_ptrcall,
        GDEXTENSION_VARIANT_TYPE_DICTIONARY
    );

    // set_state_type - vararg to accept either String or GDScript class
    {
        StringName method_name_string;
        constructors.string_name_new_with_latin1_chars(&method_name_string, "set_state_type", false);

        GDExtensionPropertyInfo args_info[] = {
            make_property(GDEXTENSION_VARIANT_TYPE_NIL, "state_type"),  // NIL means any type
        };
        GDExtensionClassMethodArgumentMetadata args_metadata[] = {
            GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
        };

        GDExtensionClassMethodInfo method_info = {
            .name = &method_name_string,
            .method_userdata = (void*)gdext_colyseus_room_set_state_type,
            .call_func = call_vararg,
            .ptrcall_func = NULL,  // Vararg methods don't support ptrcall
            .method_flags = GDEXTENSION_METHOD_FLAGS_DEFAULT,
            .has_return_value = false,
            .return_value_info = NULL,
            .return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
            .argument_count = 1,
            .arguments_info = args_info,
            .arguments_metadata = args_metadata,
            .default_argument_count = 0,
            .default_arguments = NULL
        };

        StringName class_name_string;
        constructors.string_name_new_with_latin1_chars(&class_name_string, "ColyseusRoom", false);

        api.classdb_register_extension_class_method(class_library, &class_name_string, &method_info);

        destructors.string_name_destructor(&method_name_string);
        destructors.string_name_destructor(&class_name_string);
        destruct_property(&args_info[0]);
    }
}

// Vararg call wrapper for methods that take variable arguments
static void call_vararg(void *method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr *p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError *r_error)
{
    void (*function)(void *, GDExtensionClassInstancePtr, const GDExtensionConstVariantPtr *, GDExtensionInt, GDExtensionVariantPtr, GDExtensionCallError *) = method_userdata;
    function(method_userdata, p_instance, p_args, p_argument_count, r_return, r_error);
}

static void register_colyseus_callbacks(void) {
    GDExtensionClassCreationInfo2 class_info = {
        .is_virtual = false,
        .is_abstract = false,
        .is_exposed = true,
        .set_func = NULL,
        .get_func = NULL,
        .get_property_list_func = NULL,
        .free_property_list_func = NULL,
        .property_can_revert_func = NULL,
        .property_get_revert_func = NULL,
        .validate_property_func = NULL,
        .notification_func = NULL,
        .to_string_func = NULL,
        .reference_func = NULL,
        .unreference_func = NULL,
        .create_instance_func = gdext_colyseus_callbacks_constructor,
        .free_instance_func = gdext_colyseus_callbacks_destructor,
        .recreate_instance_func = NULL,
        .get_virtual_func = NULL,
        .get_virtual_call_data_func = NULL,
        .call_virtual_with_data_func = NULL,
        .get_rid_func = NULL,
        .class_userdata = NULL
    };

    StringName class_name;
    StringName parent_class_name;

    constructors.string_name_new_with_latin1_chars(&class_name, "ColyseusCallbacks", false);
    constructors.string_name_new_with_latin1_chars(&parent_class_name, "RefCounted", false);

    api.classdb_register_extension_class2(class_library, &class_name, &parent_class_name, &class_info);

    // Register static method: get(room) -> ColyseusCallbacks
    {
        StringName method_name_string;
        constructors.string_name_new_with_latin1_chars(&method_name_string, "get", false);

        GDExtensionPropertyInfo args_info[] = {
            make_property(GDEXTENSION_VARIANT_TYPE_OBJECT, "room"),
        };
        GDExtensionClassMethodArgumentMetadata args_metadata[] = {
            GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
        };

        GDExtensionPropertyInfo return_info = make_property(GDEXTENSION_VARIANT_TYPE_OBJECT, "");

        GDExtensionClassMethodInfo method_info = {
            .name = &method_name_string,
            .method_userdata = (void*)gdext_colyseus_callbacks_get,
            .call_func = call_vararg,
            .ptrcall_func = NULL,  // Vararg methods don't support ptrcall
            .method_flags = GDEXTENSION_METHOD_FLAG_STATIC,  // Static method
            .has_return_value = true,
            .return_value_info = &return_info,
            .return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
            .argument_count = 1,
            .arguments_info = args_info,
            .arguments_metadata = args_metadata,
            .default_argument_count = 0,
            .default_arguments = NULL
        };

        StringName class_name_string;
        constructors.string_name_new_with_latin1_chars(&class_name_string, "ColyseusCallbacks", false);

        api.classdb_register_extension_class_method(class_library, &class_name_string, &method_info);

        destructors.string_name_destructor(&method_name_string);
        destructors.string_name_destructor(&class_name_string);
        destruct_property(&args_info[0]);
        destruct_property(&return_info);
    }

    // Register listen method (vararg: target, property_or_callback, [callback])
    {
        StringName method_name_string;
        constructors.string_name_new_with_latin1_chars(&method_name_string, "listen", false);

        // We declare 2 args but accept more via vararg
        GDExtensionPropertyInfo args_info[] = {
            make_property(GDEXTENSION_VARIANT_TYPE_NIL, "target"),  // String or Dictionary
            make_property(GDEXTENSION_VARIANT_TYPE_NIL, "property_or_callback"),
        };
        GDExtensionClassMethodArgumentMetadata args_metadata[] = {
            GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
            GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
        };

        GDExtensionPropertyInfo return_info = make_property(GDEXTENSION_VARIANT_TYPE_INT, "");

        GDExtensionClassMethodInfo method_info = {
            .name = &method_name_string,
            .method_userdata = (void*)gdext_colyseus_callbacks_listen,
            .call_func = call_vararg,
            .ptrcall_func = NULL,
            .method_flags = GDEXTENSION_METHOD_FLAG_VARARG,  // Vararg to handle overloads
            .has_return_value = true,
            .return_value_info = &return_info,
            .return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
            .argument_count = 0,  // 0 for vararg
            .arguments_info = NULL,
            .arguments_metadata = NULL,
            .default_argument_count = 0,
            .default_arguments = NULL
        };

        StringName class_name_string;
        constructors.string_name_new_with_latin1_chars(&class_name_string, "ColyseusCallbacks", false);

        api.classdb_register_extension_class_method(class_library, &class_name_string, &method_info);

        destructors.string_name_destructor(&method_name_string);
        destructors.string_name_destructor(&class_name_string);
        destruct_property(&args_info[0]);
        destruct_property(&args_info[1]);
        destruct_property(&return_info);
    }

    // Register on_add method (vararg)
    {
        StringName method_name_string;
        constructors.string_name_new_with_latin1_chars(&method_name_string, "on_add", false);

        GDExtensionPropertyInfo return_info = make_property(GDEXTENSION_VARIANT_TYPE_INT, "");

        GDExtensionClassMethodInfo method_info = {
            .name = &method_name_string,
            .method_userdata = (void*)gdext_colyseus_callbacks_on_add,
            .call_func = call_vararg,
            .ptrcall_func = NULL,
            .method_flags = GDEXTENSION_METHOD_FLAG_VARARG,
            .has_return_value = true,
            .return_value_info = &return_info,
            .return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
            .argument_count = 0,
            .arguments_info = NULL,
            .arguments_metadata = NULL,
            .default_argument_count = 0,
            .default_arguments = NULL
        };

        StringName class_name_string;
        constructors.string_name_new_with_latin1_chars(&class_name_string, "ColyseusCallbacks", false);

        api.classdb_register_extension_class_method(class_library, &class_name_string, &method_info);

        destructors.string_name_destructor(&method_name_string);
        destructors.string_name_destructor(&class_name_string);
        destruct_property(&return_info);
    }

    // Register on_remove method (vararg)
    {
        StringName method_name_string;
        constructors.string_name_new_with_latin1_chars(&method_name_string, "on_remove", false);

        GDExtensionPropertyInfo return_info = make_property(GDEXTENSION_VARIANT_TYPE_INT, "");

        GDExtensionClassMethodInfo method_info = {
            .name = &method_name_string,
            .method_userdata = (void*)gdext_colyseus_callbacks_on_remove,
            .call_func = call_vararg,
            .ptrcall_func = NULL,
            .method_flags = GDEXTENSION_METHOD_FLAG_VARARG,
            .has_return_value = true,
            .return_value_info = &return_info,
            .return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
            .argument_count = 0,
            .arguments_info = NULL,
            .arguments_metadata = NULL,
            .default_argument_count = 0,
            .default_arguments = NULL
        };

        StringName class_name_string;
        constructors.string_name_new_with_latin1_chars(&class_name_string, "ColyseusCallbacks", false);

        api.classdb_register_extension_class_method(class_library, &class_name_string, &method_info);

        destructors.string_name_destructor(&method_name_string);
        destructors.string_name_destructor(&class_name_string);
        destruct_property(&return_info);
    }

    // Register remove method
    {
        StringName method_name_string;
        constructors.string_name_new_with_latin1_chars(&method_name_string, "remove", false);

        GDExtensionPropertyInfo args_info[] = {
            make_property(GDEXTENSION_VARIANT_TYPE_INT, "handle"),
        };
        GDExtensionClassMethodArgumentMetadata args_metadata[] = {
            GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
        };

        GDExtensionClassMethodInfo method_info = {
            .name = &method_name_string,
            .method_userdata = (void*)gdext_colyseus_callbacks_remove,
            .call_func = call_vararg,
            .ptrcall_func = NULL,
            .method_flags = GDEXTENSION_METHOD_FLAG_NORMAL,
            .has_return_value = false,
            .return_value_info = NULL,
            .return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
            .argument_count = 1,
            .arguments_info = args_info,
            .arguments_metadata = args_metadata,
            .default_argument_count = 0,
            .default_arguments = NULL
        };

        StringName class_name_string;
        constructors.string_name_new_with_latin1_chars(&class_name_string, "ColyseusCallbacks", false);

        api.classdb_register_extension_class_method(class_library, &class_name_string, &method_info);

        destructors.string_name_destructor(&method_name_string);
        destructors.string_name_destructor(&class_name_string);
        destruct_property(&args_info[0]);
    }

    destructors.string_name_destructor(&class_name);
    destructors.string_name_destructor(&parent_class_name);
}

static void colyseus_initialize(void *userdata, GDExtensionInitializationLevel p_level) {
    (void)userdata;
    if (p_level != GDEXTENSION_INITIALIZATION_SCENE) {
        return;
    }
    
    register_colyseus_client();
    register_colyseus_room();
    register_colyseus_callbacks();
}

static void colyseus_deinitialize(void *userdata, GDExtensionInitializationLevel p_level) {
    (void)userdata;
    if (p_level != GDEXTENSION_INITIALIZATION_SCENE) {
        return;
    }
    
}

GDExtensionBool GDE_EXPORT colyseus_sdk_init(
    GDExtensionInterfaceGetProcAddress p_get_proc_address,
    GDExtensionClassLibraryPtr p_library,
    GDExtensionInitialization *r_initialization
) {
    class_library = p_library;

    // API functions.
    api.classdb_register_extension_class2 = (GDExtensionInterfaceClassdbRegisterExtensionClass2)p_get_proc_address("classdb_register_extension_class2");
    api.classdb_register_extension_class_method = (GDExtensionInterfaceClassdbRegisterExtensionClassMethod)p_get_proc_address("classdb_register_extension_class_method");
    api.classdb_register_extension_class_signal = (GDExtensionInterfaceClassdbRegisterExtensionClassSignal)p_get_proc_address("classdb_register_extension_class_signal");
    api.classdb_construct_object = (GDExtensionInterfaceClassdbConstructObject)p_get_proc_address("classdb_construct_object");
    api.object_set_instance = (GDExtensionInterfaceObjectSetInstance)p_get_proc_address("object_set_instance");
    api.object_set_instance_binding = (GDExtensionInterfaceObjectSetInstanceBinding)p_get_proc_address("object_set_instance_binding");
    api.object_get_instance_binding = (GDExtensionInterfaceObjectGetInstanceBinding)p_get_proc_address("object_get_instance_binding");
    api.mem_alloc = (GDExtensionInterfaceMemAlloc)p_get_proc_address("mem_alloc");
    api.mem_free = (GDExtensionInterfaceMemFree)p_get_proc_address("mem_free");
    api.variant_get_ptr_destructor = (GDExtensionInterfaceVariantGetPtrDestructor)p_get_proc_address("variant_get_ptr_destructor");
    api.string_new_with_utf8_chars_and_len = (GDExtensionInterfaceStringNewWithUtf8CharsAndLen)p_get_proc_address("string_new_with_utf8_chars_and_len");
    api.string_to_utf8_chars = (GDExtensionInterfaceStringToUtf8Chars)p_get_proc_address("string_to_utf8_chars");
    api.variant_call = (GDExtensionInterfaceVariantCall)p_get_proc_address("variant_call");
    api.packed_byte_array_operator_index = (GDExtensionInterfacePackedByteArrayOperatorIndex)p_get_proc_address("packed_byte_array_operator_index");
    api.packed_byte_array_operator_index_const = (GDExtensionInterfacePackedByteArrayOperatorIndexConst)p_get_proc_address("packed_byte_array_operator_index_const");
    api.ref_set_object = (GDExtensionInterfaceRefSetObject)p_get_proc_address("ref_set_object");
    api.dictionary_operator_index = (GDExtensionInterfaceDictionaryOperatorIndex)p_get_proc_address("dictionary_operator_index");
    api.array_operator_index = (GDExtensionInterfaceArrayOperatorIndex)p_get_proc_address("array_operator_index");
    api.array_operator_index_const = (GDExtensionInterfaceArrayOperatorIndexConst)p_get_proc_address("array_operator_index_const");
    api.variant_get_type = (GDExtensionInterfaceVariantGetType)p_get_proc_address("variant_get_type");
    api.object_get_instance_id = (GDExtensionInterfaceObjectGetInstanceId)p_get_proc_address("object_get_instance_id");
    api.object_get_instance_from_id = (GDExtensionInterfaceObjectGetInstanceFromId)p_get_proc_address("object_get_instance_from_id");
    api.callable_custom_create = (GDExtensionInterfaceCallableCustomCreate)p_get_proc_address("callable_custom_create");
    api.variant_new_copy = (GDExtensionInterfaceVariantNewCopy)p_get_proc_address("variant_new_copy");
    api.variant_stringify = (GDExtensionInterfaceVariantStringify)p_get_proc_address("variant_stringify");

    // Get variant from type constructor function
    GDExtensionInterfaceGetVariantFromTypeConstructor get_variant_from_type_constructor = 
        (GDExtensionInterfaceGetVariantFromTypeConstructor)p_get_proc_address("get_variant_from_type_constructor");
    GDExtensionInterfaceGetVariantToTypeConstructor get_variant_to_type_constructor = 
        (GDExtensionInterfaceGetVariantToTypeConstructor)p_get_proc_address("get_variant_to_type_constructor");

    // Constructors.
    constructors.string_name_new_with_latin1_chars = (GDExtensionInterfaceStringNameNewWithLatin1Chars)p_get_proc_address("string_name_new_with_latin1_chars");
    constructors.string_new_with_utf8_chars = (GDExtensionInterfaceStringNewWithUtf8Chars)p_get_proc_address("string_new_with_utf8_chars");
    constructors.string_new_with_utf8_chars_and_len = (GDExtensionInterfaceStringNewWithUtf8CharsAndLen)p_get_proc_address("string_new_with_utf8_chars_and_len");
    constructors.variant_from_string_constructor = get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_STRING);
    constructors.variant_from_bool_constructor = get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_BOOL);
    constructors.variant_from_object_constructor = get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_OBJECT);
    constructors.variant_from_packed_byte_array_constructor = get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
    constructors.variant_from_int_constructor = get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_INT);
    constructors.variant_from_float_constructor = get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_FLOAT);
    constructors.variant_from_dictionary_constructor = get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_DICTIONARY);
    constructors.variant_from_array_constructor = get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_ARRAY);
    constructors.string_from_variant_constructor = get_variant_to_type_constructor(GDEXTENSION_VARIANT_TYPE_STRING);
    constructors.dictionary_from_variant_constructor = get_variant_to_type_constructor(GDEXTENSION_VARIANT_TYPE_DICTIONARY);
    constructors.array_from_variant_constructor = get_variant_to_type_constructor(GDEXTENSION_VARIANT_TYPE_ARRAY);
    constructors.object_from_variant_constructor = get_variant_to_type_constructor(GDEXTENSION_VARIANT_TYPE_OBJECT);
    constructors.int_from_variant_constructor = get_variant_to_type_constructor(GDEXTENSION_VARIANT_TYPE_INT);
    constructors.string_name_from_variant_constructor = get_variant_to_type_constructor(GDEXTENSION_VARIANT_TYPE_STRING_NAME);
    
    // Get type constructors (index 0 = default constructor)
    GDExtensionInterfaceVariantGetPtrConstructor get_ptr_constructor = 
        (GDExtensionInterfaceVariantGetPtrConstructor)p_get_proc_address("variant_get_ptr_constructor");
    constructors.packed_byte_array_constructor = get_ptr_constructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 0);
    constructors.dictionary_constructor = get_ptr_constructor(GDEXTENSION_VARIANT_TYPE_DICTIONARY, 0);
    constructors.array_constructor = get_ptr_constructor(GDEXTENSION_VARIANT_TYPE_ARRAY, 0);
    constructors.string_from_string_name_constructor = get_ptr_constructor(GDEXTENSION_VARIANT_TYPE_STRING, 2);  // String(StringName)

    // Destructors.
    destructors.string_name_destructor = api.variant_get_ptr_destructor(GDEXTENSION_VARIANT_TYPE_STRING_NAME);
    destructors.string_destructor = api.variant_get_ptr_destructor(GDEXTENSION_VARIANT_TYPE_STRING);
    destructors.dictionary_destructor = api.variant_get_ptr_destructor(GDEXTENSION_VARIANT_TYPE_DICTIONARY);
    destructors.array_destructor = api.variant_get_ptr_destructor(GDEXTENSION_VARIANT_TYPE_ARRAY);
    destructors.packed_byte_array_destructor = api.variant_get_ptr_destructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
    destructors.variant_destroy = (GDExtensionInterfaceVariantDestroy)p_get_proc_address("variant_destroy");

    r_initialization->initialize = colyseus_initialize;
    r_initialization->deinitialize = colyseus_deinitialize;
    r_initialization->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;

    return 1;
}

