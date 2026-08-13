/// Plumbing shared by the two surfaces whose native calls answer on a worker
/// thread: `client.http` and `client.auth`. Both hit the same two traps, so
/// both get them solved once here.
library;

import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings/native_functions.dart';

final _n = NativeFunctions.instance;

/// Reads a string the native side allocated FOR US, and releases it.
///
/// The glue hands back heap copies because the core frees its own buffers as
/// soon as its callback returns, while a listener callable runs later on the
/// event loop. Every such pointer has to be taken exactly once, whether or not
/// anyone still wants the value — dropping one leaks.
String? takeOwnedString(Pointer<Char> ptr) {
  if (ptr == nullptr) return null;
  final value = ptr.cast<Utf8>().toDartString();
  _n.freeString(ptr);
  return value;
}

/// In-flight requests, keyed by the id passed to native code and back.
///
/// One registry per surface, not per client: the reply carries its own id, so
/// a single listener callable can serve every client in the isolate.
class ReplyRegistry<T> {
  final Map<int, Completer<T>> _waiting = {};
  int _nextId = 1;

  /// Reserves an id for [completer]. Ids are never reused.
  int register(Completer<T> completer) {
    final id = _nextId++;
    _waiting[id] = completer;
    return id;
  }

  /// The completer for [id], or null when it has already been settled — a
  /// reply can arrive after a timeout, or twice if native code misbehaves.
  Completer<T>? take(int id) {
    final completer = _waiting.remove(id);
    return (completer == null || completer.isCompleted) ? null : completer;
  }
}
