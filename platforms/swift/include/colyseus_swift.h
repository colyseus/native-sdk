/*
 * Umbrella header for the CColyseus module.
 *
 * Every public header the xcframework ships must appear here — clang warns
 * (-Wincomplete-umbrella) about any that does not, which is what catches a
 * header added to the core but never surfaced to Swift.
 *
 * websocket_transport.h and tls_context.h are deliberately absent: they pull
 * in wslay and mbedTLS headers, and Swift needs neither (transports come from
 * the default factory, TLS is configured through settings.h).
 */
#ifndef COLYSEUS_SWIFT_H
#define COLYSEUS_SWIFT_H

/* Core */
#include <colyseus/settings.h>
#include <colyseus/protocol.h>
#include <colyseus/transport.h>
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

#endif /* COLYSEUS_SWIFT_H */
