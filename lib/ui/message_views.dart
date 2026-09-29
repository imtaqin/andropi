import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../agent/models.dart';
import 'code_view.dart';
import 'preview_screen.dart';
import 'kit.dart';
import 'theme.dart';

class UserMessageView extends StatelessWidget {
  const UserMessageView(this.entry, {super.key, this.onLongPress});
  final UserEntry entry;

  /// Edit / fork / copy menu, supplied by the chat.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: p.raised,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
                bottomLeft: Radius.circular(20),
                bottomRight: Radius.circular(6),
              ),
              border: Border.all(color: p.accent.withValues(alpha: 0.18)),
            ),
            // Plain text so the long-press menu wins over text selection.
            child: Text(entry.text, style: Theme.of(context).textTheme.bodyLarge),
          ),
        ),
      ),
    );
  }
}

class AssistantMessageView extends StatelessWidget {
  const AssistantMessageView(this.entry, {super.key, required this.tools, this.cwd, this.live});
  final AssistantEntry entry;
  final Map<String, ToolRun> tools;

  /// Where relative tool paths resolve, for previews.
  final String? cwd;

  /// Fires as the agent streams; live previews re-render on it.
  final Listenable? live;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final blocks = entry.orderedBlocks;
    final children = <Widget>[];
    for (final b in blocks) {
      switch (b.kind) {
        case BlockKind.text:
          if (b.text.trim().isNotEmpty) {
            children.add(TypewriterMarkdown(text: b.text, live: entry.streaming && identical(b, blocks.last)));
          }
        case BlockKind.thinking:
          if (b.text.trim().isNotEmpty) {
            children.add(ThinkingView(text: b.text, live: entry.streaming && identical(b, blocks.last)));
          }
        case BlockKind.toolCall:
          children.add(ToolCallView(block: b, run: tools[b.toolCallId], cwd: cwd, live: live));
      }
    }
    if (entry.streaming && children.isEmpty) children.add(const _Pending());
    if (entry.error != null) children.add(_ErrorNote(entry.error!));
    if (entry.aborted) {
      children.add(Text('Stopped', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: p.faint)));
    }
    final reply = [
      for (final b in blocks)
        if (b.kind == BlockKind.text && b.text.trim().isNotEmpty) b.text.trim(),
    ].join('\n\n');
    if (!entry.streaming && reply.isNotEmpty) children.add(_MessageFooter(text: reply, model: entry.model));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: 10), children[i]],
      ],
    );
  }
}

/// Bubbles up when a message grows on its own, so the transcript can keep
/// following the bottom between agent updates.
class TranscriptGrew extends Notification {
  const TranscriptGrew();
}

/// Reveals streamed text at a steady pace so bursty providers still read as
/// typing. The pace scales with the backlog, so it never falls far behind.
class TypewriterMarkdown extends StatefulWidget {
  const TypewriterMarkdown({super.key, required this.text, required this.live});
  final String text;
  final bool live;

  @override
  State<TypewriterMarkdown> createState() => _TypewriterMarkdownState();
}

class _TypewriterMarkdownState extends State<TypewriterMarkdown> with SingleTickerProviderStateMixin {
  late final _ticker = createTicker(_tick);
  late int _shown = widget.live ? 0 : widget.text.length;
  Duration _last = Duration.zero;
  double _carry = 0;

  bool get _behind => _shown < widget.text.length;

  @override
  void initState() {
    super.initState();
    if (_behind) _ticker.start();
  }

  @override
  void didUpdateWidget(TypewriterMarkdown old) {
    super.didUpdateWidget(old);
    if (_shown > widget.text.length) _shown = widget.text.length;
    if (_behind && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final backlog = widget.text.length - _shown;
    if (backlog <= 0) {
      _ticker.stop();
      return;
    }
    // ~160 chars/s baseline, draining any backlog within about a quarter second;
    // faster once the stream has ended.
    final rate = (widget.live ? 160.0 : 500.0) + backlog * (widget.live ? 4.0 : 8.0);
    _carry += rate * dt;
    final step = _carry.floor();
    if (step == 0) return;
    _carry -= step;
    setState(() => _shown = (_shown + step).clamp(0, widget.text.length));
    const TranscriptGrew().dispatch(context);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final typing = widget.live || _behind;
    // U+258D left block as the caret; markdown renders it inline with the text.
    final visible = widget.text.substring(0, _shown);
    return MarkdownText(typing ? '$visible▍' : widget.text);
  }
}

class _MessageFooter extends StatelessWidget {
  const _MessageFooter({required this.text, this.model});
  final String text;
  final String? model;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: [
        Transform.translate(
          offset: const Offset(-8, 0),
          child: CopyButton(text: text, showLabel: false),
        ),
        if (model != null)
          Expanded(
            child: Text(
              model!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: mono, fontSize: 11, color: p.faint),
            ),
          ),
      ],
    );
  }
}

