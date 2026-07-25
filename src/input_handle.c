#include "colyseus/input_handle.h"
#include "colyseus/protocol.h"
#include "colyseus/schema/dynamic_schema.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BUFFER_FLOOR 64
#define BUFFER_RTT_BUDGET_MS 1000.0
#define BUFFER_HEADROOM 1.5

struct colyseus_input_handle {
    colyseus_schema_t* data;
    const colyseus_schema_vtable_t* vtable;
    colyseus_input_encoder_t* encoder; /* owned */

    bool stamp_render;
    bool stamp_reckon;
    double render_delay;
    bool (*allow_rewind)(void* data, void* userdata);
    void* allow_rewind_userdata;
    double last_stamp;      /* delta-coded stamp baseline */
    double pending_reckon;

    int tick_rate;          /* 0 = not advertised */
    int patch_rate;
    int sub_steps;          /* >= 1 */

    int sent_count;
    int last_processed;
    int epoch;

    int replay_buffer_size;
    double* send_times;                 /* seq % size → send time */
    colyseus_schema_t** input_buffer;   /* replay ring (lazily allocated) */
    double* reckon_times;               /* per-seq reckon stamps */

    void (*send)(const uint8_t* data, size_t length, void* userdata);
    bool (*is_open)(void* userdata);
    colyseus_room_clock_t* (*get_clock)(void* userdata);
    void* userdata;

    colyseus_wbuf_t frame; /* per-send scratch */
};

colyseus_input_handle_t* colyseus_input_handle_create(
    colyseus_schema_t* data,
    const colyseus_schema_vtable_t* vtable,
    colyseus_input_encoder_t* encoder,
    bool stamp_render, bool stamp_reckon,
    const colyseus_input_options_t* options,
    int tick_rate, int patch_rate, int sub_steps,
    void (*send)(const uint8_t* data, size_t length, void* userdata),
    bool (*is_open)(void* userdata),
    colyseus_room_clock_t* (*get_clock)(void* userdata),
    void* userdata) {

    colyseus_input_handle_t* handle = calloc(1, sizeof(colyseus_input_handle_t));
    handle->data = data;
    handle->vtable = vtable;
    handle->encoder = encoder;
    handle->stamp_render = stamp_render;
    handle->stamp_reckon = stamp_reckon;
    if (options) {
        handle->render_delay = options->render_delay;
        handle->allow_rewind = options->allow_rewind;
        handle->allow_rewind_userdata = options->allow_rewind_userdata;
    }
    handle->tick_rate = tick_rate;
    handle->patch_rate = patch_rate;
    handle->sub_steps = sub_steps > 1 ? sub_steps : 1;
    handle->send = send;
    handle->is_open = is_open;
    handle->get_clock = get_clock;
    handle->userdata = userdata;

    /* replay ring sized to worst-case in-flight = (RTT budget + patch interval) × input rate */
    double step_ms = tick_rate > 0 ? 1000.0 / tick_rate : 1000.0 / 60;
    double window = BUFFER_RTT_BUDGET_MS + (patch_rate > 0 ? patch_rate : 0);
    int size = (int)ceil(window / step_ms * BUFFER_HEADROOM);
    handle->replay_buffer_size = size > BUFFER_FLOOR ? size : BUFFER_FLOOR;

    handle->send_times = calloc(handle->replay_buffer_size, sizeof(double));
    colyseus_wbuf_init(&handle->frame);
    return handle;
}

void colyseus_input_handle_free(colyseus_input_handle_t* handle) {
    if (!handle) return;
    if (handle->input_buffer) {
        for (int i = 0; i < handle->replay_buffer_size; i++) {
            if (handle->input_buffer[i]) handle->vtable->destroy(handle->input_buffer[i]);
        }
        free(handle->input_buffer);
    }
    free(handle->reckon_times);
    free(handle->send_times);
    colyseus_wbuf_free(&handle->frame);
    colyseus_input_encoder_free(handle->encoder);
    free(handle);
}

colyseus_schema_t* colyseus_input_handle_data(colyseus_input_handle_t* handle) {
    return handle->data;
}

int colyseus_input_handle_sent_count(const colyseus_input_handle_t* handle) { return handle->sent_count; }
int colyseus_input_handle_last_processed(const colyseus_input_handle_t* handle) { return handle->last_processed; }
int colyseus_input_handle_pending_count(const colyseus_input_handle_t* handle) { return handle->sent_count - handle->last_processed; }
int colyseus_input_handle_replay_buffer_size(const colyseus_input_handle_t* handle) { return handle->replay_buffer_size; }
int colyseus_input_handle_epoch(const colyseus_input_handle_t* handle) { return handle->epoch; }
int colyseus_input_handle_tick_rate(const colyseus_input_handle_t* handle) { return handle->tick_rate; }
int colyseus_input_handle_patch_rate(const colyseus_input_handle_t* handle) { return handle->patch_rate; }
int colyseus_input_handle_sub_steps(const colyseus_input_handle_t* handle) { return handle->sub_steps; }

