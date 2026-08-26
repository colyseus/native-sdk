import 'dart:ffi';

/// Dart objects handed to native code as opaque `void*` payloads.
///
/// The predict layer stores app payloads (event data, predicted spawn locals)
/// as opaque pointers it never dereferences. A Dart object has no stable
/// address, so each one is parked here and represented by a small integer
/// cast to a pointer. Native code carries the integer around and hands it
/// back; only Dart ever resolves it.
///
/// Ownership: the native side calls the `payload_free` / `local_free` hook
/// exactly once per payload, and that hook calls [releasePayload]. Anything
/// registered but never handed to native code would leak, so [retainPayload]
/// is only called at the moment of handoff.
final Map<int, Object?> _payloads = {};

/// Cookie 0 is reserved so a null payload maps to `nullptr`.
int _nextCookie = 1;

/// Parks [payload] and returns the pointer to hand to native code.
///
/// A null payload becomes `nullptr` and costs no slot.
Pointer<Void> retainPayload(Object? payload) {
  if (payload == null) return nullptr;
  final cookie = _nextCookie++;
  _payloads[cookie] = payload;
  return Pointer<Void>.fromAddress(cookie);
}

/// The Dart object behind a payload pointer, or null.
Object? payloadFor(Pointer<Void> pointer) {
  if (pointer == nullptr) return null;
  return _payloads[pointer.address];
}

/// Releases a payload's slot. Called from the native free hook.
Object? releasePayload(Pointer<Void> pointer) {
  if (pointer == nullptr) return null;
  return _payloads.remove(pointer.address);
}

/// How many payloads are currently parked. For leak assertions in tests.
int get parkedPayloadCount => _payloads.length;
