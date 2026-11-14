import 'package:flutter/services.dart';

import 'package:ylpa_acp_core/ylpa_acp_core.dart';

/// Loads the agent-type catalog bundled with the app
/// (`assets/agent_types/*.json`, declared in pubspec) plus any extra
/// sources the caller wants to merge on top (user directory, remote
/// catalog — later phases).
///
/// Discovery uses the AssetManifest, so dropping a new manifest JSON into
/// `assets/agent_types/` and listing the folder in pubspec is enough —
/// no Dart changes.
class AcpCatalogLoader {
  static const _prefix = 'assets/agent_types/';
  static const _suffix = '.json';

  static Future<AgentCatalog> load({
    List<ManifestSource> extraSources = const [],
  }) async {
    final assetManifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = assetManifest.listAssets();
    final keys =
        assets.where((k) => k.startsWith(_prefix) && k.endsWith(_suffix)).toList()
          ..sort();
    final strings = <String>[];
    for (final key in keys) {
      try {
        strings.add(await rootBundle.loadString(key));
      } on Exception {
        continue; // fail soft: a broken manifest skips, never crashes
      }
    }
    return AgentCatalog.build([
      InlineManifestSource(strings, allowOverride: true),
      ...extraSources,
    ]);
  }
}
