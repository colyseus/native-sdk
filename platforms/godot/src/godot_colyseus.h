#ifndef gdext_colyseus_H
#define gdext_colyseus_H

#include <gdextension_interface.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <colyseus/client.h>

/*
 * Builtin wrapper sizes must match the target Godot build configuration.
 * See platforms/godot/include/extension_api.json for the authoritative values.
 */
#ifdef REAL_T_IS_DOUBLE
#define GDEXT_COLYSEUS_VARIANT_SIZE 40
#else
#define GDEXT_COLYSEUS_VARIANT_SIZE 24
#endif

#if UINTPTR_MAX == 0xffffffffu
#define GDEXT_COLYSEUS_STRING_NAME_SIZE 4
#define GDEXT_COLYSEUS_STRING_SIZE 4
#define GDEXT_COLYSEUS_PACKED_BYTE_ARRAY_SIZE 8
#define GDEXT_COLYSEUS_DICTIONARY_SIZE 4
#define GDEXT_COLYSEUS_ARRAY_SIZE 4
#else
#define GDEXT_COLYSEUS_STRING_NAME_SIZE 8
#define GDEXT_COLYSEUS_STRING_SIZE 8
#define GDEXT_COLYSEUS_PACKED_BYTE_ARRAY_SIZE 16
#define GDEXT_COLYSEUS_DICTIONARY_SIZE 8
#define GDEXT_COLYSEUS_ARRAY_SIZE 8
#endif

// Opaque types
#define GDEXT_COLYSEUS_VARIANT_WORDS (GDEXT_COLYSEUS_VARIANT_SIZE / sizeof(uintptr_t))
#define GDEXT_COLYSEUS_STRING_WORDS (GDEXT_COLYSEUS_STRING_SIZE / sizeof(uintptr_t))
#define GDEXT_COLYSEUS_STRING_NAME_WORDS (GDEXT_COLYSEUS_STRING_NAME_SIZE / sizeof(uintptr_t))
#define GDEXT_COLYSEUS_PACKED_BYTE_ARRAY_WORDS (GDEXT_COLYSEUS_PACKED_BYTE_ARRAY_SIZE / sizeof(uintptr_t))
#define GDEXT_COLYSEUS_DICTIONARY_WORDS (GDEXT_COLYSEUS_DICTIONARY_SIZE / sizeof(uintptr_t))
#define GDEXT_COLYSEUS_ARRAY_WORDS (GDEXT_COLYSEUS_ARRAY_SIZE / sizeof(uintptr_t))

_Static_assert(GDEXT_COLYSEUS_VARIANT_SIZE % sizeof(uintptr_t) == 0, "Variant size must be word-aligned");
_Static_assert(GDEXT_COLYSEUS_STRING_SIZE % sizeof(uintptr_t) == 0, "String size must be word-aligned");
_Static_assert(GDEXT_COLYSEUS_STRING_NAME_SIZE % sizeof(uintptr_t) == 0, "StringName size must be word-aligned");
_Static_assert(GDEXT_COLYSEUS_PACKED_BYTE_ARRAY_SIZE % sizeof(uintptr_t) == 0, "PackedByteArray size must be word-aligned");
_Static_assert(GDEXT_COLYSEUS_DICTIONARY_SIZE % sizeof(uintptr_t) == 0, "Dictionary size must be word-aligned");
_Static_assert(GDEXT_COLYSEUS_ARRAY_SIZE % sizeof(uintptr_t) == 0, "Array size must be word-aligned");

typedef union {
    uint8_t data[GDEXT_COLYSEUS_STRING_NAME_SIZE];
    uintptr_t words[GDEXT_COLYSEUS_STRING_NAME_WORDS];
} StringName;

typedef union {
    uint8_t data[GDEXT_COLYSEUS_STRING_SIZE];
    uintptr_t words[GDEXT_COLYSEUS_STRING_WORDS];
} String;

typedef union {
    uint8_t data[GDEXT_COLYSEUS_PACKED_BYTE_ARRAY_SIZE];
    uintptr_t words[GDEXT_COLYSEUS_PACKED_BYTE_ARRAY_WORDS];
    uint64_t align_u64;
    void *align_ptr;
} PackedByteArray;

typedef union {
    uint8_t data[GDEXT_COLYSEUS_DICTIONARY_SIZE];
    uintptr_t words[GDEXT_COLYSEUS_DICTIONARY_WORDS];
} Dictionary;

typedef union {
    uint8_t data[GDEXT_COLYSEUS_ARRAY_SIZE];
    uintptr_t words[GDEXT_COLYSEUS_ARRAY_WORDS];
} Array;

typedef union {
    uint8_t data[GDEXT_COLYSEUS_VARIANT_SIZE];
    uintptr_t words[GDEXT_COLYSEUS_VARIANT_WORDS];
    uint64_t align_u64;
    double align_f64;
    void *align_ptr;
} Variant;

