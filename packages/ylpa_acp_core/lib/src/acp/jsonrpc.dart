/// Minimal JSON-RPC 2.0 framing over newline-free text frames (one message
/// per WebSocket frame / stdio line).
library;

import 'dart:async';
import 'dart:convert';

class JsonRpcError implements Exception {
  JsonRpcError(this.code, this.message, [this.data]);

  final int code;
  final String message;
  final Object? data;

  @override
  String toString() => 'JsonRpcError($code): $message';
}

/// One decoded JSON-RPC message.
sealed class JsonRpcMessage {
  JsonRpcMessage();
}

class JsonRpcRequest extends JsonRpcMessage {
  JsonRpcRequest(this.id, this.method, this.params);

  final Object id;
  final String method;
  final Map<String, dynamic> params;
}

class JsonRpcNotification extends JsonRpcMessage {
  JsonRpcNotification(this.method, this.params);

  final String method;
  final Map<String, dynamic> params;
}

class JsonRpcResponse extends JsonRpcMessage {
  JsonRpcResponse(this.id, this.result, this.error);

  final Object id;
  final Object? result;
  final JsonRpcError? error;

  bool get isError => error != null;
}

/// Parses one frame; returns null for frames that are not valid JSON-RPC
/// (fail soft — a noisy agent must not crash the client).
JsonRpcMessage? parseFrame(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final map = decoded.cast<String, dynamic>();
  final method = map['method'] as String?;
  final id = map['id'];
  if (method != null) {
    final params = (map['params'] is Map ? map['params'] as Map : const {})
        .cast<String, dynamic>();
    return id != null
        ? JsonRpcRequest(id, method, params)
        : JsonRpcNotification(method, params);
  }
  if (id != null || map.containsKey('result') || map.containsKey('error')) {
    Object? err;
    if (map['error'] is Map) {
      final e = (map['error'] as Map).cast<String, dynamic>();
      err = JsonRpcError(
        (e['code'] as num?)?.toInt() ?? -1,
        (e['message'] as String?) ?? 'unknown error',
        e['data'],
      );
    }
    return JsonRpcResponse(id ?? '', map['result'], err as JsonRpcError?);
  }
  return null;
}

String encodeRequest(Object id, String method, Map<String, dynamic> params) =>
    jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});

String encodeResponse(Object id, Object? result) =>
    jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result ?? {}});

String encodeErrorResponse(Object id, int code, String message) => jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    });

String encodeNotification(String method, Map<String, dynamic> params) =>
    jsonEncode({'jsonrpc': '2.0', 'method': method, 'params': params});

/// Multiplexes incoming frames: matches responses to pending request
/// completers by id, and broadcasts requests/notifications to listeners.
class JsonRpcMultiplexer {
  final _pending = <String, Completer<Object?>>{};
  final _requests = StreamController<JsonRpcRequest>.broadcast();
  final _notifications = StreamController<JsonRpcNotification>.broadcast();
  int _nextId = 1;

  Stream<JsonRpcRequest> get requests => _requests.stream;
  Stream<JsonRpcNotification> get notifications => _notifications.stream;

  Object get nextId => _nextId++;

  /// Feeds one decoded frame.
  void handle(JsonRpcMessage msg) {
    switch (msg) {
      case JsonRpcResponse(:final id):
        final key = '$id';
        final completer = _pending.remove(key);
        if (completer != null && !completer.isCompleted) {
          if (msg.isError) {
            completer.completeError(msg.error!);
          } else {
            completer.complete(msg.result);
          }
        }
      case JsonRpcRequest():
        _requests.add(msg);
      case JsonRpcNotification():
        _notifications.add(msg);
    }
  }

  /// Registers a pending request and returns its future.
  Future<Object?> expect(Object id) {
    final completer = Completer<Object?>();
    _pending['$id'] = completer;
    return completer.future;
  }

  /// Removes a pending request (timeout/cancel path).
  void drop(Object id) => _pending.remove('$id');

  void failAll(Object error) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(error);
    }
    _pending.clear();
  }

  void dispose() {
    failAll(StateError('transport closed'));
    _requests.close();
    _notifications.close();
  }
}
