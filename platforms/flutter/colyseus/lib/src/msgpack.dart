import 'dart:convert';
import 'dart:typed_data';

/// Thrown when a payload isn't valid MessagePack.
class MsgpackFormatException extends FormatException {
  MsgpackFormatException(super.message, [super.source, super.offset]);
}

/// Decodes a MessagePack payload into Dart values.
///
/// Maps decode to `Map<String, dynamic>` when every key is a string and to
/// `Map<dynamic, dynamic>` otherwise; arrays to `List<dynamic>`; str to
/// [String]; bin/ext to [Uint8List]. Integers stay [int], floats [double].
///
/// The outbound direction is built natively (see `buildMessage`), so this is
/// only the receive half — the native reader can't express nested containers.
Object? msgpackDecode(Uint8List bytes) => _Decoder(bytes).decodeValue();

class _Decoder {
  final Uint8List _bytes;
  final ByteData _view;
  int _offset = 0;

  _Decoder(this._bytes)
      : _view = ByteData.view(
          _bytes.buffer,
          _bytes.offsetInBytes,
          _bytes.lengthInBytes,
        );

  Object? decodeValue() {
    final byte = _readUint8();

    if (byte <= 0x7f) return byte; // positive fixint
    if (byte >= 0xe0) return byte - 0x100; // negative fixint
    if (byte >= 0x80 && byte <= 0x8f) return _readMap(byte & 0x0f);
    if (byte >= 0x90 && byte <= 0x9f) return _readArray(byte & 0x0f);
    if (byte >= 0xa0 && byte <= 0xbf) return _readString(byte & 0x1f);

    switch (byte) {
      case 0xc0:
        return null;
      case 0xc2:
        return false;
      case 0xc3:
        return true;

      case 0xc4:
        return _readBytes(_readUint8());
      case 0xc5:
        return _readBytes(_readUint16());
      case 0xc6:
        return _readBytes(_readUint32());

      // ext: the type tag is dropped, the payload comes through as bytes.
      case 0xc7:
        final length = _readUint8();
        _readUint8();
        return _readBytes(length);
      case 0xc8:
        final length = _readUint16();
        _readUint8();
        return _readBytes(length);
      case 0xc9:
        final length = _readUint32();
        _readUint8();
        return _readBytes(length);

      case 0xca:
        return _readFloat32();
      case 0xcb:
        return _readFloat64();

      case 0xcc:
        return _readUint8();
      case 0xcd:
        return _readUint16();
      case 0xce:
        return _readUint32();
      case 0xcf:
        return _readUint64();

      case 0xd0:
        return _readInt8();
      case 0xd1:
        return _readInt16();
      case 0xd2:
        return _readInt32();
      case 0xd3:
        return _readInt64();

      case 0xd4:
        _readUint8();
        return _readBytes(1);
      case 0xd5:
        _readUint8();
        return _readBytes(2);
      case 0xd6:
        _readUint8();
        return _readBytes(4);
      case 0xd7:
        _readUint8();
        return _readBytes(8);
      case 0xd8:
        _readUint8();
        return _readBytes(16);

      case 0xd9:
        return _readString(_readUint8());
      case 0xda:
        return _readString(_readUint16());
      case 0xdb:
        return _readString(_readUint32());

      case 0xdc:
        return _readArray(_readUint16());
      case 0xdd:
        return _readArray(_readUint32());

      case 0xde:
        return _readMap(_readUint16());
      case 0xdf:
        return _readMap(_readUint32());
    }

    throw MsgpackFormatException(
      'Unknown MessagePack prefix 0x${byte.toRadixString(16)}',
      _bytes,
      _offset - 1,
    );
  }

  Object _readMap(int length) {
    final entries = <dynamic, dynamic>{};
    var allStringKeys = true;
    for (var i = 0; i < length; i++) {
      final key = decodeValue();
      if (key is! String) allStringKeys = false;
      entries[key] = decodeValue();
    }
    if (!allStringKeys) return entries;
    return entries.map((key, value) => MapEntry(key as String, value));
  }

  List<dynamic> _readArray(int length) =>
      [for (var i = 0; i < length; i++) decodeValue()];

  String _readString(int length) {
    final slice = _take(length);
    // Colyseus payloads are UTF-8; tolerate malformed sequences rather than
    // dropping a whole message for one bad byte.
    return const Utf8Decoder(allowMalformed: true).convert(slice);
  }

  Uint8List _readBytes(int length) => Uint8List.fromList(_take(length));

  Uint8List _take(int length) {
    _require(length);
    final slice = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return slice;
  }

  void _require(int count) {
    if (_offset + count > _bytes.lengthInBytes) {
      throw MsgpackFormatException(
        'Truncated MessagePack payload',
        _bytes,
        _offset,
      );
    }
  }

  int _readUint8() {
    _require(1);
    return _view.getUint8(_offset++);
  }

  int _readInt8() {
    _require(1);
    return _view.getInt8(_offset++);
  }

  int _readUint16() {
    _require(2);
    final value = _view.getUint16(_offset);
    _offset += 2;
    return value;
  }

  int _readInt16() {
    _require(2);
    final value = _view.getInt16(_offset);
    _offset += 2;
    return value;
  }

  int _readUint32() {
    _require(4);
    final value = _view.getUint32(_offset);
    _offset += 4;
    return value;
  }

  int _readInt32() {
    _require(4);
    final value = _view.getInt32(_offset);
    _offset += 4;
    return value;
  }

  /// Values above 2^63-1 wrap into negative territory — Dart has no unsigned
  /// 64-bit integer, and msgpack payloads that large don't occur in practice.
  int _readUint64() {
    _require(8);
    final value = _view.getUint64(_offset);
    _offset += 8;
    return value;
  }

  int _readInt64() {
    _require(8);
    final value = _view.getInt64(_offset);
    _offset += 8;
    return value;
  }

  double _readFloat32() {
    _require(4);
    final value = _view.getFloat32(_offset);
    _offset += 4;
    return value;
  }

  double _readFloat64() {
    _require(8);
    final value = _view.getFloat64(_offset);
    _offset += 8;
    return value;
  }
}
