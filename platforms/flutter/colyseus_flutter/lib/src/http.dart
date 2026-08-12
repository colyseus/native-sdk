import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings/colyseus_core.dart';
import 'bindings/native_functions.dart';
import 'colyseus.dart';

final _n = NativeFunctions.instance;

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
  dynamic get json {
    if (_decoded != null) return _decoded;
    try {
      return _decoded = jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  dynamic _decoded;

  @override
  String toString() => 'ColyseusHttpResponse($statusCode, ${body.length} bytes)';
}

/// Pending requests, keyed by the id handed to native code.
///
/// One registry for the whole isolate: the reply carries its id back, so a
/// single listener callable can serve every client.
final Map<int, Completer<ColyseusHttpResponse>> _pending = {};
int _nextRequestId = 1;

void _onHttpReply(int requestId, int status, Pointer<Char> body, int errorCode,
    Pointer<Char> errorMessage) {
  final completer = _pending.remove(requestId);

  // Read then release: these are copies the native side made for us, and they
  // leak whether or not anyone is still waiting on the request.
  String? bodyText;
  if (body != nullptr) {
    bodyText = body.cast<Utf8>().toDartString();
    _n.freeString(body);
  }
  String? errorText;
  if (errorMessage != nullptr) {
    errorText = errorMessage.cast<Utf8>().toDartString();
    _n.freeString(errorMessage);
  }

  if (completer == null || completer.isCompleted) return;

  if (errorCode != 0 || status == 0) {
    completer.completeError(
        ColyseusHttpException(errorCode, errorText ?? 'request failed'));
    return;
  }
  if (status < 200 || status >= 300) {
    completer.completeError(ColyseusHttpException(
        status, 'HTTP $status', body: bodyText ?? ''));
    return;
  }
  completer.complete(ColyseusHttpResponse(status, bodyText ?? ''));
}

/// Late-bound so a program that never makes a request pays nothing, and so the
/// callable outlives every client (it is never closed).
NativeCallable<HttpReplyNative>? _httpCallable;

Pointer<NativeFunction<HttpReplyNative>> _httpReplyPointer() {
  // A listener, not isolateLocal: the reply arrives on the worker thread, and
  // a listener is the only shape that may cross threads.
  return (_httpCallable ??=
          NativeCallable<HttpReplyNative>.listener(_onHttpReply))
      .nativeFunction;
}

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
    final ptr = token == null ? nullptr : token.toNativeUtf8();
    core.colyseus_http_set_auth_token(
        _handle, ptr == nullptr ? nullptr : ptr.cast<Char>());
    if (ptr != nullptr) malloc.free(ptr);
  }

  Future<ColyseusHttpResponse> get(String path) => _send(0, path, null);

  Future<ColyseusHttpResponse> post(String path, {Object? body}) =>
      _send(1, path, body);

  Future<ColyseusHttpResponse> put(String path, {Object? body}) =>
      _send(2, path, body);

  Future<ColyseusHttpResponse> delete(String path) => _send(3, path, null);

  Future<ColyseusHttpResponse> patch(String path, {Object? body}) =>
      _send(4, path, body);

  Future<ColyseusHttpResponse> _send(int method, String path, Object? body) {
    final http = _handle;
    if (http == nullptr) {
      return Future.error(
          ColyseusHttpException(0, 'client has been disposed'));
    }

    final id = _nextRequestId++;
    final completer = Completer<ColyseusHttpResponse>();
    _pending[id] = completer;

    // A String body goes out verbatim; anything else is encoded, so callers
    // can pass a Map without stringifying it first.
    final encoded =
        body == null ? null : (body is String ? body : jsonEncode(body));

    final pathPtr = path.toNativeUtf8();
    final bodyPtr = encoded?.toNativeUtf8();
    _n.httpRequest(
      http.address,
      method,
      pathPtr.cast<Char>(),
      bodyPtr == null ? nullptr : bodyPtr.cast<Char>(),
      id,
      _httpReplyPointer(),
    );
    malloc.free(pathPtr);
    if (bodyPtr != null) malloc.free(bodyPtr);

    return completer.future;
  }
}