class MarkdownText extends StatelessWidget {
  const MarkdownText(this.data, {super.key});
  final String data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.palette;
    final body = theme.textTheme.bodyLarge!;
    final code = TextStyle(fontFamily: mono, fontSize: 13, height: 1.5, color: p.text);
    return MarkdownBody(
      data: data,
      selectable: true,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      builders: {'pre': _CodeBlockBuilder(context)},
      onTapLink: (text, href, title) {
        if (href != null) Clipboard.setData(ClipboardData(text: href));
      },
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: body,
        a: body.copyWith(decoration: TextDecoration.underline, decorationColor: p.faint),
        h1: theme.textTheme.headlineSmall,
        h2: theme.textTheme.titleLarge,
        h3: theme.textTheme.titleMedium,
        h4: theme.textTheme.titleSmall,
        strong: body.copyWith(fontWeight: FontWeight.w600),
        listBullet: body.copyWith(color: p.muted),
        code: code.copyWith(backgroundColor: p.raised, fontSize: 13.5),
        blockquote: body.copyWith(color: p.muted),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: p.border, width: 3)),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12),
        tableHead: body.copyWith(fontWeight: FontWeight.w600),
        tableBody: body,
        tableBorder: TableBorder.all(color: p.border),
        tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: p.border)),
        ),
        blockSpacing: 10,
        listIndent: 20,
      ),
    );
  }
}

/// Fenced code: bordered, horizontally scrollable, with language and copy.
class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder(this.context);
  final BuildContext context;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final codeEl = element.children?.whereType<md.Element>().firstOrNull;
    final text = (codeEl?.textContent ?? element.textContent).replaceFirst(RegExp(r'\n$'), '');
    final lang = (codeEl?.attributes['class'] ?? '').replaceFirst('language-', '');
    final previewable = const {'html', 'htm', 'svg'}.contains(lang.toLowerCase());
    // Markdown rebuilds this subtree while streaming; the navigator outlives it.
    final navigator = Navigator.of(context);
    return CodeBox(
      text: text,
      label: lang.isEmpty ? null : lang,
      language: lang,
      onPreview: previewable
          ? () => HtmlPreviewScreen.open(navigator.context, title: 'Preview', source: () => text)
          : null,
    );
  }
}

class ThinkingView extends StatefulWidget {
  const ThinkingView({super.key, required this.text, required this.live});
  final String text;
  final bool live;

  @override
  State<ThinkingView> createState() => _ThinkingViewState();
}

