import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:ylpa_acp_core/ylpa_acp_core.dart';

void main() {
  group('bundled manifest catalog', () {
    late List<AgentTypeManifest> bundled;

    setUpAll(() async {
      final dir = Directory('assets/agent_types');
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.json'))
          .cast<File>()
          .toList();
      bundled = await Future.wait(files.map((f) async =>
          AgentTypeManifest.fromJson(
              jsonDecode(await f.readAsString()) as Map<String, dynamic>)));
    });

    test('all bundled manifests parse with a non-empty id', () {
      expect(bundled, isNotEmpty);
      for (final m in bundled) {
        expect(m.id, isNotEmpty, reason: 'manifest missing id');
        expect(m.displayName, isNotEmpty);
        expect(m.bridge.serveCommand, isNotEmpty);
      }
    });

    test('contains the core ACP agents', () {
      final ids = bundled.map((m) => m.id).toSet();
      expect(
        ids,
        containsAll(['claude-code', 'opencode', 'gemini-cli', 'codex']),
      );
    });

    test('every env auth field names its env var', () {
      for (final m in bundled) {
        for (final f in m.auth.fields) {
          expect(f.env, isNotNull,
              reason: '${m.id}: env field ${f.id} has no env key');
        }
      }
    });

    test('cwd spawn option exists everywhere', () {
      for (final m in bundled) {
        expect(m.spawnOptions.any((o) => o.id == 'cwd'), isTrue,
            reason: '${m.id} needs a cwd option');
      }
    });

    test('abstract template exists for the custom editor', () {
      final custom =
          bundled.firstWhere((m) => m.id == 'custom-acp', orElse: () => throw StateError('missing'));
      expect(custom.isTemplate, isTrue);
    });
  });

  group('AgentCatalog merge rules', () {
    test('later user source overrides bundled by id', () async {
      final bundled = InlineManifestSource([
        jsonEncode({
          'id': 'opencode',
          'displayName': 'OpenCode',
          'version': 1,
          'bridge': {'serveCommand': 'bundled-cmd', 'defaultPort': 8771},
        }),
      ]);
      final user = InlineManifestSource([
        jsonEncode({
          'id': 'opencode',
          'displayName': 'OpenCode (local build)',
          'version': 2,
          'bridge': {'serveCommand': 'user-cmd', 'defaultPort': 9000},
        }),
      ]);
      final catalog = await AgentCatalog.build([bundled, user]);
      final opencode = catalog.byId('opencode')!;
      expect(opencode.displayName, 'OpenCode (local build)');
      expect(opencode.bridge.serveCommand, 'user-cmd');
    });

    test('remote source is additive-only by default', () async {
      final bundled = InlineManifestSource([
        jsonEncode({
          'id': 'opencode',
          'displayName': 'OpenCode',
          'version': 1,
          'bridge': {'serveCommand': 'bundled-cmd'},
        }),
      ]);
      // Remote entries override only when allowOverride is true.
      final remote = InlineManifestSource([
        jsonEncode({
          'id': 'opencode',
          'displayName': 'Malicious override',
          'bridge': {'serveCommand': 'evil'},
        }),
      ], allowOverride: false);
      final catalog = await AgentCatalog.build([bundled, remote]);
      expect(catalog.byId('opencode')!.displayName, 'OpenCode');
    });

    test('unparsable entries are skipped, valid ones survive', () async {
      final src = InlineManifestSource([
        '{not json',
        jsonEncode({
          'id': 'ok-agent',
          'displayName': 'OK',
          'bridge': {'serveCommand': 'x'},
        }),
      ]);
      final catalog = await AgentCatalog.build([src]);
      expect(catalog.types, hasLength(1));
      expect(catalog.byId('ok-agent'), isNotNull);
    });

    test('instantiable hides abstract templates', () async {
      final src = InlineManifestSource([
        jsonEncode({
          'id': 'custom-acp',
          'displayName': 'Custom ACP agent',
          'abstract': true,
          'bridge': {'serveCommand': 'x'},
        }),
        jsonEncode({
          'id': 'real',
          'displayName': 'Real agent',
          'bridge': {'serveCommand': 'y'},
        }),
      ]);
      final catalog = await AgentCatalog.build([src]);
      expect(catalog.types, hasLength(2));
      expect(catalog.instantiable.map((t) => t.id), ['real']);
    });
  });

  group('AgentInstance', () {
    test('endpoint and port fall back to manifest defaults', () {
      final manifest = AgentTypeManifest(
        id: 'opencode',
        displayName: 'OpenCode',
        bridge: const BridgeSetup(serveCommand: 'x', defaultPort: 8771),
      );
      final instance = AgentInstance(
        id: 'i1',
        manifestId: 'opencode',
        label: 'Laptop',
        host: '192.168.1.20',
      );
      expect(instance.effectivePort(manifest), 8771);
      expect(
        instance.acpEndpoint(manifest).toString(),
        'ws://192.168.1.20:8771/acp/ws',
      );
      expect(
        instance.acpEndpoint(manifest, tls: true).scheme,
        'wss',
      );
    });

    test('JSON round-trip preserves extensions verbatim', () {
      final instance = AgentInstance(
        id: 'i1',
        manifestId: 'claude-code',
        label: 'Home server',
        host: 'box.tailnet.ts.net',
        tokenRef: 'tok_i1',
        fieldValues: {'cwd': '/srv/project'},
        secretRefs: {'ANTHROPIC_API_KEY': 'sec_anthropic'},
        extensions: {
          'mcpServers': [
            {'name': 'github', 'command': 'npx', 'args': ['-y', '@modelcontextprotocol/server-github']}
          ],
          'sharedSkills': ['code-review'],
        },
      );
      final back = AgentInstance.fromJson(
          jsonDecode(jsonEncode(instance.toJson())) as Map<String, dynamic>);
      expect(back.manifestId, 'claude-code');
      expect(back.host, 'box.tailnet.ts.net');
      expect(back.fieldValues['cwd'], '/srv/project');
      expect(back.secretRefs['ANTHROPIC_API_KEY'], 'sec_anthropic');
      final mcp = back.extensions['mcpServers'] as List;
      expect((mcp.first as Map)['name'], 'github');
      expect(back.extensions['sharedSkills'], ['code-review']);
    });
  });
}
