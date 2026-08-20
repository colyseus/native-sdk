#include "colyseus/room_clock.h"
#include "colyseus/utils/time.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/*
 * The EMA math must be bit-identical to the JS reference (the SDK test
 * fixtures compare float64 strictly). Clang on ARM64 defaults to
 * -ffp-contract=on and fuses `a*b + c*d` into FMA, which changes the result
 * by 1 ULP vs JS (which never fuses).
 */
#pragma STDC FP_CONTRACT OFF

#define EMA_ALPHA 0.1
#define RENDER_TAU_DEFAULT 250.0
#define RENDER_SNAP 250.0
#define RTT_OUTLIER_X 4.0
#define JITTER_GAIN (1.0 / 16.0)
#define JITTER_STALL_X 4
#define RTT_GATE_FACTOR 1.2
#define RTT_GATE_WINDOW 10000.0
#define RTT_GATE_WARMUP 30
#define RTT_FLOOR_MAX 64 /* deque capacity — holds only descending record-lows */

static double default_now(void) {
    return (double)colyseus_monotonic_ms();
}

double (*colyseus_room_clock_now_provider)(void) = default_now;

static double get_now(void) {
    return colyseus_room_clock_now_provider
        ? colyseus_room_clock_now_provider()
        : default_now();
}

struct colyseus_room_clock {
    double clock_offset;
    bool clock_has_sample;
    int offset_count;

    /* sliding-window-minimum deque (front = windowed min) */
    double rtt_floor_t[RTT_FLOOR_MAX];
    double rtt_floor_v[RTT_FLOOR_MAX];
    int rtt_floor_len;

    double rtt;
    double smoothed_rtt;
    bool rtt_has_sample;

    double jitter;
    double last_recv_time;

    double last_server_time;
    double patch_interval;

    double render_tau;
    double render_sn;
    double render_sn_at;
};

colyseus_room_clock_t* colyseus_room_clock_create(void) {
    colyseus_room_clock_t* clock = calloc(1, sizeof(colyseus_room_clock_t));
    clock->last_recv_time = -1;
    clock->render_tau = RENDER_TAU_DEFAULT;
    return clock;
}

void colyseus_room_clock_free(colyseus_room_clock_t* clock) {
    free(clock);
}

double colyseus_room_clock_now(const colyseus_room_clock_t* clock) {
    (void)clock;
    return get_now();
}

double colyseus_room_clock_server_now(const colyseus_room_clock_t* clock) {
    return get_now() + clock->clock_offset;
}

double colyseus_room_clock_render_now(colyseus_room_clock_t* clock) {
    double target = colyseus_room_clock_server_now(clock);
    if (clock->render_tau <= 0) return target;
    double t = get_now();
    if (clock->render_sn == 0) {
        clock->render_sn = target;
        clock->render_sn_at = t;
        return clock->render_sn;
    }
    double dt = t - clock->render_sn_at;
    if (dt > 100) dt = 100;                /* clamp tab-resume stalls */
    if (dt < 0.5) return clock->render_sn; /* same frame — advance once */
    clock->render_sn_at = t;
    clock->render_sn += dt;                /* free-run at 1 ms/ms */
    if (fabs(target - clock->render_sn) > RENDER_SNAP) {
        clock->render_sn = target;
        return clock->render_sn;
    }
    clock->render_sn += (target - clock->render_sn) * (1 - exp(-dt / clock->render_tau));
    return clock->render_sn;
}

void colyseus_room_clock_set_render_tau(colyseus_room_clock_t* clock, double milliseconds) {
    clock->render_tau = milliseconds > 0 ? milliseconds : 0;
}

double colyseus_room_clock_rtt(const colyseus_room_clock_t* clock) { return clock->rtt; }
double colyseus_room_clock_smoothed_rtt(const colyseus_room_clock_t* clock) { return clock->smoothed_rtt; }
double colyseus_room_clock_jitter(const colyseus_room_clock_t* clock) { return clock->jitter; }
double colyseus_room_clock_last_server_time(const colyseus_room_clock_t* clock) { return clock->last_server_time; }
double colyseus_room_clock_patch_interval(const colyseus_room_clock_t* clock) { return clock->patch_interval; }
double colyseus_room_clock_offset(const colyseus_room_clock_t* clock) { return clock->clock_offset; }