class _ThinkingViewState extends State<ThinkingView> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final label = Theme.of(context).textTheme.labelMedium;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => open = !open),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.live ? 'Thinking' : 'Thought process', style: label),
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: open ? 0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(LucideIcons.chevronRight, size: 16, color: p.muted),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topLeft,
          child: open
              ? Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.only(left: 12),
                  decoration: BoxDecoration(
                    border: Border(left: BorderSide(color: p.border, width: 2)),
                  ),
                  child: SelectableText(
                    widget.text.trim(),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: p.muted),
                  ),
                )
              : widget.live
              // While the model thinks, show the newest lines as they stream.
              ? Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.only(left: 12),
                  constraints: const BoxConstraints(maxHeight: 96),
                  decoration: BoxDecoration(
                    border: Border(left: BorderSide(color: p.border, width: 2)),
                  ),
                  child: SingleChildScrollView(
                    reverse: true,
                    physics: const NeverScrollableScrollPhysics(),
                    child: Text(
                      widget.text.trim(),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.faint),
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

class ToolCallView extends StatefulWidget {
  const ToolCallView({super.key, required this.block, required this.run, this.cwd, this.live});
  final Block block;
  final ToolRun? run;
  final String? cwd;
  final Listenable? live;

  @override
  State<ToolCallView> createState() => _ToolCallViewState();
}

class _ToolCallViewState extends State<ToolCallView> {
  bool open = false;

  /// Set once this card has streamed live content; it then stays visible
  /// after the call lands instead of folding away (which made the transcript
  /// jump). Cards restored from history start folded.
  bool sawLive = false;

  String? _absolute(String? path) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('/') || (widget.cwd ?? '').isEmpty) return path;
    return '${widget.cwd}/$path';
  }

  /// The page as it stands: the file on disk once written, else the content
  /// streamed so far.
  String _htmlSource() {
    final args = widget.block.liveArgs;
    final file = _absolute(args?['path'] as String?);
    if (widget.block.args != null && file != null) {
      try {
        final f = File(file);
        if (f.existsSync()) return f.readAsStringSync();
      } catch (_) {}
    }
    return args?['content'] as String? ?? '';
  }

  void _preview(String path, {required bool writing}) {
    final file = _absolute(path);
    HtmlPreviewScreen.open(
      context,
      title: path.split('/').last,
      source: _htmlSource,
      baseDir: file == null ? null : File(file).parent.path,
      // Re-render as it streams; a finished file is static.
      live: writing ? widget.live : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = widget.block;
    final run = widget.run;
    final status = run?.status;
    final args = b.liveArgs;
    final cwd = widget.cwd ?? '';
    // Paths inside the workspace read better relative to it.
    final summary = cwd.isEmpty ? toolSummary(b.toolName, args) : toolSummary(b.toolName, args).replaceAll('$cwd/', '');

    // Arguments still streaming in: show what the model is writing, live.
    final writing = b.args == null && run == null;
    if (writing) sawLive = true;
    final path = args?['path'] as String?;
    final ext = path != null && path.contains('.') ? path.split('.').last.toLowerCase() : null;
    final previewable =
        path != null && (b.toolName == 'write' || b.toolName == 'edit') && const {'html', 'htm', 'svg'}.contains(ext);
    final liveText = switch (b.toolName) {
      'write' => args?['content'],
      'edit' => args?['newText'],
      'bash' => args?['command'],
      _ => null,
    } as String?;

    final Widget indicator = switch (status) {
      ToolStatus.done => Icon(LucideIcons.check, size: 15, color: p.success),
      ToolStatus.failed => Icon(LucideIcons.x, size: 15, color: p.danger),
      _ => SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: p.muted)),
    };

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => open = !open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
              child: Row(
                children: [
                  SizedBox.square(dimension: 16, child: Center(child: indicator)),
                  const SizedBox(width: 10),
                  Icon(toolIcon(b.toolName), size: 15, color: p.accent),
                  const SizedBox(width: 6),
                  Text(
                    b.toolName ?? 'tool',
                    style: TextStyle(fontFamily: mono, fontSize: 12.5, fontWeight: FontWeight.w600, color: p.text),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      writing && summary.isEmpty ? 'preparing…' : summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: mono, fontSize: 12.5, color: p.muted),
                    ),
                  ),
                  if (previewable)
                    TextButton.icon(
                      onPressed: () => _preview(path, writing: writing),
                      style: TextButton.styleFrom(
                        foregroundColor: p.text,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                      ),
                      icon: const Icon(LucideIcons.play, size: 16),
                      label: Text(writing ? 'Live' : 'Preview'),
                    ),
                  Icon(open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 18, color: p.faint),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
          if ((writing || sawLive) && !open && liveText != null && liveText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: CodeBox(
                text: liveText,
                label: path?.split('/').last ?? b.toolName,
                language: b.toolName == 'bash' ? 'bash' : ext,
                maxHeight: 260,
                followTail: true,
              ),
            ),
          if (open) ...[
            Divider(height: 1, color: p.border),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (b.toolName == 'write' && liveText != null)
                    _Section(
                      label: 'Content',
                      child: CodeBox(text: liveText, label: path?.split('/').last, language: ext, maxHeight: 320),
                    )
                  else
                    _Section(
                      label: 'Input',
                      child: CodeBox(
                        text: const JsonEncoder.withIndent('  ').convert(args ?? {}),
                        label: 'json',
                        maxHeight: 220,
                      ),
                    ),
                  if (run != null && run.output.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _Section(
                      label: status == ToolStatus.failed ? 'Error' : 'Output',
                      child: CodeBox(text: run.output.trimRight(), label: 'output', lineNumbers: false, maxHeight: 320),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(label.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
        ),
        child,
      ],
    );
  }
}

class NoticeView extends StatelessWidget {
  const NoticeView(this.entry, {super.key});
  final NoticeEntry entry;

  @override
  Widget build(BuildContext context) {
    if (entry.error) return _ErrorNote(entry.text);
    return Text(entry.text, style: Theme.of(context).textTheme.bodySmall);
  }
}

class _ErrorNote extends StatelessWidget {
  const _ErrorNote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.danger.withValues(alpha: 0.4)),
      ),
      child: SelectableText(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: p.danger)),
    );
  }
}

class _Pending extends StatefulWidget {
  const _Pending();

  @override
  State<_Pending> createState() => _PendingState();
}

class _PendingState extends State<_Pending> with SingleTickerProviderStateMixin {
  late final controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  /// Triangle wave in [0.25, 1] over one animation cycle.
  static double _pulse(double t) => 0.25 + 0.75 * (1 - ((t % 1) * 2 - 1).abs());

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Align(
      alignment: Alignment.centerLeft,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: p.muted.withValues(alpha: _pulse(controller.value - i * 0.18)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
