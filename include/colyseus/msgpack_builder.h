#ifndef COLYSEUS_MSGPACK_BUILDER_H
#define COLYSEUS_MSGPACK_BUILDER_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct msgpack_payload msgpack_payload_t;

/* Creation functions */
msgpack_payload_t* msgpack_map_create(void);
msgpack_payload_t* msgpack_array_create(void);
msgpack_payload_t* msgpack_nil_create(void);
msgpack_payload_t* msgpack_bool_create(bool value);
msgpack_payload_t* msgpack_int_create(int64_t value);
msgpack_payload_t* msgpack_uint_create(uint64_t value);
msgpack_payload_t* msgpack_float_create(double value);
msgpack_payload_t* msgpack_str_create(const char* value);

/* Map operations */
void msgpack_map_put_str(msgpack_payload_t* map, const char* key, const char* value);
void msgpack_map_put_int(msgpack_payload_t* map, const char* key, int64_t value);
void msgpack_map_put_uint(msgpack_payload_t* map, const char* key, uint64_t value);
void msgpack_map_put_float(msgpack_payload_t* map, const char* key, double value);
void msgpack_map_put_bool(msgpack_payload_t* map, const char* key, bool value);
void msgpack_map_put_nil(msgpack_payload_t* map, const char* key);
void msgpack_map_put_payload(msgpack_payload_t* map, const char* key, msgpack_payload_t* value);

/* Array operations */
void msgpack_array_push_str(msgpack_payload_t* arr, const char* value);
void msgpack_array_push_int(msgpack_payload_t* arr, int64_t value);
void msgpack_array_push_uint(msgpack_payload_t* arr, uint64_t value);
void msgpack_array_push_float(msgpack_payload_t* arr, double value);
void msgpack_array_push_bool(msgpack_payload_t* arr, bool value);
void msgpack_array_push_nil(msgpack_payload_t* arr);
void msgpack_array_push_payload(msgpack_payload_t* arr, msgpack_payload_t* value);

/* Encoding */
uint8_t* msgpack_payload_encode(msgpack_payload_t* payload, size_t* out_len);

/* Cleanup */
void msgpack_payload_free(msgpack_payload_t* payload);
void msgpack_encoded_data_free(uint8_t* data, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_MSGPACK_BUILDER_H */
