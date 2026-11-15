import 'package:flutter/material.dart';

import 'package:ylpa_acp_core/ylpa_acp_core.dart';

import '../../acp/acp_instance_store.dart';
import '../../design/tokens.dart';
import '../../theme/app_theme.dart';
import '../../services/secure_storage.dart';
import 'acp_agent_form.dart';

/// Edit or delete a saved ACP agent instance. Same dynamic form as the
/// wizard — one widget for every agent type.
class AcpAgentSettingsScreen extends StatefulWidget {
  const AcpAgentSettingsScreen({
    super.key,
    required this.instance,
    required this.manifest,
    required this.instanceStore,
    required this.secureStorage,
  });

  final AgentInstance instance;
  final AgentTypeManifest? manifest;
  final AcpInstanceStore instanceStore;
  final SecureStorage secureStorage;

  @override
  State<AcpAgentSettingsScreen> createState() => _AcpAgentSettingsScreenState();
}

class _AcpAgentSettingsScreenState extends State<AcpAgentSettingsScreen> {
  late final TextEditingController _label;
  late final TextEditingController _host;
  late final TextEditingController _port;
  final _formKey = GlobalKey<AcpAgentFormState>();
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(text: widget.instance.label);
    _host = TextEditingController(text: widget.instance.host);
    _port = TextEditingController(
      text: widget.instance.port != 0 ? '${widget.instance.port}' : '',
    );
  }

  @override
  void dispose() {
    _label.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final manifest = widget.manifest;
    final values = _formKey.currentState?.collect();
    if (manifest == null || values == null) return;
    final host = _host.text.trim();
    if (host.isEmpty) {
      _snack('Host is required');
      return;
    }
    final port = int.tryParse(_port.text.trim()) ?? 0;

    // Replace secrets that were re-typed; keep old secretRefs otherwise.
    final secretRefs = Map.of(widget.instance.secretRefs);
    for (final entry in values.secrets.entries) {
      await widget.secureStorage
          .writeAcpSecret(widget.instance.id, entry.key, entry.value);
      secretRefs[entry.key] = 'acp_${entry.key}_${widget.instance.id}';
    }

    var cwd = values.envValues.remove('__cwd') ?? widget.instance.cwd;

    final updated = AgentInstance(
      id: widget.instance.id,
      manifestId: widget.instance.manifestId,
      label: _label.text.trim().isEmpty ? widget.instance.label : _label.text.trim(),
      host: host,
      port: port,
      tokenRef: widget.instance.tokenRef,
      fieldValues: values.envValues,
      secretRefs: secretRefs,
      cwd: cwd,
      extensions: widget.instance.extensions,
      createdAtMs: widget.instance.createdAtMs,
    );
    await widget.instanceStore
        .upsert(AcpInstanceRecord(instance: updated, secrets: const {}));
    if (!mounted) return;
    _snack('Saved');
    Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this agent?'),
        content: Text(
            '${widget.instance.label} and its saved secrets will be removed '
            'from the phone. Nothing on your machine is touched.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.secureStorage.deleteAcpSecrets(widget.instance.id);
    await widget.instanceStore.remove(widget.instance.id);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final manifest = widget.manifest;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.instance.label),
        actions: [
          IconButton(
            tooltip: 'Remove agent',
            icon: Icon(Icons.delete_outline_rounded, color: colors.error),
            onPressed: _delete,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            HermesSpace.pageH, HermesSpace.pageTop, HermesSpace.pageH, 24),
        children: [
          Text(
            manifest != null
                ? '${manifest.displayName} · ${manifest.id} (manifest v${manifest.version})'
                : 'Agent type "${widget.instance.manifestId}" is not in the '
                    'catalog anymore — update the manifest to edit its fields.',
            style: HermesType.support.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: HermesSpace.x4),
          TextField(
            controller: _label,
            onChanged: (_) => _markDirty(),
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: HermesSpace.x3),
          Row(children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _host,
                onChanged: (_) => _markDirty(),
                decoration: const InputDecoration(
                  labelText: 'Host *',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: HermesSpace.x2),
            Expanded(
              child: TextField(
                controller: _port,
                onChanged: (_) => _markDirty(),
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Port',
                  helperText: manifest != null
                      ? 'default ${manifest.bridge.defaultPort}'
                      : null,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ]),
          const SizedBox(height: HermesSpace.x4),
          if (manifest != null)
            AcpAgentForm(
              key: const ValueKey('settings-form'),
              manifest: manifest,
              initialEnvValues: {
                ...widget.instance.fieldValues,
                // Non-secret env fields saved on the instance.
              },
              initialSecrets: widget.instance.secretRefs,
            ),
          const SizedBox(height: HermesSpace.x4),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check_rounded),
            label: const Text('Save changes'),
          ),
        ],
      ),
    );
  }
}