/* Snapshot the just-sent input + its send time (and reckon stamp) by seq. */
static void record_sent(colyseus_input_handle_t* handle, int seq) {
    if (!handle->input_buffer) {
        handle->input_buffer = calloc(handle->replay_buffer_size, sizeof(colyseus_schema_t*));
        bool is_dynamic = colyseus_vtable_is_dynamic(handle->vtable);
        for (int i = 0; i < handle->replay_buffer_size; i++) {
            /* dynamic vtables have no base.create — construct via their own path */
            handle->input_buffer[i] = is_dynamic
                ? (colyseus_schema_t*)colyseus_dynamic_schema_create(
                      (const colyseus_dynamic_vtable_t*)handle->vtable)
                : handle->vtable->create();
            handle->input_buffer[i]->__vtable = handle->vtable;
        }
    }
    int slot = seq % handle->replay_buffer_size;
    colyseus_input_encoder_copy_into(handle->encoder, handle->input_buffer[slot]);
    handle->send_times[slot] = colyseus_room_clock_now(NULL);
    if (handle->stamp_reckon) {
        if (!handle->reckon_times) {
            handle->reckon_times = calloc(handle->replay_buffer_size, sizeof(double));
        }
        handle->reckon_times[slot] = handle->pending_reckon;
    }
}

int colyseus_input_handle_send(colyseus_input_handle_t* handle) {
    if (!handle->is_open || !handle->is_open(handle->userdata)) return 0;

    size_t body_length = 0;
    const uint8_t* body = colyseus_input_encoder_encode(handle->encoder, &body_length);
    bool reliable = !colyseus_input_encoder_is_unreliable(handle->encoder);

    bool want_stamp = (handle->stamp_reckon || handle->stamp_render) && reliable
        && (handle->allow_rewind == NULL
            || handle->allow_rewind(handle->data, handle->allow_rewind_userdata));
    bool both = handle->stamp_reckon && handle->stamp_render;

    colyseus_wbuf_reset(&handle->frame);
    uint8_t opcode = reliable ? COLYSEUS_PROTOCOL_ROOM_INPUT_RELIABLE
                              : COLYSEUS_PROTOCOL_ROOM_INPUT_UNRELIABLE;
    if (want_stamp) opcode |= COLYSEUS_PROTOCOL_MODIFIER_TIMED;
    colyseus_wbuf_push(&handle->frame, opcode);

    if (want_stamp) {
        colyseus_room_clock_t* clock = handle->get_clock ? handle->get_clock(handle->userdata) : NULL;
        bool synced = clock && colyseus_room_clock_last_server_time(clock) > 0;
        double rk = 0;
        double render_delta = 0;
        if (synced) {
            rk = floor(colyseus_room_clock_server_now(clock) + 0.5);
            if (rk < 0) rk = 0;
            render_delta = floor(handle->render_delay + colyseus_room_clock_smoothed_rtt(clock) / 2 + 0.5);
            if (render_delta < 0) render_delta = 0;
            if (render_delta > 0xffff) render_delta = 0xffff;
        }
        handle->pending_reckon = rk;
        /* the mode's single u32 timeline, delta-coded vs the baseline;
         * BOTH mode trails the absolute u16 renderDelta */
        double stamp = handle->stamp_reckon ? rk : (rk > render_delta ? rk - render_delta : 0);
        colyseus_encode_number(&handle->frame, stamp - handle->last_stamp);
        handle->last_stamp = stamp;
        if (both) colyseus_encode_uint16(&handle->frame, (uint16_t)render_delta);
    } else {
        handle->pending_reckon = 0;
    }

    colyseus_wbuf_append(&handle->frame, body, body_length);
    /* WS-only transport: unreliable falls back to the reliable channel */
    handle->send(handle->frame.data, handle->frame.length, handle->userdata);

    int seq;
    if (reliable) {
        seq = ++handle->sent_count; /* implicit count seq */
    } else {
        seq = handle->sent_count = colyseus_input_encoder_seq(handle->encoder);
    }
    record_sent(handle, seq);
    return seq;
}

void colyseus_input_handle_reset(colyseus_input_handle_t* handle) {
    colyseus_input_encoder_reset(handle->encoder);
    handle->sent_count = handle->last_processed = colyseus_input_encoder_seq(handle->encoder);
    handle->last_stamp = 0;
    memset(handle->send_times, 0, handle->replay_buffer_size * sizeof(double));
    handle->epoch++;
}

colyseus_schema_t* colyseus_input_handle_at(colyseus_input_handle_t* handle, int seq) {
    if (!handle->input_buffer) return NULL;
    if (seq <= handle->last_processed || seq > handle->sent_count) return NULL;
    if (handle->sent_count - seq >= handle->replay_buffer_size) return NULL;
    return handle->input_buffer[seq % handle->replay_buffer_size];
}

double colyseus_input_handle_reckon_time_at(colyseus_input_handle_t* handle, int seq) {
    if (!handle->reckon_times) return 0;
    if (seq <= handle->last_processed || seq > handle->sent_count) return 0;
    if (handle->sent_count - seq >= handle->replay_buffer_size) return 0;
    return handle->reckon_times[seq % handle->replay_buffer_size];
}

double colyseus_input_handle_ack_input(colyseus_input_handle_t* handle, int seq) {
    if (seq <= handle->last_processed) return -1;
    bool aged = handle->sent_count - seq >= handle->replay_buffer_size;
    handle->last_processed = seq;
    if (aged) return -1;
    double sent_at = handle->send_times[seq % handle->replay_buffer_size];
    return sent_at > 0 ? colyseus_room_clock_now(NULL) - sent_at : -1;
}
