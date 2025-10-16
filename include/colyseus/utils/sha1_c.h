#ifndef COLYSEUS_SHA1_C_H
#define COLYSEUS_SHA1_C_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

    typedef struct {
        uint32_t state[5];
        uint32_t count[2];
        uint8_t buffer[64];
    } sha1_context_t;

    void sha1_init(sha1_context_t* context);
    void sha1_update(sha1_context_t* context, const uint8_t* data, size_t len);
    void sha1_final(sha1_context_t* context, uint8_t digest[20]);

    /* Convenience function */
    void sha1_hash(const uint8_t* data, size_t len, uint8_t digest[20]);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_SHA1_C_H */
