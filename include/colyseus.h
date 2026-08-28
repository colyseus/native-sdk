/*
 * Colyseus Native SDK — the single public header.
 *
 *     #include <colyseus.h>
 *
 * is the whole integration surface. Nothing under colyseus/ needs to be
 * included directly, and linking the `colyseus` artifact carries the include
 * path, so a consumer needs no -I of its own.
 *
 * Every header under include/colyseus/ must appear below. `zig build` walks the
 * tree and fails when one does not: a header that reaches no umbrella reaches
 * no binding, and nothing else notices — the module still builds, the symbol
 * just isn't there.
 *
 * Requires C11 (or C++11). Under C99 the duplicated forward typedefs in room.h,
 * schema/types.h and schema/collections.h warn with -pedantic.
 *
 * No extern "C" here on purpose: each header carries its own, and wrapping them
 * again would put schema/field_access.h's static inline bodies inside a linkage
 * specification for no reason.
 */
#ifndef COLYSEUS_H
#define COLYSEUS_H

/* Core */
#include <colyseus/settings.h>
#include <colyseus/protocol.h>
#include <colyseus/transport.h>
#include <colyseus/websocket_transport.h>
#include <colyseus/http.h>
#include <colyseus/client.h>
#include <colyseus/room.h>
#include <colyseus/room_clock.h>
#include <colyseus/messages.h>
#include <colyseus/latency.h>
#include <colyseus/net_delay.h>
#include <colyseus/input_handle.h>

/* Auth */
#include <colyseus/auth/auth.h>
#include <colyseus/auth/secure_storage.h>

/* Schema */
#include <colyseus/schema.h>
#include <colyseus/schema/types.h>
#include <colyseus/schema/field_access.h>
#include <colyseus/schema/decode.h>
#include <colyseus/schema/encode.h>
#include <colyseus/schema/decoder.h>
#include <colyseus/schema/collections.h>
#include <colyseus/schema/callbacks.h>
#include <colyseus/schema/dynamic_schema.h>
#include <colyseus/schema/ref_tracker.h>
#include <colyseus/schema/input_encoder.h>
#include <colyseus/schema/quantize.h>

/* Prediction */
#include <colyseus/predict/predict.h>
#include <colyseus/predict/reconciler.h>
#include <colyseus/predict/sim_reconciler.h>
#include <colyseus/predict/events.h>
#include <colyseus/predict/spawns.h>
#include <colyseus/predict/drift.h>

/* Utils */
#include <colyseus/utils/time.h>
#include <colyseus/utils/strUtil.h>
#include <colyseus/utils/sha1_c.h>

#endif /* COLYSEUS_H */
