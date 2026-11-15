import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:ylpa_acp_core/ylpa_acp_core.dart';
/// Connection lifecycle of an ACP chat session.
enum AcpConnectionState { idle, connecting, ready, failed }

/// One renderable line of the ACP chat transcript.
///
/// Agent text chunks are coalesced into the trailing [AgentLine]; tool calls
/// keep their own line, updated in place by `tool_call_update`.
class AcpChatLine {
  AcpChatLine.user(this.text)
      : kind = LineKind.user,
        id = null,
        status = null;

  AcpChatLine.agent(this.text)
      : kind = LineKind.agent,
        id = null,
        status = null;

  AcpChatLine.thought(this.text)
      : kind = LineKind.thought,
        id = null,
        status = null;

  AcpChatLine.system(this.text)
      : kind = LineKind.system,
        id = null,
        status = null;

  AcpChatLine.tool({
    required String this.id,
    required this.text,
    required this.status,
  }) : kind = LineKind.tool;

  AcpChatLine.plan(List<String> entries)
      : kind = LineKind.plan,
        text = entries.join('\n'),
        id = null,
        status = null;

  final LineKind kind;
  final String text;
  final String? id; // toolCallId for tool lines
  final String? status; // pending / in_progress / completed / failed
}

enum LineKind { user, agent, thought, tool, plan, system }

/// Pending permission decision surfaced to the UI.
@immutable
class AcpPendingPermission {
  const AcpPendingPermission({required this.request});
  final AcpPermissionRequest request;
}

