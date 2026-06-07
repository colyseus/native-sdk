#include "colyseus/utils/time.h"

#ifdef _WIN32
    #include <windows.h>
#elif defined(__EMSCRIPTEN__)
    #include <emscripten.h>
#elif defined(__APPLE__)
    #include <mach/mach_time.h>
#else
    #include <time.h>
#endif

uint64_t colyseus_monotonic_ms(void) {
#ifdef _WIN32
    return (uint64_t)GetTickCount64();
#elif defined(__EMSCRIPTEN__)
    return (uint64_t)emscripten_get_now();
#elif defined(__APPLE__)
    static mach_timebase_info_data_t tb = {0};
    if (tb.denom == 0) {
        mach_timebase_info(&tb);
    }
    uint64_t t = mach_absolute_time();
    /* Convert to nanoseconds then to milliseconds */
    return (t * tb.numer / tb.denom) / 1000000ULL;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
#endif
}
