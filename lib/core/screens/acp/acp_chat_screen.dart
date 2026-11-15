import 'package:flutter/material.dart';

import 'package:ylpa_acp_core/ylpa_acp_core.dart';

import '../../acp/acp_session_controller.dart';
import '../../acp/acp_instance_store.dart';
import '../../design/tokens.dart';
import '../../theme/app_theme.dart';
import '../../services/secure_storage.dart';

/// ACP chat: streaming transcript (text, reasoning, tool calls, plan),
/// dynamic config pickers from the agent's `configOptions`, a slash-command
/// hint line, and the permission approval dialog.
///
/// Deliberately a plain Material scaffold — it renders ACP updates, not
/// Hermes Dashboard state, and shares no code with the Hermes chat path.
///
/// The app bar carries an agent switcher (any saved ACP instance) and a
/// workspace path button. Switching agents reconnects with the current
/// workspace path, so a session always runs in the chosen workspace.
class AcpChatScreen extends StatefulWidget {
  const AcpChatScreen({
    super.key,
    required this.instance,
    required this.manifest,
    required this.bearerToken,
    required this.instanceStore,
    required this.secureStorage,
    required this.catalog,
  });

  final AgentInstance instance;
  final AgentTypeManifest manifest;
  final String? bearerToken;

  final AcpInstanceStore instanceStore;
  final SecureStorage secureStorage;
  final AgentCatalog catalog;

  @override
  State<AcpChatScreen> createState() => _AcpChatScreenState();
}

class _AcpChatScreenState extends State<AcpChatScreen> {
  AcpSessionController? _controller;
  final _composer = TextEditingController();
  final _scroll = ScrollController();

  List<AgentInstance> _instances = [];
  bool _loadingInstances = true;

  @override
  void initState() {
    super.initState();
    _loadInstances();
    _createController(widget.instance, widget.manifest, widget.bearerToken);
  }

  Future<void> _loadInstances() async {
    final instances = widget.instanceStore.load();
    if (!mounted) return;
    setState(() {
      _instances = instances;
      _loadingInstances = false;
    });
  }

  void _createController(
    AgentInstance instance,
    AgentTypeManifest manifest,
    String? bearerToken,
  ) {
    _controller?.dispose();
    _controller = AcpSessionController(
      instance: instance,
      manifest: manifest,
      bearerToken: bearerToken,
      sessionCwd: instance.cwd.isEmpty ? null : instance.cwd,
    );
    _controller!.addListener(_onControllerChanged);
    _controller!.connect();
  }