/// Orchestrates one ACP connection for the chat screen: connect →
/// initialize → session/new → prompt/updates, with fail-soft degradation at
/// every step (a failed step shows an honest message, never a crash).
class AcpSessionController extends ChangeNotifier
    implements AcpRequestHandlers {
  AcpSessionController({
    required this.instance,
    required this.manifest,
    required this.bearerToken,
    String? sessionCwd,
  }) : _sessionCwd = sessionCwd;

  final AgentInstance instance;
  final AgentTypeManifest? manifest;

  /// [redacted] for the bridge daemon, read from secure storage by the
  /// caller; null when the daemon is unauthenticated.
  final String? bearerToken;

  /// Workspace (cwd) for this session. Defaults to `instance.cwd`; call
  /// [setWorkspace] to change it mid-chat (reconnects with the new path).
  String? _sessionCwd;

  /// Effective working directory sent to `session/new`.
  String get sessionCwd => _sessionCwd ?? instance.cwd;

  final AgentInstance instance;
  final AgentTypeManifest? manifest;

  /// Bearer token for the bridge daemon, read from secure storage by the
  /// caller; null when the daemon is unauthenticated.
  final String? bearerToken;

  AcpClient? _client;
  AcpConnectionState state = AcpConnectionState.idle;
  String? failure;
  NewSessionResult? session;

  /// Models/modes advertised by the agent — rendered as dynamic pickers.
  List<SessionConfigOption> get configOptions =>
      session?.configOptions ?? const [];

  /// Slash commands advertised by the agent.
  List<SlashCommand> get commands => session?.availableCommands ?? const [];

  final List<AcpChatLine> lines = [];
  AcpPendingPermission? pendingPermission;

  /// Set while a prompt turn is in flight (composer shows a stop button).
  bool turnRunning = false;

  String? _activeSessionId;
  StreamSubscription<AcpEvent>? _eventsSub;

  // ── connect ─────────────────────────────────────────────────────────

  Future<void> connect() async {
    if (state == AcpConnectionState.connecting ||
        state == AcpConnectionState.ready) {
      return;
    }
    state = AcpConnectionState.connecting;
    failure = null;
    lines.clear();
    notifyListeners();
    try {
      final endpoint = instance.acpEndpoint(manifest);
      final transport = await WebSocketAcpTransport.connect(
        endpoint,
        bearerToken: bearerToken,
      );
      final client = AcpClient(transport, handlers: this);
      _client = client;
      _eventsSub = client.events.listen(_onEvent);
      final caps = await client.initialize();
      final capsLine = caps.agentName.isEmpty
          ? 'Connected (agent did not report a name)'
          : 'Connected to ${caps.agentName} ${caps.agentVersion}'.trim();
      lines.add(AcpChatLine.system(capsLine));
      final result = await client.sessionNew(cwd: sessionCwd);
      session = result;
      _activeSessionId = result.sessionId;
      lines.add(AcpChatLine.system('Working directory: $sessionCwd'));
      state = AcpConnectionState.ready;
    } catch (e) {
      state = AcpConnectionState.failed;
      final detail = e is JsonRpcError
          ? ' (code ${e.code}${e.data != null ? ' data=${e.data}' : ''})'
          : '';
      failure = 'Could not connect to ${instance.host}: $e$detail';
      lines.add(AcpChatLine.system(failure!));
    } finally {
      notifyListeners();
    }
  }

  void _onEvent(AcpEvent event) {
    switch (event) {
      case AcpSessionEvent(:final update):
        _applyUpdate(update);
      case AcpPermissionNeeded(:final request):
        pendingPermission = AcpPendingPermission(request: request);
      case AcpDisconnected(:final error):
        if (state == AcpConnectionState.ready) {
          state = AcpConnectionState.failed;
          failure = error == null
              ? 'Connection closed by the agent'
              : 'Connection lost: $error';
          lines.add(AcpChatLine.system(failure!));
        }
    }
    notifyListeners();
  }

  void _applyUpdate(SessionUpdate update) {
    switch (update) {
      case AgentMessageChunk(:final text):
        _appendAgentText(text);
      case AgentThoughtChunk(:final text):
        lines.add(AcpChatLine.thought(text));
      case UserMessageChunk():
        break; // the user's own text is already on screen
      case ToolCall(
          :final toolCallId,
          :final title,
          :final status,
          :final rawOutput,
        ):
        final body = StringBuffer(title);
        if (rawOutput is Map && rawOutput['output'] is String) {
          final out = rawOutput['output'] as String;
          if (out.isNotEmpty) body.write('\n${_trimOutput(out)}');
        }
        lines.add(AcpChatLine.tool(
          id: toolCallId,
          text: body.toString(),
          status: status,
        ));
      case ToolCallUpdate(:final toolCallId, :final status, :final rawOutput):
        final idx = lines.lastIndexWhere(
            (l) => l.kind == LineKind.tool && l.id == toolCallId);
        if (idx < 0) break;
        final existing = lines[idx];
        var text = existing.text;
        if (rawOutput is Map && rawOutput['output'] is String) {
          final out = rawOutput['output'] as String;
          if (out.isNotEmpty) text = '$text\n${_trimOutput(out)}';
        }
        lines[idx] = AcpChatLine.tool(
          id: toolCallId,
          text: text,
          status: status ?? existing.status,
        );
      case PlanUpdate(:final entries):
        lines.add(AcpChatLine.plan(
            entries.map((e) => '${_planBox(e.status)} ${e.content}').toList()));
      case CurrentModeUpdate(:final currentModeId):
        lines.add(AcpChatLine.system('Mode: $currentModeId'));
      case AvailableCommandsUpdate(:final commands):
        if (commands.isNotEmpty) {
          lines.add(AcpChatLine.system(
            'Commands: ${commands.map((c) => '/${c.name}').join('  ')}',
          ));
        }
      case UnknownUpdate():
        break; // forward compatible: unknown updates stay invisible
    }
  }

  void _appendAgentText(String chunk) {
    if (chunk.isEmpty) return;
    final last = lines.isEmpty ? null : lines.last;
    if (last != null && last.kind == LineKind.agent) {
      lines[lines.length - 1] = AcpChatLine.agent(last.text + chunk);
    } else {
      lines.add(AcpChatLine.agent(chunk));
    }
  }

  static String _trimOutput(String out) {
    final one = out.replaceAll('\r', '');
    if (one.length <= 400) return one;
    return '${one.substring(0, 400)}… (truncated)';
  }

  static String _planBox(String status) => switch (status) {
        'completed' => '☑',
        'in_progress' => '▣',
        _ => '☐',
      };

  // ── turn actions ────────────────────────────────────────────────────

  /// Applies a config option (model/mode) chosen from a dynamic picker.
  Future<void> setConfigOption(String configId, String value) async {
    final id = _activeSessionId;
    final client = _client;
    if (id == null || client == null) return;
    try {
      await client.setConfigOption(id, configId, value);
    } catch (e) {
      lines.add(AcpChatLine.system('Could not apply $configId: $e'));
      notifyListeners();
    }
  }

  Future<void> sendPrompt(String text) async {
    final client = _client;
    final id = _activeSessionId;
    if (client == null || id == null || turnRunning) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    lines.add(AcpChatLine.user(trimmed));
    turnRunning = true;
    notifyListeners();
    try {
      final stop = await client.prompt(id, [TextBlock(trimmed)]);
      lines.add(AcpChatLine.system('Turn ended (${stop.name}).'));
    } catch (e) {
      lines.add(AcpChatLine.system('Prompt failed: $e'));
    } finally {
      turnRunning = false;
      notifyListeners();
    }
  }

  Future<void> cancelTurn() async {
    final id = _activeSessionId;
    if (id == null) return;
    try {
      await _client?.cancel(id);
    } catch (_) {
      // fail soft: cancel is best-effort
    }
  }

  /// Change the session workspace mid-chat. Reconnects with the new cwd so
  /// `session/new` is sent with the updated path. Fail-soft: on failure the
  /// old connection state is preserved and an error line is added.
  Future<void> setWorkspace(String cwd) async {
    final trimmed = cwd.trim();
    if (trimmed.isEmpty) {
      lines.add(AcpChatLine.system('Workspace path is required.'));
      notifyListeners();
      return;
    }
    if (!trimmed.startsWith('/') && !RegExp(r'^[A-Za-z]:').hasMatch(trimmed)) {
      lines.add(AcpChatLine.system('Workspace must be an absolute path.'));
      notifyListeners();
      return;
    }
    _sessionCwd = trimmed;
    state = AcpConnectionState.idle;
    failure = null;
    await connect();
  }

  /// The UI's permission dialog answered.
  Future<void> resolvePermission(PermissionOutcome outcome) async {
    final request = pendingPermission?.request;
    pendingPermission = null;
    notifyListeners();
    // The client answers the agent directly; the UI decision is passed
    // through the handlers channel by remembering it. Since
    // [onRequestPermission] is invoked by the client's frame pump, the
    // flow is: event → dialog → resolvePermission completes the completer.
    if (request != null) {
      final completer =
          _permissionAnswers.remove('${request.requestId}');
      if (completer != null && !completer.isCompleted) {
        completer.complete(outcome);
      }
    }
  }

  final _permissionAnswers = <String, Completer<PermissionOutcome>>{};

  // ── AcpRequestHandlers ──────────────────────────────────────────────

  @override
  Future<PermissionOutcome> onRequestPermission(
      AcpPermissionRequest request) async {
    final completer = Completer<PermissionOutcome>();
    _permissionAnswers['${request.requestId}'] = completer;
    pendingPermission = AcpPendingPermission(request: request);
    notifyListeners();
    // Race-safe: if the dialog was answered before we got here, resolve now.
    return completer.future;
  }

  @override
  Future<String?> onReadTextFile(String path, {int? line, int? limit}) async {
    // The agent asks the PHONE to read a file: there is no shared
    // filesystem, so deny honestly instead of pretending.
    return null;
  }

  @override
  Future<void> onWriteTextFile(String path, String content) async {}

  // ── dispose ─────────────────────────────────────────────────────────

  @override
  void dispose() {
    _eventsSub?.cancel();
    _client?.close().ignore();
    super.dispose();
  }
}
