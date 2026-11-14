/// Typed ACP data models, parsed defensively: unknown `sessionUpdate`
/// variants and extra keys degrade to the honest data they are instead of
/// throwing (fail soft, newer agents must still load on older apps).
library;

/// Result of `initialize` — what the agent can do. Drives all dynamic UI.
class AgentCaps {
  const AgentCaps({
    this.protocolVersion = '',
    this.agentName = '',
    this.agentVersion = '',
    this.loadSession = false,
    this.promptCapabilities = const PromptCaps(),
    this.raw = const {},
  });

  final String protocolVersion;
  final String agentName;
  final String agentVersion;

  /// `capabilities.loadSession` — whether `session/load` exists.
  final bool loadSession;

  final PromptCaps promptCapabilities;

  /// Full initialize result, preserved verbatim for forward compatibility.
  final Map<String, dynamic> raw;

  static AgentCaps fromJson(Map<String, dynamic> json) {
    final caps = json['capabilities'] is Map
        ? (json['capabilities'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final prompt = caps['promptCapabilities'] is Map
        ? (caps['promptCapabilities'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final info = json['agentInfo'] is Map
        ? (json['agentInfo'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    return AgentCaps(
      protocolVersion: json['protocolVersion']?.toString() ?? '',
      agentName: (info['name'] as String?) ?? '',
      agentVersion: (info['version'] as String?) ?? '',
      loadSession: caps['loadSession'] == true,
      promptCapabilities: PromptCaps.fromJson(prompt),
      raw: json,
    );
  }
}

class PromptCaps {
  const PromptCaps({
    this.text = true,
    this.image = false,
    this.audio = false,
    this.embeddedContext = false,
  });

  final bool text;
  final bool image;
  final bool audio;
  final bool embeddedContext;

  static PromptCaps fromJson(Map<String, dynamic> json) => PromptCaps(
        text: json['text'] != false,
        image: json['image'] == true,
        audio: json['audio'] == true,
        embeddedContext: json['embeddedContext'] == true,
      );
}

/// A config option advertised by the agent via `session/new` /
/// `initialize` — models, modes, etc. Rendered as dynamic dropdowns.
class SessionConfigOption {
  const SessionConfigOption({
    required this.id,
    required this.name,
    required this.category,
    this.currentValue,
    this.options = const [],
  });

  final String id; // e.g. 'model'
  final String name; // e.g. 'Model'
  final String category; // e.g. 'model', 'mode'
  final String? currentValue;

  /// `[{"value": "...", "name": "..."}]`
  final List<ConfigOptionValue> options;

  static SessionConfigOption fromJson(Map<String, dynamic> json) {
    final rawOptions = json['options'];
    return SessionConfigOption(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? (json['id']?.toString() ?? ''),
      category: (json['category'] as String?) ?? '',
      currentValue: json['currentValue']?.toString(),
      options: rawOptions is List
          ? rawOptions
              .whereType<Map>()
              .map((o) => ConfigOptionValue(
                    value: o['value']?.toString() ?? '',
                    name: (o['name'] as String?) ?? o['value']?.toString() ?? '',
                  ))
              .toList()
          : const [],
    );
  }
}

class ConfigOptionValue {
  const ConfigOptionValue({required this.value, required this.name});
  final String value;
  final String name;
}

/// Prompt content blocks accepted by `session/prompt`.
sealed class ContentBlock {
  Map<String, dynamic> toJson();
}

class TextBlock extends ContentBlock {
  TextBlock(this.text);
  final String text;
  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};
}

class ImageBlock extends ContentBlock {
  ImageBlock({required this.data, required this.mimeType, this.uri});
  final String data; // base64
  final String mimeType;
  final String? uri;
  @override
  Map<String, dynamic> toJson() => {
        'type': 'image',
        'data': data,
        'mimeType': mimeType,
        if (uri != null) 'uri': uri,
      };
}

class AudioBlock extends ContentBlock {
  AudioBlock({required this.data, required this.mimeType});
  final String data;
  final String mimeType;
  @override
  Map<String, dynamic> toJson() => {'type': 'audio', 'data': data, 'mimeType': mimeType};
}

class ResourceLinkBlock extends ContentBlock {
  ResourceLinkBlock({required this.uri, required this.name, this.mimeType});
  final String uri;
  final String name;
  final String? mimeType;
  @override
  Map<String, dynamic> toJson() => {
        'type': 'resource_link',
        'uri': uri,
        'name': name,
        if (mimeType != null) 'mimeType': mimeType,
      };
}

/// One streamed `session/update` — the atoms the chat UI renders.
sealed class SessionUpdate {
  static SessionUpdate fromJson(Map<String, dynamic> json) {
    final kind = (json['sessionUpdate'] as String?) ?? '';
    switch (kind) {
      case 'agent_message_chunk':
        return AgentMessageChunk(_textContent(json['content']));
      case 'agent_thought_chunk':
        return AgentThoughtChunk(_textContent(json['content']));
      case 'tool_call':
        return ToolCall(
          toolCallId: (json['toolCallId'] as String?) ?? '',
          title: (json['title'] as String?) ?? '',
          kind: (json['kind'] as String?) ?? '',
          status: (json['status'] as String?) ?? 'pending',
          rawInput: json['rawInput'],
          rawOutput: json['rawOutput'],
          content: _contentList(json['content']),
        );
      case 'tool_call_update':
        return ToolCallUpdate(
          toolCallId: (json['toolCallId'] as String?) ?? '',
          title: json['title'] as String?,
          status: json['status'] as String?,
          rawOutput: json['rawOutput'],
          content: _contentList(json['content']),
        );
      case 'plan':
        return PlanUpdate(
            (json['entries'] as List? ?? const [])
                .whereType<Map>()
                .map((e) => PlanEntry(
                      content: (e['content'] as String?) ?? '',
                      priority: (e['priority'] as String?) ?? 'medium',
                      status: (e['status'] as String?) ?? 'pending',
                    ))
                .toList());
      case 'available_commands_update':
        return AvailableCommandsUpdate(
          commands: (json['commands'] as List? ?? const [])
              .whereType<Map>()
              .map((c) => SlashCommand(
                    name: (c['name'] as String?) ?? '',
                    description: (c['description'] as String?) ?? '',
                  ))
              .toList(),
        );
      case 'current_mode_update':
        return CurrentModeUpdate(
          (json['currentModeId'] as String?) ?? '',
        );
      case 'user_message_chunk':
        return UserMessageChunk(_textContent(json['content']));
      default:
        return UnknownUpdate(kind, json);
    }
  }

  static String _textContent(Object? content) {
    if (content is Map) {
      return (content['text'] as String?) ?? '';
    }
    if (content is String) return content;
    return '';
  }

  static List<String> _contentList(Object? content) {
    if (content is! List) return const [];
    return content
        .whereType<Map>()
        .map((c) {
          final inner = c['content'];
          if (inner is Map) return (inner['text'] as String?) ?? '';
          if (inner is String) return inner;
          return (c['text'] as String?) ?? '';
        })
        .where((s) => s.isNotEmpty)
        .toList();
  }
}

class AgentMessageChunk extends SessionUpdate {
  AgentMessageChunk(this.text);
  final String text;
}

class AgentThoughtChunk extends SessionUpdate {
  AgentThoughtChunk(this.text);
  final String text;
}

class UserMessageChunk extends SessionUpdate {
  UserMessageChunk(this.text);
  final String text;
}

class ToolCall extends SessionUpdate {
  ToolCall({
    required this.toolCallId,
    required this.title,
    required this.kind,
    required this.status,
    this.rawInput,
    this.rawOutput,
    this.content = const [],
  });

  final String toolCallId;
  final String title;
  final String kind; // read, edit, delete, move, search, execute, think, fetch, other
  final String status; // pending, in_progress, completed, failed
  final Object? rawInput;
  final Object? rawOutput;
  final List<String> content;
}

class ToolCallUpdate extends SessionUpdate {
  ToolCallUpdate({
    required this.toolCallId,
    this.title,
    this.status,
    this.rawOutput,
    this.content = const [],
  });

  final String toolCallId;
  final String? title;
  final String? status;
  final Object? rawOutput;
  final List<String> content;
}

class PlanEntry {
  const PlanEntry({
    required this.content,
    required this.priority,
    required this.status,
  });
  final String content;
  final String priority; // high, medium, low
  final String status; // pending, in_progress, completed
}

class PlanUpdate extends SessionUpdate {
  PlanUpdate(this.entries);
  final List<PlanEntry> entries;
}

class SlashCommand {
  const SlashCommand({required this.name, required this.description});
  final String name;
  final String description;
}

class AvailableCommandsUpdate extends SessionUpdate {
  AvailableCommandsUpdate({required this.commands});
  final List<SlashCommand> commands;
}

class CurrentModeUpdate extends SessionUpdate {
  CurrentModeUpdate(this.currentModeId);
  final String currentModeId;
}

class UnknownUpdate extends SessionUpdate {
  UnknownUpdate(this.kind, this.raw);
  final String kind;
  final Map<String, dynamic> raw;
}

/// A permission decision the agent asks for (e.g. "allow rm -rf ?").
class AcpPermissionRequest {
  const AcpPermissionRequest({
    required this.requestId,
    required this.sessionId,
    required this.toolCallId,
    this.title = '',
    this.kind = '',
    this.options = const [],
    this.raw = const {},
  });

  final Object requestId;
  final String sessionId;
  final String toolCallId;
  final String title;
  final String kind;

  /// `[{"optionId": "allow_once", "name": "Allow once", "kind": "allow_once"}]`
  final List<PermissionOption> options;
  final Map<String, dynamic> raw;

  static AcpPermissionRequest fromRequest(Object id, Map<String, dynamic> params) {
    final options = (params['options'] as List? ?? const [])
        .whereType<Map>()
        .map((o) => PermissionOption(
              optionId: o['optionId']?.toString() ?? '',
              name: (o['name'] as String?) ?? '',
              kind: (o['kind'] as String?) ?? '',
            ))
        .toList();
    return AcpPermissionRequest(
      requestId: id,
      sessionId: (params['sessionId'] as String?) ?? '',
      toolCallId: (params['toolCallId'] as String?) ?? '',
      title: (params['title'] as String?) ?? '',
      kind: (params['kind'] as String?) ?? '',
      options: options,
      raw: params,
    );
  }
}

class PermissionOption {
  const PermissionOption({
    required this.optionId,
    required this.name,
    required this.kind,
  });
  final String optionId;
  final String name;
  final String kind; // allow_once, allow_always, reject_once, reject_always
}

/// Outcome the app's permission UI produces.
class PermissionOutcome {
  const PermissionOutcome.allow(this.optionId) : denied = false;
  const PermissionOutcome.deny() : optionId = null, denied = true;

  final String? optionId;
  final bool denied;

  Map<String, dynamic> toJson() =>
      denied ? {'outcome': 'rejected'} : {'outcome': 'selected', 'optionId': optionId};
}

/// A file-edit/content update surfaced in chat (the UI shows diffs).
class FileEditInfo {
  const FileEditInfo({required this.path, required this.content});
  final String path;
  final String content;
}
