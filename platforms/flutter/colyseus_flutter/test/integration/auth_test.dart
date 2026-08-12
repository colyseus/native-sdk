@Tags(['integration'])
library;

import 'package:colyseus_flutter/colyseus_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// `client.auth` against the example-server's `@colyseus/auth` routes.
///
/// The server keeps its users in a list that lives for the process, so every
/// test that registers uses a fresh address.
String _freshEmail() =>
    'flutter-${DateTime.now().microsecondsSinceEpoch}@example.com';

void main() {
  setUpAll(() => requireServer(exampleServer));

  // The token is persisted in the platform's secure storage under one
  // process-wide key, so a signed-in run leaks into every later one — other
  // suites then join the playground carrying a token its onAuth rejects.
  // Leave the machine signed out.
  tearDownAll(() {
    final client = ColyseusClient(exampleServer);
    client.auth.signOut();
    client.dispose();
  });

  test('anonymous sign-in returns a token and a user', () async {
    final client = ColyseusClient(exampleServer);
    final data = await client.auth.signInAnonymously();

    expect(data.token, isNotNull);
    expect(data.token, isNotEmpty);
    expect(data.user?['anonymous'], isTrue);
    expect(data.user?['anonymousId'], isNotNull);
    client.dispose();
  });

  // A fresh client restores whatever token secure storage still holds, so a
  // "starts signed out" assertion would depend on what ran before it.
  test('the token is kept on the client after signing in', () async {
    final client = ColyseusClient(exampleServer);
    client.auth.signOut();
    expect(client.auth.token, isNull, reason: 'signOut should clear it');

    final data = await client.auth.signInAnonymously();
    expect(client.auth.token, data.token);
    client.dispose();
  });

  // The whole point of the token: it authenticates the next request.
  test('getUserData reads back the signed-in user', () async {
    final client = ColyseusClient(exampleServer);
    final signIn = await client.auth.signInAnonymously();

    final data = await client.auth.getUserData();
    expect(data.user?['anonymousId'], signIn.user?['anonymousId']);
    client.dispose();
  });

  test('getUserData without a token fails rather than hanging', () async {
    final client = ColyseusClient(exampleServer);
    client.auth.signOut(); // a restored token would make this a real request

    await expectLater(
        client.auth.getUserData(), throwsA(isA<ColyseusAuthException>()));
    client.dispose();
  });

  test('register then sign in with the same credentials', () async {
    final client = ColyseusClient(exampleServer);
    final email = _freshEmail();

    final registered = await client.auth.registerWithEmailAndPassword(
        email, 'secret123');
    expect(registered.token, isNotEmpty);
    expect(registered.user?['email'], email);

    // A second client proves the sign-in stands on its own rather than
    // reading the first client's leftover token.
    final other = ColyseusClient(exampleServer);
    final signedIn =
        await other.auth.signInWithEmailAndPassword(email, 'secret123');
    expect(signedIn.token, isNotEmpty);
    expect(signedIn.user?['email'], email);

    client.dispose();
    other.dispose();
  });

  test('registering carries options through to the user record', () async {
    final client = ColyseusClient(exampleServer);
    final email = _freshEmail();

    final data = await client.auth.registerWithEmailAndPassword(
        email, 'secret123',
        options: {'displayName': 'Endel', 'level': 3});

    expect(data.user?['options']?['displayName'], 'Endel');
    expect(data.user?['options']?['level'], 3);
    client.dispose();
  });

  test('signing in with a wrong password fails', () async {
    final client = ColyseusClient(exampleServer);
    final email = _freshEmail();
    await client.auth.registerWithEmailAndPassword(email, 'secret123');

    final other = ColyseusClient(exampleServer);
    await expectLater(
      other.auth.signInWithEmailAndPassword(email, 'not-the-password'),
      throwsA(isA<ColyseusAuthException>()),
    );
    client.dispose();
    other.dispose();
  });

  test('a token set by hand is used for the next call', () async {
    final source = ColyseusClient(exampleServer);
    final signIn = await source.auth.signInAnonymously();

    // The reason to expose the setter: carry a session across app launches.
    final restored = ColyseusClient(exampleServer);
    restored.auth.token = signIn.token;
    expect(restored.auth.token, signIn.token);

    final data = await restored.auth.getUserData();
    expect(data.user?['anonymousId'], signIn.user?['anonymousId']);

    source.dispose();
    restored.dispose();
  });

  test('onChange reports the sign-in and the sign-out', () async {
    final client = ColyseusClient(exampleServer);

    final seen = <ColyseusAuthData>[];
    final sub = client.auth.onChange.listen(seen.add);
    // Give the subscription a turn of the loop before the request goes out.
    await settle(const Duration(milliseconds: 50));

    await client.auth.signInAnonymously();
    expect(await waitFor(() => seen.isNotEmpty), isTrue,
        reason: 'no change fired for the sign-in');
    expect(seen.last.token, isNotEmpty);

    final afterSignIn = seen.length;
    client.auth.signOut();
    expect(await waitFor(() => seen.length > afterSignIn), isTrue,
        reason: 'no change fired for the sign-out');
    expect(seen.last.token, anyOf(isNull, isEmpty));

    await sub.cancel();
    client.dispose();
  });

  // The native hook now names the auth handle it fired for, so a program
  // holding two clients does not see the other one's sign-ins.
  test('onChange only reports its own client', () async {
    final a = ColyseusClient(exampleServer);
    final b = ColyseusClient(exampleServer);

    final seenA = <ColyseusAuthData>[];
    final seenB = <ColyseusAuthData>[];
    final subA = a.auth.onChange.listen(seenA.add);
    final subB = b.auth.onChange.listen(seenB.add);
    await settle(const Duration(milliseconds: 50));

    await a.auth.signInAnonymously();
    expect(await waitFor(() => seenA.any((d) => d.token != null)), isTrue);
    await settle(const Duration(milliseconds: 100));
    // Subscribing emits the current state, so b has its own signed-out event;
    // what it must never see is a's token.
    expect(seenB.every((d) => d.token == null), isTrue,
        reason: 'b saw a token that belonged to a');

    await subA.cancel();
    await subB.cancel();
    a.dispose();
    b.dispose();
  });

  test('signOut clears the token', () async {
    final client = ColyseusClient(exampleServer);
    await client.auth.signInAnonymously();
    expect(client.auth.token, isNotNull);

    client.auth.signOut();
    expect(client.auth.token, isNull);
    client.dispose();
  });

  test('the token authenticates a plain http call too', () async {
    final client = ColyseusClient(exampleServer);
    await client.auth.signInAnonymously();

    // auth and http share the client's token, so the auth module signing in
    // is enough for client.http to be authenticated.
    final res = await client.http.get('/auth/userdata');
    expect(res.statusCode, 200);
    expect(res.json['user']['anonymous'], isTrue);
    client.dispose();
  });

  test('calling through a disposed client fails instead of crashing',
      () async {
    final client = ColyseusClient(exampleServer);
    await client.auth.signInAnonymously();
    client.dispose();

    await expectLater(client.auth.signInAnonymously(),
        throwsA(isA<ColyseusAuthException>()));
  });
}
