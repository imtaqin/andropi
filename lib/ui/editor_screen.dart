import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/gradle.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/powershell.dart';
import 'package:re_highlight/languages/properties.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart' show Mode;

import '../agent/agent_controller.dart';
import 'illustration.dart';
import 'preview_screen.dart';
import 'theme.dart';

/// Files bigger than this open read-only: the editor keeps every line in memory and re-highlights on edits.
const _maxEditableBytes = 1536 * 1024;

/// A full code editor for one project file, so small fixes don't need a round trip through the agent.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.agent, required this.path, this.line});
  final AgentController agent;
  final String path;

  /// 1-based line to put the cursor on after opening.
  final int? line;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final _controller = CodeLineEditingController();
  late final _find = CodeFindController(_controller);
  final _scroll = CodeScrollController();
  final _focus = FocusNode();

  bool _loading = true;
  bool _binary = false;
  bool _readOnly = false;
  bool _dirty = false;
  bool _saving = false;
  bool _canUndo = false;
  bool _canRedo = false;
  String? _error;
  String _saved = '';
  int _size = 0;

  String get _name => widget.path.split('/').last;
  String get _ext => _name.contains('.') ? _name.split('.').last.toLowerCase() : '';
  bool get _previewable => const {'html', 'htm', 'svg'}.contains(_ext);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _find.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final file = File(widget.path);
      final bytes = await file.readAsBytes();
      _size = bytes.length;
      final head = bytes.length > 8192 ? bytes.sublist(0, 8192) : bytes;
      if (head.contains(0)) {
        setState(() {
          _binary = true;
          _loading = false;
        });
        return;
      }
      _readOnly = bytes.length > _maxEditableBytes;
      final text = utf8.decode(bytes, allowMalformed: true);
      _saved = text;
      _controller.value = CodeLineEditingValue(codeLines: CodeLines.fromText(text));
      _controller.clearHistory();
      _controller.addListener(_onChanged);
      setState(() => _loading = false);
      _jumpToLine();
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _jumpToLine() {
    final line = widget.line;
    if (line == null || line < 1) return;
    final index = (line - 1).clamp(0, _controller.lineCount - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.selection = CodeLineSelection.collapsed(index: index, offset: 0);
      _controller.makeCursorCenterIfInvisible();
    });
  }

  void _onChanged() {
    final dirty = _controller.text != _saved;
    final canUndo = _controller.canUndo;
    final canRedo = _controller.canRedo;
    if (dirty != _dirty || canUndo != _canUndo || canRedo != _canRedo) {
      setState(() {
        _dirty = dirty;
        _canUndo = canUndo;
        _canRedo = canRedo;
      });
    }
  }

  Future<bool> _save() async {
    if (_readOnly || _saving) return false;
    setState(() => _saving = true);
    try {
      final text = _controller.text;
      await File(widget.path).writeAsString(text);
      _saved = text;
      if (!mounted) return true;
      setState(() {
        _dirty = false;
        _saving = false;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Saved'), duration: Duration(seconds: 1)));
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return false;
    }
  }

  Future<void> _confirmLeave() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: Text('Save changes to $_name before leaving?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text('Discard')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'save' && !await _save()) return;
    if (!mounted) return;
    setState(() => _dirty = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  void _toggleFind() {
    if (_find.value == null) {
      _find.findMode();
    } else {
      _find.close();
    }
  }

  void _preview() {
    final dir = widget.path.substring(0, widget.path.lastIndexOf('/').clamp(0, widget.path.length));
    HtmlPreviewScreen.open(context, title: _name, source: () => _controller.text, baseDir: dir);
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _controller.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final ready = !_loading && !_binary && _error == null;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
            if (_dirty) _save();
          },
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): _toggleFind,
        },
        child: Scaffold(
          backgroundColor: p.bg,
          appBar: AppBar(
            titleSpacing: 0,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        _name,
                        overflow: TextOverflow.ellipsis,
                        style: t.titleMedium?.copyWith(fontFamily: mono),
                      ),
                    ),
                    if (_dirty) ...[
                      const SizedBox(width: 6),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
                      ),
                    ],
                    if (_readOnly) ...[const SizedBox(width: 6), Icon(LucideIcons.lock, size: 13, color: p.muted)],
                  ],
                ),
                Text(
                  _relativePath,
                  overflow: TextOverflow.ellipsis,
                  style: t.labelSmall?.copyWith(fontFamily: mono, color: p.muted),
                ),
              ],
            ),
            actions: [
              if (ready && !_readOnly) ...[
                IconButton(
                  tooltip: 'Undo',
                  icon: const Icon(LucideIcons.undo2, size: 20),
                  onPressed: _canUndo ? _controller.undo : null,
                ),
                IconButton(
                  tooltip: 'Redo',
                  icon: const Icon(LucideIcons.redo2, size: 20),
                  onPressed: _canRedo ? _controller.redo : null,
                ),
              ],
              if (ready)
                IconButton(tooltip: 'Find', icon: const Icon(LucideIcons.search, size: 20), onPressed: _toggleFind),
              if (ready && !_readOnly)
                IconButton(
                  tooltip: 'Save',
                  icon: _saving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(LucideIcons.save, size: 20, color: _dirty ? p.accent : null),
                  onPressed: _dirty && !_saving ? _save : null,
                ),
              if (ready)
                PopupMenuButton<String>(
                  icon: const Icon(LucideIcons.ellipsisVertical, size: 20),
                  onSelected: (v) {
                    if (v == 'preview') _preview();
                    if (v == 'copy') _copyAll();
                  },
                  itemBuilder: (_) => [
                    if (_previewable) const PopupMenuItem(value: 'preview', child: Text('Preview')),
                    const PopupMenuItem(value: 'copy', child: Text('Copy all')),
                  ],
                ),
              const SizedBox(width: 4),
            ],
          ),
          body: _body(context),
        ),
      ),
    );
  }

  String get _relativePath {
    final cwd = widget.agent.cwd;
    if (cwd.isNotEmpty && widget.path.startsWith('$cwd/')) return widget.path.substring(cwd.length + 1);
    return widget.path;
  }

  Widget _body(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: t.bodyMedium?.copyWith(color: p.danger),
          ),
        ),
      );
    }
    if (_binary) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Illustration('projects', height: 150),
              const SizedBox(height: 16),
              Text('Binary file', style: t.titleMedium),
              const SizedBox(height: 4),
              Text('${_formatSize(_size)} · can\'t be shown as text', style: t.bodySmall?.copyWith(color: p.muted)),
            ],
          ),
        ),
      );
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        if (_readOnly)
          Container(
            width: double.infinity,
            color: p.surface,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(LucideIcons.lock, size: 14, color: p.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Large file (${_formatSize(_size)}), opened read-only.',
                    style: t.bodySmall?.copyWith(color: p.muted),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: CodeEditor(
            controller: _controller,
            findController: _find,
            scrollController: _scroll,
            focusNode: _focus,
            autofocus: false,
            readOnly: _readOnly,
            showCursorWhenReadOnly: true,
            wordWrap: false,
            padding: const EdgeInsets.fromLTRB(4, 8, 12, 80),
            style: CodeEditorStyle(
              fontFamily: mono,
              fontSize: 13,
              fontHeight: 1.5,
              textColor: p.text,
              backgroundColor: p.bg,
              cursorColor: p.accent,
              selectionColor: p.accent.withValues(alpha: 0.22),
              highlightColor: p.warning.withValues(alpha: 0.28),
              cursorLineColor: p.surface,
              chunkIndicatorColor: p.faint,
              codeTheme: _highlightTheme(_ext, _name, dark, p),
            ),
            indicatorBuilder: (context, editing, chunk, notifier) => Row(
              children: [
                DefaultCodeLineNumber(
                  controller: editing,
                  notifier: notifier,
                  textStyle: TextStyle(fontFamily: mono, fontSize: 12, height: 1.5 * 13 / 12, color: p.faint),
                  focusedTextStyle: TextStyle(fontFamily: mono, fontSize: 12, height: 1.5 * 13 / 12, color: p.text),
                ),
                DefaultCodeChunkIndicator(width: 16, controller: chunk, notifier: notifier),
              ],
            ),
            leadingDivider: Container(width: 1, color: p.border),
            findBuilder: (context, controller, readOnly) => _FindBar(controller: controller, readOnly: readOnly),
            toolbarController: MobileSelectionToolbarController(builder: _toolbar),
          ),
        ),
      ],
    );
  }

  Widget _toolbar({
    required BuildContext context,
    required TextSelectionToolbarAnchors anchors,
    required CodeLineEditingController controller,
    required VoidCallback onDismiss,
    required VoidCallback onRefresh,
  }) {
    final hasSelection = !controller.selection.isCollapsed;
    return TextSelectionToolbar(
      anchorAbove: anchors.primaryAnchor,
      anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
      children: [
        if (hasSelection && !_readOnly)
          _toolbarButton('Cut', 0, () {
            controller.cut();
            onDismiss();
          }),
        if (hasSelection)
          _toolbarButton('Copy', 1, () {
            controller.copy();
            onDismiss();
          }),
        if (!_readOnly)
          _toolbarButton('Paste', 2, () {
            controller.paste();
            onDismiss();
          }),
        _toolbarButton('Select all', 3, () {
          controller.selectAll();
          onRefresh();
        }),
      ],
    );
  }

  Widget _toolbarButton(String label, int index, VoidCallback onPressed) {
    return TextSelectionToolbarTextButton(
      padding: TextSelectionToolbarTextButton.getPadding(index, 4),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// Compact find / replace strip docked above the code, styled with the app palette.
class _FindBar extends StatelessWidget implements PreferredSizeWidget {
  const _FindBar({required this.controller, required this.readOnly});
  final CodeFindController controller;
  final bool readOnly;

  static const _row = 44.0;

  @override
  Size get preferredSize {
    final v = controller.value;
    if (v == null) return Size.zero;
    return Size(double.infinity, (v.replaceMode ? _row * 2 : _row) + 1);
  }

  @override
  Widget build(BuildContext context) {
    final v = controller.value;
    if (v == null) return const SizedBox.shrink();
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final result = v.result == null
        ? (v.option.pattern.isEmpty ? '' : '0/0')
        : '${v.result!.index + 1}/${v.result!.matches.length}';
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Column(
        children: [
          SizedBox(
            height: _row,
            child: Row(
              children: [
                if (!readOnly)
                  _icon(
                    v.replaceMode ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                    'Replace',
                    controller.toggleMode,
                    p.muted,
                  )
                else
                  const SizedBox(width: 8),
                Expanded(child: _field(context, controller.findInputController, controller.findInputFocusNode, 'Find')),
                _toggle(context, 'Aa', v.option.caseSensitive, controller.toggleCaseSensitive),
                _toggle(context, '.*', v.option.regex, controller.toggleRegex),
                SizedBox(
                  width: 44,
                  child: Text(
                    result,
                    textAlign: TextAlign.center,
                    style: t.labelSmall?.copyWith(color: p.muted, fontFamily: mono),
                  ),
                ),
                _icon(LucideIcons.chevronUp, 'Previous', v.result == null ? null : controller.previousMatch, p.text),
                _icon(LucideIcons.chevronDown, 'Next', v.result == null ? null : controller.nextMatch, p.text),
                _icon(LucideIcons.x, 'Close', controller.close, p.text),
              ],
            ),
          ),
          if (v.replaceMode)
            SizedBox(
              height: _row,
              child: Row(
                children: [
                  const SizedBox(width: 40),
                  Expanded(
                    child: _field(
                      context,
                      controller.replaceInputController,
                      controller.replaceInputFocusNode,
                      'Replace',
                    ),
                  ),
                  _icon(LucideIcons.replace, 'Replace', v.result == null ? null : controller.replaceMatch, p.text),
                  _icon(
                    LucideIcons.replaceAll,
                    'Replace all',
                    v.result == null ? null : controller.replaceAllMatches,
                    p.text,
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _field(BuildContext context, TextEditingController c, FocusNode f, String hint) {
    final p = context.palette;
    return SizedBox(
      height: 34,
      child: TextField(
        controller: c,
        focusNode: f,
        maxLines: 1,
        style: TextStyle(fontFamily: mono, fontSize: 13, color: p.text),
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          filled: true,
          fillColor: p.bg,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
        ),
      ),
    );
  }

  Widget _toggle(BuildContext context, String label, bool on, VoidCallback onTap) {
    final p = context.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        margin: const EdgeInsets.only(left: 4),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: on ? p.accent.withValues(alpha: 0.15) : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(fontFamily: mono, fontSize: 12, color: on ? p.accent : p.muted, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _icon(IconData icon, String tooltip, VoidCallback? onTap, Color color) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      iconSize: 18,
      color: color,
      onPressed: onTap,
      icon: Icon(icon),
    );
  }
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

Mode? _languageFor(String ext, String name) {
  switch (name.toLowerCase()) {
    case 'dockerfile':
      return langDockerfile;
    case 'makefile':
    case 'gnumakefile':
      return langMakefile;
  }
  return switch (ext) {
    'dart' => langDart,
    'js' || 'jsx' || 'mjs' || 'cjs' => langJavascript,
    'ts' || 'tsx' || 'mts' || 'cts' => langTypescript,
    'py' || 'pyw' => langPython,
    'json' || 'jsonc' || 'json5' || 'webmanifest' => langJson,
    'html' || 'htm' || 'xml' || 'svg' || 'xhtml' || 'plist' || 'vue' => langXml,
    'css' => langCss,
    'scss' || 'sass' || 'less' => langScss,
    'md' || 'markdown' || 'mdx' => langMarkdown,
    'sh' || 'bash' || 'zsh' || 'fish' => langBash,
    'yaml' || 'yml' => langYaml,
    'kt' || 'kts' => langKotlin,
    'java' => langJava,
    'go' => langGo,
    'rs' => langRust,
    'c' || 'h' => langC,
    'cpp' || 'cc' || 'cxx' || 'hpp' || 'hh' || 'hxx' => langCpp,
    'cs' => langCsharp,
    'sql' => langSql,
    'toml' || 'ini' || 'cfg' || 'conf' || 'env' => langIni,
    'properties' => langProperties,
    'gradle' => langGradle,
    'rb' => langRuby,
    'php' => langPhp,
    'swift' => langSwift,
    'lua' => langLua,
    'ps1' || 'psm1' => langPowershell,
    'diff' || 'patch' => langDiff,
    'mk' => langMakefile,
    _ => null,
  };
}

CodeHighlightTheme? _highlightTheme(String ext, String name, bool dark, Palette p) {
  final mode = _languageFor(ext, name);
  if (mode == null) return null;
  return CodeHighlightTheme(
    languages: {'code': CodeHighlightThemeMode(mode: mode)},
    theme: dark ? _darkSyntax(p) : _lightSyntax(p),
  );
}

Map<String, TextStyle> _syntax({
  required Color text,
  required Color keyword,
  required Color string,
  required Color number,
  required Color comment,
  required Color title,
  required Color type,
  required Color attr,
  required Color tag,
}) {
  TextStyle c(Color color) => TextStyle(color: color);
  return {
    'root': c(text),
    'keyword': c(keyword),
    'meta-keyword': c(keyword),
    'template-tag': c(keyword),
    'variable.language_': c(keyword),
    'selector-pseudo': c(keyword),
    'deletion': c(keyword),
    'string': c(string),
    'regexp': c(string),
    'meta-string': c(string),
    'template-variable': c(string),
    'addition': c(tag),
    'number': c(number),
    'literal': c(number),
    'symbol': c(number),
    'operator': c(number),
    'meta': c(number),
    'selector-id': c(number),
    'selector-attr': c(number),
    'comment': TextStyle(color: comment, fontStyle: FontStyle.italic),
    'quote': TextStyle(color: comment, fontStyle: FontStyle.italic),
    'doctag': c(keyword),
    'title': c(title),
    'title.function_': c(title),
    'title.class_': c(type),
    'title.class_.inherited__': c(type),
    'function': c(title),
    'selector-class': c(title),
    'section': TextStyle(color: title, fontWeight: FontWeight.w600),
    'type': c(type),
    'built_in': c(type),
    'class': c(type),
    'variable': c(type),
    'bullet': c(type),
    'params': c(text),
    'attr': c(attr),
    'attribute': c(attr),
    'property': c(attr),
    'tag': c(tag),
    'name': c(tag),
    'selector-tag': c(tag),
    'code': c(string),
    'emphasis': TextStyle(color: text, fontStyle: FontStyle.italic),
    'strong': TextStyle(color: text, fontWeight: FontWeight.w700),
    'link': TextStyle(color: attr, decoration: TextDecoration.underline),
  };
}

Map<String, TextStyle> _lightSyntax(Palette p) => _syntax(
  text: p.text,
  keyword: const Color(0xFFCF222E),
  string: const Color(0xFF0A3069),
  number: const Color(0xFF0550AE),
  comment: const Color(0xFF6E7781),
  title: const Color(0xFF8250DF),
  type: const Color(0xFF953800),
  attr: const Color(0xFF0550AE),
  tag: const Color(0xFF116329),
);

Map<String, TextStyle> _darkSyntax(Palette p) => _syntax(
  text: p.text,
  keyword: const Color(0xFFFF7B72),
  string: const Color(0xFFA5D6FF),
  number: const Color(0xFF79C0FF),
  comment: const Color(0xFF8B949E),
  title: const Color(0xFFD2A8FF),
  type: const Color(0xFFFFA657),
  attr: const Color(0xFF79C0FF),
  tag: const Color(0xFF7EE787),
);
