/// A single configurable field rendered by the UI for an agent type.
///
/// Fields are data, not code: the Add-Agent wizard and the settings screen
/// render forms directly from these. Secret fields are stored in secure
/// storage and injected as env vars into the bridge's agent spawn command;
/// they never touch `AgentInstance` persistence or logs.
library;

enum FieldType { text, secret, choice, bool, number }

/// A field the user fills in when configuring an agent type.
class ConfigField {
  const ConfigField({
    required this.id,
    required this.label,
    required this.type,
    this.env,
    this.required = false,
    this.isDynamic = false,
    this.defaultValue,
    this.help,
    this.choices = const [],
  });

  /// Stable identifier within the manifest, e.g. `apiKey`, `model`.
  final String id;

  /// Human label shown in the form.
  final String label;

  final FieldType type;

  /// Environment variable injected into the agent spawn environment
  /// (e.g. `ANTHROPIC_API_KEY`). Null for pure UI options like `cwd`.
  final String? env;

  /// Whether the value must be present before connecting.
  final bool required;

  /// If true, the concrete choices/values are resolved live from the agent
  /// (e.g. model lists from `configOptions`), not from [choices]. Serialized
  /// as JSON key `"dynamic"`.
  final bool isDynamic;

  final String? defaultValue;

  final String? help;

  /// Static options for [FieldType.choice]; ignored when [dynamic].
  final List<Choice> choices;

  /// Parses defensively: unknown field types fall back to [FieldType.text]
  /// instead of throwing (fail soft — an older app must still load a newer
  /// manifest).
  static ConfigField fromJson(Map<String, dynamic> json) {
    final type = switch ((json['type'] as String?)?.toLowerCase()) {
      'secret' => FieldType.secret,
      'choice' => FieldType.choice,
      'bool' => FieldType.bool,
      'number' => FieldType.number,
      _ => FieldType.text,
    };
    final rawChoices = json['choices'];
    return ConfigField(
      id: (json['id'] as String?) ?? (json['key'] as String?) ?? '',
      label: (json['label'] as String?) ?? (json['id'] as String?) ?? '',
      type: type,
      env: json['env'] as String?,
      required: json['required'] == true,
      isDynamic: json['dynamic'] == true,
      defaultValue: json['defaultValue'] as String?,
      help: json['help'] as String?,
      choices: rawChoices is List
          ? rawChoices
              .map((c) => c is Map
                  ? Choice.fromJson(c.cast<String, dynamic>())
                  : Choice.simple(c.toString()))
              .toList()
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'type': type.name,
        if (env != null) 'env': env,
        if (required) 'required': true,
        if (isDynamic) 'dynamic': true,
        if (defaultValue != null) 'defaultValue': defaultValue,
        if (help != null) 'help': help,
        if (choices.isNotEmpty)
          'choices': choices.map((c) => c.toJson()).toList(),
      };
}

class Choice {
  const Choice({required this.value, this.label});
  const Choice.simple(String value) : this(value: value, label: value);

  /// Value sent to the agent / put in the env var.
  final String value;
  final String? label;

  static Choice fromJson(Map<String, dynamic> json) => Choice(
        value: (json['value'] as String?) ?? '',
        label: json['label'] as String?,
      );

  Map<String, dynamic> toJson() => {'value': value, if (label != null) 'label': label};
}
