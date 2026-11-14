import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:ylpa_acp_core/ylpa_acp_core.dart';

/// Persists saved ACP agent instances (one connection to one agent on one
/// machine) in SharedPreferences as a JSON list.
///
/// Secrets are never stored here: `AgentInstance.secretRefs` points at keys
/// in secure storage (see [AcpSecrets]).
class AcpInstanceStore {
  AcpInstanceStore(this._prefs);

  static const _storageKey = 'acp_instances_v1';

  final SharedPreferences _prefs;

  List<AgentInstance> load() {
    final raw = _prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((m) => AgentInstance.fromJson(m.cast<String, dynamic>()))
          .toList();
    } on FormatException {
      return []; // fail soft: corrupt data reads as empty, never crashes
    }
  }

  Future<void> _writeAll(List<AgentInstance> instances) async {
    final json = jsonEncode(instances.map((i) => i.toJson()).toList());
    await _prefs.setString(_storageKey, json);
  }

  Future<void> upsert(AcpInstanceRecord record) async {
    final all = load();
    final idx = all.indexWhere((i) => i.id == record.instance.id);
    if (idx >= 0) {
      all[idx] = record.instance;
    } else {
      all.add(record.instance);
    }
    await _writeAll(all);
  }

  Future<void> remove(String instanceId) async {
    final all = load().where((i) => i.id != instanceId).toList();
    await _writeAll(all);
  }
}

/// Everything needed to save one instance together with its secrets.
class AcpInstanceRecord {
  AcpInstanceRecord({
    required this.instance,
    required this.secrets,
  });

  final AgentInstance instance;

  /// env key (e.g. `ANTHROPIC_API_KEY`) -> plain value, written to secure
  /// storage by the caller at save time.
  final Map<String, String> secrets;
}
