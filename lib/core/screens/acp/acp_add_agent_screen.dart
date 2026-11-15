import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:ylpa_acp_core/ylpa_acp_core.dart';

import '../../acp/acp_instance_store.dart';
import '../../design/list.dart';
import '../../design/tokens.dart';
import '../../theme/app_theme.dart';
import '../../services/secure_storage.dart';
import 'acp_agent_form.dart';

/// Add-Agent wizard: pick agent type from the catalog → connection details
/// → form rendered from the manifest → shows the one-line bridge command to
/// run on the machine → saves the instance (secrets to the Keystore).
class AcpAddAgentScreen extends StatefulWidget {
  const AcpAddAgentScreen({
    super.key,
    required this.catalog,
    required this.instanceStore,
    required this.secureStorage,
  });

  final AgentCatalog catalog;
  final AcpInstanceStore instanceStore;
  final SecureStorage secureStorage;

  @override
  State<AcpAddAgentScreen> createState() => _AcpAddAgentScreenState();
}

class _AcpAddAgentScreenState extends State<AcpAddAgentScreen> {
  AgentTypeManifest? _selected;
  final _labelController = TextEditingController();
  final _hostController = TextEditingController(text: '192.168.1.');
  final _portController = TextEditingController();
  final _tokenController = TextEditingController();

  final _formKey = GlobalKey<AcpAgentFormState>();
  bool _testing = false;
  /// Working directory on the agent machine — the user sets this per agent;
  /// it is never hardcoded. Must be an absolute path (OpenCode requires it).
  final _cwdController = TextEditingController();

  @override
  void dispose() {
    _labelController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _tokenController.dispose();
    _cwdController.dispose();
    super.dispose();
  }

  void _select(AgentTypeManifest manifest) {
    setState(() {
      _selected = manifest;
      _portController.text = manifest.bridge.defaultPort.toString();
    });
  }

