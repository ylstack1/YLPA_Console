import 'package:flutter/material.dart';

import 'package:ylpa_acp_core/ylpa_acp_core.dart';

import '../../theme/app_theme.dart';
import '../../design/tokens.dart';

/// Values collected by [AcpAgentForm].
class AcpFormValues {
  AcpFormValues({required this.envValues, required this.secrets});

  /// Non-secret env fields and spawn options: env key (or field id) → value.
  final Map<String, String> envValues;

  /// env key → plain secret value, to be written to secure storage.
  final Map<String, String> secrets;
}

/// Renders a manifest's `auth.fields` + `spawnOptions` as a plain form.
///
/// This is the dynamic-UI heart of the ACP layer: one widget serves every
/// agent type — the fields are data from the manifest, never code. Choice
/// fields marked `dynamic` (model lists) render as free text with a hint,
/// because their real options arrive live from the agent at session time.
class AcpAgentForm extends StatefulWidget {
  const AcpAgentForm({
    super.key,
    required this.manifest,
    this.initialEnvValues = const {},
    this.initialSecrets = const {},
    this.includeCwd = true,
  });

  final AgentTypeManifest manifest;

  /// Existing non-secret values (editing an instance).
  final Map<String, String> initialEnvValues;

  /// Env keys of existing secrets — shown as "saved" placeholders; the
  /// actual secret value is never rendered back.
  final Map<String, String> initialSecrets;

  /// Whether to ask for `cwd` (true for wizard + settings; the field also
  /// exists in spawnOptions when the manifest declares it).
  final bool includeCwd;

  @override
  State<AcpAgentForm> createState() => AcpAgentFormState();
}

class AcpAgentFormState extends State<AcpAgentForm> {
  final _textControllers = <String, TextEditingController>{};
  final _secretControllers = <String, TextEditingController>{};
  final _formKey = GlobalKey<FormState>();

  List<ConfigField> get _fields => [
        ...widget.manifest.auth.fields,
        ...widget.manifest.spawnOptions,
      ];

  String _fieldKey(ConfigField f) => f.env ?? f.id;

  @override
  void dispose() {
    for (final c in _textControllers.values) {
      c.dispose();
    }
    for (final c in _secretControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Validates and returns the values, or null when the form is invalid.
  AcpFormValues? collect() {
    if (!(_formKey.currentState?.validate() ?? false)) return null;
    final env = <String, String>{};
    final secrets = <String, String>{};
    for (final f in _fields) {
      if (f.type == FieldType.bool) continue; // not rendered yet
      final key = _fieldKey(f);
      final isSecret = f.type == FieldType.secret;
      final controller = _textControllers[key];
      final raw = controller?.text.trim() ?? '';
      if (isSecret) {
        if (raw.isNotEmpty) secrets[key] = raw;
      } else if (raw.isNotEmpty) {
        env[key] = raw;
      }
    }
    return AcpFormValues(envValues: env, secrets: secrets);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.manifest.auth.note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: HermesSpace.x3),
              child: Text(
                widget.manifest.auth.note!,
                style: HermesType.support
                    .copyWith(color: colors.textSecondary),
              ),
            ),
          for (final f in _fields) _fieldTile(f, colors),
          if (widget.includeCwd && !widget.manifest.spawnOptions.any((o) => o.id == 'cwd'))
            _plainTile(
              controller: _textControllers.putIfAbsent(
                '__cwd',
                () => TextEditingController(text: '~'),
              ),
              label: 'Working directory',
              hint: 'Path on the machine, e.g. /home/me/project',
              colors: colors,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
        ],
      ),
    );
  }

  Widget _fieldTile(ConfigField f, HermesThemeColors colors) {
    if (f.type == FieldType.bool) {
      return const SizedBox.shrink(); // not rendered in phase 1
    }
    final key = _fieldKey(f);
    final hadSecret = widget.initialSecrets[key] != null;
    final controller = _textControllers.putIfAbsent(
      key,
      () => TextEditingController(
        text: widget.initialEnvValues[key] ??
            (f.type == FieldType.secret ? '' : f.defaultValue ?? ''),
      ),
    );
    final isSecret = f.type == FieldType.secret;
    if (f.type == FieldType.choice && f.choices.isNotEmpty) {
      // Static dropdown from manifest choices.
      return Padding(
        padding: const EdgeInsets.only(bottom: HermesSpace.x3),
        child: DropdownButtonFormField<String>(
          initialValue: controller.text.isEmpty ? null : controller.text,
          decoration: _decoration(f.label, colors,
              hint: f.help, required: f.required),
          items: f.choices
              .map((c) => DropdownMenuItem(
                    value: c.value,
                    child: Text(c.label ?? c.value),
                  ))
              .toList(),
          onChanged: (v) => controller.text = v ?? '',
          validator: f.required
              ? (v) => (v == null || v.isEmpty) ? 'Required' : null
              : null,
        ),
      );
    }
    if (isSecret) {
      return Padding(
        padding: const EdgeInsets.only(bottom: HermesSpace.x3),
        child: TextFormField(
          controller: controller,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: _decoration(f.label, colors,
                  hint: f.help, required: f.required)
              .copyWith(
            helperText: hadSecret
                ? 'Saved — type a new value to replace it'
                : null,
          ),
          validator: f.required
              ? (v) => (v == null || v.trim().isEmpty)
                  ? (hadSecret ? null : 'Required')
                  : null
              : null,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: HermesSpace.x3),
      child: TextFormField(
        controller: controller,
        decoration: _decoration(
          f.type == FieldType.choice && f.isDynamic
              ? '${f.label} (resolved live from the agent)'
              : f.label,
          colors,
          hint: f.help,
          required: f.required,
        ),
        keyboardType:
            f.type == FieldType.number ? TextInputType.number : null,
        validator: f.required
            ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null
            : null,
      ),
    );
  }

  Widget _plainTile({
    required TextEditingController controller,
    required String label,
    required String hint,
    required HermesThemeColors colors,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: HermesSpace.x3),
      child: TextFormField(
        controller: controller,
        decoration: _decoration(label, colors, hint: hint, required: false),
        validator: validator,
      ),
    );
  }

  InputDecoration _decoration(
    String label,
    HermesThemeColors colors, {
    String? hint,
    required bool required,
  }) {
    return InputDecoration(
      labelText: required ? '$label *' : label,
      helperText: hint,
      border: const OutlineInputBorder(),
      isDense: true,
    );
  }
}
