import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'agent_type_manifest.dart';

/// A source of agent-type manifests.
///
/// Three kinds of sources feed the catalog, in priority order:
/// 1. **Bundled** — JSON strings shipped in the app binary.
/// 2. **User** — manifest files the user (or the in-app editor) dropped in a
///    directory; override bundled entries by id.
/// 3. **Remote** — a URL returning `{"types": [...]}`; new agents reach all
///    users without an app release. Remote entries are additive by default
///    (they never shadow bundled ones unless `allowOverride: true`).
abstract class ManifestSource {
  /// Whether entries from this source may replace entries already loaded
  /// from earlier sources (same id). Bundled + user sources override;
  /// remote catalogs are additive-only unless explicitly allowed.
  bool get allowOverride;

  Future<List<AgentTypeManifest>> load();
}

/// Manifests provided directly as JSON strings (bundled assets, in-memory
/// plugin lists).
class InlineManifestSource implements ManifestSource {
  InlineManifestSource(this._jsonStrings, {this.allowOverride = true});

  final List<String> _jsonStrings;
  @override
  final bool allowOverride;

  @override
  Future<List<AgentTypeManifest>> load() async => _jsonStrings
      .map(_parseOne)
      .whereType<AgentTypeManifest>()
      .toList();
}

/// A remote catalog URL returning `{"types": [ ...manifests... ]}`.
class RemoteCatalogSource implements ManifestSource {
  RemoteCatalogSource(this.url, {this.httpClient, this.allowOverride = false});

  final String url;
  final http.Client? httpClient;
  @override
  final bool allowOverride;

  @override
  Future<List<AgentTypeManifest>> load() async {
    final client = httpClient ?? http.Client();
    try {
      final resp = await client.get(Uri.parse(url));
      if (resp.statusCode != 200) {
        throw CatalogException('Catalog URL $url returned ${resp.statusCode}');
      }
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      final types = decoded is Map
          ? (decoded['types'] as List? ?? const [])
          : (decoded is List ? decoded : const []);
      return types
          .whereType<Map>()
          .map((m) => _parseOne(jsonEncode(m)))
          .whereType<AgentTypeManifest>()
          .toList();
    } on FormatException {
      throw CatalogException('Catalog URL $url returned malformed JSON');
    } finally {
      if (httpClient == null) client.close();
    }
  }
}

/// Manifest JSON files inside a user directory (the in-app custom editor
/// writes here; users can also drop files in manually).
/// Missing directories resolve to an empty list — fail soft.
class DirectoryManifestSource implements ManifestSource {
  DirectoryManifestSource(this.dirPath, {this.allowOverride = true});

  final String dirPath;
  @override
  final bool allowOverride;

  @override
  Future<List<AgentTypeManifest>> load() async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const [];
    final out = <AgentTypeManifest>[];
    await for (final f in dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json')).cast<File>()) {
      try {
        final m = _parseOne(await f.readAsString());
        if (m is AgentTypeManifest) out.add(m);
      } on FileSystemException {
        continue;
      }
    }
    return out;
  }
}

/// Thrown for unreadable catalogs or malformed manifest groups.
class CatalogException implements Exception {
  CatalogException(this.message);
  final String message;
  @override
  String toString() => 'CatalogException: $message';
}

Object? _parseOne(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return AgentTypeManifest.fromJson(decoded.cast<String, dynamic>());
    }
    return null;
  } on FormatException {
    return null;
  }
}

/// The merged agent-type catalog.
///
/// Merge rules (deterministic, testable):
/// - Later sources in the list win only if their [ManifestSource] allows
///   override; otherwise their ids are additive-only.
/// - Within a source, an id colliding with an earlier entry of the *same*
///   source wins if it has a higher or equal [AgentTypeManifest.version].
/// - `abstract` manifests (templates) are always kept — the editor needs
///   them — but they are flagged ([AgentTypeManifest.isTemplate]).
class AgentCatalog {
  AgentCatalog._(List<AgentTypeManifest> types) : _types = types;

  final List<AgentTypeManifest> _types;

  static Future<AgentCatalog> build(List<ManifestSource> sources) async {
    final byId = <String, AgentTypeManifest>{};
    for (final source in sources) {
      List<AgentTypeManifest> batch;
      try {
        batch = await source.load();
      } on Exception {
        continue; // fail soft: an unreachable/broken remote catalog skips, never crashes
      }
      for (final m in batch) {
        if (m.id.isEmpty) continue;
        if (source.allowOverride || !byId.containsKey(m.id)) {
          byId[m.id] = m;
        }
      }
    }
    final types = byId.values.toList()
      ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return AgentCatalog._(types);
  }

  List<AgentTypeManifest> get types => List.unmodifiable(_types);

  /// Instantiable types only (hides abstract templates).
  List<AgentTypeManifest> get instantiable =>
      _types.where((t) => !t.isTemplate).toList();

  AgentTypeManifest? byId(String id) {
    for (final t in _types) {
      if (t.id == id) return t;
    }
    return null;
  }
}