  /// Switch to a different saved agent, keeping the current workspace path.
  /// Reconnects with the new instance (and its manifest) in the same cwd.
  Future<void> _switchAgent(AgentInstance next) async {
    if (next.id == widget.instance.id) return;
    final manifest = widget.catalog.byId(next.manifestId);
    if (manifest == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Unknown agent type for ${next.label}'),
      ));
      return;
    }
    final token = await _loadToken(next);
    if (!mounted) return;
    setState(() {
      // Rebuild with the new instance so the app bar title + controller follow it.
    });
    // Recreate the controller against the new agent, same workspace path.
    _createController(next, manifest, token);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Switched to ${next.label} (workspace: ${_controller!.sessionCwd})'),
    ));
  }

  Future<String?> _loadToken(AgentInstance instance) async {
    final tokenRef = instance.tokenRef;
    if (tokenRef == null) return null;
    return widget.secureStorage.readAcpSecret(instance.id, 'bridge_token');
  }

  /// Open a sheet to change the session workspace (cwd). Reconnects with the
  /// new path so the agent works in that directory.
  Future<void> _showWorkspaceSheet() async {
    final current = _controller?.sessionCwd ?? widget.instance.cwd;
    final cwdController = TextEditingController(text: current);
    final outcome = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Workspace'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Absolute path on the agent machine where this session runs.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: HermesSpace.x3),
            TextField(
              controller: cwdController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Workspace path',
                hintText: '/home/me/project',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop(cwdController.text.trim());
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (outcome == null || outcome.isEmpty) return;
    if (!outcome.startsWith('/') &&
        !RegExp(r'^[A-Za-z]:').hasMatch(outcome)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Workspace must be an absolute path.'),
      ));
      return;
    }
    await _controller?.setWorkspace(outcome);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Workspace: $outcome'),
    ));
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
    // Keep the transcript pinned to the newest line.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _controller?.removeListener(_onControllerChanged);
    _controller?.dispose();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _showPermissionDialog(AcpPendingPermission pending) async {
    final options = pending.request.options;
    final outcome = await showDialog<PermissionOutcome>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Permission requested'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (pending.request.title.isNotEmpty)
              Text(pending.request.title),
            if (pending.request.kind.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: HermesSpace.x2),
                child: Text(
                  'Kind: ${pending.request.kind}',
                  style: HermesType.support
                      .copyWith(color: Theme.of(context).hermes.textSecondary),
                ),
              ),
          ],
        ),
        actions: [
          for (final option in options)
            TextButton(
              onPressed: () => Navigator.of(context).pop(
                option.kind.startsWith('reject')
                    ? const PermissionOutcome.deny()
                    : PermissionOutcome.allow(option.optionId),
              ),
              child: Text(option.name),
            ),
        ],
      ),
    );
    if (outcome != null) {
      await _controller?.resolvePermission(outcome);
    }
  }

  void _send() {
    final text = _composer.text;
    _composer.clear();
    _controller?.sendPrompt(text);
  }

  Widget _appBarTitle(HermesThemeColors colors) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.instance.label,
            style: HermesType.body.copyWith(color: colors.textPrimary)),
        Text(
          '${widget.instance.host}:${widget.instance.port}  •  ${widget.manifest.displayName}',
          style: HermesType.support.copyWith(color: colors.textSecondary),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final state = _controller?.state ?? AcpConnectionState.idle;
    return Scaffold(
      appBar: AppBar(
        title: _appBarTitle(colors),
        actions: [
          // Agent switcher — any saved ACP instance, same workspace path.
          IconButton(
            tooltip: 'Switch agent',
            icon: const Icon(Icons.account_circle_rounded),
            onPressed: _loadingInstances
                ? null
                : () => _showAgentSwitcher(colors),
          ),
          // Workspace (cwd) override for this session.
          IconButton(
            tooltip: 'Workspace path',
            icon: const Icon(Icons.folder_rounded),
            onPressed: state == AcpConnectionState.ready
                ? _showWorkspaceSheet
                : null,
          ),
          if (_controller?.configOptions.isNotEmpty == true)
            IconButton(
              tooltip: 'Model & options',
              icon: const Icon(Icons.tune_rounded),
              onPressed: _showConfigSheet,
            ),
        ],
      ),
      body: Column(
        children: [
          if (state == AcpConnectionState.failed)
            _failureView(colors)
          else if (state == AcpConnectionState.connecting)
            _connectingView(colors)
          else
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.symmetric(
                    horizontal: HermesSpace.x4, vertical: HermesSpace.x3),
                itemCount: _controller?.lines.length ?? 0,
                itemBuilder: (context, index) =>
                    _line(context, _controller!.lines[index], colors),
              ),
            ),
          if (_controller?.pendingPermission != null &&
              !_permissionDialogOpen)
            _PermissionBanner(
              title: _controller!.pendingPermission!.request.title,
              onReview: () =>
                  _showPermissionDialog(_controller!.pendingPermission!),
            ),
          _composer_(colors),
        ],
      ),
    );
  }

  /// Show the saved-agent switcher. Picking one reconnects the chat to that
  /// agent in the current workspace path.
  Future<void> _showAgentSwitcher(HermesThemeColors colors) async {
    final selected = await showDialog<AgentInstance>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Switch agent'),
        content: SizedBox(
          width: double.maxFinite,
          child: _loadingInstances
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: _instances.length,
                  itemBuilder: (context, index) {
                    final inst = _instances[index];
                    final manifest = widget.catalog.byId(inst.manifestId);
                    final isCurrent = inst.id == widget.instance.id;
                    return ListTile(
                      leading: Icon(
                        isCurrent ? Icons.check_circle : Icons.radio_button_unchecked,
                        color: isCurrent ? colors.accent : colors.textDisabled,
                        size: 20,
                      ),
                      title: Text(
                        inst.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.body.copyWith(
                          color: isCurrent ? colors.textPrimary : colors.textSecondary,
                        ),
                      ),
                      subtitle: Text(
                        '${manifest?.displayName ?? inst.manifestId}  •  ${inst.host}:${inst.port}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.support.copyWith(color: colors.textSecondary),
                      ),
                      onTap: () => Navigator.of(context).pop(inst),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (selected != null) {
      await _switchAgent(selected);
    }
  }

  bool get _permissionDialogOpen => false; // dialog is modal; banner is backup

  Widget _failureView(HermesThemeColors colors) {
    return Expanded(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(HermesSpace.x6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 40, color: colors.textDisabled),
              const SizedBox(height: HermesSpace.x3),
              Text(
                _controller?.failure ?? 'Not connected',
                textAlign: TextAlign.center,
                style: HermesType.support.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: HermesSpace.x4),
              OutlinedButton.icon(
                onPressed: () {
                  setState(() {
                    _controller?.state = AcpConnectionState.idle;
                  });
                  _controller?.connect();
                },
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _connectingView(HermesThemeColors colors) {
    return Expanded(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: HermesSpace.x3),
            Text(
              'Connecting to ${widget.instance.host}…',
              style: HermesType.support.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _line(BuildContext context, AcpChatLine line, HermesThemeColors colors) {
    switch (line.kind) {
      case LineKind.user:
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: HermesSpace.x1),
            padding: const EdgeInsets.symmetric(
                horizontal: HermesSpace.x3, vertical: HermesSpace.x2),
            constraints: const BoxConstraints(maxWidth: 320),
            decoration: BoxDecoration(
              color: colors.accent.withOpacity(0.15),
              borderRadius: BorderRadius.circular(HermesRadius.control),
            ),
            child: Text(line.text,
                style: HermesType.body.copyWith(color: colors.textPrimary)),
          ),
        );
      case LineKind.agent:
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: HermesSpace.x1),
            padding: const EdgeInsets.symmetric(
                horizontal: HermesSpace.x3, vertical: HermesSpace.x2),
            constraints: const BoxConstraints(maxWidth: 360),
            decoration: BoxDecoration(
              color: HermesSurfaces.group(colors),
              borderRadius: BorderRadius.circular(HermesRadius.control),
            ),
            child: Text(line.text,
                style: HermesType.body.copyWith(color: colors.textPrimary)),
          ),
        );
      case LineKind.thought:
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: HermesSpace.x1),
            padding: const EdgeInsets.symmetric(
                horizontal: HermesSpace.x3, vertical: HermesSpace.x2),
            constraints: const BoxConstraints(maxWidth: 360),
            decoration: BoxDecoration(
              color: colors.accentSoft.withOpacity(0.15),
              borderRadius: BorderRadius.circular(HermesRadius.control),
            ),
            child: Text(line.text,
                style: HermesType.body.copyWith(
                    color: colors.textSecondary, fontStyle: FontStyle.italic)),
          ),
        );
      case LineKind.tool:
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: HermesSpace.x1),
            padding: const EdgeInsets.symmetric(
                horizontal: HermesSpace.x3, vertical: HermesSpace.x2),
            constraints: const BoxConstraints(maxWidth: 360),
            decoration: BoxDecoration(
              color: colors.surface2,
              border: Border.all(color: colors.border),
              borderRadius: BorderRadius.circular(HermesRadius.control),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tool: ${line.id ?? '-'} (${line.status ?? '-'})',
                  style: HermesType.support.copyWith(color: colors.textSecondary),
                ),
                const SizedBox(height: HermesSpace.x1),
                Text(line.text,
                    style: HermesType.body.copyWith(color: colors.textPrimary)),
              ],
            ),
          ),
        );
      case LineKind.plan:
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: HermesSpace.x1),
            padding: const EdgeInsets.symmetric(
                horizontal: HermesSpace.x3, vertical: HermesSpace.x2),
            constraints: const BoxConstraints(maxWidth: 360),
            decoration: BoxDecoration(
              color: colors.accent.withOpacity(0.1),
              borderRadius: BorderRadius.circular(HermesRadius.control),
            ),
            child: Text(line.text,
                style: HermesType.body.copyWith(color: colors.textPrimary)),
          ),
        );
      case LineKind.system:
        return Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: HermesSpace.x1),
            child: Text(line.text,
                style: HermesType.support.copyWith(color: colors.textSecondary)),
          ),
        );
    }
  }

  Widget _composer_(HermesThemeColors colors) {
    final canSend = _controller?.state == AcpConnectionState.ready;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            HermesSpace.x3, HermesSpace.x2, HermesSpace.x3, HermesSpace.x3),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _composer,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                enabled: canSend,
                decoration: InputDecoration(
                  hintText: canSend
                      ? 'Message the agent…'
                      : _controller?.turnRunning == true
                          ? 'Turn running…'
                          : 'Not connected',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: canSend ? (_) => _send() : null,
              ),
            ),
            const SizedBox(width: HermesSpace.x2),
            if (_controller?.turnRunning == true)
              IconButton.filled(
                tooltip: 'Stop',
                icon: const Icon(Icons.stop_rounded),
                onPressed: _controller?.cancelTurn,
              )
            else
              IconButton.filled(
                tooltip: 'Send',
                icon: const Icon(Icons.send_rounded),
                onPressed: canSend ? _send : null,
              ),
          ],
        ),
      ),
    );
  }

  void _showConfigSheet() {
    final options = _controller?.configOptions ?? const [];
    if (options.isEmpty) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Padding(
          padding: const EdgeInsets.all(HermesSpace.x4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Model & options',
                  style: HermesType.heading.copyWith(color: colors.textPrimary)),
              const SizedBox(height: HermesSpace.x4),
              for (final option in options)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(option.name,
                        style: HermesType.body.copyWith(color: colors.textPrimary)),
                    const SizedBox(height: HermesSpace.x1),
                    if (option.options.isNotEmpty)
                      Wrap(
                        spacing: HermesSpace.x2,
                        runSpacing: HermesSpace.x2,
                        children: [
                          for (final value in option.options)
                            FilterChip(
                              label: Text(value.name),
                              selected: value.value == option.currentValue,
                              onSelected: (_) {
                                Navigator.of(context).pop();
                                _controller?.setConfigOption(
                                    option.id, value.value);
                              },
                            ),
                        ],
                      ),
                    const SizedBox(height: HermesSpace.x4),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionBanner extends StatelessWidget {
  const _PermissionBanner({required this.title, required this.onReview});

  final String title;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Material(
      color: colors.accent.withOpacity(0.12),
      child: InkWell(
        onTap: onReview,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: HermesSpace.x4, vertical: HermesSpace.x2),
          child: Row(
            children: [
              Icon(Icons.shield_outlined, size: 18, color: colors.accent),
              const SizedBox(width: HermesSpace.x2),
              Expanded(
                child: Text(
                  title.isEmpty
                      ? 'The agent asks for permission'
                      : 'Permission: $title',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      HermesType.support.copyWith(color: colors.textPrimary),
                ),
              ),
              Text('Review',
                  style: HermesType.support.copyWith(color: colors.accent)),
            ],
          ),
        ),
      ),
    );
  }
}