void colyseus_room_clock_set_patch_interval(colyseus_room_clock_t* clock, double milliseconds) {
    clock->patch_interval = milliseconds > 0 ? milliseconds : 0;
}

/* Push an RTT sample into the sliding-window-min deque; returns the floor. */
static double push_rtt_floor(colyseus_room_clock_t* clock, double rtt_sample, double t_now) {
    /* drop back entries no lower than this sample */
    while (clock->rtt_floor_len > 0 &&
           clock->rtt_floor_v[clock->rtt_floor_len - 1] >= rtt_sample) {
        clock->rtt_floor_len--;
    }
    if (clock->rtt_floor_len < RTT_FLOOR_MAX) {
        clock->rtt_floor_v[clock->rtt_floor_len] = rtt_sample;
        clock->rtt_floor_t[clock->rtt_floor_len] = t_now;
        clock->rtt_floor_len++;
    }
    /* expire entries older than the window from the front */
    double cutoff = t_now - RTT_GATE_WINDOW;
    int drop = 0;
    while (drop < clock->rtt_floor_len && clock->rtt_floor_t[drop] < cutoff) drop++;
    if (drop > 0) {
        memmove(clock->rtt_floor_v, clock->rtt_floor_v + drop, (clock->rtt_floor_len - drop) * sizeof(double));
        memmove(clock->rtt_floor_t, clock->rtt_floor_t + drop, (clock->rtt_floor_len - drop) * sizeof(double));
        clock->rtt_floor_len -= drop;
    }
    return clock->rtt_floor_v[0];
}

void colyseus_room_clock_sample(colyseus_room_clock_t* clock, double s_now, double rtt_sample) {
    double t_now = get_now();
    const double a = EMA_ALPHA;

    /* jitter vs the cadence — idle patches round to a whole multiple; bursts
     * (mult 0) and stalls (mult > 4) are skipped */
    double pi = clock->patch_interval;
    if (clock->last_recv_time >= 0 && pi > 0) {
        double gap = t_now - clock->last_recv_time;
        double mult = floor(gap / pi + 0.5);
        if (mult >= 1 && mult <= JITTER_STALL_X) {
            clock->jitter += (fabs(gap - mult * pi) - clock->jitter) * JITTER_GAIN;
        }
    }
    clock->last_recv_time = t_now;

    clock->last_server_time = s_now;

    /* reject impossible / outlier RTT (tab-resume spikes once converged) */
    if (rtt_sample < 0) {
        rtt_sample = -1;
    } else if (clock->smoothed_rtt > 0 && rtt_sample > clock->smoothed_rtt * RTT_OUTLIER_X) {
        rtt_sample = -1;
    }

    /* offset: prefer the RTT-corrected estimate when a fresh sample exists */
    double offset_sample = rtt_sample >= 0 ? s_now + rtt_sample / 2 - t_now : s_now - t_now;
    if (!clock->clock_has_sample) {
        clock->clock_offset = offset_sample;
        clock->clock_has_sample = true;
        if (rtt_sample >= 0) {
            push_rtt_floor(clock, rtt_sample, t_now);
            clock->offset_count = 1;
        }
    } else if (rtt_sample >= 0) {
        /* gate on the windowed-min RTT floor — except during post-reset warmup */
        double floor_rtt = push_rtt_floor(clock, rtt_sample, t_now);
        bool warming = clock->offset_count < RTT_GATE_WARMUP;
        clock->offset_count++;
        if (warming || rtt_sample <= floor_rtt * RTT_GATE_FACTOR) {
            clock->clock_offset = clock->clock_offset * (1 - a) + offset_sample * a;
        }
    }

    /* RTT: seeded on the first valid sample (separate flag from the offset seed) */
    if (rtt_sample >= 0) {
        clock->rtt = rtt_sample;
        if (!clock->rtt_has_sample) {
            clock->smoothed_rtt = rtt_sample;
            clock->rtt_has_sample = true;
        } else {
            clock->smoothed_rtt = clock->smoothed_rtt * (1 - a) + rtt_sample * a;
        }
    }
}

void colyseus_room_clock_reset(colyseus_room_clock_t* clock) {
    double tau = clock->render_tau;
    double pi = clock->patch_interval;
    memset(clock, 0, sizeof(*clock));
    clock->last_recv_time = -1;
    clock->render_tau = tau;
    clock->patch_interval = pi;
}
