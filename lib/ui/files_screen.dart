import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import 'db_screen.dart';
import 'editor_screen.dart';
import 'illustration.dart';
import 'preview_screen.dart';
import 'search_screen.dart';
import 'theme.dart';

const _imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp'};
const _htmlExts = {'html', 'htm', 'svg'};
const _dbExts = {'db', 'sqlite', 'sqlite3'};
const _codeExts = {
  'dart',
  'js',
  'jsx',
  'mjs',
  'cjs',
  'ts',
  'tsx',
  'py',
  'kt',
  'kts',
  'java',
  'go',
  'rs',
  'c',
  'h',
  'cpp',
  'cc',
  'hpp', //
  'cs', 'rb', 'php', 'swift', 'lua', 'sh', 'bash', 'zsh', 'ps1', 'css', 'scss', 'sass', 'less', 'html', 'htm', 'xml',
  'vue', 'svelte', 'sql', 'gradle', 'r', 'scala', 'ex', 'exs', 'zig', 'nim',
};
const _configExts = {'yaml', 'yml', 'toml', 'ini', 'cfg', 'conf', 'env', 'properties', 'lock'};
const _archiveExts = {'zip', 'tar', 'gz', 'tgz', 'bz2', 'xz', '7z', 'rar', 'apk', 'jar', 'aar'};
const _videoExts = {'mp4', 'mkv', 'webm', 'mov', 'avi'};
const _audioExts = {'mp3', 'wav', 'ogg', 'flac', 'm4a', 'aac'};
const _sheetExts = {'csv', 'tsv', 'xlsx', 'xls'};

String _baseName(String path) {
  final trimmed = path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
  return trimmed.substring(trimmed.lastIndexOf('/') + 1);
}

String _dirName(String path) {
  final i = path.lastIndexOf('/');
  if (i <= 0) return '/';
  return path.substring(0, i);
}

String _extOf(String name) {
  final i = name.lastIndexOf('.');
  return i <= 0 ? '' : name.substring(i + 1).toLowerCase();
}

String _join(String dir, String name) => dir.endsWith('/') ? '$dir$name' : '$dir/$name';

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String _formatTime(DateTime t) {
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1 && now.day == t.day) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays == 0 ? 1 : diff.inDays}d ago';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

IconData _iconFor(String name, bool isDir) {
  if (isDir) return LucideIcons.folder;
  final lower = name.toLowerCase();
  final ext = _extOf(name);
  if (lower == 'dockerfile' || lower == 'makefile') return LucideIcons.fileCog;
  if (_imageExts.contains(ext) || ext == 'svg' || ext == 'ico' || ext == 'bmp') return LucideIcons.fileImage;
  if (_dbExts.contains(ext)) return LucideIcons.database;
  if (ext == 'json' || ext == 'jsonc') return LucideIcons.fileJson;
  if (ext == 'md' || ext == 'txt' || ext == 'rst' || ext == 'log' || ext == 'pdf') return LucideIcons.fileText;
  if (_codeExts.contains(ext)) return LucideIcons.fileCode;
  if (_configExts.contains(ext) || lower.startsWith('.')) return LucideIcons.fileCog;
  if (_archiveExts.contains(ext)) return LucideIcons.fileArchive;
  if (_videoExts.contains(ext)) return LucideIcons.fileVideo;
  if (_audioExts.contains(ext)) return LucideIcons.fileAudio;
  if (_sheetExts.contains(ext)) return LucideIcons.fileSpreadsheet;
  return LucideIcons.file;
}

/// One listed directory entry with its stat, captured once per refresh so sorting and rendering stay cheap.
class _Entry {
  _Entry(this.path, this.isDir, this.stat);
  final String path;
  final bool isDir;
  final FileStat stat;
  String get name => _baseName(path);
}

