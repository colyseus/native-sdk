#include "godot_colyseus.h"
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
    printf("[ColyseusClient] Starting registration\n");
    fflush(stdout);

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

    printf("[ColyseusClient] Allocating StringNames\n");
    fflush(stdout);

    // Initialize StringNames
    StringName class_name;
    StringName parent_class_name;

    printf("[ColyseusClient] Creating class_name StringName\n");
    fflush(stdout);
    constructors.string_name_new_with_latin1_chars(&class_name, "ColyseusClient", false);

    printf("[ColyseusClient] Creating parent_class_name StringName\n");
    fflush(stdout);
    constructors.string_name_new_with_latin1_chars(&parent_class_name, "RefCounted", false);

    printf("[ColyseusClient] Registering class\n");
    fflush(stdout);
    api.classdb_register_extension_class2(class_library, &class_name, &parent_class_name, &class_info);
    printf("[ColyseusClient] Class registered successfully\n");
    fflush(stdout);

    // Register methods using generic helpers
    printf("[ColyseusClient] Registering connect_to method\n");
    fflush(stdout);

    bind_method_1_no_ret(
        "ColyseusClient",
        "connect_to",
        gdext_colyseus_client_connect_to,
        "endpoint",
        GDEXTENSION_VARIANT_TYPE_STRING
    );

    printf("[ColyseusClient] connect_to method registered successfully\n");
    fflush(stdout);

    printf("[ColyseusClient] Registering get_endpoint method\n");
    fflush(stdout);

    bind_method_0_with_ret(
        "ColyseusClient",
        "get_endpoint",
        gdext_colyseus_client_get_endpoint_wrapper,
        GDEXTENSION_VARIANT_TYPE_STRING
    );

    printf("[ColyseusClient] get_endpoint method registered successfully\n");
    fflush(stdout);

    printf("[ColyseusClient] Registering join_or_create method\n");
    fflush(stdout);

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

    printf("[ColyseusClient] join_or_create method registered successfully\n");
    fflush(stdout);

    printf("[ColyseusClient] Registration complete\n");
    fflush(stdout);
}

static void register_colyseus_room(void) {
    printf("[ColyseusRoom] Starting registration\n");
    fflush(stdout);
    
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
    bind_signal_1("ColyseusRoom", "message_received", "data", GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
    bind_signal_2("ColyseusRoom", "error", "code", GDEXTENSION_VARIANT_TYPE_INT, "message", GDEXTENSION_VARIANT_TYPE_STRING);
    bind_signal_2("ColyseusRoom", "left", "code", GDEXTENSION_VARIANT_TYPE_INT, "reason", GDEXTENSION_VARIANT_TYPE_STRING);

    // Register methods using generic helpers
    
    bind_method_2_no_ret(
        "ColyseusRoom",
        "send_message",
        gdext_colyseus_room_send_message,
        "type",
        GDEXTENSION_VARIANT_TYPE_STRING,
        "data",
        GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY
    );

    bind_method_2_no_ret(
        "ColyseusRoom",
        "send_message_int",
        gdext_colyseus_room_send_message_int,
        "type",
        GDEXTENSION_VARIANT_TYPE_INT,
        "data",
        GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY
    );

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
}

static void colyseus_initialize(void *userdata, GDExtensionInitializationLevel p_level) {
    (void)userdata;
    if (p_level != GDEXTENSION_INITIALIZATION_SCENE) {
        return;
    }
    
    register_colyseus_client();
    register_colyseus_room();
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

    // Get variant from type constructor function
    GDExtensionInterfaceGetVariantFromTypeConstructor get_variant_from_type_constructor = 
        (GDExtensionInterfaceGetVariantFromTypeConstructor)p_get_proc_address("get_variant_from_type_constructor");
    GDExtensionInterfaceGetVariantToTypeConstructor get_variant_to_type_constructor = 
        (GDExtensionInterfaceGetVariantToTypeConstructor)p_get_proc_address("get_variant_to_type_constructor");

    // Constructors.
    constructors.string_name_new_with_latin1_chars = (GDExtensionInterfaceStringNameNewWithLatin1Chars)p_get_proc_address("string_name_new_with_latin1_chars");
    constructors.string_new_with_utf8_chars = (GDExtensionInterfaceStringNewWithUtf8Chars)p_get_proc_address("string_new_with_utf8_chars");
    constructors.variant_from_string_constructor = get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_STRING);
    constructors.variant_from_bool_constructor = get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_BOOL);
    constructors.variant_from_object_constructor = get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_OBJECT);
    constructors.string_from_variant_constructor = get_variant_to_type_constructor(GDEXTENSION_VARIANT_TYPE_STRING);

    // Destructors.
    destructors.string_name_destructor = api.variant_get_ptr_destructor(GDEXTENSION_VARIANT_TYPE_STRING_NAME);
    destructors.string_destructor = api.variant_get_ptr_destructor(GDEXTENSION_VARIANT_TYPE_STRING);
    destructors.variant_destroy = (GDExtensionInterfaceVariantDestroy)p_get_proc_address("variant_destroy");

    r_initialization->initialize = colyseus_initialize;
    r_initialization->deinitialize = colyseus_deinitialize;
    r_initialization->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;

    return 1;
}

