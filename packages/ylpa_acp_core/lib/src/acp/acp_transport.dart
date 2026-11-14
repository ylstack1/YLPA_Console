import 'dart:async';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Byte-framing-agnostic transport between the app and an agent endpoint.
///
/// WebSocket is the default (acpremote-style `ws://host:port/acp/ws`). A
/// future local runner (Termux-like, in-app stdio) implements the same
/// interface — nothing else in the stack changes.
abstract class AcpTransport {
  Future<void> send(String message);
  Stream<String> get incoming;
  Future<void> close();
}

class WebSocketAcpTransport implements AcpTransport {
  WebSocketAcpTransport._(this._channel);

  final WebSocketChannel _channel;
  final _incoming = StreamController<String>.broadcast();

  /// Connects to e.g. `ws://192.168.1.20:8770/acp/ws` with optional bearer
  /// token sent as `Authorization: Bearer <token>`.
  static Future<WebSocketAcpTransport> connect(
    Uri uri, {
    String? bearerToken,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final WebSocketChannel channel;
    if (bearerToken != null) {
      // Native platforms can set upgrade headers; this is the standard way
      // to authenticate against acpremote's bearer-protected endpoint.
      channel = IOWebSocketChannel.connect(
        uri,
        protocols: const ['acp'],
        headers: {'Authorization': 'Bearer $bearerToken'},
      );
    } else {
      channel = WebSocketChannel.connect(uri, protocols: const ['acp']);
    }
    // Fail fast on unreachable hosts instead of hanging.
    final ready = channel.ready;
    try {
      await ready.timeout(timeout);
    } on TimeoutException {
      channel.sink.close().ignore();
      rethrow;
    }
    return WebSocketAcpTransport._(channel)
      .._pump();
  }

  void _pump() {
    _channel.stream.listen(
      (data) {
        if (data is String) {
          _incoming.add(data);
        } else if (data is List<int>) {
          _incoming.add(String.fromCharCodes(data));
        }
      },
      onError: (Object e) => _incoming.addError(e),
      onDone: () => _incoming.close(),
      cancelOnError: true,
    );
  }

  @override
  Future<void> send(String message) async {
    _channel.sink.add(message);
  }

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  Future<void> close() async {
    await _channel.sink.close();
    await _incoming.close();
  }
}
