import 'package:flutter/material.dart';

import 'package:ylpa_acp_core/ylpa_acp_core.dart';

import '../../acp/acp_catalog_loader.dart';
import '../../acp/acp_instance_store.dart';
import '../../design/list.dart';
import '../../design/page.dart';
import '../../design/tokens.dart';
import '../../theme/app_theme.dart';
import '../../services/secure_storage.dart';
import 'acp_add_agent_screen.dart';
import 'acp_agent_settings_screen.dart';
import 'acp_chat_screen.dart';

/// Home of the ACP layer: saved agent instances + the Add-Agent entry.
/// Purely additive to the Hermes app; reached from Settings → ACP agents.
class AcpHubScreen extends StatefulWidget {
  const AcpHubScreen({
    super.key,
    required this.instanceStore,
    required this.secureStorage,
  });

  final AcpInstanceStore instanceStore;
  final SecureStorage secureStorage;

  @override
  State<AcpHubScreen> createState() => _AcpHubScreenState();
}

class _AcpHubScreenState extends State<AcpHubScreen> {
  AgentCatalog? _catalog;
  List<AgentInstance> _instances = [];
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final catalog = await AcpCatalogLoader.load();
      final instances = widget.instanceStore.load();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _instances = instances;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = 'Could not load the agent catalog: $e');
    }
  }

  AgentTypeManifest? _manifestOf(AgentInstance instance) =>
      _catalog?.byId(instance.manifestId);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final catalog = _catalog;
    return HermesPage(
      title: 'ACP agents',
      onRefresh: _reload,
      floatingActionButton: FloatingActionButton(
        onPressed: _openWizard,
        tooltip: 'Add agent',
        child: const Icon(Icons.add_rounded),
      ),
      children: [
        if (_loadError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: HermesSpace.x4),
            child: Text(
              _loadError!,
              style: HermesType.support.copyWith(color: colors.error),
            ),
          ),
        if (catalog == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: HermesSpace.x4),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          HermesSectionHeader(
            'Agent types (${catalog.instantiable.length} built-in)',
            trailing: Text(
              'via Agent Client Protocol',
              style:
                  HermesType.support.copyWith(color: colors.textSecondary),
            ),
          ),
          Text(
            'One client, every ACP agent: Claude Code, OpenCode, Gemini CLI, '
            'Codex, Qwen Code or your own. The agent runs on your machine '
            'behind a bridge daemon; the phone stays a thin client.',
            style: HermesType.support.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: HermesSpace.x4),
          HermesSectionHeader('Your agents (${_instances.length})'),
          if (_instances.isEmpty)
            Text(
              'No agents yet. Tap + to add one — the wizard gives you the '
              'exact one-line command to run on your machine.',
              style:
                  HermesType.support.copyWith(color: colors.textSecondary),
            )
          else
            HermesListGroup(
              children: [
                for (final instance in _instances)
                  HermesListRow(
                    icon: Icons.smart_toy_outlined,
                    title: instance.label,
                    subtitle:
                        '${_manifestOf(instance)?.displayName ?? instance.manifestId} · ${instance.host}',
                    onTap: () => _openChat(instance),
                    trailing: IconButton(
                      tooltip: 'Settings',
                      icon: const Icon(Icons.settings_outlined, size: 18),
                      onPressed: () => _openSettings(instance),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: HermesSpace.x2),
          const Text(
            'Long-press an agent for settings.',
            style: HermesType.support,
          ),
        ],
      ],
    );
  }

  Future<void> _openWizard() async {
    final catalog = _catalog;
    if (catalog == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AcpAddAgentScreen(
        catalog: catalog,
        instanceStore: widget.instanceStore,
        secureStorage: widget.secureStorage,
      ),
    ));
    await _reload();
  }

  Future<void> _openSettings(AgentInstance instance) async {
    final manifest = _manifestOf(instance);
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AcpAgentSettingsScreen(
        instance: instance,
        manifest: manifest,
        instanceStore: widget.instanceStore,
        secureStorage: widget.secureStorage,
      ),
    ));
    await _reload();
  }

  Future<void> _openChat(AgentInstance instance) async {
    final manifest = _manifestOf(instance);
    if (manifest == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Unknown agent type ${instance.manifestId}'),
      ));
      return;
    }
    final token = await _loadToken(instance);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AcpChatScreen(
        instance: instance,
        manifest: manifest,
        bearerToken: token,
        instanceStore: widget.instanceStore,
        secureStorage: widget.secureStorage,
        catalog: _catalog!,
      ),
    ));
  }

  Future<String?> _loadToken(AgentInstance instance) async {
    final tokenRef = instance.tokenRef;
    if (tokenRef == null) return null;
    return widget.secureStorage.readAcpSecret(instance.id, 'bridge_token');
  }
}
