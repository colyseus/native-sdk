#ifndef gdext_colyseus_H
#define gdext_colyseus_H

#include <gdextension_interface.h>
#include <stdint.h>
#include <stdbool.h>
#include <colyseus/client.h>

#ifdef REAL_T_IS_DOUBLE
#define VARIANT_SIZE 40
#else
#define VARIANT_SIZE 24
#endif

#ifdef BUILD_32
#define STRING_NAME_SIZE 4
#define STRING_SIZE 4
#else
#define STRING_NAME_SIZE 8
#define STRING_SIZE 8
#endif

// Opaque types
typedef struct {
    uint8_t data[STRING_NAME_SIZE]; 
} StringName;

typedef struct {
    uint8_t data[STRING_SIZE]; 
} String;

// PackedByteArray is typically 16 bytes (pointer + size + capacity or similar)
#define PACKED_BYTE_ARRAY_SIZE 16
typedef struct {
    uint8_t data[PACKED_BYTE_ARRAY_SIZE];
} PackedByteArray;

// Dictionary and Array sizes (same as PackedByteArray in most builds)
#define DICTIONARY_SIZE 8
#define ARRAY_SIZE 8
typedef struct {
    uint8_t data[DICTIONARY_SIZE];
} Dictionary;

typedef struct {
    uint8_t data[ARRAY_SIZE];
} Array;

typedef struct {
    uint8_t data[VARIANT_SIZE];
} Variant;

// Enums.
typedef enum
{
    PROPERTY_HINT_NONE = 0,
} PropertyHint;

typedef enum
{
    PROPERTY_USAGE_NONE = 0,
    PROPERTY_USAGE_STORAGE = 2,
    PROPERTY_USAGE_EDITOR = 4,
    PROPERTY_USAGE_DEFAULT = PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR,
} PropertyUsageFlags;

// Forward declarations
typedef struct ColyseusClient ColyseusClient;
typedef struct ColyseusRoom ColyseusRoom;

// Constructors struct
struct Constructors
{
    GDExtensionInterfaceStringNameNewWithLatin1Chars string_name_new_with_latin1_chars;
    GDExtensionInterfaceStringNewWithUtf8Chars string_new_with_utf8_chars;
    GDExtensionInterfaceStringNewWithUtf8CharsAndLen string_new_with_utf8_chars_and_len;
    GDExtensionVariantFromTypeConstructorFunc variant_from_string_constructor;
    GDExtensionVariantFromTypeConstructorFunc variant_from_bool_constructor;
    GDExtensionVariantFromTypeConstructorFunc variant_from_object_constructor;
    GDExtensionVariantFromTypeConstructorFunc variant_from_packed_byte_array_constructor;
    GDExtensionVariantFromTypeConstructorFunc variant_from_int_constructor;
    GDExtensionVariantFromTypeConstructorFunc variant_from_float_constructor;
    GDExtensionVariantFromTypeConstructorFunc variant_from_dictionary_constructor;
    GDExtensionVariantFromTypeConstructorFunc variant_from_array_constructor;
    GDExtensionTypeFromVariantConstructorFunc string_from_variant_constructor;
    GDExtensionTypeFromVariantConstructorFunc dictionary_from_variant_constructor;
    GDExtensionTypeFromVariantConstructorFunc array_from_variant_constructor;
    GDExtensionTypeFromVariantConstructorFunc object_from_variant_constructor;
    GDExtensionTypeFromVariantConstructorFunc int_from_variant_constructor;
    GDExtensionTypeFromVariantConstructorFunc string_name_from_variant_constructor;
    GDExtensionPtrConstructor packed_byte_array_constructor;
    GDExtensionPtrConstructor dictionary_constructor;
    GDExtensionPtrConstructor array_constructor;
    GDExtensionPtrConstructor string_from_string_name_constructor;  // String(StringName) constructor
};

// Destructors struct
struct Destructors
{
    GDExtensionPtrDestructor string_name_destructor;
    GDExtensionPtrDestructor string_destructor;
    GDExtensionPtrDestructor dictionary_destructor;
    GDExtensionPtrDestructor array_destructor;
    GDExtensionPtrDestructor packed_byte_array_destructor;
    GDExtensionInterfaceVariantDestroy variant_destroy;
};

// Global instances (defined in register_types.c)
extern struct Constructors constructors;
extern struct Destructors destructors;

