import 'dart:convert';

class ModelInfo {
  ModelInfo(this.json);
  final Map<String, dynamic> json;

  String get provider => json['provider'] as String;
  String get id => json['id'] as String;
  String get name => json['name'] as String? ?? id;
  bool get reasoning => json['reasoning'] == true;
  int? get contextWindow => json['contextWindow'] as int?;
  bool get acceptsImages => (json['input'] as List?)?.contains('image') ?? false;
  String get key => '$provider/$id';
}

class ProviderInfo {
  ProviderInfo(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get name => json['name'] as String? ?? id;
  bool get configured => json['configured'] == true;
  bool get oauth => json['oauth'] == true;
  List<String> get methods => (json['methods'] as List? ?? const []).cast<String>();
  int get modelCount => json['models'] as int? ?? 0;
}

class SessionSummary {
  SessionSummary(this.json);
  final Map<String, dynamic> json;

  String get path => json['path'] as String;
  String get id => json['id'] as String;
  String? get name => json['name'] as String?;
  String get cwd => json['cwd'] as String? ?? '';
  String get firstMessage => json['firstMessage'] as String? ?? '';
  int get messageCount => json['messageCount'] as int? ?? 0;
  DateTime get modified => DateTime.fromMillisecondsSinceEpoch(json['modified'] as int);

  String get title {
    final n = name?.trim();
    if (n != null && n.isNotEmpty) return n;
    final first = firstMessage.trim().split('\n').first;
    return first.isEmpty ? 'Untitled session' : first;
  }
}

// ---------------------------------------------------------------------------
// Transcript

sealed class ChatEntry {}

class UserEntry extends ChatEntry {
  UserEntry(this.text, {this.images = 0});
  final String text;
  final int images;
}

enum BlockKind { text, thinking, toolCall }

class Block {
  Block(this.kind);
  final BlockKind kind;
  final StringBuffer buffer = StringBuffer();
  String? toolCallId;
  String? toolName;
  Map<String, dynamic>? args;

  String get text => buffer.toString();

  /// Arguments so far: final ones once known, else string fields read from
  /// the streamed JSON (for tool calls the buffer holds raw argument JSON).
  Map<String, dynamic>? get liveArgs => args ?? (buffer.isEmpty ? null : partialJsonStrings(text));

  set text(String value) {
    buffer
      ..clear()
      ..write(value);
  }
}

class AssistantEntry extends ChatEntry {
  final blocks = <int, Block>{};
  bool streaming = true;
  String? error;
  bool aborted = false;
  String? model;

  List<Block> get orderedBlocks {
    final keys = blocks.keys.toList()..sort();
    return [for (final k in keys) blocks[k]!];
  }

  Block block(int index, BlockKind kind) => blocks.putIfAbsent(index, () => Block(kind));

