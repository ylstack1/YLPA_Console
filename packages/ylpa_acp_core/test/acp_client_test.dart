import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';

import 'package:ylpa_acp_core/ylpa_acp_core.dart';

/// Scriptable fake transport: records sent frames, replays scripted
/// incoming frames. Simulates a real ACP agent over WebSocket.
class FakeTransport implements AcpTransport {
  final _incoming = StreamController<String>.broadcast();
  final sent = <Map<String, dynamic>>[];

  // Scripting hooks the test agent uses.
  final Map<String, Map<String, dynamic>> responses = {}; // method -> result
  final List<String Function(Map<String, dynamic> request)> notificationScripts =
      [];

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  Future<void> send(String message) async {
    final frame = jsonDecode(message) as Map<String, dynamic>;
    sent.add(frame);
    if (frame['method'] != null) {
      final method = frame['method'] as String;
      final id = frame['id'];
      // Fake agent answers any scripted response, else an empty result.
      final scripted = responses[method];
      final params = (frame['params'] as Map?)?.cast<String, dynamic>() ?? {};
      if (id != null) {
        final result = scripted ??
            (method == 'initialize'
                ? _defaultInitializeResult
                : const {});
        _push(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
      }
      // Simulate agent-driven notifications triggered by the request.
      for (final script in notificationScripts) {
        final out = script(frame.cast<String, dynamic>());
        if (out.isNotEmpty) _push(out);
      }
      // Drift helper: expose the request for assertions.
      lastRequests.add((id: id, method: method, params: params));
    }
  }

  final List<({Object? id, String method, Map<String, dynamic> params})>
      lastRequests = [];

  Map<String, dynamic> get _defaultInitializeResult => {
        'protocolVersion': 1,
        'agentInfo': {'name': 'Fake Agent', 'version': '1.0.0'},
        'capabilities': {
          'loadSession': true,
          'promptCapabilities': {'text': true, 'image': true},
        },
      };

  void _push(String frame) => _incoming.add(frame);

  /// Pushes an agent→client `session/update` notification.
  void pushUpdate(String sessionId, Map<String, dynamic> update) =>
      _push(jsonEncode({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {'sessionId': sessionId, ...update},
      }));

  /// Pushes an agent→client request (e.g. permission) that awaits a reply.
  Map<String, dynamic> pushRequest(
      Object id, String method, Map<String, dynamic> params) {
    final frame = {
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    };
    _push(jsonEncode(frame));
    return frame;
  }

  Future<Map<String, dynamic>> get lastClientReply async =>
      await Future.delayed(
        const Duration(milliseconds: 10),
        () => sent.last,
      );

  @override
  Future<void> close() async {
    await _incoming.close();
  }
}

void main() {
  group('AcpClient', () {
    late FakeTransport transport;
    late AcpClient client;

    setUp(() {
      transport = FakeTransport();
      client = AcpClient(transport);
    });

    tearDown(() => client.close());

    test('initialize parses caps and gates other methods', () async {
      await expectLater(client.sessionNew(cwd: '/x'), throwsStateError);

      final caps = await client.initialize();
      expect(caps.agentName, 'Fake Agent');
      expect(caps.loadSession, isTrue);
      expect(caps.promptCapabilities.image, isTrue);
      expect(client.caps?.agentVersion, '1.0.0');
      expect(transport.sent.first['method'], 'initialize');
    });

    test('session/new surfaces configOptions + commands (dynamic UI data)',
        () async {
      transport.responses['session/new'] = {
        'sessionId': 'sess_1',
        'configOptions': [
          {
            'id': 'model',
            'name': 'Model',
            'category': 'model',
            'currentValue': 'gpt-4o',
            'options': [
              {'value': 'gpt-4o', 'name': 'GPT-4o'},
              {'value': 'o3', 'name': 'o3'},
            ],
          }
        ],
        'availableCommands': [
          {'name': 'review', 'description': 'Review the diff'}
        ],
      };
      await client.initialize();
      final session = await client.sessionNew(cwd: '/home/me/project');
      expect(session.sessionId, 'sess_1');
      expect(session.configOptions, hasLength(1));
      final model = session.configOptions.first;
      expect(model.id, 'model');
      expect(model.currentValue, 'gpt-4o');
      expect(model.options.map((o) => o.value), contains('o3'));
      expect(session.availableCommands.single.name, 'review');
    });

    test('prompt streams agent updates through events', () async {
      transport.notificationScripts.add((frame) {
        if (frame['method'] != 'session/prompt') return '';
        return jsonEncode({
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': {
            'sessionId': 'sess_1',
            'update': {
              'sessionUpdate': 'agent_message_chunk',
              'content': {'type': 'text', 'text': 'Hello from the agent'},
            },
          },
        });
      });
      transport.responses['session/prompt'] = {'stopReason': 'end_turn'};
      await client.initialize();
      final updates = <SessionUpdate>[];
      client.events.listen((ev) {
        if (ev is AcpSessionEvent) updates.add(ev.update);
      });
      final stop = await client.prompt('sess_1', [TextBlock('hi')]);
      expect(stop, PromptStopReason.endTurn);
      // Stream events are delivered asynchronously; pump the loop.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(updates, isNotEmpty);
      expect(updates.first, isA<AgentMessageChunk>());
      expect((updates.first as AgentMessageChunk).text, 'Hello from the agent');
    });

    test('tool_call + tool_call_update + plan parse defensively', () async {
      transport.pushUpdate('sess_1', {
        'update': {
          'sessionUpdate': 'tool_call',
          'toolCallId': 'c1',
          'title': 'Read file',
          'kind': 'read',
          'status': 'in_progress',
          'rawInput': {'path': '/a'},
        }
      });
      transport.pushUpdate('sess_1', {
        'update': {
          'sessionUpdate': 'tool_call_update',
          'toolCallId': 'c1',
          'status': 'completed',
          'content': [
            {
              'type': 'tool_call_content_chunk',
              'content': {'type': 'text', 'text': 'file contents here'},
            }
          ],
        }
      });
      transport.pushUpdate('sess_1', {
        'update': {
          'sessionUpdate': 'plan',
          'entries': [
            {'content': 'Step 1', 'priority': 'high', 'status': 'completed'},
          ],
        }
      });
      // A totally unknown future variant must not crash.
      transport.pushUpdate('sess_1', {
        'update': {'sessionUpdate': 'holo_projection_v9', 'zorp': true},
      });

      final updates = <SessionUpdate>[];
      client.events.listen((ev) {
        if (ev is AcpSessionEvent) updates.add(ev.update);
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final tool = updates.whereType<ToolCall>().first;
      expect(tool.toolCallId, 'c1');
      expect(tool.kind, 'read');
      expect(tool.rawInput, {'path': '/a'});

      final toolDone = updates.whereType<ToolCallUpdate>().first;
      expect(toolDone.status, 'completed');
      expect(toolDone.content.single, 'file contents here');

      final plan = updates.whereType<PlanUpdate>().first;
      expect(plan.entries.single.status, 'completed');

      final unknown = updates.whereType<UnknownUpdate>().first;
      expect(unknown.kind, 'holo_projection_v9');
    });

    test('permission request round-trips through handler', () async {
      // Dedicated transport: only this test's client listens, so the reply
      // frames in transport.sent belong to this client alone.
      final permTransport = FakeTransport();
      final picked = <AcpPermissionRequest>[];
      final client2 = AcpClient(
        permTransport,
        handlers: _ScriptedHandlers(onPermission: (req) {
          picked.add(req);
          return const PermissionOutcome.allow('allow_once');
        }),
      );
      addTearDown(client2.close);
      permTransport.responses['session/prompt'] = {'stopReason': 'end_turn'};
      // When the prompt arrives, the fake agent asks for permission.
      permTransport.notificationScripts.add((frame) {
        if (frame['method'] != 'session/prompt') return '';
        permTransport.pushRequest(42, 'session/request_permission', {
          'sessionId': 'sess_1',
          'toolCallId': 'c9',
          'title': 'Run rm -rf /tmp/x',
          'kind': 'execute',
          'options': [
            {'optionId': 'allow_once', 'name': 'Allow once', 'kind': 'allow_once'},
            {'optionId': 'reject_once', 'name': 'Reject', 'kind': 'reject_once'},
          ],
        });
        return '';
      });
      await client2.initialize();
      final evs = <AcpEvent>[];
      client2.events.listen(evs.add);
      await client2.prompt('sess_1', [TextBlock('clean up')]);
      // The agent→client request is delivered asynchronously after the
      // prompt response; pump the loop before asserting.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(picked, hasLength(1));
      expect(picked.single.title, 'Run rm -rf /tmp/x');
      expect(picked.single.options.map((o) => o.optionId),
          contains('allow_once'));
      // A permission event was surfaced for the UI.
      expect(evs.whereType<AcpPermissionNeeded>(), isNotEmpty);
      // And the client replied to the agent with the selected option.
      final reply = permTransport.sent
          .firstWhere((m) => m['id'] == 42 && m.containsKey('result'));
      expect((reply['result'] as Map)['optionId'], 'allow_once');
    });

    test('fs requests are answered by handlers', () async {
      final fsTransport = FakeTransport();
      final client3 = AcpClient(
        fsTransport,
        handlers: _ScriptedHandlers(
          onRead: (path, {line, limit}) => Future.value('FILE CONTENT'),
        ),
      );
      addTearDown(client3.close);
      fsTransport.pushRequest(7, 'fs/read_text_file', {'path': '/etc/hosts'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final reply = fsTransport.sent.firstWhere((m) => m['id'] == 7);
      expect(reply['result'], 'FILE CONTENT');
    });

    test('setConfigOption applies model choice', () async {
      transport.responses['session/set_config_option'] = const {};
      await client.initialize();
      await client.setConfigOption('sess_1', 'model', 'o3');
      final req = transport.lastRequests.last;
      expect(req.method, 'session/set_config_option');
      expect(req.params['configId'], 'model');
      expect(req.params['value'], 'o3');
    });

    test('duplicate/late frames are ignored without crashing (fail-soft)',
        () async {
      await client.initialize();
      transport.sent.clear();
      // Force an error response for the next call.
      transport.responses.remove('session/list');
      // Hack: rewrite the send pipeline for one call.
      // Simpler: patch via a notification script that replies with an error.
      transport.notificationScripts.add((frame) {
        if (frame['method'] != 'session/list') return '';
        return jsonEncode({
          'jsonrpc': '2.0',
          'id': frame['id'],
          'error': {'code': -32000, 'message': 'no sessions'},
        });
      });
      // The fake auto-replies with {} too; the later error frame wins because
      // the completer is already completed — so assert the happy path
      // returned and no crash occurred (fail-soft behavior).
      final sessions = await client.listSessions();
      expect(sessions, isEmpty);
    });
  });
}

class _ScriptedHandlers implements AcpRequestHandlers {
  _ScriptedHandlers({
    this.onPermission,
    this.onRead,
  });

  final FutureOr<PermissionOutcome> Function(AcpPermissionRequest)? onPermission;
  final Future<String?> Function(String path, {int? line, int? limit})? onRead;

  @override
  Future<PermissionOutcome> onRequestPermission(AcpPermissionRequest req) async {
    final outcome = onPermission?.call(req) ?? const PermissionOutcome.deny();
    return await outcome;
  }

  @override
  Future<String?> onReadTextFile(String path, {int? line, int? limit}) =>
      onRead?.call(path, line: line, limit: limit) ?? Future.value(null);

  @override
  Future<void> onWriteTextFile(String path, String content) async {}
}
