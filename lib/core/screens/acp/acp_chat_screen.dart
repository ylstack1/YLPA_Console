import 'package:flutter/material.dart';

import 'package:ylpa_acp_core/ylpa_acp_core.dart';

import '../../acp/acp_session_controller.dart';
import '../../design/tokens.dart';
import '../../theme/app_theme.dart';

/// ACP chat: streaming transcript (text, reasoning, tool calls, plan),
/// dynamic config pickers from the agent's `configOptions`, a slash-command
/// hint line, and the permission approval dialog.
///
/// Deliberately a plain Material scaffold — it renders ACP updates, not
/// Hermes Dashboard state, and shares no code with the Hermes chat path.
class AcpChatScreen extends StatefulWidget {
  const AcpChatScreen({
    super.key,
    required this.instance,
    required this.manifest,
    required this.bearerToken,
  });

  final AgentInstance instance;
  final AgentTypeManifest manifest;
  final String? bearerToken;

  @override
  State<AcpChatScreen> createState() => _AcpChatScreenState();
}

class _AcpChatScreenState extends State<AcpChatScreen> {
  late final AcpSessionController _controller;
  final _composer = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller = AcpSessionController(
      instance: widget.instance,
      manifest: widget.manifest,
      bearerToken: widget.bearerToken,
    );
    _controller.addListener(_onControllerChanged);
    _controller.connect();
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
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
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
      await _controller.resolvePermission(outcome);
    }
  }

  void _send() {
    final text = _composer.text;
    _composer.clear();
    _controller.sendPrompt(text);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final state = _controller.state;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.instance.label),
        actions: [
          if (_controller.configOptions.isNotEmpty)
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
                itemCount: _controller.lines.length,
                itemBuilder: (context, index) =>
                    _line(context, _controller.lines[index], colors),
              ),
            ),
          if (_controller.pendingPermission != null &&
              !_permissionDialogOpen)
            _PermissionBanner(
              title: _controller.pendingPermission!.request.title,
              onReview: () =>
                  _showPermissionDialog(_controller.pendingPermission!),
            ),
          _composer_(colors),
        ],
      ),
    );
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
                _controller.failure ?? 'Not connected',
                textAlign: TextAlign.center,
                style: HermesType.support.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: HermesSpace.x4),
              OutlinedButton.icon(
                onPressed: () {
                  setState(() {
                    _controller.state = AcpConnectionState.idle;
                  });
                  _controller.connect();
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
            child: SelectableText(line.text,
                style: HermesType.body.copyWith(color: colors.textPrimary)),
          ),
        );
      case LineKind.thought:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: HermesSpace.x1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.psychology_outlined,
                  size: 16, color: colors.textDisabled),
              const SizedBox(width: HermesSpace.x2),
              Expanded(
                child: Text(
                  line.text,
                  style: HermesType.support
                      .copyWith(color: colors.textSecondary, fontStyle: FontStyle.italic),
                ),
              ),
            ],
          ),
        );
      case LineKind.tool:
        return Container(
          margin: const EdgeInsets.symmetric(vertical: HermesSpace.x1),
          padding: const EdgeInsets.all(HermesSpace.x2),
          decoration: BoxDecoration(
            border: Border.all(color: colors.textDisabled.withOpacity(0.3)),
            borderRadius: BorderRadius.circular(HermesRadius.control),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _toolIcon(line.status, colors),
                  const SizedBox(width: HermesSpace.x2),
                  Expanded(
                    child: Text(
                      line.text.split('\n').first,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          HermesType.support.copyWith(color: colors.textPrimary),
                    ),
                  ),
                ],
              ),
              if (line.text.contains('\n'))
                Padding(
                  padding: const EdgeInsets.only(
                      left: HermesSpace.x5, top: HermesSpace.x1),
                  child: SelectableText(
                    line.text.split('\n').skip(1).join('\n'),
                    style: HermesType.support
                        .copyWith(color: colors.textSecondary),
                  ),
                ),
            ],
          ),
        );
      case LineKind.plan:
        return Container(
          margin: const EdgeInsets.symmetric(vertical: HermesSpace.x1),
          padding: const EdgeInsets.all(HermesSpace.x3),
          decoration: BoxDecoration(
            color: HermesSurfaces.group(colors),
            borderRadius: BorderRadius.circular(HermesRadius.control),
          ),
          child: SelectableText(
            line.text,
            style: HermesType.support.copyWith(color: colors.textPrimary),
          ),
        );
      case LineKind.system:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: HermesSpace.x1),
          child: Text(
            line.text,
            textAlign: TextAlign.center,
            style: HermesType.caption.copyWith(color: colors.textDisabled),
          ),
        );
    }
  }

  Widget _toolIcon(String? status, HermesThemeColors colors) {
    switch (status) {
      case 'completed':
        return Icon(Icons.check_circle_outline_rounded,
            size: 16, color: colors.success);
      case 'failed':
        return Icon(Icons.error_outline_rounded, size: 16, color: colors.error);
      case 'in_progress':
        return const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      default:
        return Icon(Icons.circle_outlined, size: 16, color: colors.textDisabled);
    }
  }

  Future<void> _showConfigSheet() async {
    final options = _controller.configOptions;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        final colors = Theme.of(context).hermes;
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(HermesSpace.x4),
            shrinkWrap: true,
            children: [
              for (final option in options) ...[
                Text(option.name,
                    style:
                        HermesType.body.copyWith(color: colors.textPrimary)),
                const SizedBox(height: HermesSpace.x2),
                if (option.options.isEmpty)
                  Text(
                    option.currentValue ?? '(none)',
                    style: HermesType.support
                        .copyWith(color: colors.textSecondary),
                  )
                else
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
                            _controller.setConfigOption(
                                option.id, value.value);
                          },
                        ),
                    ],
                  ),
                const SizedBox(height: HermesSpace.x4),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _composer_(HermesThemeColors colors) {
    final canSend = _controller.state == AcpConnectionState.ready;
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
                      : _controller.turnRunning
                          ? 'Agent is working…'
                          : 'Connecting…',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: HermesSpace.x2),
            if (_controller.turnRunning)
              IconButton.filled(
                tooltip: 'Stop',
                icon: const Icon(Icons.stop_rounded),
                onPressed: _controller.cancelTurn,
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
