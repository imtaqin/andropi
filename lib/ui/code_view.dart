import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';
import 'package:highlight/highlight.dart' show highlight, Node;

import 'theme.dart';

/// Token colors for highlight.js class names, tuned to sit on [Palette.surface].
Map<String, Color> _syntax(Brightness b) => b == Brightness.dark
    ? const {
        'keyword': Color(0xFFFF7B72),
        'built_in': Color(0xFFFFA657),
        'type': Color(0xFFFFA657),
        'literal': Color(0xFF79C0FF),
        'number': Color(0xFF79C0FF),
        'string': Color(0xFFA5D6FF),
        'regexp': Color(0xFFA5D6FF),
        'comment': Color(0xFF8B949E),
        'doctag': Color(0xFF8B949E),
        'meta': Color(0xFF8B949E),
        'title': Color(0xFFD2A8FF),
        'function': Color(0xFFD2A8FF),
        'class': Color(0xFFFFA657),
        'params': Color(0xFFE6EDF3),
        'attr': Color(0xFF79C0FF),
        'attribute': Color(0xFF79C0FF),
        'variable': Color(0xFFFFA657),
        'symbol': Color(0xFF79C0FF),
        'tag': Color(0xFF7EE787),
        'name': Color(0xFF7EE787),
        'selector-tag': Color(0xFF7EE787),
        'selector-class': Color(0xFFD2A8FF),
        'addition': Color(0xFF7EE787),
        'deletion': Color(0xFFFFA198),
        'section': Color(0xFF79C0FF),
        'bullet': Color(0xFFFFA657),
        'subst': Color(0xFFE6EDF3),
      }
    : const {
        'keyword': Color(0xFFCF222E),
        'built_in': Color(0xFF953800),
        'type': Color(0xFF953800),
        'literal': Color(0xFF0550AE),
        'number': Color(0xFF0550AE),
        'string': Color(0xFF0A3069),
        'regexp': Color(0xFF0A3069),
        'comment': Color(0xFF6E7781),
        'doctag': Color(0xFF6E7781),
        'meta': Color(0xFF6E7781),
        'title': Color(0xFF8250DF),
        'function': Color(0xFF8250DF),
        'class': Color(0xFF953800),
        'params': Color(0xFF1F2328),
        'attr': Color(0xFF0550AE),
        'attribute': Color(0xFF0550AE),
        'variable': Color(0xFF953800),
        'symbol': Color(0xFF0550AE),
        'tag': Color(0xFF116329),
        'name': Color(0xFF116329),
        'selector-tag': Color(0xFF116329),
        'selector-class': Color(0xFF8250DF),
        'addition': Color(0xFF116329),
        'deletion': Color(0xFF82071E),
        'section': Color(0xFF0550AE),
        'bullet': Color(0xFF953800),
        'subst': Color(0xFF1F2328),
      };

const _aliases = {
  'sh': 'bash',
  'shell': 'bash',
  'zsh': 'bash',
  'console': 'bash',
  'ts': 'typescript',
  'tsx': 'typescript',
  'js': 'javascript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'py': 'python',
  'kt': 'kotlin',
  'rs': 'rust',
  'yml': 'yaml',
  'html': 'xml',
  'md': 'markdown',
  'c++': 'cpp',
  'cs': 'csharp',
};

List<TextSpan> highlightSpans(String code, String? language, Brightness brightness) {
  final lang = language?.toLowerCase().trim();
  if (lang == null || lang.isEmpty || lang == 'text' || lang == 'plaintext') return [TextSpan(text: code)];
  try {
    final nodes = highlight.parse(code, language: _aliases[lang] ?? lang).nodes;
    if (nodes == null) return [TextSpan(text: code)];
    final colors = _syntax(brightness);
    return _spans(nodes, colors, null);
  } catch (_) {
    return [TextSpan(text: code)];
  }
}

List<TextSpan> _spans(List<Node> nodes, Map<String, Color> colors, Color? inherited) {
  final out = <TextSpan>[];
  for (final n in nodes) {
    final color = colors[n.className] ?? inherited;
    final italic = n.className == 'comment';
    final style = color == null ? null : TextStyle(color: color, fontStyle: italic ? FontStyle.italic : null);
    if (n.value != null) {
      out.add(TextSpan(text: n.value, style: style));
    } else if (n.children != null) {
      out.add(TextSpan(style: style, children: _spans(n.children!, colors, color)));
    }
  }
  return out;
}

/// Bordered code panel: language label, copy button, line numbers, highlighting.
class CodeBox extends StatelessWidget {
  const CodeBox({
    super.key,
    required this.text,
    this.label,
    this.language,
    this.maxHeight,
    this.lineNumbers = true,
    this.followTail = false,
    this.onPreview,
  });
  final String text;
  final String? label;
  final String? language;
  final double? maxHeight;
  final bool lineNumbers;

  /// Keep the newest lines in view while the text is still being written.
  final bool followTail;
  final VoidCallback? onPreview;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final brightness = Theme.of(context).brightness;
    final style = TextStyle(fontFamily: mono, fontSize: 12.5, height: 1.6, color: p.text);
    final lines = '\n'.allMatches(text).length + 1;
    final showNumbers = lineNumbers && lines > 1;

    Widget code = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.fromLTRB(showNumbers ? 12 : 14, 12, 14, 14),
      child: SelectableText.rich(TextSpan(style: style, children: highlightSpans(text, language ?? label, brightness))),
    );
    Widget body = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showNumbers)
          Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 10, 14),
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: p.border)),
            ),
            child: Text(
              List.generate(lines, (i) => '${i + 1}').join('\n'),
              textAlign: TextAlign.right,
              style: style.copyWith(color: p.faint),
            ),
          ),
        Expanded(child: code),
      ],
    );
    if (maxHeight != null) {
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight!),
        child: SingleChildScrollView(reverse: followTail, child: body),
      );
    }
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 36,
            decoration: BoxDecoration(
              color: p.raised.withValues(alpha: 0.5),
              border: Border(bottom: BorderSide(color: p.border)),
            ),
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(LucideIcons.code, size: 14, color: p.faint),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    (label == null || label!.isEmpty) ? 'code' : label!,
                    style: TextStyle(fontFamily: mono, fontSize: 11.5, color: p.muted),
                  ),
                ),
                if (onPreview != null) _HeaderAction(icon: LucideIcons.play, label: 'Preview', onTap: onPreview!),
                CopyButton(text: text),
                const SizedBox(width: 4),
              ],
            ),
          ),
          body,
        ],
      ),
    );
  }
}

/// Copy action that confirms in place instead of with a snackbar.
class CopyButton extends StatefulWidget {
  const CopyButton({super.key, required this.text, this.showLabel = true});
  final String text;
  final bool showLabel;

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  bool copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    HapticFeedback.selectionClick();
    if (!mounted) return;
    setState(() => copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = copied ? p.success : p.muted;
    return InkWell(
      onTap: _copy,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: Icon(copied ? LucideIcons.check : LucideIcons.copy, key: ValueKey(copied), size: 14, color: color),
            ),
            if (widget.showLabel) ...[
              const SizedBox(width: 5),
              Text(copied ? 'Copied' : 'Copy', style: TextStyle(fontSize: 11.5, color: color)),
            ],
          ],
        ),
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: p.text),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: p.text),
            ),
          ],
        ),
      ),
    );
  }
}
