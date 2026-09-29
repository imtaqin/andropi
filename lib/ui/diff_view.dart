import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'kit.dart';
import 'theme.dart';

/// Splits a unified diff (possibly covering several files) into one patch per file.
List<({String path, String patch})> splitPatch(String patch) {
  final lines = patch.split('\n');
  final out = <({String path, String patch})>[];
  var current = <String>[];

  void flush() {
    while (current.isNotEmpty && current.last.isEmpty) {
      current.removeLast();
    }
    if (current.isEmpty) return;
    out.add((path: _pathOf(current), patch: current.join('\n')));
    current = <String>[];
  }

  final gitStyle = lines.any((l) => l.startsWith('diff --git '));
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    final starts = gitStyle
        ? l.startsWith('diff --git ')
        : l.startsWith('--- ') && i + 1 < lines.length && lines[i + 1].startsWith('+++ ');
    if (starts) flush();
    current.add(l);
  }
  flush();
  return out;
}

String _pathOf(List<String> lines) {
  String strip(String p) {
    p = p.trim();
    final tab = p.indexOf('\t');
    if (tab >= 0) p = p.substring(0, tab);
    if (p.startsWith('"') && p.endsWith('"') && p.length > 1) p = p.substring(1, p.length - 1);
    if (p.startsWith('a/') || p.startsWith('b/')) p = p.substring(2);
    return p;
  }

  String? minus;
  for (final l in lines) {
    if (l.startsWith('@@')) break;
    if (l.startsWith('+++ ')) {
      final p = l.substring(4);
      if (p.trim() != '/dev/null') return strip(p);
    }
    if (l.startsWith('--- ')) minus = l.substring(4);
    if (l.startsWith('rename to ')) return l.substring(10).trim();
  }
  if (minus != null && minus.trim() != '/dev/null') return strip(minus);
  final head = lines.first;
  if (head.startsWith('diff --git ')) {
    final rest = head.substring(11);
    final b = rest.lastIndexOf(' b/');
    if (b >= 0) return rest.substring(b + 3);
    return strip(rest.split(' ').first);
  }
  final bin = lines.firstWhere((l) => l.startsWith('Binary files '), orElse: () => '');
  if (bin.isNotEmpty) {
    final m = RegExp(r'Binary files (.+) and (.+) differ').firstMatch(bin);
    if (m != null) {
      final b = m.group(2)!.trim();
      return strip(b == '/dev/null' ? m.group(1)! : b);
    }
  }
  return '';
}

enum _Kind { add, del, ctx, hunk, note }

class _Line {
  const _Line(this.kind, this.text, {this.oldNo, this.newNo});
  final _Kind kind;
  final String text;
  final int? oldNo;
  final int? newNo;
}

class _ParsedFile {
  _ParsedFile(this.path);
  final String path;
  final lines = <_Line>[];
  int adds = 0;
  int dels = 0;
  bool binary = false;
  String? note;
}

final _hunkRe = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');

_ParsedFile _parse(String path, String patch) {
  final f = _ParsedFile(path);
  var inHunk = false;
  var oldNo = 0;
  var newNo = 0;
  for (final raw in patch.split('\n')) {
    final l = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    final m = _hunkRe.firstMatch(l);
    if (m != null) {
      inHunk = true;
      oldNo = int.parse(m.group(1)!);
      newNo = int.parse(m.group(2)!);
      f.lines.add(_Line(_Kind.hunk, l));
      continue;
    }
    if (!inHunk) {
      if (l.startsWith('Binary files ') || l.startsWith('GIT binary patch')) f.binary = true;
      if (l.startsWith('new file mode')) f.note ??= 'New file';
      if (l.startsWith('deleted file mode')) f.note ??= 'Deleted file';
      if (l.startsWith('rename from ')) f.note = 'Renamed from ${l.substring(12)}';
      continue;
    }
    if (l.startsWith('+')) {
      f.adds++;
      f.lines.add(_Line(_Kind.add, l.substring(1), newNo: newNo++));
    } else if (l.startsWith('-')) {
      f.dels++;
      f.lines.add(_Line(_Kind.del, l.substring(1), oldNo: oldNo++));
    } else if (l.startsWith('\\')) {
      f.lines.add(_Line(_Kind.note, l));
    } else if (l.isEmpty) {
      // A trailing blank from the split, or an empty context line.
      f.lines.add(_Line(_Kind.ctx, '', oldNo: oldNo++, newNo: newNo++));
    } else {
      f.lines.add(_Line(_Kind.ctx, l.substring(1), oldNo: oldNo++, newNo: newNo++));
    }
  }
  while (f.lines.isNotEmpty && f.lines.last.kind == _Kind.ctx && f.lines.last.text.isEmpty) {
    f.lines.removeLast();
  }
  return f;
}

