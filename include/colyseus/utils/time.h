#ifndef COLYSEUS_TIME_H
#define COLYSEUS_TIME_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Returns a monotonic timestamp in milliseconds. Suitable for measuring
 * intervals; the absolute value has no defined epoch. */
uint64_t colyseus_monotonic_ms(void);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_TIME_H */
