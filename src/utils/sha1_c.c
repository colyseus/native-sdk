#include "colyseus/utils/sha1_c.h"
#include <string.h>

#define SHA1_ROL(value, bits) (((value) << (bits)) | ((value) >> (32 - (bits))))

#define SHA1_BLK0(i) (block->l[i] = (SHA1_ROL(block->l[i], 24) & 0xFF00FF00) | (SHA1_ROL(block->l[i], 8) & 0x00FF00FF))
#define SHA1_BLK(i) (block->l[i & 15] = SHA1_ROL(block->l[(i + 13) & 15] ^ block->l[(i + 8) & 15] ^ block->l[(i + 2) & 15] ^ block->l[i & 15], 1))

#define SHA1_R0(v, w, x, y, z, i) z += ((w & (x ^ y)) ^ y) + SHA1_BLK0(i) + 0x5A827999 + SHA1_ROL(v, 5); w = SHA1_ROL(w, 30);
#define SHA1_R1(v, w, x, y, z, i) z += ((w & (x ^ y)) ^ y) + SHA1_BLK(i) + 0x5A827999 + SHA1_ROL(v, 5); w = SHA1_ROL(w, 30);
#define SHA1_R2(v, w, x, y, z, i) z += (w ^ x ^ y) + SHA1_BLK(i) + 0x6ED9EBA1 + SHA1_ROL(v, 5); w = SHA1_ROL(w, 30);
#define SHA1_R3(v, w, x, y, z, i) z += (((w | x) & y) | (w & x)) + SHA1_BLK(i) + 0x8F1BBCDC + SHA1_ROL(v, 5); w = SHA1_ROL(w, 30);
#define SHA1_R4(v, w, x, y, z, i) z += (w ^ x ^ y) + SHA1_BLK(i) + 0xCA62C1D6 + SHA1_ROL(v, 5); w = SHA1_ROL(w, 30);

typedef union {
    uint8_t c[64];
    uint32_t l[16];
} sha1_workspace_block_t;

static void sha1_transform(uint32_t state[5], const uint8_t buffer[64]) {
    uint32_t a, b, c, d, e;
    sha1_workspace_block_t* block = (sha1_workspace_block_t*)buffer;
    
    a = state[0];
    b = state[1];
    c = state[2];
    d = state[3];
    e = state[4];
    
    SHA1_R0(a, b, c, d, e,  0); SHA1_R0(e, a, b, c, d,  1); SHA1_R0(d, e, a, b, c,  2); SHA1_R0(c, d, e, a, b,  3);
    SHA1_R0(b, c, d, e, a,  4); SHA1_R0(a, b, c, d, e,  5); SHA1_R0(e, a, b, c, d,  6); SHA1_R0(d, e, a, b, c,  7);
    SHA1_R0(c, d, e, a, b,  8); SHA1_R0(b, c, d, e, a,  9); SHA1_R0(a, b, c, d, e, 10); SHA1_R0(e, a, b, c, d, 11);
    SHA1_R0(d, e, a, b, c, 12); SHA1_R0(c, d, e, a, b, 13); SHA1_R0(b, c, d, e, a, 14); SHA1_R0(a, b, c, d, e, 15);
    SHA1_R1(e, a, b, c, d,  0); SHA1_R1(d, e, a, b, c,  1); SHA1_R1(c, d, e, a, b,  2); SHA1_R1(b, c, d, e, a,  3);
    SHA1_R2(a, b, c, d, e,  4); SHA1_R2(e, a, b, c, d,  5); SHA1_R2(d, e, a, b, c,  6); SHA1_R2(c, d, e, a, b,  7);
    SHA1_R2(b, c, d, e, a,  8); SHA1_R2(a, b, c, d, e,  9); SHA1_R2(e, a, b, c, d, 10); SHA1_R2(d, e, a, b, c, 11);
    SHA1_R2(c, d, e, a, b, 12); SHA1_R2(b, c, d, e, a, 13); SHA1_R2(a, b, c, d, e, 14); SHA1_R2(e, a, b, c, d, 15);
    SHA1_R2(d, e, a, b, c,  0); SHA1_R2(c, d, e, a, b,  1); SHA1_R2(b, c, d, e, a,  2); SHA1_R2(a, b, c, d, e,  3);
    SHA1_R2(e, a, b, c, d,  4); SHA1_R2(d, e, a, b, c,  5); SHA1_R2(c, d, e, a, b,  6); SHA1_R2(b, c, d, e, a,  7);
    SHA1_R3(a, b, c, d, e,  8); SHA1_R3(e, a, b, c, d,  9); SHA1_R3(d, e, a, b, c, 10); SHA1_R3(c, d, e, a, b, 11);
    SHA1_R3(b, c, d, e, a, 12); SHA1_R3(a, b, c, d, e, 13); SHA1_R3(e, a, b, c, d, 14); SHA1_R3(d, e, a, b, c, 15);
    SHA1_R3(c, d, e, a, b,  0); SHA1_R3(b, c, d, e, a,  1); SHA1_R3(a, b, c, d, e,  2); SHA1_R3(e, a, b, c, d,  3);
    SHA1_R3(d, e, a, b, c,  4); SHA1_R3(c, d, e, a, b,  5); SHA1_R3(b, c, d, e, a,  6); SHA1_R3(a, b, c, d, e,  7);
    SHA1_R3(e, a, b, c, d,  8); SHA1_R3(d, e, a, b, c,  9); SHA1_R3(c, d, e, a, b, 10); SHA1_R3(b, c, d, e, a, 11);
    SHA1_R4(a, b, c, d, e, 12); SHA1_R4(e, a, b, c, d, 13); SHA1_R4(d, e, a, b, c, 14); SHA1_R4(c, d, e, a, b, 15);
    SHA1_R4(b, c, d, e, a,  0); SHA1_R4(a, b, c, d, e,  1); SHA1_R4(e, a, b, c, d,  2); SHA1_R4(d, e, a, b, c,  3);
    SHA1_R4(c, d, e, a, b,  4); SHA1_R4(b, c, d, e, a,  5); SHA1_R4(a, b, c, d, e,  6); SHA1_R4(e, a, b, c, d,  7);
    SHA1_R4(d, e, a, b, c,  8); SHA1_R4(c, d, e, a, b,  9); SHA1_R4(b, c, d, e, a, 10); SHA1_R4(a, b, c, d, e, 11);
    SHA1_R4(e, a, b, c, d, 12); SHA1_R4(d, e, a, b, c, 13); SHA1_R4(c, d, e, a, b, 14); SHA1_R4(b, c, d, e, a, 15);
    
    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
}

