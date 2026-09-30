import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import 'i18n.dart';
import 'folder_picker.dart';
import 'kit.dart';
import 'theme.dart';

/// Where a new chat works: its own project folder (default), an existing
/// folder, or the workspace root.
Future<void> showNewChatSheet(BuildContext context, AgentController agent) async {
  agent.integrations.refreshProjects().catchError((_) {});
  final dir = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _NewChatSheet(agent: agent),
  );
  if (dir == null || !context.mounted) return;
  if (dir == _pick) {
    final picked = await FolderPicker.pick(context, agent);
    if (picked != null) await agent.newSession(dir: picked);
    return;
  }
  await agent.newSession(dir: dir.isEmpty ? null : dir);
}

const _pick = '\u0000pick';

class _NewChatSheet extends StatefulWidget {
  const _NewChatSheet({required this.agent});
  final AgentController agent;

  @override
  State<_NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<_NewChatSheet> {
  late final String workspace = widget.agent.info['workspace'] as String? ?? '';
  late final name = TextEditingController(text: _suggestName());
  String? error;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  String _suggestName() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'project-${two(n.month)}${two(n.day)}-${two(n.hour)}${two(n.minute)}';
  }

  void _createProject() {
    final clean = name.text.trim().replaceAll(RegExp(r'[/\\:*?"<>|\s]+'), '-');
    if (clean.isEmpty) return;
    final dir = Directory('$workspace/$clean');
    if (dir.existsSync() && dir.listSync().isNotEmpty) {
      setState(() => error = '"$clean" already exists. Pick another name, or open it as an existing folder.');
      return;
    }
    dir.createSync(recursive: true);
    Navigator.pop(context, dir.path);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final recent = widget.agent.integrations.projects.take(4).toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr('New chat'), style: text.titleLarge),
              const SizedBox(height: 4),
              Text(tr('Each chat can have its own folder to work in.'), style: text.bodySmall),
              const SizedBox(height: 16),
              SurfaceCard(
                highlight: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const IconTile(icon: LucideIcons.folderPlus),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(tr('New project'), style: text.titleSmall),
                              Text(tr('A fresh folder in the workspace'), style: text.bodySmall),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: name,
                      autocorrect: false,
                      style: const TextStyle(fontFamily: mono, fontSize: 14),
                      decoration: InputDecoration(
                        prefixText: 'workspace/',
                        prefixStyle: TextStyle(fontFamily: mono, fontSize: 14, color: p.faint),
                        errorText: error,
                        errorMaxLines: 3,
                      ),
                      onChanged: (_) {
                        if (error != null) setState(() => error = null);
                      },
                      onSubmitted: (_) => _createProject(),
                    ),
                    const SizedBox(height: 12),
                    PrimaryButton(
                      label: tr('Create and start'),
                      icon: LucideIcons.arrowRight,
                      onPressed: _createProject,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: LucideIcons.folderOpen,
                    color: const Color(0xFF14B8A6),
                    title: tr('Open a folder'),
                    subtitle: tr('Continue in an existing project folder'),
                    onTap: () => Navigator.pop(context, _pick),
                  ),
                  SettingsRow(
                    icon: LucideIcons.messageSquare,
                    color: p.muted,
                    title: tr('Quick chat'),
                    subtitle: tr('No project folder; works in the workspace root'),
                    onTap: () => Navigator.pop(context, ''),
                  ),
                ],
              ),
              if (recent.isNotEmpty) ...[
                const SectionLabel('Recent projects', padding: EdgeInsets.fromLTRB(4, 20, 4, 8)),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final pr in recent)
                      ActionChip(
                        avatar: Icon(pr.isGit ? LucideIcons.folderGit2 : LucideIcons.folder, size: 15, color: p.accent),
                        label: Text(pr.name, style: const TextStyle(fontFamily: mono, fontSize: 12.5)),
                        backgroundColor: p.raised,
                        side: BorderSide(color: p.border),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                        onPressed: () => Navigator.pop(context, pr.path),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
