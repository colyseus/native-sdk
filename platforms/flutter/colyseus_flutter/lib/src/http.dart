import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings/colyseus_core.dart';
import 'bindings/native_functions.dart';
import 'colyseus.dart';
import 'native_reply.dart';

final _n = NativeFunctions.instance;

/// Mirrors `flutter_http_method_t` in `src/flutter_colyseus.h` — the glue
/// switches on the ordinal, so the order here is part of the ABI.
enum _Method { get, post, put, delete, patch }

/// A non-2xx reply, or a transport failure before one arrived.
class ColyseusHttpException implements Exception {
  ColyseusHttpException(this.code, this.message, {this.body});

  /// HTTP status when the server answered, otherwise the transport's code.
  final int code;
  final String message;

  /// The raw response body, when the failure carried one.
  final String? body;

  @override
  String toString() => 'ColyseusHttpException($code): $message';
}

/// One HTTP reply.
class ColyseusHttpResponse {
  ColyseusHttpResponse(this.statusCode, this.body);

  final int statusCode;

  /// The response body, verbatim.
  final String body;

  /// [body] decoded as JSON, or null when it isn't valid JSON.
  ///
  /// The Colyseus routes answer JSON; this is the reader for them. Reach for
  /// [body] when an endpoint returns something else.
  dynamic get json => _decoded ??= _decode();

  dynamic _decoded;

  dynamic _decode() {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => 'ColyseusHttpResponse($statusCode, ${body.length} bytes)';
}

final _replies = ReplyRegistry<ColyseusHttpResponse>();

void _onReply(int requestId, int status, Pointer<Char> body, int errorCode,
    Pointer<Char> errorMessage) {
  // Take both before anything can bail out: they are ours to release.
  final bodyText = takeOwnedString(body);
  final errorText = takeOwnedString(errorMessage);

  final completer = _replies.take(requestId);
  if (completer == null) return;

  if (errorText != null || status == 0) {
    completer.completeError(
        ColyseusHttpException(errorCode, errorText ?? 'request failed'));
  } else if (status < 200 || status >= 300) {
    completer.completeError(
        ColyseusHttpException(status, 'HTTP $status', body: bodyText ?? ''));
  } else {
    completer.complete(ColyseusHttpResponse(status, bodyText ?? ''));
  }
}

/// Late-bound so a program that never makes a request pays nothing, and never
/// closed, because the callable outlives every client.
NativeCallable<HttpReplyNative>? _callable;

Pointer<NativeFunction<HttpReplyNative>> _replyPointer() =>
    // A listener, not isolateLocal: the reply arrives on the worker thread,
    // and a listener is the only shape that may cross threads.
    (_callable ??= NativeCallable<HttpReplyNative>.listener(_onReply))
        .nativeFunction;

/// The HTTP surface of a [ColyseusClient], reached as `client.http`.
///
/// Paths are relative to the client's endpoint, so `/test` hits
/// `http://host:port/test`. Every call resolves with the reply or throws
/// [ColyseusHttpException].
///
/// ```dart
/// final res = await client.http.get('/test');
/// print(res.json['things']);
/// ```
class ColyseusHttp {
  ColyseusHttp(this._client);

  final Pointer<colyseus_client_t> _client;

  Pointer<colyseus_http_t> get _handle => core.colyseus_client_get_http(_client);

  /// Bearer token attached to every request from this client.
  ///
  /// Setting it through [ColyseusAuth.token] is usually what you want — that
  /// keeps the auth module's own state in step.
  set authToken(String? token) {
    // Null has to reach the core as a null POINTER: it only omits the header
    // when auth_token is null, so an empty string would send an empty Bearer.
    final ptr = token?.toNativeUtf8();
    core.colyseus_http_set_auth_token(
        _handle, ptr?.cast<Char>() ?? nullptr);
    if (ptr != null) malloc.free(ptr);
  }

  Future<ColyseusHttpResponse> get(String path) => _send(_Method.get, path);

  Future<ColyseusHttpResponse> post(String path, {Object? body}) =>
      _send(_Method.post, path, body);

  Future<ColyseusHttpResponse> put(String path, {Object? body}) =>
      _send(_Method.put, path, body);

  Future<ColyseusHttpResponse> delete(String path) =>
      _send(_Method.delete, path);

  Future<ColyseusHttpResponse> patch(String path, {Object? body}) =>
      _send(_Method.patch, path, body);

  Future<ColyseusHttpResponse> _send(_Method method, String path,
      [Object? body]) {
    final http = _handle;
    if (http == nullptr) {
      return Future.error(ColyseusHttpException(0, 'client has been disposed'));
    }

    final completer = Completer<ColyseusHttpResponse>();
    final id = _replies.register(completer);

    // A String body goes out verbatim; anything else is encoded, so callers
    // can pass a Map without stringifying it first.
    final encoded =
        body == null ? null : (body is String ? body : jsonEncode(body));

    final pathPtr = path.toNativeUtf8();
    final bodyPtr = encoded?.toNativeUtf8();
    _n.httpRequest(
      http.address,
      method.index,
      pathPtr.cast<Char>(),
      bodyPtr?.cast<Char>() ?? nullptr,
      id,
      _replyPointer(),
    );
    malloc.free(pathPtr);
    if (bodyPtr != null) malloc.free(bodyPtr);

    return completer.future;
  }
}
