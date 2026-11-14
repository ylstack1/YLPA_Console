import 'dart:async';

import 'acp_models.dart';
import 'acp_transport.dart';
import 'jsonrpc.dart';

/// Callbacks for agent→client requests. ACP requires the client to answer
/// these; the defaults are honest refusals so the client never hangs.
abstract class AcpRequestHandlers {
  /// `session/request_permission` — show the app's approval UI, return the
  /// chosen [PermissionOutcome].
  Future<PermissionOutcome> onRequestPermission(AcpPermissionRequest request);

  /// `fs/read_text_file` — agent asks the client to read a file.
  Future<String?> onReadTextFile(String path, {int? line, int? limit});

  /// `fs/write_text_file` — agent asks the client to write a file.
  Future<void> onWriteTextFile(String path, String content);
}

/// Deny-everything default (safe, never hangs the agent).
class DenyAllAcpHandlers implements AcpRequestHandlers {
  @override
  Future<PermissionOutcome> onRequestPermission(AcpPermissionRequest request) =>
      Future.value(const PermissionOutcome.deny());

  @override
  Future<String?> onReadTextFile(String path, {int? line, int? limit}) async =>
      null;

  @override
  Future<void> onWriteTextFile(String path, String content) async {}
}

/// Events surfaced by [AcpClient.events] for the UI layer.
sealed class AcpEvent {}

class AcpSessionEvent extends AcpEvent {
  AcpSessionEvent(this.sessionId, this.update);
  final String sessionId;
  final SessionUpdate update;
}

class AcpPermissionNeeded extends AcpEvent {
  AcpPermissionNeeded(this.request);
  final AcpPermissionRequest request;
}

class AcpDisconnected extends AcpEvent {
  AcpDisconnected(this.error);
  final Object? error;
}

/// The one client for every ACP agent.
///
/// Lifecycle:
/// ```dart
/// final transport = await WebSocketAcpTransport.connect(uri);
/// final client = AcpClient(transport, handlers: myHandlers);
/// final caps = await client.initialize();
/// final session = await client.sessionNew(cwd: '/home/me/project');
/// await for (final ev in client.events) { ... }   // updates, permissions
/// await client.prompt(session.sessionId, [TextBlock('hi')]);
/// ```
class AcpClient {
  AcpClient(this._transport, {AcpRequestHandlers? handlers})
      : _handlers = handlers ?? DenyAllAcpHandlers() {
    _sub = _transport.incoming.listen(_onFrame, onError: _onError, onDone: _onDone);
  }

  final AcpTransport _transport;
  final AcpRequestHandlers _handlers;
  final _mux = JsonRpcMultiplexer();
  final _events = StreamController<AcpEvent>.broadcast();
  late final StreamSubscription<String> _sub;
  bool _initialized = false;
  bool _closed = false;

  AgentCaps? _caps;
  AgentCaps? get caps => _caps;

  Stream<AcpEvent> get events => _events.stream;