/// Browses the project on disk so the user can look at, open and tidy files without asking the agent.
class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key, required this.agent, this.root});
  final AgentController agent;

  /// Top of the tree; defaults to the current project folder.
  final String? root;

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  late final String _root = _normalize(widget.root ?? widget.agent.cwd);
  late String _dir = _root;
  List<_Entry> _entries = [];
  bool _loading = true;
  bool _showHidden = false;
  String? _error;

  AgentController get agent => widget.agent;

  static String _normalize(String p) => p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = <_Entry>[];
      await for (final e in Directory(_dir).list(followLinks: false)) {
        FileStat stat = await e.stat();
        if (e is Link) stat = await FileStat.stat(e.path);
        items.add(_Entry(e.path, stat.type == FileSystemEntityType.directory, stat));
      }
      items.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _entries = items;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _entries = [];
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _go(String dir) {
    setState(() {
      _dir = _normalize(dir);
      _loading = true;
    });
    _load();
  }

  bool get _atRoot => _dir == _root;

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _open(_Entry e) async {
    if (e.isDir) return _go(e.path);
    final ext = _extOf(e.name);
    final nav = Navigator.of(context);
    if (_imageExts.contains(ext)) {
      await nav.push(MaterialPageRoute(builder: (_) => _ImageViewer(path: e.path)));
    } else if (_dbExts.contains(ext)) {
      await nav.push(
        MaterialPageRoute(
          builder: (_) => DbScreen(agent: agent, path: e.path),
        ),
      );
    } else if (_htmlExts.contains(ext)) {
      await _openHtml(e);
    } else {
      await nav.push(
        MaterialPageRoute(
          builder: (_) => EditorScreen(agent: agent, path: e.path),
        ),
      );
    }
    if (mounted) _load();
  }

  Future<void> _openHtml(_Entry e) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.eye),
              title: const Text('Preview'),
              onTap: () => Navigator.pop(ctx, 'preview'),
            ),
            ListTile(
              leading: const Icon(LucideIcons.pencil),
              title: const Text('Edit'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'preview') {
      await HtmlPreviewScreen.open(
        context,
        title: e.name,
        source: () => File(e.path).readAsStringSync(),
        baseDir: _dirName(e.path),
      );
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => EditorScreen(agent: agent, path: e.path),
        ),
      );
    }
  }

  Future<String?> _prompt({required String title, String initial = '', required String action}) {
    final controller = TextEditingController(text: initial);
    final dot = initial.lastIndexOf('.');
    controller.selection = TextSelection(baseOffset: 0, extentOffset: dot > 0 ? dot : initial.length);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontFamily: mono),
          decoration: const InputDecoration(hintText: 'name'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: Text(action)),
        ],
      ),
    );
  }

  String? _validName(String? name) {
    if (name == null || name.isEmpty) return null;
    if (name == '.' || name == '..' || name.contains('\u0000')) {
      _snack('Invalid name');
      return null;
    }
    return name;
  }

  Future<void> _newFile() async {
    final name = _validName(await _prompt(title: 'New file', action: 'Create'));
    if (name == null) return;
    final path = _join(_dir, name);
    try {
      if (await FileSystemEntity.type(path) != FileSystemEntityType.notFound) return _snack('$name already exists');
      final file = await File(path).create(recursive: true);
      await _load();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => EditorScreen(agent: agent, path: file.path),
        ),
      );
      if (mounted) _load();
    } catch (e) {
      _snack('$e');
    }
  }

  Future<void> _newFolder() async {
    final name = _validName(await _prompt(title: 'New folder', action: 'Create'));
    if (name == null) return;
    final path = _join(_dir, name);
    try {
      if (await FileSystemEntity.type(path) != FileSystemEntityType.notFound) return _snack('$name already exists');
      await Directory(path).create(recursive: true);
      await _load();
    } catch (e) {
      _snack('$e');
    }
  }

  Future<void> _rename(_Entry e) async {
    final name = _validName(await _prompt(title: 'Rename', initial: e.name, action: 'Rename'));
    if (name == null || name == e.name) return;
    final target = _join(_dirName(e.path), name);
    try {
      if (await FileSystemEntity.type(target) != FileSystemEntityType.notFound) return _snack('$name already exists');
      if (e.isDir) {
        await Directory(e.path).rename(target);
      } else {
        await File(e.path).rename(target);
      }
      await _load();
    } catch (err) {
      _snack('$err');
    }
  }

  Future<void> _duplicate(_Entry e) async {
    final dir = _dirName(e.path);
    final ext = e.isDir ? '' : _extOf(e.name);
    final stem = ext.isEmpty ? e.name : e.name.substring(0, e.name.length - ext.length - 1);
    String candidate(int n) => '$stem copy${n > 1 ? ' $n' : ''}${ext.isEmpty ? '' : '.$ext'}';
    var n = 1;
    while (await FileSystemEntity.type(_join(dir, candidate(n))) != FileSystemEntityType.notFound) {
      n++;
    }
    final target = _join(dir, candidate(n));
    try {
      if (e.isDir) {
        await _copyDir(Directory(e.path), Directory(target));
      } else {
        await File(e.path).copy(target);
      }
      await _load();
    } catch (err) {
      _snack('$err');
    }
  }

  Future<void> _copyDir(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final child in from.list(followLinks: false)) {
      final dest = _join(to.path, _baseName(child.path));
      if (child is Directory) {
        await _copyDir(child, Directory(dest));
      } else if (child is File) {
        await child.copy(dest);
      } else if (child is Link) {
        await Link(dest).create(await child.target());
      }
    }
  }

  Future<void> _delete(_Entry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${e.isDir ? 'folder' : 'file'}?'),
        content: Text(
          e.isDir ? '"${e.name}" and everything inside it will be deleted.' : '"${e.name}" will be deleted.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: context.palette.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (e.isDir) {
        await Directory(e.path).delete(recursive: true);
      } else {
        await File(e.path).delete();
      }
      await _load();
    } catch (err) {
      _snack('$err');
    }
  }

  Future<void> _copyPath(_Entry e) async {
    await Clipboard.setData(ClipboardData(text: e.path));
    if (mounted) _snack('Path copied');
  }

  Future<void> _entryAction(_Entry e, String action) async {
    switch (action) {
      case 'open':
        await _open(e);
      case 'edit':
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => EditorScreen(agent: agent, path: e.path),
          ),
        );
      case 'rename':
        await _rename(e);
      case 'duplicate':
        await _duplicate(e);
      case 'delete':
        await _delete(e);
      case 'copy':
        await _copyPath(e);
      case 'share':
        await agent.client.shareFile(e.path);
      case 'download':
        try {
          _snack('Saved to ${await agent.client.saveToDownloads(e.path)}');
        } catch (err) {
          _snack('$err');
        }
    }
  }

  /// Copies files picked from the phone into the folder being viewed.
  Future<void> _import() async {
    final picked = await FilePicker.pickFiles();
    var count = 0;
    for (final f in picked) {
      if (f.path == null) continue;
      var target = _join(_dir, f.name);
      if (File(target).existsSync()) {
        final dot = f.name.lastIndexOf('.');
        final stem = dot > 0 ? f.name.substring(0, dot) : f.name;
        final ext = dot > 0 ? f.name.substring(dot) : '';
        var n = 2;
        while (File(target).existsSync()) {
          target = _join(_dir, '$stem ($n)$ext');
          n++;
        }
      }
      await File(f.path!).copy(target);
      count++;
    }
    if (count == 0) return;
    _snack('Imported $count file${count == 1 ? '' : 's'}');
    await _load();
  }

  Future<void> _showEntrySheet(_Entry e) async {
    final p = context.palette;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Row(
                children: [
                  Icon(_iconFor(e.name, e.isDir), size: 18, color: p.muted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      e.name,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(ctx).textTheme.titleSmall?.copyWith(fontFamily: mono),
                    ),
                  ),
                ],
              ),
            ),
            ..._menuItems(e).map(
              (m) => ListTile(
                leading: Icon(m.$3, color: m.$1 == 'delete' ? p.danger : null),
                title: Text(m.$2, style: m.$1 == 'delete' ? TextStyle(color: p.danger) : null),
                onTap: () => Navigator.pop(ctx, m.$1),
              ),
            ),
          ],
        ),
      ),
    );
    if (action != null && mounted) await _entryAction(e, action);
  }

  List<(String, String, IconData)> _menuItems(_Entry e) => [
    if (!e.isDir && _htmlExts.contains(_extOf(e.name))) ('edit', 'Edit', LucideIcons.pencil),
    ('rename', 'Rename', LucideIcons.textCursorInput),
    ('duplicate', 'Duplicate', LucideIcons.copyPlus),
    ('copy', 'Copy path', LucideIcons.copy),
    if (!e.isDir) ('share', 'Share', LucideIcons.share2),
    if (!e.isDir) ('download', 'Save to Downloads', LucideIcons.download),
    ('delete', 'Delete', LucideIcons.trash2),
  ];

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _atRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _go(_dirName(_dir));
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_atRoot ? 'Files' : _baseName(_dir)),
          actions: [
            IconButton(
              tooltip: 'Search',
              icon: const Icon(LucideIcons.search, size: 20),
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => SearchScreen(agent: agent))),
            ),
            IconButton(
              tooltip: _showHidden ? 'Hide hidden files' : 'Show hidden files',
              icon: Icon(_showHidden ? LucideIcons.eye : LucideIcons.eyeOff, size: 20),
              onPressed: () => setState(() => _showHidden = !_showHidden),
            ),
            PopupMenuButton<String>(
              icon: const Icon(LucideIcons.plus, size: 22),
              tooltip: 'New',
              onSelected: (v) => switch (v) {
                'file' => _newFile(),
                'folder' => _newFolder(),
                _ => _import(),
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'file',
                  child: ListTile(
                    leading: Icon(LucideIcons.filePlus2),
                    title: Text('New file'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: 'folder',
                  child: ListTile(
                    leading: Icon(LucideIcons.folderPlus),
                    title: Text('New folder'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: 'import',
                  child: ListTile(
                    leading: Icon(LucideIcons.upload),
                    title: Text('Import from phone'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Column(
          children: [
            _Breadcrumbs(root: _root, dir: _dir, onTap: _go),
            Expanded(child: _list(context)),
          ],
        ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    if (_loading && _entries.isEmpty && _error == null) return const Center(child: CircularProgressIndicator());
    final visible = _showHidden ? _entries : _entries.where((e) => !e.name.startsWith('.')).toList();
    final hiddenCount = _entries.length - visible.length;
    Widget child;
    if (_error != null) {
      child = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 60),
          Icon(LucideIcons.folderX, size: 40, color: p.faint),
          const SizedBox(height: 12),
          Text("Can't open this folder", textAlign: TextAlign.center, style: t.titleMedium),
          const SizedBox(height: 4),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: t.bodySmall?.copyWith(color: p.muted),
          ),
        ],
      );
    } else if (visible.isEmpty) {
      child = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 40),
          const Illustration('projects', height: 150),
          const SizedBox(height: 16),
          Text('This folder is empty', textAlign: TextAlign.center, style: t.titleMedium),
          const SizedBox(height: 4),
          Text(
            hiddenCount > 0
                ? '$hiddenCount hidden ${hiddenCount == 1 ? 'item' : 'items'} — tap the eye to show them.'
                : 'Create a file or folder with the + button.',
            textAlign: TextAlign.center,
            style: t.bodySmall?.copyWith(color: p.muted),
          ),
        ],
      );
    } else {
      child = ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 40),
        itemCount: visible.length,
        itemBuilder: (context, i) => _tile(context, visible[i]),
      );
    }
    return RefreshIndicator(onRefresh: _load, child: child);
  }

  Widget _tile(BuildContext context, _Entry e) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final ext = _extOf(e.name);
    final hidden = e.name.startsWith('.');
    final Color tint;
    if (e.isDir) {
      tint = p.accent;
    } else if (_dbExts.contains(ext)) {
      tint = p.success;
    } else if (_imageExts.contains(ext) || ext == 'svg') {
      tint = p.warning;
    } else if (_codeExts.contains(ext) || ext == 'json') {
      tint = p.accentAlt;
    } else {
      tint = p.muted;
    }
    final meta = [if (!e.isDir) _formatSize(e.stat.size), _formatTime(e.stat.modified)].join(' · ');
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _open(e),
      onLongPress: () => _showEntrySheet(e),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: tint.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
              child: Icon(_iconFor(e.name, e.isDir), size: 18, color: tint),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Opacity(
                opacity: hidden ? 0.6 : 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(meta, style: t.bodySmall?.copyWith(color: p.muted)),
                  ],
                ),
              ),
            ),
            PopupMenuButton<String>(
              icon: Icon(LucideIcons.ellipsisVertical, size: 18, color: p.muted),
              onSelected: (a) => _entryAction(e, a),
              itemBuilder: (_) => [
                for (final m in _menuItems(e))
                  PopupMenuItem(
                    value: m.$1,
                    child: Text(m.$2, style: m.$1 == 'delete' ? TextStyle(color: p.danger) : null),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Tappable path segments from the root down to the current folder; tapping one jumps up to it.
class _Breadcrumbs extends StatefulWidget {
  const _Breadcrumbs({required this.root, required this.dir, required this.onTap});
  final String root;
  final String dir;
  final ValueChanged<String> onTap;

  @override
  State<_Breadcrumbs> createState() => _BreadcrumbsState();
}

class _BreadcrumbsState extends State<_Breadcrumbs> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(_Breadcrumbs old) {
    super.didUpdateWidget(old);
    if (old.dir != widget.dir) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final crumbs = <(String, String)>[(_baseName(widget.root).isEmpty ? '/' : _baseName(widget.root), widget.root)];
    if (widget.dir != widget.root && widget.dir.startsWith(widget.root)) {
      var acc = widget.root;
      for (final part in widget.dir.substring(widget.root.length).split('/').where((s) => s.isNotEmpty)) {
        acc = _join(acc, part);
        crumbs.add((part, acc));
      }
    }
    return Container(
      height: 40,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(10)),
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        itemCount: crumbs.length,
        separatorBuilder: (_, _) => Icon(LucideIcons.chevronRight, size: 14, color: p.faint),
        itemBuilder: (context, i) {
          final last = i == crumbs.length - 1;
          return InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: last ? null : () => widget.onTap(crumbs[i].$2),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (i == 0) ...[Icon(LucideIcons.folderRoot, size: 14, color: p.muted), const SizedBox(width: 5)],
                  Text(
                    crumbs[i].$1,
                    style: t.labelMedium?.copyWith(
                      fontFamily: mono,
                      color: last ? p.text : p.muted,
                      fontWeight: last ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Full-screen pinch-zoom viewer for an image file.
class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          _baseName(path),
          style: const TextStyle(fontFamily: mono, fontSize: 15, color: Colors.white),
        ),
        actions: [
          IconButton(
            tooltip: 'Copy path',
            icon: const Icon(LucideIcons.copy, size: 20),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: path));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Path copied')));
            },
          ),
        ],
      ),
      body: InteractiveViewer(
        minScale: 0.5,
        maxScale: 8,
        child: Center(
          child: Image.file(
            File(path),
            errorBuilder: (_, e, _) => Text("Can't display this image", style: TextStyle(color: p.faint)),
          ),
        ),
      ),
    );
  }
}