// GDExtension interface struct - holds function pointers
typedef struct {
    GDExtensionInterfaceClassdbRegisterExtensionClass2 classdb_register_extension_class2;
    GDExtensionInterfaceClassdbRegisterExtensionClassMethod classdb_register_extension_class_method;
    GDExtensionInterfaceClassdbRegisterExtensionClassSignal classdb_register_extension_class_signal;
    GDExtensionInterfaceClassdbConstructObject classdb_construct_object;
    GDExtensionInterfaceObjectSetInstance object_set_instance;
    GDExtensionInterfaceObjectSetInstanceBinding object_set_instance_binding;
    GDExtensionInterfaceObjectGetInstanceBinding object_get_instance_binding;
    GDExtensionInterfaceMemAlloc mem_alloc;
    GDExtensionInterfaceMemFree mem_free;
    GDExtensionInterfaceVariantGetPtrDestructor variant_get_ptr_destructor;
    GDExtensionInterfaceStringNewWithUtf8CharsAndLen string_new_with_utf8_chars_and_len;
    GDExtensionInterfaceStringToUtf8Chars string_to_utf8_chars;
    GDExtensionInterfaceVariantCall variant_call;
    GDExtensionInterfacePackedByteArrayOperatorIndex packed_byte_array_operator_index;
    GDExtensionInterfacePackedByteArrayOperatorIndexConst packed_byte_array_operator_index_const;
    GDExtensionInterfaceRefSetObject ref_set_object;
    GDExtensionInterfaceDictionaryOperatorIndex dictionary_operator_index;
    GDExtensionInterfaceArrayOperatorIndex array_operator_index;
    GDExtensionInterfaceArrayOperatorIndexConst array_operator_index_const;
    GDExtensionInterfaceVariantGetType variant_get_type;
    GDExtensionInterfaceObjectGetInstanceId object_get_instance_id;
    GDExtensionInterfaceObjectGetInstanceFromId object_get_instance_from_id;
    GDExtensionInterfaceCallableCustomCreate callable_custom_create;
    GDExtensionInterfaceVariantNewCopy variant_new_copy;
    GDExtensionInterfaceVariantStringify variant_stringify;
} GDExtensionInterface;

// GDExtension interface globals
extern GDExtensionInterface api;
extern GDExtensionClassLibraryPtr class_library;

// ColyseusClientWrapper type
typedef struct ColyseusClientWrapper {
    colyseus_client_t* native_client;
} ColyseusClientWrapper;

// ColyseusRoomWrapper type (forward declaration)
typedef struct {
    colyseus_room_t* native_room;
    GDExtensionObjectPtr godot_object;
    const colyseus_schema_vtable_t* pending_vtable;  // Vtable to set when native room is assigned
} ColyseusRoomWrapper;

// ColyseusClient methods
GDExtensionObjectPtr gdext_colyseus_client_constructor(void* p_class_userdata);
void gdext_colyseus_client_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance);
void gdext_colyseus_client_reference(void* p_class_userdata, GDExtensionClassInstancePtr p_instance);
void gdext_colyseus_client_unreference(void* p_class_userdata, GDExtensionClassInstancePtr p_instance);
void gdext_colyseus_client_connect_to(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_client_join_or_create(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_client_join_or_create_ptrcall(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);

// Simple getter (reference implementation style)
const char* gdext_colyseus_client_get_endpoint(const ColyseusClientWrapper* self);

// GDExtension wrappers for get_endpoint (call and ptrcall versions)
void gdext_colyseus_client_get_endpoint_ptrcall(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_client_get_endpoint_call(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);

// ColyseusRoom methods
GDExtensionObjectPtr gdext_colyseus_room_constructor(void* p_class_userdata);
ColyseusRoomWrapper* gdext_colyseus_room_get_last_wrapper(void);
ColyseusRoomWrapper* gdext_colyseus_room_get_wrapper_by_id(GDObjectInstanceID instance_id);
void gdext_colyseus_room_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance);
void gdext_colyseus_room_reference(void* p_class_userdata, GDExtensionClassInstancePtr p_instance);
void gdext_colyseus_room_unreference(void* p_class_userdata, GDExtensionClassInstancePtr p_instance);
void gdext_colyseus_room_send_message(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_room_send_message_int(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_room_leave(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_room_get_id(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_room_get_session_id(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_room_get_name(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_room_has_joined(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);

// get_state() - returns current state as Dictionary
void gdext_colyseus_room_get_state(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);

// set_state_type(name: String) - sets the schema vtable for state decoding
void gdext_colyseus_room_set_state_type(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);

#endif // gdext_colyseus_H

