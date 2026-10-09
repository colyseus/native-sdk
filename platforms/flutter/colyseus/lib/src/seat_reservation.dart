/// A seat the server reserved for this client: what the server's
/// `matchMaker.joinOrCreate()` / `create()` / `join()` / `joinById()` /
/// `reserveSeatFor()` return. Join with it through
/// `ColyseusClient.consumeSeatReservation`.
///
/// Reads straight from a server route's JSON or a lobby room's message:
///
/// ```dart
/// final response = await client.http.post('/find_match');
/// final seat = SeatReservation.fromJson(response.json);
/// ```
class SeatReservation {
  const SeatReservation({
    required this.name,
    required this.roomId,
    required this.processId,
    required this.sessionId,
    this.publicAddress,
    this.reconnectionToken,
    this.devMode,
  });

  /// From the reservation object as the server serializes it. Takes any
  /// `Map`, so a decoded message payload works as-is.
  factory SeatReservation.fromJson(Map<dynamic, dynamic> json) {
    String field(String key) {
      final value = json[key];
      if (value is String) return value;
      throw FormatException('Invalid seat reservation: missing $key');
    }

    return SeatReservation(
      name: field('name'),
      roomId: field('roomId'),
      processId: field('processId'),
      sessionId: field('sessionId'),
      publicAddress: json['publicAddress'] as String?,
      reconnectionToken: json['reconnectionToken'] as String?,
      devMode: json['devMode'] as bool?,
    );
  }

  /// The room's name, as defined on the server.
  final String name;
  final String roomId;

  /// The server process hosting the room.
  final String processId;
  final String sessionId;

  /// Where that process is reached, when it differs from the client's
  /// endpoint. Set by servers configured with a `publicAddress`.
  final String? publicAddress;

  /// Set when the reservation re-takes a seat held for reconnection.
  final String? reconnectionToken;
  final bool? devMode;

  Map<String, dynamic> toJson() => {
        'name': name,
        'roomId': roomId,
        'processId': processId,
        'sessionId': sessionId,
        if (publicAddress != null) 'publicAddress': publicAddress,
        if (reconnectionToken != null) 'reconnectionToken': reconnectionToken,
        if (devMode != null) 'devMode': devMode,
      };

  @override
  String toString() => 'SeatReservation($name, roomId: $roomId, sessionId: $sessionId)';
}