void sha1_init(sha1_context_t* context) {
    context->state[0] = 0x67452301;
    context->state[1] = 0xEFCDAB89;
    context->state[2] = 0x98BADCFE;
    context->state[3] = 0x10325476;
    context->state[4] = 0xC3D2E1F0;
    context->count[0] = context->count[1] = 0;
}

void sha1_update(sha1_context_t* context, const uint8_t* data, size_t len) {
    size_t i, j;
    
    j = (context->count[0] >> 3) & 63;
    
    if ((context->count[0] += len << 3) < (len << 3))
        context->count[1]++;
    
    context->count[1] += (len >> 29);
    
    if ((j + len) > 63) {
        memcpy(&context->buffer[j], data, (i = 64 - j));
        sha1_transform(context->state, context->buffer);
        
        for (; i + 63 < len; i += 64) {
            sha1_transform(context->state, &data[i]);
        }
        
        j = 0;
    } else {
        i = 0;
    }
    
    memcpy(&context->buffer[j], &data[i], len - i);
}

void sha1_final(sha1_context_t* context, uint8_t digest[20]) {
    uint8_t finalcount[8];
    
    for (int i = 0; i < 8; i++) {
        finalcount[i] = (uint8_t)((context->count[(i >= 4 ? 0 : 1)] >> ((3 - (i & 3)) * 8)) & 255);
    }
    
    sha1_update(context, (const uint8_t*)"\200", 1);
    
    while ((context->count[0] & 504) != 448) {
        sha1_update(context, (const uint8_t*)"\0", 1);
    }
    
    sha1_update(context, finalcount, 8);
    
    for (int i = 0; i < 20; i++) {
        digest[i] = (uint8_t)((context->state[i >> 2] >> ((3 - (i & 3)) * 8)) & 255);
    }
}

void sha1_hash(const uint8_t* data, size_t len, uint8_t digest[20]) {
    sha1_context_t ctx;
    sha1_init(&ctx);
    sha1_update(&ctx, data, len);
    sha1_final(&ctx, digest);
}