  Future<void> _save() async {
    final manifest = _selected;
    if (manifest == null) return;
    final form = _formKey.currentState;
    final values = form?.collect();
    if (values == null) {
      _snack('Please fill in the required fields');
      return;
    }

    final host = _hostController.text.trim();
    if (host.isEmpty) {
      _snack('Host is required');
      return;
    }
    final port =
        int.tryParse(_portController.text.trim()) ?? manifest.bridge.defaultPort;

    final instanceId =
        'acp_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final label = _labelController.text.trim().isEmpty
        ? '${manifest.displayName} · $host'
        : _labelController.text.trim();

    // Secret fields (env keys) + bridge token go to secure storage.
    final secretRefs = <String, String>{};
    for (final entry in values.secrets.entries) {
      final isAuthSecret =
          manifest.auth.fields.any((f) => (f.env ?? f.id) == entry.key);
      final field = isAuthSecret ? entry.key : 'bridge_$entry.key';
      await widget.secureStorage
          .writeAcpSecret(instanceId, field, entry.value);
      if (isAuthSecret) secretRefs[entry.key] = 'acp_${field}_$instanceId';
    }

    String? tokenRef;
    final token = _tokenController.text.trim();
    if (token.isNotEmpty) {
      await widget.secureStorage
          .writeAcpSecret(instanceId, 'bridge_token', token);
      tokenRef = 'acp_bridge_token_$instanceId';
    }

    // cwd: entered as an absolute path in the connection step.
    values.envValues.remove('cwd');
    values.envValues.remove('__cwd');
    var cwd = _cwdController.text.trim();
    if (cwd.isEmpty) {
      _snack('Working directory is required');
      return;
    }
    if (!cwd.startsWith('/') && !RegExp(r'^[A-Za-z]:').hasMatch(cwd)) {
      _snack('Working directory must be an absolute path');
      return;
    }

    final instance = AgentInstance(
      id: instanceId,
      manifestId: manifest.id,
      label: label,
      host: host,
      port: port,
      tokenRef: tokenRef,
      fieldValues: values.envValues,
      secretRefs: secretRefs,
      cwd: cwd,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await widget.instanceStore.upsert(AcpInstanceRecord(
      instance: instance,
      secrets: const {},
    ));
    if (!mounted) return;
    _snack('Saved. Run the setup command on your machine, then open the agent.');
    Navigator.of(context).pop(true);
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Tries to reach the bridge daemon at host:port/acp/ws and reports
  /// success or failure without saving anything.
  Future<void> _testConnection() async {
    final manifest = _selected;
    if (manifest == null) {
      _snack('Pick an agent type first');
      return;
    }
    final host = _hostController.text.trim();
    if (host.isEmpty) {
      _snack('Host is required');
      return;
    }
    final port =
        int.tryParse(_portController.text.trim()) ?? manifest.bridge.defaultPort;
    final token = _tokenController.text.trim().isEmpty
        ? null
        : _tokenController.text.trim();

    setState(() => _testing = true);
    try {
      final endpoint = Uri.parse('ws://$host:$port/acp/ws');
      final transport = await WebSocketAcpTransport.connect(
        endpoint,
        bearerToken: token,
      );
      await transport.close();
      if (!mounted) return;
      _snack('Connection OK — bridge is reachable');
    } on Exception catch (e) {
      if (!mounted) return;
      _snack('Cannot reach bridge: ${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final manifest = _selected;
    return Scaffold(
      appBar: AppBar(title: const Text('Add agent')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            HermesSpace.pageH, HermesSpace.pageTop, HermesSpace.pageH, 24),
        children: [
          HermesSectionHeader('1 · Agent type'),
          Wrap(
            spacing: HermesSpace.x2,
            runSpacing: HermesSpace.x2,
            children: [
              for (final type in widget.catalog.instantiable)
                _typeChip(type, colors),
            ],
          ),
          if (manifest == null) ...[
            const SizedBox(height: HermesSpace.x4),
            Text(
              'Pick an agent type. Every one speaks the same Agent Client '
              'Protocol — the wizard just fills in the specifics.',
              style: HermesType.support.copyWith(color: colors.textSecondary),
            ),
          ] else ...[
            HermesSectionHeader('2 · Connection'),
            TextField(
              controller: _labelController,
              decoration: const InputDecoration(
                labelText: 'Name (optional)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: HermesSpace.x3),
            Row(children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _hostController,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Host *',
                    helperText: 'PC or server address (LAN / Tailscale)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: HermesSpace.x2),
              Expanded(
                child: TextField(
                  controller: _portController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  decoration: InputDecoration(
                    labelText: 'Port',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: HermesSpace.x3),
            TextField(
              controller: _tokenController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Bridge token (optional)',
                helperText:
                    'Only if your bridge daemon is protected with a bearer token',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: HermesSpace.x3),
            TextField(
              controller: _cwdController,
              decoration: const InputDecoration(
                labelText: 'Working directory *',
                helperText:
                    'Absolute path on the agent machine (e.g. C:\\Users\\You\\project or /home/me/project)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: HermesSpace.x3),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testing ? null : _testConnection,
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_check_rounded, size: 18),
                    label: Text(_testing ? 'Testing…' : 'Test connection'),
                  ),
                ),
                const SizedBox(width: HermesSpace.x2),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _testing ? null : _save,
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('Save agent'),
                  ),
                ),
              ],
            ),
            HermesSectionHeader('3 · Agent configuration'),
            AcpAgentForm(
              key: _formKey,
              manifest: manifest,
              includeCwd: false, // cwd is collected via _cwdController above
            ),
            const SizedBox(height: HermesSpace.x4),
            _bridgeCommandCard(manifest, colors),
            const SizedBox(height: HermesSpace.x4),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check_rounded),
              label: const Text('Save agent'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _typeChip(AgentTypeManifest type, HermesThemeColors colors) {
    final selected = _selected?.id == type.id;
    return FilterChip(
      selected: selected,
      label: Text(type.displayName),
      onSelected: (_) => _select(type),
      avatar: Icon(
        selected ? Icons.check_circle_rounded : Icons.smart_toy_outlined,
        size: 18,
      ),
    );
  }

  /// The one-paste command for the machine — mirrors the Hermes QR flow's
  /// "one command on the computer" onboarding.
  Widget _bridgeCommandCard(
      AgentTypeManifest manifest, HermesThemeColors colors) {
    final command = manifest.bridge.serveCommand;
    return Container(
      padding: const EdgeInsets.all(HermesSpace.x4),
      decoration: BoxDecoration(
        color: HermesSurfaces.group(colors),
        borderRadius: BorderRadius.circular(HermesRadius.group),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('On your machine',
              style: HermesType.body.copyWith(color: colors.textPrimary)),
          const SizedBox(height: HermesSpace.x2),
          if (manifest.bridge.installHint != null)
            Text('Install: ${manifest.bridge.installHint}',
                style:
                    HermesType.support.copyWith(color: colors.textSecondary)),
          const SizedBox(height: HermesSpace.x2),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(HermesSpace.x3),
            decoration: BoxDecoration(
              color: colors.textPrimary.withOpacity(0.06),
              borderRadius: BorderRadius.circular(HermesRadius.control),
            ),
            child: SelectableText(
              command,
              style: HermesType.value.copyWith(color: colors.textPrimary),
            ),
          ),
          const SizedBox(height: HermesSpace.x2),
          Row(
            children: [
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: command));
                  _snack('Command copied');
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy command'),
              ),
              const SizedBox(width: HermesSpace.x2),
              Expanded(
                child: Text(
                  'It serves this agent at ws://host:${manifest.bridge.defaultPort}',
                  style:
                      HermesType.support.copyWith(color: colors.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
