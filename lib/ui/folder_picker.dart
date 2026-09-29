import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import 'kit.dart';
import 'theme.dart';

/// The last path segment, for showing a folder by name.
String folderName(String path) => path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path;

/// Folder name to show for a session's cwd, or null for the workspace root.
String? sessionFolder(String cwd, String workspace) {
  if (cwd.isEmpty || cwd == workspace || cwd == '$workspace/') return null;
  return folderName(cwd);
}

/// Browse the app workspace or phone storage and pick a folder to work in.
/// Pops with the chosen absolute path.
class FolderPicker extends StatefulWidget {
  const FolderPicker({super.key, required this.agent});
  final AgentController agent;

  static Future<String?> pick(BuildContext context, AgentController agent) =>
      Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => FolderPicker(agent: agent)));

  @override
  State<FolderPicker> createState() => _FolderPickerState();
}

enum _Root { workspace, phone }

class _FolderPickerState extends State<FolderPicker> with WidgetsBindingObserver {
  _Root root = _Root.workspace;
  late String workspace = widget.agent.info['workspace'] as String? ?? '/';
  String phoneRoot = '/storage/emulated/0';
  bool phoneGranted = false;
  late String path = workspace;
  bool showHidden = false;

  String get base => root == _Root.workspace ? workspace : phoneRoot;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAccess();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The grant happens in system settings; re-check when the user comes back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkAccess();
  }

  Future<void> _checkAccess() async {
    final a = await widget.agent.client.storageAccess();
    if (!mounted) return;
    setState(() {
      phoneGranted = a.granted;
      phoneRoot = a.root;
    });
  }

  void _switch(_Root r) => setState(() {
    root = r;
    path = base;
  });

  List<Directory> _children() {
    try {
      final dirs = Directory(path).listSync(followLinks: false).whereType<Directory>().where((d) {
        final name = folderName(d.path);
        return showHidden || !name.startsWith('.');
      }).toList();
      dirs.sort((a, b) => folderName(a.path).toLowerCase().compareTo(folderName(b.path).toLowerCase()));
      return dirs;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _newFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'my-project'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Create')),
        ],
      ),
    );
    controller.dispose();
    final clean = name?.trim().replaceAll(RegExp(r'[/\\:*?"<>|]+'), '-');
    if (clean == null || clean.isEmpty) return;
    try {
      final dir = Directory('$path/$clean')..createSync(recursive: true);
      setState(() => path = dir.path);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create it: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final locked = root == _Root.phone && !phoneGranted;
    final crumbs = path.substring(base.length).split('/').where((s) => s.isNotEmpty).toList();
    final children = locked ? const <Directory>[] : _children();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose a folder'),
        actions: [
          IconButton(
            tooltip: showHidden ? 'Hide hidden folders' : 'Show hidden folders',
            icon: Icon(showHidden ? LucideIcons.eye : LucideIcons.eyeOff, size: 18),
            onPressed: () => setState(() => showHidden = !showHidden),
          ),
          if (!locked)
            IconButton(
              tooltip: 'New folder',
              icon: const Icon(LucideIcons.folderPlus, size: 20),
              onPressed: _newFolder,
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: SegmentedButton<_Root>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: _Root.workspace,
                  icon: Icon(LucideIcons.boxes, size: 16),
                  label: Text('Workspace'),
                ),
                ButtonSegment(
                  value: _Root.phone,
                  icon: Icon(LucideIcons.smartphone, size: 16),
                  label: Text('Phone storage'),
                ),
              ],
              selected: {root},
              onSelectionChanged: (s) => _switch(s.first),
            ),
          ),
          // Breadcrumbs: tap a segment to jump back up.
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _Crumb(
                  label: root == _Root.workspace ? 'workspace' : 'phone',
                  icon: root == _Root.workspace ? LucideIcons.boxes : LucideIcons.smartphone,
                  active: crumbs.isEmpty,
                  onTap: () => setState(() => path = base),
                ),
                for (var i = 0; i < crumbs.length; i++) ...[
                  Icon(LucideIcons.chevronRight, size: 14, color: p.faint),
                  _Crumb(
                    label: crumbs[i],
                    active: i == crumbs.length - 1,
                    onTap: () => setState(() => path = '$base/${crumbs.take(i + 1).join('/')}'),
                  ),
                ],
              ],
            ),
          ),
          Divider(height: 16, color: p.border),
          Expanded(
            child: locked
                ? ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      SurfaceCard(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const IconTile(icon: LucideIcons.folderLock, color: Color(0xFFF59E0B), size: 44),
                            const SizedBox(height: 14),
                            Text('Allow file access', style: text.titleMedium),
                            const SizedBox(height: 6),
                            Text(
                              'To work in Download, Documents or any other folder on your phone, AndroPI needs '
                              '"All files access". Turn it on for AndroPI on the next screen, then come back.',
                              style: text.bodySmall,
                            ),
                            const SizedBox(height: 16),
                            PrimaryButton(
                              label: 'Allow access',
                              icon: LucideIcons.shieldCheck,
                              onPressed: widget.agent.client.requestStorageAccess,
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : children.isEmpty
                ? Center(child: Text('No folders here', style: text.bodySmall))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                    itemCount: children.length,
                    itemBuilder: (context, i) {
                      final d = children[i];
                      final git = Directory('${d.path}/.git').existsSync();
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                        leading: IconTile(
                          icon: git ? LucideIcons.folderGit2 : LucideIcons.folder,
                          color: git ? p.accent : p.muted,
                          size: 34,
                        ),
                        title: Text(folderName(d.path), style: text.bodyMedium),
                        subtitle: git ? Text('git repository', style: text.bodySmall) : null,
                        trailing: Icon(LucideIcons.chevronRight, size: 16, color: p.faint),
                        onTap: () => setState(() => path = d.path),
                      );
                    },
                  ),
          ),
          if (!locked)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: PrimaryButton(
                  label: crumbs.isEmpty
                      ? 'Open ${root == _Root.workspace ? 'workspace' : 'phone storage'}'
                      : 'Open ${crumbs.last}',
                  icon: LucideIcons.folderOpen,
                  onPressed: () => Navigator.pop(context, path),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Crumb extends StatelessWidget {
  const _Crumb({required this.label, required this.active, required this.onTap, this.icon});
  final String label;
  final bool active;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            if (icon != null) ...[Icon(icon, size: 14, color: active ? p.accent : p.muted), const SizedBox(width: 5)],
            Text(
              label,
              style: TextStyle(
                fontFamily: mono,
                fontSize: 12.5,
                color: active ? p.text : p.muted,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
