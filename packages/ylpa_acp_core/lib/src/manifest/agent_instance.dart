import 'agent_type_manifest.dart';

/// A saved connection to one concrete agent on one machine.
///
/// Everything the app needs to connect: which agent type it is, where the
/// bridge daemon lives, what the user configured. Secret values are never
/// stored here — `secretRefs` points at keys in secure storage (Keystore on
/// Android).
class AgentInstance {
  AgentInstance({
    required this.id,
    required this.manifestId,
    required this.label,
    required this.host,
    int? port,
    this.tokenRef,
    Map<String, String>? fieldValues,
    Map<String, String>? secretRefs,
    this.cwd = '~',
    Map<String, dynamic>? extensions,
    this.createdAtMs = 0,
  })  : port = port ?? 0,
        fieldValues = fieldValues ?? {},
        secretRefs = secretRefs ?? {},
        extensions = extensions ?? {};

  final String id;
  final String manifestId;

  /// User-chosen name shown in the UI ("My laptop · Claude").
  final String label;

  /// Bridge daemon host, e.g. `192.168.1.20` or `mybox.tailnet.ts.net`.
  final String host;
  final int port;

  /// Secure-storage key holding the bearer token for the bridge endpoint.
  final String? tokenRef;

  /// Answers to the manifest's non-secret fields (env key -> value for env
  /// fields, option id -> value otherwise).
  final Map<String, String> fieldValues;

  /// env key (e.g. `ANTHROPIC_API_KEY`) -> secure-storage key.
  final Map<String, String> secretRefs;

  /// Working directory the agent operates in on the machine.
  final String cwd;

  /// Open extension map — per-agent extras such as MCP servers, provider
  /// presets or shared-skill references. Preserved verbatim on save/load so
  /// the schema can grow without migrations.
  final Map<String, dynamic> extensions;

  final int createdAtMs;

  /// Effective port: saved port, else the manifest default.
  int effectivePort(AgentTypeManifest? manifest) =>
      port != 0 ? port : (manifest?.bridge.defaultPort ?? 8770);

  /// WebSocket endpoint of the bridge daemon.
  Uri acpEndpoint(AgentTypeManifest? manifest, {bool tls = false}) {
    final scheme = tls ? 'wss' : 'ws';
    return Uri.parse('$scheme://$host:${effectivePort(manifest)}/acp/ws');
  }

  Map<String, String> get envValues {
    // Non-secret env fields live in fieldValues keyed by env name.
    return Map.of(fieldValues);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'manifestId': manifestId,
        'label': label,
        'host': host,
        if (port != 0) 'port': port,
        if (tokenRef != null) 'tokenRef': tokenRef,
        if (fieldValues.isNotEmpty) 'fieldValues': fieldValues,
        if (secretRefs.isNotEmpty) 'secretRefs': secretRefs,
        'cwd': cwd,
        if (extensions.isNotEmpty) 'extensions': extensions,
        if (createdAtMs != 0) 'createdAtMs': createdAtMs,
      };

  static AgentInstance fromJson(Map<String, dynamic> json) {
    Map<String, String> stringMap(dynamic v) => v is Map
        ? v.map((k, val) => MapEntry(k.toString(), val?.toString() ?? ''))
        : <String, String>{};
    return AgentInstance(
      id: (json['id'] as String?) ?? '',
      manifestId: (json['manifestId'] as String?) ?? '',
      label: (json['label'] as String?) ?? '',
      host: (json['host'] as String?) ?? '',
      port: (json['port'] as num?)?.toInt() ?? 0,
      tokenRef: json['tokenRef'] as String?,
      fieldValues: stringMap(json['fieldValues']),
      secretRefs: stringMap(json['secretRefs']),
      cwd: (json['cwd'] as String?) ?? '~',
      extensions: json['extensions'] is Map
          ? (json['extensions'] as Map).cast<String, dynamic>()
          : {},
      createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// In-memory store of saved instances. The app layer persists `toJson`
/// wherever it wants (SharedPreferences, file) and hands the list back.
class AgentInstanceStore {
  AgentInstanceStore(List<AgentInstance> items) : _items = List.of(items);

  final List<AgentInstance> _items;
  List<AgentInstance> get all => List.unmodifiable(_items);

  AgentInstance? byId(String id) {
    for (final i in _items) {
      if (i.id == id) return i;
    }
    return null;
  }

  void upsert(AgentInstance instance) {
    final idx = _items.indexWhere((i) => i.id == instance.id);
    if (idx >= 0) {
      _items[idx] = instance;
    } else {
      _items.add(instance);
    }
  }

  void remove(String id) => _items.removeWhere((i) => i.id == id);
}