  /// Replaces streamed state with the authoritative final message.
  void applyMessage(Map<String, dynamic> message) {
    blocks.clear();
    final content = message['content'] as List? ?? const [];
    for (var i = 0; i < content.length; i++) {
      final c = content[i] as Map<String, dynamic>;
      switch (c['type']) {
        case 'text':
          block(i, BlockKind.text).text = c['text'] as String? ?? '';
        case 'thinking':
          block(i, BlockKind.thinking).text = c['thinking'] as String? ?? '';
        case 'toolCall':
          block(i, BlockKind.toolCall)
            ..toolCallId = c['id'] as String?
            ..toolName = c['name'] as String?
            ..args = (c['arguments'] as Map?)?.cast<String, dynamic>();
      }
    }
    streaming = false;
    model = message['model'] as String?;
    final stop = message['stopReason'];
    aborted = stop == 'aborted';
    if (stop == 'error') error = readableError(message['errorMessage'] as String? ?? 'The model returned an error.');
  }
}

/// Turns a provider's `400 {"error":{"message":...}}` into `message (400)`.
String readableError(String raw) {
  final match = RegExp(r'^(\d{3})\s+(\{.*\})$', dotAll: true).firstMatch(raw.trim());
  if (match == null) return raw;
  try {
    final body = jsonDecode(match.group(2)!);
    final error = body is Map ? body['error'] : null;
    final message = error is Map ? error['message'] : (body is Map ? body['message'] : null);
    if (message is String && message.isNotEmpty) return '$message (${match.group(1)})';
  } on FormatException {
    // Not JSON after all; show it as is.
  }
  return raw;
}

class NoticeEntry extends ChatEntry {
  NoticeEntry(this.text, {this.error = false});
  final String text;
  final bool error;
}

enum ToolStatus { running, done, failed }

class ToolRun {
  ToolRun(this.id);
  final String id;
  ToolStatus status = ToolStatus.running;
  String output = '';
}

String contentText(dynamic content) {
  if (content is String) return content;
  if (content is List) {
    return content.whereType<Map>().where((c) => c['type'] == 'text').map((c) => c['text'] as String? ?? '').join('\n');
  }
  return '';
}

int contentImages(dynamic content) =>
    content is List ? content.whereType<Map>().where((c) => c['type'] == 'image').length : 0;

/// One-line summary of a tool call for collapsed display.
String toolSummary(String? name, Map<String, dynamic>? args) {
  if (args == null) return '';
  String? pick(List<String> keys) {
    for (final k in keys) {
      final v = args[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  final value = switch (name) {
    'bash' => pick(['command'])?.replaceAllMapped(
      RegExp(r'''(?:/data/(?:data|user/\d+)/com\.imtaqin\.andropi|/storage/emulated/\d+|/sdcard)(?:/[^\s'"/;|&>]+)+'''),
      (m) => _shortPath(m[0]) ?? m[0]!,
    ),
    'read' || 'write' || 'edit' || 'ls' => _shortPath(pick(['path', 'file_path'])),
    'grep' => pick(['pattern']),
    'find' => pick(['pattern', 'path']),
    _ => null,
  };
  return (value ?? jsonEncode(args)).split('\n').first;
}

/// Full paths on the phone are long and say little; the file name is what matters. Generic names
/// (SKILL.md, index.html, …) keep their folder so it's clear which one, e.g. `ui-designer/SKILL.md`.
String? _shortPath(String? path) {
  if (path == null) return null;
  final parts = path.split('/').where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return path;
  final base = parts.last;
  const generic = {'skill.md', 'readme.md', 'agents.md', 'package.json', 'main.py', 'main.dart'};
  final stem = base.contains('.') ? base.substring(0, base.lastIndexOf('.')).toLowerCase() : base.toLowerCase();
  if (parts.length > 1 && (generic.contains(base.toLowerCase()) || stem == 'index')) {
    return '${parts[parts.length - 2]}/$base';
  }
  return base;
}

/// Reads top-level-looking `"key": "string"` pairs from possibly truncated
/// JSON. The last value may be cut off; it is returned as far as it goes.
/// Repeated keys keep the latest value (e.g. the edit being written now).
Map<String, dynamic> partialJsonStrings(String raw) {
  final out = <String, dynamic>{};
  final key = RegExp(r'"([A-Za-z_][A-Za-z0-9_]*)"\s*:\s*"');
  var pos = 0;
  while (true) {
    final m = key.firstMatch(raw.substring(pos));
    if (m == null) break;
    var i = pos + m.end;
    final value = StringBuffer();
    while (i < raw.length) {
      final c = raw[i];
      if (c == '"') break;
      if (c != r'\') {
        value.write(c);
        i++;
        continue;
      }
      if (i + 1 >= raw.length) {
        i = raw.length;
        break;
      }
      final e = raw[i + 1];
      switch (e) {
        case 'n':
          value.write('\n');
        case 't':
          value.write('\t');
        case 'r':
          value.write('\r');
        case 'b':
          value.write('\b');
        case 'f':
          value.write('\f');
        case 'u':
          if (i + 6 > raw.length) {
            i = raw.length;
            continue;
          }
          final code = int.tryParse(raw.substring(i + 2, i + 6), radix: 16);
          if (code != null) value.writeCharCode(code);
          i += 6;
          continue;
        default:
          value.write(e);
      }
      i += 2;
    }
    out[m.group(1)!] = value.toString();
    pos = i < raw.length ? i + 1 : raw.length;
    if (pos >= raw.length) break;
  }
  return out;
}