  /// Emits an event only if the controller is still open (close-race safe).
  void _emit(AcpEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _onFrame(String text) {
    final msg = parseFrame(text);
    if (msg == null) return;
    switch (msg) {
      case JsonRpcRequest(:final id, :final method, :final params):
        _handleAgentRequest(id, method, params);
      case JsonRpcNotification(:final method, :final params):
        _handleNotification(method, params);
      case JsonRpcResponse():
        _mux.handle(msg);
    }
  }

  void _onError(Object e) {
    _mux.failAll(e);
    _emit(AcpDisconnected(e));
  }

  void _onDone() {
    _closed = true;
    _mux.failAll(StateError('connection closed'));
    _emit(AcpDisconnected(null));
  }

  Future<void> _handleAgentRequest(
      Object id, String method, Map<String, dynamic> params) async {
    try {
      Object? result;
      switch (method) {
        case 'session/request_permission':
          final req = AcpPermissionRequest.fromRequest(id, params);
          _emit(AcpPermissionNeeded(req));
          final outcome = await _handlers.onRequestPermission(req);
          result = outcome.toJson();
        case 'fs/read_text_file':
          final content = await _handlers.onReadTextFile(
            (params['path'] as String?) ?? '',
            line: (params['line'] as num?)?.toInt(),
            limit: (params['limit'] as num?)?.toInt(),
          );
          if (content == null) {
            _transport.send(_err(id, -32002, 'file access denied by client'));
            return;
          }
          result = content;
        case 'fs/write_text_file':
          await _handlers.onWriteTextFile(
            (params['path'] as String?) ?? '',
            (params['content'] as String?) ?? '',
          );
          result = const {};
        case 'terminal/create':
          // Terminals are an optional agent capability; deny until the app
          // ships terminal UI (honest failure, agent falls back).
          _transport.send(_err(id, -32601, 'terminal not supported by client'));
          return;
        case 'elicitation/create':
          _transport.send(_err(id, -32601, 'elicitation not supported yet'));
          return;
        default:
          _transport.send(_err(id, -32601, 'method not supported: $method'));
          return;
      }
      await _transport.send(encodeResponse(id, result));
    } catch (e) {
      await _transport.send(_err(id, -32000, e.toString()));
    }
  }

  String _err(Object id, int code, String message) =>
      encodeErrorResponse(id, code, message);

  void _handleNotification(String method, Map<String, dynamic> params) {
    if (method == 'session/update') {
      // ACP shape: {"sessionId": "...", "update": {"sessionUpdate": "...", ...}}
      final updateJson = params['update'] is Map
          ? (params['update'] as Map).cast<String, dynamic>()
          : params;
      final update = SessionUpdate.fromJson(updateJson);
      final sessionId = (params['sessionId'] as String?) ?? '';
      _emit(AcpSessionEvent(sessionId, update));
      return;
    }
    // Unknown notifications are ignored (forward compatible).
  }

  // ---- client → agent -------------------------------------------------

  /// Sends `initialize`. Must be called first; every other method checks.
  Future<AgentCaps> initialize({
    String clientName = 'YLPA Console',
    String clientVersion = '0.1.0',
    int protocolVersion = 1,
    Map<String, dynamic> authMethod = const {},
  }) async {
    final id = _mux.nextId;
    final done = _mux.expect(id);
    await _transport.send(encodeRequest(id, 'initialize', {
      'protocolVersion': protocolVersion,
      'clientCapabilities': {
        'fs': {'readTextFile': true, 'writeTextFile': true},
      },
      if (authMethod.isNotEmpty) 'authMethod': authMethod,
      'clientInfo': {'name': clientName, 'version': clientVersion},
    }));
    final result = (await done) as Map? ?? const {};
    _caps = AgentCaps.fromJson((result).cast<String, dynamic>());
    _initialized = true;
    return _caps!;
  }

  /// `authenticate` — for env-based auth, most agents skip this.
  Future<void> authenticate(String methodId) async {
    _requireInit();
    final id = _mux.nextId;
    final done = _mux.expect(id);
    await _transport.send(
        encodeRequest(id, 'authenticate', {'methodId': methodId}));
    await done;
  }

  /// `session/new` — returns the session id plus the agent's advertised
  /// configOptions (models, modes) and slash commands. This is where all
  /// dynamic UI data comes from.
  Future<NewSessionResult> sessionNew({
    required String cwd,
    List<String> additionalDirectories = const [],
    Map<String, dynamic> mcpServers = const {},
  }) async {
    _requireInit();
    final id = _mux.nextId;
    final done = _mux.expect(id);
    await _transport.send(encodeRequest(id, 'session/new', {
      'cwd': cwd,
      'mcpServers': mcpServers,
      if (additionalDirectories.isNotEmpty)
        'additionalDirectories': additionalDirectories,
    }));
    final result = ((await done) as Map? ?? const {}).cast<String, dynamic>();
    return NewSessionResult(
      sessionId: (result['sessionId'] as String?) ?? '',
      configOptions: (result['configOptions'] as List? ?? const [])
          .whereType<Map>()
          .map((o) => SessionConfigOption.fromJson(o.cast<String, dynamic>()))
          .toList(),
      availableCommands: (result['availableCommands'] as List? ?? const [])
          .whereType<Map>()
          .map((c) => SlashCommand(
                name: (c['name'] as String?) ?? '',
                description: (c['description'] as String?) ?? '',
              ))
          .toList(),
      modes: result['modes'],
      raw: result,
    );
  }

  /// `session/prompt` — resolves when the turn completes (ACP semantics),
  /// while streamed updates arrive on [events] during the turn.
  Future<PromptStopReason> prompt(
      String sessionId, List<ContentBlock> blocks) async {
    _requireInit();
    final id = _mux.nextId;
    final done = _mux.expect(id);
    await _transport.send(encodeRequest(id, 'session/prompt', {
      'sessionId': sessionId,
      'prompt': blocks.map((b) => b.toJson()).toList(),
    }));
    final result = (await done.timeout(
      const Duration(seconds: 60),
      onTimeout: () => throw TimeoutException('OpenCode did not respond to prompt within 60 seconds', const Duration(seconds: 60)),
    )) as Map? ?? const {};
    final stop = (result['stopReason'] as String?) ?? 'end_turn';
    return PromptStopReason.fromName(stop);
  }

  Future<void> cancel(String sessionId) => _notify(
      'session/cancel', {'sessionId': sessionId});

  Future<void> setConfigOption(
      String sessionId, String configId, String value) {
    _requireInit();
    final id = _mux.nextId;
    final done = _mux.expect(id);
    _transport.send(encodeRequest(id, 'session/set_config_option',
        {'sessionId': sessionId, 'configId': configId, 'value': value}));
    return done;
  }

  Future<List<String>> listSessions() async {
    _requireInit();
    final id = _mux.nextId;
    final done = _mux.expect(id);
    await _transport.send(encodeRequest(id, 'session/list', const {}));
    final result = (await done) as Map? ?? const {};
    return ((result)['sessions'] as List? ?? const [])
        .whereType<Map>()
        .map((s) => (s['sessionId'] as String?) ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }

  Future<void> unload(String sessionId) =>
      _notify('session/unload', {'sessionId': sessionId});

  Future<void> _notify(String method, Map<String, dynamic> params) async {
    _requireInit();
    await _transport.send(encodeNotification(method, params));
  }

  void _requireInit() {
    if (!_initialized) {
      throw StateError('AcpClient.initialize() must be called first');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub.cancel();
    _mux.dispose();
    await _events.close();
    await _transport.close();
  }
}

enum PromptStopReason {
  endTurn,
  maxTokens,
  maxTurnRequests,
  refusal,
  cancelled;

  static PromptStopReason fromName(String name) => switch (name) {
        'max_tokens' => maxTokens,
        'max_turn_requests' => maxTurnRequests,
        'refusal' => refusal,
        'cancelled' => cancelled,
        _ => endTurn,
      };
}

class NewSessionResult {
  const NewSessionResult({
    required this.sessionId,
    required this.configOptions,
    required this.availableCommands,
    this.modes,
    this.raw = const {},
  });

  final String sessionId;
  final List<SessionConfigOption> configOptions;
  final List<SlashCommand> availableCommands;
  final Object? modes;
  final Map<String, dynamic> raw;
}