typedef Variant GDExtensionValueStorage;

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
    PROPERTY_USAGE_NIL_IS_VARIANT = 1 << 17,  // 131072 - indicates NIL type means "any Variant"
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
    GDExtensionTypeFromVariantConstructorFunc bool_from_variant_constructor;
    GDExtensionTypeFromVariantConstructorFunc dictionary_from_variant_constructor;
    GDExtensionTypeFromVariantConstructorFunc array_from_variant_constructor;
    GDExtensionTypeFromVariantConstructorFunc object_from_variant_constructor;
    GDExtensionTypeFromVariantConstructorFunc int_from_variant_constructor;
    GDExtensionTypeFromVariantConstructorFunc float_from_variant_constructor;
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
    GDExtensionInterfaceClassdbRegisterExtensionClass4 classdb_register_extension_class4;
    GDExtensionInterfaceClassdbRegisterExtensionClass5 classdb_register_extension_class5;
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
    GDExtensionInterfaceVariantSetKeyed variant_set_keyed;
    GDExtensionInterfaceVariantSetIndexed variant_set_indexed;
    GDExtensionInterfaceVariantNewNil variant_new_nil;
    GDExtensionInterfaceObjectGetInstanceId object_get_instance_id;
    GDExtensionInterfaceObjectGetInstanceFromId object_get_instance_from_id;
    GDExtensionInterfaceCallableCustomCreate callable_custom_create;
    GDExtensionInterfaceVariantNewCopy variant_new_copy;
    GDExtensionInterfaceVariantStringify variant_stringify;
} GDExtensionInterface;

// GDExtension interface globals
extern GDExtensionInterface api;
extern GDExtensionClassLibraryPtr class_library;

static inline void gdext_variant_new_nil(Variant *variant) {
    if (api.variant_new_nil) {
        api.variant_new_nil(variant);
    } else {
        memset(variant, 0, sizeof(*variant));
    }
}

static inline void gdext_variant_assign(Variant *dst, GDExtensionConstVariantPtr src) {
    destructors.variant_destroy(dst);
    api.variant_new_copy(dst, src);
}

static inline void gdext_variant_move_assign(Variant *dst, Variant *src) {
    gdext_variant_assign(dst, src);
    destructors.variant_destroy(src);
    gdext_variant_new_nil(src);
}

static inline void gdext_variant_set_keyed(Variant *container, GDExtensionConstVariantPtr key, Variant *value) {
    GDExtensionBool valid = 0;
    api.variant_set_keyed(container, key, value, &valid);
}

static inline void gdext_variant_set_indexed(Variant *container, GDExtensionInt index, Variant *value) {
    GDExtensionBool valid = 0;
    GDExtensionBool oob = 0;
    api.variant_set_indexed(container, index, value, &valid, &oob);
}

// ColyseusClientWrapper type
typedef struct ColyseusClientWrapper {
    colyseus_client_t* native_client;
    GDExtensionObjectPtr godot_object;
    volatile int pending_http_requests;  // Track in-flight HTTP requests
} ColyseusClientWrapper;

// Forward declaration for GDScript schema context
typedef struct gdscript_schema_context gdscript_schema_context_t;

// ColyseusRoomWrapper type (forward declaration)
typedef struct {
    colyseus_room_t* native_room;
    GDExtensionObjectPtr godot_object;
    const colyseus_schema_vtable_t* pending_vtable;  // Vtable to set when native room is assigned
    gdscript_schema_context_t* gdscript_schema_ctx;  // GDScript schema context (if using GDScript classes)
    Variant* gdscript_state_instance;                 // GDScript state instance (for get_state())
} ColyseusRoomWrapper;

// ColyseusClient methods
GDExtensionObjectPtr gdext_colyseus_client_constructor(void* p_class_userdata);
void gdext_colyseus_client_destructor(void* p_class_userdata, GDExtensionClassInstancePtr p_instance);
void gdext_colyseus_client_reference(void* p_class_userdata, GDExtensionClassInstancePtr p_instance);
void gdext_colyseus_client_unreference(void* p_class_userdata, GDExtensionClassInstancePtr p_instance);
void gdext_colyseus_client_set_endpoint(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
// Matchmaking methods (call + ptrcall versions)
void gdext_colyseus_client_join_or_create(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_client_join_or_create_ptrcall(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_client_create(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_client_create_ptrcall(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_client_join(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_client_join_ptrcall(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_client_join_by_id(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_client_join_by_id_ptrcall(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_client_reconnect(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_client_reconnect_ptrcall(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);

// Simple getter (reference implementation style)
const char* gdext_colyseus_client_get_endpoint(const ColyseusClientWrapper* self);

// GDExtension wrappers for get_endpoint (call and ptrcall versions)
void gdext_colyseus_client_get_endpoint_ptrcall(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_client_get_endpoint_call(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);

// ColyseusClient HTTP methods (vararg call convention)
void gdext_colyseus_client_http_get(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_client_http_post(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_client_http_put(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_client_http_delete(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);
void gdext_colyseus_client_http_patch(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);

// ColyseusClient auth methods
void gdext_colyseus_client_auth_set_token(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
void gdext_colyseus_client_auth_get_token(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);

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
void gdext_colyseus_room_is_connected(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);

// get_state() - returns current state as Dictionary (uses ptrcall signature like other methods)
void gdext_colyseus_room_get_state(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);

// set_state_type(type) - sets the schema vtable for state decoding
// Accepts either:
//   - String: Legacy mode, looks up vtable by name in registry
//   - Object (GDScript class): New mode, parses class definition() method
void gdext_colyseus_room_set_state_type(void* p_method_userdata, GDExtensionClassInstancePtr p_instance, const GDExtensionConstVariantPtr* p_args, GDExtensionInt p_argument_count, GDExtensionVariantPtr r_return, GDExtensionCallError* r_error);

#endif // gdext_colyseus_H
