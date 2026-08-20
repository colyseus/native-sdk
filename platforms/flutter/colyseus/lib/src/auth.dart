import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings/colyseus_core.dart';
import 'bindings/native_functions.dart';
import 'colyseus.dart';
import 'native_reply.dart';

final _n = NativeFunctions.instance;

/// Mirrors `flutter_auth_op_t` in `src/flutter_colyseus.h` — the glue switches
/// on the ordinal, so the order here is part of the ABI.
enum _Op { getUserData, register, signIn, signInAnonymous, sendPasswordReset }

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

final _replies = ReplyRegistry<ColyseusAuthData>();

void _onReply(int requestId, Pointer<Char> userJson, Pointer<Char> token,
    Pointer<Char> error) {
  // Take all three before anything can bail out: they are ours to release.
  final user = takeOwnedString(userJson);
  final tokenText = takeOwnedString(token);
  final errorText = takeOwnedString(error);

  final completer = _replies.take(requestId);
  if (completer == null) return;

  if (errorText != null) {
    completer.completeError(ColyseusAuthException(errorText));
  } else {
    completer.complete(ColyseusAuthData(tokenText, user));
  }
}

NativeCallable<AuthReplyNative>? _replyCallable;

Pointer<NativeFunction<AuthReplyNative>> _replyPointer() =>
    (_replyCallable ??= NativeCallable<AuthReplyNative>.listener(_onReply))
        .nativeFunction;

/// Change subscriptions, keyed by the auth handle the notification names.
final Map<int, StreamController<ColyseusAuthData>> _changes = {};
NativeCallable<AuthChangeNative>? _changeCallable;

void _onChange(int auth, Pointer<Char> userJson, Pointer<Char> token) {
  final data =
      ColyseusAuthData(takeOwnedString(token), takeOwnedString(userJson));
  final controller = _changes[auth];
  if (controller != null && !controller.isClosed) controller.add(data);
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
    final value = takeOwnedString(_n.authGetToken(auth.address));
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Adopt a token obtained elsewhere (a previous session, your own backend),
  /// or null to drop it.
  set token(String? value) {
    final auth = _handle;
    if (auth == nullptr) return;
    // Null has to reach the core as a null POINTER — see ColyseusHttp.authToken.
    using((arena) => core.colyseus_auth_set_token(auth,
        value == null ? nullptr : value.toNativeUtf8(allocator: arena).cast()));
  }

  /// Server-side route prefix, `/auth` unless the server moved it.
  set path(String value) => _setString(core.colyseus_auth_set_path, value);

  /// Key the token is persisted under in the platform's secure storage.
  ///
  /// It defaults to one process-wide key, so a signed-in session outlives the
  /// process and is restored by the next client — give a test run its own key
  /// if you don't want that.
  set storageKey(String value) =>
      _setString(core.colyseus_auth_set_storage_key, value);

  void _setString(
      void Function(Pointer<colyseus_auth_t>, Pointer<Char>) apply, String value) {
    final auth = _handle;
    if (auth == nullptr) return;
    using((arena) => apply(auth, value.toNativeUtf8(allocator: arena).cast()));
  }

  /// Fires whenever the token changes — a sign-in, a refresh, a sign-out.
  ///
  /// Subscribing emits the CURRENT state first, so a listener attached at
  /// startup hears one event without anything having happened: a null token
  /// when signed out, or the restored session when secure storage had one.
  /// A null token is the cue to send the player back to a login screen.
  Stream<ColyseusAuthData> get onChange {
    final auth = _handle;
    if (auth == nullptr) return const Stream.empty();

    return (_changes[auth.address] ??= _subscribe(auth.address)).stream;
  }

  StreamController<ColyseusAuthData> _subscribe(int auth) {
    _changeCallable ??= NativeCallable<AuthChangeNative>.listener(_onChange);
    _n.authOnChange(auth, _changeCallable!.nativeFunction);
    return StreamController<ColyseusAuthData>.broadcast();
  }

  /// The user record behind the current token.
  Future<ColyseusAuthData> getUserData() => _send(_Op.getUserData);

  /// Create an account. [options] is merged into the request body.
  Future<ColyseusAuthData> registerWithEmailAndPassword(
          String email, String password, {Map<String, dynamic>? options}) =>
      _send(_Op.register, email: email, password: password, options: options);

  Future<ColyseusAuthData> signInWithEmailAndPassword(
          String email, String password) =>
      _send(_Op.signIn, email: email, password: password);

  /// Sign in without credentials. The token still identifies the player, so
  /// keep it if you want them to come back to the same account.
  Future<ColyseusAuthData> signInAnonymously({Map<String, dynamic>? options}) =>
      _send(_Op.signInAnonymous, options: options);

  Future<ColyseusAuthData> sendPasswordResetEmail(String email) =>
      _send(_Op.sendPasswordReset, email: email);

  /// Drop the token locally and notify [onChange]. No request is made.
  void signOut() {
    final auth = _handle;
    if (auth != nullptr) core.colyseus_auth_signout(auth);
  }

  /// Release this client's change subscription.
  void dispose() {
    final auth = _handle;
    if (auth == nullptr) return;
    _changes.remove(auth.address)?.close();
  }

  Future<ColyseusAuthData> _send(_Op op,
      {String? email, String? password, Map<String, dynamic>? options}) {
    final auth = _handle;
    if (auth == nullptr) {
      return Future.error(ColyseusAuthException('client has been disposed'));
    }

    final completer = Completer<ColyseusAuthData>();
    final id = _replies.register(completer);

    // The glue copies every string before it returns, so the arena can
    // reclaim them as soon as the call does.
    Pointer<Char> str(Arena arena, String? value) =>
        value == null ? nullptr : value.toNativeUtf8(allocator: arena).cast();

    using((arena) => _n.authRequest(
          auth.address,
          op.index,
          str(arena, email),
          str(arena, password),
          str(arena, options == null ? null : jsonEncode(options)),
          id,
          _replyPointer(),
        ));

    return completer.future;
  }
}