/// Renders a unified diff with per-file headers, line numbers and tinted
/// added/removed lines; long lines scroll sideways rather than wrap.
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.patch, this.maxHeight, this.showHeaders = true});
  final String patch;
  final double? maxHeight;

  /// Hide the per-file header when the caller already shows the path.
  final bool showHeaders;

  static const _maxLines = 4000;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (patch.trim().isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
        decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(16)),
        alignment: Alignment.center,
        child: Text('No changes', style: Theme.of(context).textTheme.bodySmall),
      );
    }
    final files = [for (final f in splitPatch(patch)) _parse(f.path, f.patch)];
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < files.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          _FileDiff(file: files[i], showHeader: showHeaders, maxLines: _maxLines),
        ],
      ],
    );
    if (maxHeight == null) return body;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight!),
      child: SingleChildScrollView(child: body),
    );
  }
}

class _FileDiff extends StatelessWidget {
  const _FileDiff({required this.file, required this.showHeader, required this.maxLines});
  final _ParsedFile file;
  final bool showHeader;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final lines = file.lines.length > maxLines ? file.lines.sublist(0, maxLines) : file.lines;
    final oldMax = file.lines.fold<int>(0, (m, l) => (l.oldNo ?? 0) > m ? l.oldNo! : m);
    final newMax = file.lines.fold<int>(0, (m, l) => (l.newNo ?? 0) > m ? l.newNo! : m);
    final digits = [oldMax, newMax, 99].reduce((a, b) => a > b ? a : b).toString().length;
    final gutter = digits * 7.5 + 8;

    Widget message(String s) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      child: Text(s, style: text.bodySmall),
    );

    return Container(
      decoration: BoxDecoration(
        color: p.raised,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showHeader)
            Container(
              color: p.surface,
              padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
              child: Row(
                children: [
                  Icon(file.binary ? LucideIcons.file : LucideIcons.fileCode, size: 15, color: p.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      file.path.isEmpty ? '(unknown file)' : file.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: mono, fontSize: 12.5, color: p.text, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DiffStat(additions: file.adds, deletions: file.dels),
                ],
              ),
            ),
          if (file.note != null && !file.binary)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text(file.note!, style: text.bodySmall),
            ),
          if (file.binary)
            message('Binary file changed')
          else if (lines.isEmpty)
            message(file.note ?? 'No content changes')
          else
            LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: box.maxWidth),
                  child: IntrinsicWidth(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [for (final l in lines) _row(context, l, gutter)],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (file.lines.length > maxLines) message('${file.lines.length - maxLines} more lines not shown'),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, _Line l, double gutter) {
    final p = context.palette;
    final base = TextStyle(fontFamily: mono, fontSize: 12, height: 1.5, color: p.text);
    final num = base.copyWith(color: p.faint, fontSize: 11);
    final (Color? bg, String sign, Color signColor) = switch (l.kind) {
      _Kind.add => (p.success.withValues(alpha: 0.12), '+', p.success),
      _Kind.del => (p.danger.withValues(alpha: 0.12), '-', p.danger),
      _Kind.hunk => (p.accentAlt.withValues(alpha: 0.07), '', p.muted),
      _ => (null, ' ', p.faint),
    };
    if (l.kind == _Kind.hunk || l.kind == _Kind.note) {
      return Container(
        color: bg,
        padding: EdgeInsets.fromLTRB(12, l.kind == _Kind.hunk ? 3 : 0, 12, l.kind == _Kind.hunk ? 3 : 0),
        child: Text(
          l.text,
          softWrap: false,
          style: base.copyWith(color: p.muted, fontStyle: l.kind == _Kind.note ? FontStyle.italic : null),
        ),
      );
    }
    return Container(
      color: bg,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: gutter,
            child: Text('${l.oldNo ?? ''}', textAlign: TextAlign.right, style: num.copyWith(height: 1.64)),
          ),
          SizedBox(
            width: gutter,
            child: Text('${l.newNo ?? ''}', textAlign: TextAlign.right, style: num.copyWith(height: 1.64)),
          ),
          SizedBox(
            width: 20,
            child: Text(
              sign,
              textAlign: TextAlign.center,
              style: base.copyWith(color: signColor),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Text(l.text.replaceAll('\t', '    '), softWrap: false, style: base),
          ),
        ],
      ),
    );
  }
}

/// Compact "+N −M" pair used in file lists and diff headers.
class DiffStat extends StatelessWidget {
  const DiffStat({super.key, required this.additions, required this.deletions, this.binary = false});
  final int additions;
  final int deletions;
  final bool binary;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (binary) return Pill('binary', color: p.muted);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Pill('+$additions', color: p.success),
        const SizedBox(width: 4),
        Pill('-$deletions', color: p.danger),
      ],
    );
  }
}
