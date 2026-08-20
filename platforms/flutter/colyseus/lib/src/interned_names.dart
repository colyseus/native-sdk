import 'dart:ffi';

import 'package:ffi/ffi.dart';

final _interned = <String, Pointer<Char>>{};

/// A stable native string for [name], allocated once per distinct name.
///
/// The per-frame prediction reads take field names as `const char*`. Encoding
/// and freeing a fresh buffer on each of those calls would dominate their
/// cost, and field names are a small closed set fixed by the schema — so they
/// are interned for the life of the process and never freed.
///
/// Only for names that come from schema definitions. Do not pass user- or
/// server-supplied strings through here: an unbounded key space would leak.
Pointer<Char> internedName(String name) {
  return _interned.putIfAbsent(name, () => name.toNativeUtf8().cast<Char>());
}
