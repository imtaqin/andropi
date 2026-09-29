import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import 'code_view.dart';
import 'kit.dart';
import 'theme.dart';

/// Back up and restore sessions, skills, templates and settings as a zip.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  /// Remembered for the app's lifetime so Restore defaults to it.
  static String? _lastBackup;

  late final _path = TextEditingController(text: _lastBackup ?? '');
  bool _includeWorkspace = false;
  bool _backingUp = false;
  bool _restoring = false;
  ({String path, int files})? _result;

  AgentController get agent => widget.agent;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _backup() async {
    setState(() => _backingUp = true);
    try {
      final r = await agent.features.backup(includeWorkspace: _includeWorkspace);
      _lastBackup = r.path;
      if (mounted) {
        setState(() {
          _result = r;
          _path.text = r.path;
        });
      }
    } catch (e) {
      _snack('$e');
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  Future<void> _choose() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
      final path = files.firstOrNull?.path;
      if (path != null && mounted) setState(() => _path.text = path);
    } catch (e) {
      _snack('$e');
    }
  }

  Future<void> _restore() async {
    final path = _path.text.trim();
    if (path.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore backup?'),
        content: const Text(
          'Sessions, skills, templates and settings are overwritten with the backup\'s copies. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Restore')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _restoring = true);
    try {
      final n = await agent.features.restoreBackup(path);
      _snack('Restored $n ${n == 1 ? 'file' : 'files'}');
    } catch (e) {
      _snack('$e');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final r = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & restore')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          const SectionLabel('Back up', padding: EdgeInsets.fromLTRB(4, 8, 4, 10)),
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconTile(icon: LucideIcons.archive, color: p.accent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Sessions, skills, templates, schedules and settings in one zip.',
                        style: text.bodyMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _includeWorkspace,
                  onChanged: _backingUp ? null : (v) => setState(() => _includeWorkspace = v),
                  title: Text('Include workspace files', style: text.titleSmall),
                  subtitle: Text('Your project folders too; the zip can get large.', style: text.bodySmall),
                ),
                const SizedBox(height: 8),
                PrimaryButton(label: 'Create backup', icon: LucideIcons.download, busy: _backingUp, onPressed: _backup),
                if (r != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                    decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(14)),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${r.files} files', style: text.labelSmall),
                              const SizedBox(height: 2),
                              SelectableText(
                                r.path,
                                style: text.bodySmall?.copyWith(fontFamily: mono, color: p.text),
                              ),
                            ],
                          ),
                        ),
                        CopyButton(text: r.path, showLabel: false),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(LucideIcons.keyRound, size: 14, color: p.muted),
                    const SizedBox(width: 6),
                    Expanded(child: Text('Provider keys and tokens are not included.', style: text.bodySmall)),
                  ],
                ),
              ],
            ),
          ),
          const SectionLabel('Restore'),
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconTile(icon: LucideIcons.archiveRestore, color: p.warning),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Enter the path of a backup zip, or choose one from your phone.',
                        style: text.bodyMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _path,
                  autocorrect: false,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(fontFamily: mono, fontSize: 13),
                  decoration: const InputDecoration(labelText: 'Backup file', hintText: '/…/andropi-backup.zip'),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _restoring ? null : _choose,
                    icon: const Icon(LucideIcons.folderOpen, size: 16),
                    label: const Text('Choose file'),
                  ),
                ),
                const SizedBox(height: 8),
                PrimaryButton(
                  label: 'Restore',
                  icon: LucideIcons.rotateCcw,
                  busy: _restoring,
                  onPressed: _path.text.trim().isEmpty ? null : _restore,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
