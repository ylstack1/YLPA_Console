import 'config_field.dart';

/// Declarative description of an agent type — the "plugin" unit.
///
/// Everything that differs between Claude Code, OpenCode, Gemini CLI or a
/// custom agent lives here as data. Capabilities are deliberately absent:
/// they come from the agent itself at `initialize` time.
class AgentTypeManifest {
  const AgentTypeManifest({
    required this.id,
    required this.displayName,
    this.version = 1,
    this.icon = 'custom',
    this.description,
    this.isTemplate = false,
    this.bridge = const BridgeSetup(),
    this.auth = const AuthSetup(),
    this.spawnOptions = const [],
    this.links = const {},
    this.extras = const {},
  });

  /// Stable catalog id, e.g. `claude-code`, `opencode`, or a user-defined
  /// `my-org-agent`. Uniqueness key for the catalog.
  final String id;
  final String displayName;
  final String icon;

  /// Bump when the manifest changes; catalog merging prefers higher.
  final int version;

  final String? description;

  /// True for templates (e.g. `custom-acp`) that are shown in the editor but
  /// cannot be instantiated directly. Serialized as JSON key `"abstract"`.
  final bool isTemplate;

  /// How the agent is launched on the host machine behind a bridge daemon.
  final BridgeSetup bridge;

  /// Authentication the agent needs.
  final AuthSetup auth;

  /// Extra options the wizard asks for (cwd, default model, ...).
  final List<ConfigField> spawnOptions;

  final Map<String, String> links;

  /// Open map for future growth (per-agent hints, MCP provider presets,
  /// skill bundle references). Unknown keys are preserved, never dropped.
  final Map<String, dynamic> extras;

  static AgentTypeManifest fromJson(Map<String, dynamic> json) {
    final bridgeJson = json['bridge'] is Map ? (json['bridge'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    final authJson = json['auth'] is Map ? (json['auth'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    final linksJson = json['links'] is Map ? (json['links'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    final extras = <String, dynamic>{...json.cast<String, dynamic>()}
      ..removeWhere((k, _) => const [
            'id', 'displayName', 'icon', 'version', 'description', 'abstract',
            'bridge', 'auth', 'spawnOptions', 'links',
          ].contains(k));
    return AgentTypeManifest(
      id: (json['id'] as String?) ?? '',
      displayName: (json['displayName'] as String?) ?? (json['id'] as String?) ?? 'Unnamed agent',
      icon: (json['icon'] as String?) ?? 'custom',
      version: (json['version'] as num?)?.toInt() ?? 1,
      description: json['description'] as String?,
      isTemplate: json['abstract'] == true,
      bridge: BridgeSetup.fromJson(bridgeJson),
      auth: AuthSetup.fromJson(authJson),
      spawnOptions: json['spawnOptions'] is List
          ? (json['spawnOptions'] as List)
              .whereType<Map>()
              .map((e) => ConfigField.fromJson(e.cast<String, dynamic>()))
              .toList()
          : const [],
      links: linksJson.map((k, v) => MapEntry(k, v?.toString() ?? '')),
      extras: extras,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'icon': icon,
        'version': version,
        if (description != null) 'description': description,
        if (isTemplate) 'abstract': true,
        'bridge': bridge.toJson(),
        'auth': auth.toJson(),
        'spawnOptions': spawnOptions.map((f) => f.toJson()).toList(),
        'links': links,
        ...extras,
      };
}

/// How to serve the agent on a machine, behind a bridge daemon.
class BridgeSetup {
  const BridgeSetup({
    this.serveCommand = '',
    this.defaultPort = 8770,
    this.installHint,
  });

  /// One-paste command the user runs on the machine to expose the agent,
  /// e.g. `acpremote serve-command -- opencode acp`.
  final String serveCommand;
  final int defaultPort;
  final String? installHint;

  static BridgeSetup fromJson(Map<String, dynamic> json) => BridgeSetup(
        serveCommand: (json['serveCommand'] as String?) ?? '',
        defaultPort: (json['defaultPort'] as num?)?.toInt() ?? 8770,
        installHint: json['installHint'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'serveCommand': serveCommand,
        'defaultPort': defaultPort,
        if (installHint != null) 'installHint': installHint,
      };
}

enum AuthMode { env, oauth, none }

class AuthSetup {
  const AuthSetup({this.mode = AuthMode.none, this.fields = const [], this.note});

  final AuthMode mode;

  /// Env-var fields the user may fill (API keys etc.). Secret values go to
  /// secure storage; non-secret ones to `AgentInstance.fieldValues`.
  final List<ConfigField> fields;
  final String? note;

  static AuthSetup fromJson(Map<String, dynamic> json) => AuthSetup(
        mode: switch ((json['mode'] as String?)?.toLowerCase()) {
          'env' => AuthMode.env,
          'oauth' => AuthMode.oauth,
          _ => AuthMode.none,
        },
        fields: json['fields'] is List
            ? (json['fields'] as List)
                .whereType<Map>()
                .map((e) => ConfigField.fromJson(e.cast<String, dynamic>()))
                .toList()
            : const [],
        note: json['note'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'fields': fields.map((f) => f.toJson()).toList(),
        if (note != null) 'note': note,
      };
}
