import 'dart:convert';
import 'dart:typed_data';

import 'package:colyseus_flutter/src/msgpack.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  group('scalars', () {
    test('positive fixint', () {
      expect(msgpackDecode(bytes([0x00])), 0);
      expect(msgpackDecode(bytes([0x7f])), 127);
    });

    test('negative fixint', () {
      expect(msgpackDecode(bytes([0xff])), -1);
      expect(msgpackDecode(bytes([0xe0])), -32);
    });

    test('nil and booleans', () {
      expect(msgpackDecode(bytes([0xc0])), isNull);
      expect(msgpackDecode(bytes([0xc2])), isFalse);
      expect(msgpackDecode(bytes([0xc3])), isTrue);
    });

    test('sized unsigned integers', () {
      expect(msgpackDecode(bytes([0xcc, 0xff])), 255);
      expect(msgpackDecode(bytes([0xcd, 0x01, 0x00])), 256);
      expect(msgpackDecode(bytes([0xce, 0x00, 0x01, 0x00, 0x00])), 65536);
    });

    test('sized signed integers', () {
      expect(msgpackDecode(bytes([0xd0, 0xff])), -1);
      expect(msgpackDecode(bytes([0xd1, 0xff, 0x00])), -256);
      expect(msgpackDecode(bytes([0xd2, 0xff, 0xff, 0x00, 0x00])), -65536);
    });

    test('floats', () {
      final f32 = ByteData(5)
        ..setUint8(0, 0xca)
        ..setFloat32(1, 1.5);
      expect(msgpackDecode(f32.buffer.asUint8List()), 1.5);

      final f64 = ByteData(9)
        ..setUint8(0, 0xcb)
        ..setFloat64(1, -12.25);
      expect(msgpackDecode(f64.buffer.asUint8List()), -12.25);
    });
  });

  group('strings', () {
    test('fixstr', () {
      expect(msgpackDecode(bytes([0xa3, 0x61, 0x62, 0x63])), 'abc');
    });

    test('empty', () {
      expect(msgpackDecode(bytes([0xa0])), '');
    });

    test('str8 with multibyte utf-8', () {
      final encoded = utf8.encode('héllo ☃');
      expect(
        msgpackDecode(bytes([0xd9, encoded.length, ...encoded])),
        'héllo ☃',
      );
    });
  });

  group('containers', () {
    test('fixarray of scalars', () {
      expect(msgpackDecode(bytes([0x93, 0x01, 0x02, 0x03])), [1, 2, 3]);
    });

    test('fixmap with string keys', () {
      // {"a": 1, "b": true}
      final decoded = msgpackDecode(bytes([
        0x82,
        0xa1, 0x61, 0x01, //
        0xa1, 0x62, 0xc3,
      ]));
      expect(decoded, isA<Map<String, dynamic>>());
      expect(decoded, {'a': 1, 'b': true});
    });

    test('non-string keys stay dynamic', () {
      // {1: "x"}
      final decoded = msgpackDecode(bytes([0x81, 0x01, 0xa1, 0x78]));
      expect(decoded, isA<Map>());
      expect((decoded as Map)[1], 'x');
    });

    // The gap this decoder replaced: the native reader returned null for any
    // nested container, silently dropping payload.
    test('nested map inside a map', () {
      // {"outer": {"inner": 42}}
      final decoded = msgpackDecode(bytes([
        0x81,
        0xa5, 0x6f, 0x75, 0x74, 0x65, 0x72, //
        0x81,
        0xa5, 0x69, 0x6e, 0x6e, 0x65, 0x72, //
        0x2a,
      ]));
      expect(decoded, {
        'outer': {'inner': 42},
      });
    });

    test('nested array inside a map', () {
      // {"xs": [1, 2]}
      final decoded = msgpackDecode(bytes([
        0x81,
        0xa2, 0x78, 0x73, //
        0x92, 0x01, 0x02,
      ]));
      expect(decoded, {
        'xs': [1, 2],
      });
    });

    test('array of maps', () {
      // [{"a": 1}, {"a": 2}]
      final decoded = msgpackDecode(bytes([
        0x92,
        0x81, 0xa1, 0x61, 0x01, //
        0x81, 0xa1, 0x61, 0x02,
      ]));
      expect(decoded, [
        {'a': 1},
        {'a': 2},
      ]);
    });

    test('deeply nested mixed containers', () {
      // {"a": [{"b": [null, false]}]}
      final decoded = msgpackDecode(bytes([
        0x81,
        0xa1, 0x61, //
        0x91,
        0x81,
        0xa1, 0x62, //
        0x92, 0xc0, 0xc2,
      ]));
      expect(decoded, {
        'a': [
          {
            'b': [null, false],
          },
        ],
      });
    });

    test('empty containers', () {
      expect(msgpackDecode(bytes([0x90])), isEmpty);
      expect(msgpackDecode(bytes([0x80])), isEmpty);
    });
  });

  group('binary', () {
    test('bin8', () {
      expect(msgpackDecode(bytes([0xc4, 0x02, 0xde, 0xad])), bytes([0xde, 0xad]));
    });

    test('fixext carries the payload without the type tag', () {
      expect(msgpackDecode(bytes([0xd4, 0x07, 0x2a])), bytes([0x2a]));
    });
  });

  group('malformed input', () {
    test('truncated payload throws', () {
      expect(
        () => msgpackDecode(bytes([0xcd, 0x01])),
        throwsA(isA<MsgpackFormatException>()),
      );
    });

    test('reserved prefix throws', () {
      expect(
        () => msgpackDecode(bytes([0xc1])),
        throwsA(isA<MsgpackFormatException>()),
      );
    });

    test('truncated string throws', () {
      expect(
        () => msgpackDecode(bytes([0xa5, 0x61])),
        throwsA(isA<MsgpackFormatException>()),
      );
    });
  });
}
