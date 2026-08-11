/// Event types from the native layer.
enum ColyseusEventType {
  none(0),
  roomJoin(1),
  roomStateChange(2),
  roomMessage(3),
  roomError(4),
  roomLeave(5),
  clientError(6),
  propertyChange(7),
  itemAdd(8),
  itemRemove(9),
  roomDrop(14),
  roomReconnect(15);

  final int value;
  const ColyseusEventType(this.value);

  static ColyseusEventType fromValue(int v) {
    return ColyseusEventType.values.firstWhere(
      (e) => e.value == v,
      orElse: () => ColyseusEventType.none,
    );
  }
}

/// Message value types from the native msgpack reader.
enum MessageValueType {
  nil(0),
  boolean(1),
  integer(2),
  unsignedInteger(3),
  float(4),
  string(5),
  binary(6),
  array(7),
  map(8);

  final int value;
  const MessageValueType(this.value);

  static MessageValueType fromValue(int v) {
    return MessageValueType.values.firstWhere(
      (e) => e.value == v,
      orElse: () => MessageValueType.nil,
    );
  }
}

/// Schema field types.
enum SchemaFieldType {
  string(0),
  number(1),
  boolean(2),
  int8(3),
  uint8(4),
  int16(5),
  uint16(6),
  int32(7),
  uint32(8),
  int64(9),
  uint64(10),
  float32(11),
  float64(12),
  ref(13),
  array(14),
  map(15);

  final int value;
  const SchemaFieldType(this.value);

  static SchemaFieldType? fromValue(int v) {
    if (v < 0 || v >= SchemaFieldType.values.length) return null;
    return SchemaFieldType.values[v];
  }

  bool get isNumeric =>
      this != SchemaFieldType.string &&
      this != SchemaFieldType.ref &&
      this != SchemaFieldType.array &&
      this != SchemaFieldType.map;
}

/// Error from a Colyseus room or client operation.
class ColyseusError {
  final int code;
  final String message;

  const ColyseusError(this.code, this.message);

  @override
  String toString() => 'ColyseusError($code: $message)';
}
