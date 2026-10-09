import 'package:colyseus/colyseus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fromJson reads the server object, optional fields included', () {
    final seat = SeatReservation.fromJson(<dynamic, dynamic>{
      'name': 'my_room',
      'roomId': 'r1',
      'processId': 'p1',
      'sessionId': 's1',
      'publicAddress': 'node1.example.com',
      'devMode': true,
    });
    expect(seat.name, 'my_room');
    expect(seat.publicAddress, 'node1.example.com');
    expect(seat.reconnectionToken, isNull);
    expect(seat.devMode, isTrue);
  });

  test('toJson round-trips and leaves out what was never set', () {
    const seat = SeatReservation(name: 'n', roomId: 'r', processId: 'p', sessionId: 's');
    expect(seat.toJson(), {'name': 'n', 'roomId': 'r', 'processId': 'p', 'sessionId': 's'});
    expect(SeatReservation.fromJson(seat.toJson()).toJson(), seat.toJson());
  });

  test('fromJson names the missing field', () {
    expect(
      () => SeatReservation.fromJson({'name': 'n', 'roomId': 'r', 'sessionId': 's'}),
      throwsA(isA<FormatException>().having(
          (e) => e.message, 'message', 'Invalid seat reservation: missing processId')),
    );
  });
}
