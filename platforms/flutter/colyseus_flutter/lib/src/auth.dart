import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings/colyseus_core.dart';
import 'bindings/native_functions.dart';
import 'colyseus.dart';

final _n = NativeFunctions.instance;

/// An auth call that the server rejected, or that never reached it.
class ColyseusAuthException implements Exception {
  ColyseusAuthException(this.message);

  final String message;

  @override
  String toString() => 'ColyseusAuthException: $message';
}

/// The token and user record a successful auth call returns.
class ColyseusAuthData {
  ColyseusAuthData(this.token, this.rawUser);

  /// The JWT, forwarded on every later HTTP request and room join.
  ///
  /// Null after a sign-out, and on a call that returns only a user record.
  final String? token;

  /// The `user` payload as it arrived, or null when the call carried none.
  final String? rawUser;

  /// [rawUser] decoded as JSON, or null when absent or malformed.
  Map<String, dynamic>? get user {
    final raw = rawUser;
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() =>
      'ColyseusAuthData(token: ${token == null ? 'none' : 'set'}, '
      'user: ${user?.keys.toList()})';
}

final Map<int, Completer<ColyseusAuthData>> _pending = {};
int _nextRequestId = 1;

String? _takeString(Pointer<Char> ptr) {
  if (ptr == nullptr) return null;
  final value = ptr.cast<Utf8>().toDartString();
  _n.freeString(ptr);
  return value;
}

void _onAuthReply(int requestId, Pointer<Char> userJson, Pointer<Char> token,
    Pointer<Char> error) {
  final completer = _pending.remove(requestId);

  // Always drain, even with nobody waiting — these are copies made for us.
  final user = _takeString(userJson);
  final tokenText = _takeString(token);
  final errorText = _takeString(error);

  if (completer == null || completer.isCompleted) return;
  if (errorText != null) {
    completer.completeError(ColyseusAuthException(errorText));
    return;
  }
  completer.complete(ColyseusAuthData(tokenText, user));
}

NativeCallable<AuthReplyNative>? _replyCallable;

Pointer<NativeFunction<AuthReplyNative>> _authReplyPointer() {
  return (_replyCallable ??=
          NativeCallable<AuthReplyNative>.listener(_onAuthReply))
      .nativeFunction;
}

/// Change notifications, keyed by the auth handle they belong to.
final Map<int, StreamController<ColyseusAuthData>> _changeControllers = {};
NativeCallable<AuthChangeNative>? _changeCallable;

void _onAuthChange(Pointer<Char> userJson, Pointer<Char> token) {
  final user = _takeString(userJson);
  final tokenText = _takeString(token);
  final data = ColyseusAuthData(tokenText, user);
  // The native hook carries no handle, and one client per isolate is the
  // normal case; broadcast to every live subscriber rather than guess.
  for (final controller in _changeControllers.values) {
    if (!controller.isClosed) controller.add(data);
  }
}

/// The auth surface of a [ColyseusClient], reached as `client.auth`.
///
/// Mirrors the TypeScript SDK: the token is stored on the client and sent as a
/// Bearer header on every later HTTP request, so signing in once is enough.
///
/// ```dart
/// final data = await client.auth.signInAnonymously();
/// print(data.user?['id']);
/// ```
class ColyseusAuth {
  ColyseusAuth(this._client);

  final Pointer<colyseus_client_t> _client;

  Pointer<colyseus_auth_t> get _handle => core.colyseus_client_get_auth(_client);

  /// The current token, or null when signed out.
  String? get token {
    final auth = _handle;
    if (auth == nullptr) return null;
    final ptr = _n.authGetToken(auth.address);
    final value = _takeString(ptr);
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Adopt a token obtained elsewhere (a previous session, your own backend).
  set token(String? value) {
    final auth = _handle;
    if (auth == nullptr) return;
    final ptr = (value ?? '').toNativeUtf8();
    core.colyseus_auth_set_token(auth, ptr.cast<Char>());
    malloc.free(ptr);
  }

  /// Server-side route prefix, `/auth` unless the server moved it.
  set path(String value) {
    final auth = _handle;
    if (auth == nullptr) return;
    final ptr = value.toNativeUtf8();
    core.colyseus_auth_set_path(auth, ptr.cast<Char>());
    malloc.free(ptr);
  }

  /// Key the token is persisted under in the platform's secure storage.
  set storageKey(String value) {
    final auth = _handle;
    if (auth == nullptr) return;
    final ptr = value.toNativeUtf8();
    core.colyseus_auth_set_storage_key(auth, ptr.cast<Char>());
    malloc.free(ptr);
  }

  /// Fires whenever the token changes — a sign-in, a refresh, a sign-out.
  ///
  /// A sign-out arrives as a [ColyseusAuthData] with a null token, which is
  /// the cue to send the player back to a login screen.
  Stream<ColyseusAuthData> get onChange {
    final auth = _handle;
    if (auth == nullptr) return const Stream.empty();

    final existing = _changeControllers[auth.address];
    if (existing != null) return existing.stream;

    final controller = StreamController<ColyseusAuthData>.broadcast();
    _changeControllers[auth.address] = controller;
    _changeCallable ??=
        NativeCallable<AuthChangeNative>.listener(_onAuthChange);
    _n.authOnChange(auth.address, _changeCallable!.nativeFunction);
    return controller.stream;
  }

  /// The user record behind the current token.
  Future<ColyseusAuthData> getUserData() => _send(0, null, null, null);

  /// Create an account. [options] is merged into the request body.
  Future<ColyseusAuthData> registerWithEmailAndPassword(
          String email, String password, {Map<String, dynamic>? options}) =>
      _send(1, email, password, options);

  Future<ColyseusAuthData> signInWithEmailAndPassword(
          String email, String password) =>
      _send(2, email, password, null);

  /// Sign in without credentials. The token still identifies the player, so
  /// keep it if you want them to come back to the same account.
  Future<ColyseusAuthData> signInAnonymously({Map<String, dynamic>? options}) =>
      _send(3, null, null, options);

  Future<ColyseusAuthData> sendPasswordResetEmail(String email) =>
      _send(4, email, null, null);

  /// Drop the token locally and notify [onChange]. No request is made.
  void signOut() {
    final auth = _handle;
    if (auth == nullptr) return;
    core.colyseus_auth_signout(auth);
  }

  /// Release this client's change subscription.
  void dispose() {
    final auth = _handle;
    if (auth == nullptr) return;
    _changeControllers.remove(auth.address)?.close();
  }

  Future<ColyseusAuthData> _send(
      int op, String? arg1, String? arg2, Map<String, dynamic>? options) {
    final auth = _handle;
    if (auth == nullptr) {
      return Future.error(ColyseusAuthException('client has been disposed'));
    }

    final id = _nextRequestId++;
    final completer = Completer<ColyseusAuthData>();
    _pending[id] = completer;

    final a1 = arg1?.toNativeUtf8();
    final a2 = arg2?.toNativeUtf8();
    final opts = options == null ? null : jsonEncode(options).toNativeUtf8();
    _n.authRequest(
      auth.address,
      op,
      a1 == null ? nullptr : a1.cast<Char>(),
      a2 == null ? nullptr : a2.cast<Char>(),
      opts == null ? nullptr : opts.cast<Char>(),
      id,
      _authReplyPointer(),
    );
    if (a1 != null) malloc.free(a1);
    if (a2 != null) malloc.free(a2);
    if (opts != null) malloc.free(opts);

    return completer.future;
  }
}
