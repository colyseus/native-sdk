@Tags(['integration'])
library;

import 'package:colyseus/colyseus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// `client.http` against the example-server's `/test` routes.
///
/// The core's http calls BLOCK, so the binding queues them on a worker thread
/// and answers through a listener callable. That makes the interesting cases
/// the boring-looking ones: a request must not stall the isolate, replies must
/// land on the right future, and every string that crosses back has to be
/// released rather than leaked.
void main() {
  setUpAll(() => requireServer(exampleServer));

  test('GET returns the route payload', () async {
    final client = ColyseusClient(exampleServer);
    final res = await client.http.get('/test');

    expect(res.statusCode, 200);
    expect(res.json['things'], [1, 2, 3, 4, 5, 6]);
    client.dispose();
  });

  test('POST sends a JSON body and echoes it back', () async {
    final client = ColyseusClient(exampleServer);
    final res = await client.http.post('/test', body: {'name': 'endel', 'n': 7});

    expect(res.statusCode, 200);
    expect(res.json['method'], 'POST');
    expect(res.json['body']['name'], 'endel');
    expect(res.json['body']['n'], 7);
    client.dispose();
  });

  test('PUT, PATCH and DELETE each reach their own route', () async {
    final client = ColyseusClient(exampleServer);

    final put = await client.http.put('/test', body: {'v': 1});
    expect(put.json['method'], 'PUT');
    expect(put.json['body']['v'], 1);

    final patch = await client.http.patch('/test', body: {'v': 2});
    expect(patch.json['method'], 'PATCH');
    expect(patch.json['body']['v'], 2);

    final del = await client.http.delete('/test');
    expect(del.json['method'], 'DELETE');

    client.dispose();
  });

  test('a String body goes out verbatim', () async {
    final client = ColyseusClient(exampleServer);
    final res = await client.http.post('/test', body: '{"raw":true}');

    expect(res.json['body']['raw'], isTrue);
    client.dispose();
  });

  test('a non-2xx reply throws with the status', () async {
    final client = ColyseusClient(exampleServer);

    await expectLater(
      client.http.get('/no_such_route'),
      throwsA(isA<ColyseusHttpException>()
          .having((e) => e.code, 'code', greaterThanOrEqualTo(400))),
    );
    client.dispose();
  });

  test('a non-JSON body is still readable', () async {
    final client = ColyseusClient(exampleServer);
    final res = await client.http.get('/hello_world');

    expect(res.body, contains('bubblegum'));
    expect(res.json, isNull, reason: 'plain text is not JSON');
    client.dispose();
  });

  // The whole point of the worker thread. Timers are useless to check it —
  // a localhost round trip fits inside one tick — so compare how long the
  // CALL takes against how long the request takes. Blocking would make them
  // equal; queueing makes the call almost free.
  test('the call returns without waiting for the round trip', () async {
    final client = ColyseusClient(exampleServer);
    // Warm the connection so the measured request isn't paying for setup.
    await client.http.get('/test');

    final watch = Stopwatch()..start();
    final pending = client.http.get('/test');
    final callUs = watch.elapsedMicroseconds;
    final res = await pending;
    final totalUs = watch.elapsedMicroseconds;

    expect(res.statusCode, 200);
    expect(totalUs, greaterThan(200),
        reason: 'round trip too fast to tell anything from');
    expect(callUs, lessThan(totalUs ~/ 2),
        reason: 'get() took ${callUs}us of a ${totalUs}us round trip, so it '
            'ran the request on this thread');
    client.dispose();
  });

  // Replies come back by request id, so overlapping calls must not cross.
  test('concurrent requests resolve to their own replies', () async {
    final client = ColyseusClient(exampleServer);

    final results = await Future.wait([
      client.http.post('/test', body: {'i': 0}),
      client.http.post('/test', body: {'i': 1}),
      client.http.post('/test', body: {'i': 2}),
      client.http.get('/test'),
    ]);

    expect(results[0].json['body']['i'], 0);
    expect(results[1].json['body']['i'], 1);
    expect(results[2].json['body']['i'], 2);
    expect(results[3].json['things'], hasLength(6));
    client.dispose();
  });

  test('several clients each answer their own requests', () async {
    final a = ColyseusClient(exampleServer);
    final b = ColyseusClient(exampleServer);

    final results = await Future.wait([
      a.http.post('/test', body: {'who': 'a'}),
      b.http.post('/test', body: {'who': 'b'}),
    ]);

    expect(results[0].json['body']['who'], 'a');
    expect(results[1].json['body']['who'], 'b');
    a.dispose();
    b.dispose();
  });

  test('requesting through a disposed client fails instead of crashing',
      () async {
    final client = ColyseusClient(exampleServer);
    await client.http.get('/test');
    client.dispose();

    await expectLater(
        client.http.get('/test'), throwsA(isA<ColyseusHttpException>()));
  });

  test('the auth token rides along as a Bearer header', () async {
    final client = ColyseusClient(exampleServer);
    client.http.authToken = 'test-token';

    // The route ignores the header; this pins that setting it neither crashes
    // nor breaks the request path.
    final res = await client.http.get('/test');
    expect(res.statusCode, 200);

    client.http.authToken = null;
    expect((await client.http.get('/test')).statusCode, 200);
    client.dispose();
  });
}
