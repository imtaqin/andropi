import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/features.dart';
import 'i18n.dart';
import 'changes_screen.dart';
import 'editor_screen.dart';
import 'files_screen.dart';
import 'git_screen.dart';
import 'kit.dart';
import 'preview_screen.dart';
import 'search_screen.dart';
import 'tasks_screen.dart';
import 'theme.dart';
import 'usage_screen.dart';

// ---------------------------------------------------------------------------
// Attachments

/// A file or picture attached to the next message.
class Attachment {
  Attachment(this.path, this.name, {this.mime});
  final String path;
  final String name;
  final String? mime;

  static const _imageTypes = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'webp': 'image/webp',
    'gif': 'image/gif',
  };

  String get ext => name.contains('.') ? name.split('.').last.toLowerCase() : '';
  String? get imageMime => mime?.startsWith('image/') == true ? mime : _imageTypes[ext];
  bool get isImage => imageMime != null;
}

/// Pictures go to the model as images; other files are copied into the
/// project's `.attachments/` folder and referenced by path in the message.
Future<({String text, List<Map<String, String>> images})> preparePrompt(
  String text,
  List<Attachment> attachments,
  String cwd,
) async {
  final images = <Map<String, String>>[];
  final paths = <String>[];
  for (final a in attachments) {
    final file = File(a.path);
    if (!file.existsSync()) continue;
    if (a.isImage && file.lengthSync() < 8 * 1024 * 1024) {
      images.add({'type': 'image', 'data': base64Encode(await file.readAsBytes()), 'mimeType': a.imageMime!});
    } else {
      final dir = Directory('$cwd/.attachments')..createSync(recursive: true);
      final target = '${dir.path}/${a.name}';
      await file.copy(target);
      paths.add(target);
    }
  }
  final note = paths.isEmpty ? '' : '\n\nAttached files:\n${paths.map((p) => '- $p').join('\n')}';
  return (text: '$text$note'.trim(), images: images);
}

Future<List<Attachment>> pickAttachments(BuildContext context) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: SettingsGroup(
          children: [
            SettingsRow(
              icon: LucideIcons.images,
              color: const Color(0xFF3E63DD),
              title: tr('Photos'),
              subtitle: tr('Screenshots, sketches, error photos'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            SettingsRow(
              icon: LucideIcons.camera,
              color: const Color(0xFF30A46C),
              title: tr('Camera'),
              subtitle: tr('Take a picture now'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            SettingsRow(
              icon: LucideIcons.paperclip,
              color: const Color(0xFFF76B15),
              title: tr('Files'),
              subtitle: tr('PDFs, code, data, anything'),
              onTap: () => Navigator.pop(context, 'files'),
            ),
          ],
        ),
      ),
    ),
  );
  final picker = ImagePicker();
  switch (choice) {
    case 'gallery':
      final images = await picker.pickMultiImage(imageQuality: 85, maxWidth: 2048);
      return [for (final x in images) Attachment(x.path, x.name, mime: x.mimeType)];
    case 'camera':
      final x = await picker.pickImage(source: ImageSource.camera, imageQuality: 85, maxWidth: 2048);
      return x == null ? [] : [Attachment(x.path, x.name, mime: x.mimeType)];
    case 'files':
      final files = await FilePicker.pickFiles();
      return [
        for (final f in files)
          if (f.path != null) Attachment(f.path!, f.name),
      ];
  }
  return const [];
}

/// Thumbnails / chips of what will be sent with the next message.
class AttachmentStrip extends StatelessWidget {
  const AttachmentStrip({super.key, required this.items, required this.onRemove});
  final List<Attachment> items;
  final void Function(Attachment) onRemove;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SizedBox(
      height: 68,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final a = items[i];
          return Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: a.isImage
                    ? Image.file(File(a.path), width: 56, height: 56, fit: BoxFit.cover)
                    : Container(
                        width: 120,
                        height: 56,
                        color: p.raised,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        alignment: Alignment.centerLeft,
                        child: Row(
                          children: [
                            Icon(LucideIcons.fileText, size: 16, color: p.muted),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                a.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11, color: p.text),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
              Positioned(
                right: -6,
                top: -6,
                child: GestureDetector(
                  onTap: () => onRemove(a),
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(color: p.text, shape: BoxShape.circle),
                    child: Icon(LucideIcons.x, size: 12, color: p.inverse),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Approvals

/// Asks once before turning every approval off, since pi can then delete files or push without asking.
Future<bool> confirmBypass(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Bypass all permissions?')),
        content: Text(tr('pi will run every command, edit any file and use every tool without asking.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Bypass'))),
        ],
      ),
    ) ??
    false;

class ApprovalCards extends StatelessWidget {
  const ApprovalCards({super.key, required this.features});
  final Features features;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: features,
      builder: (context, _) {
        if (features.approvals.isEmpty) return const SizedBox.shrink();
        final a = features.approvals.first;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: p.warning.withValues(alpha: 0.6), width: 1.2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconTile(icon: toolIcon(a.toolName), color: p.warning, size: 32),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Allow ${a.toolName}?', style: text.titleSmall),
                          Text(a.reason, style: text.bodySmall),
                        ],
                      ),
                    ),
                    if (features.approvals.length > 1) Pill('+${features.approvals.length - 1}', color: p.muted),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 110),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(12)),
                  child: SingleChildScrollView(
                    child: Text(
                      a.summary,
                      style: TextStyle(fontFamily: mono, fontSize: 12, color: p.text, height: 1.45),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => features.answer(a, allow: false),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42), foregroundColor: p.danger),
                        child: Text(tr('Deny')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => features.answer(a, allow: true, always: true),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
                        child: Text(tr('Always')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => features.answer(a, allow: true),
                        style: FilledButton.styleFrom(minimumSize: const Size(0, 42)),
                        child: Text(tr('Allow')),
                      ),
                    ),
                  ],
                ),
                TextButton.icon(
                  onPressed: () async {
                    if (!await confirmBypass(context)) return;
                    await features.client.call('settings_set', {
                      'settings': {'approvalMode': 'auto'},
                    });
                    for (final pending in [...features.approvals]) {
                      await features.answer(pending, allow: true);
                    }
                  },
                  style: TextButton.styleFrom(foregroundColor: p.muted),
                  icon: const Icon(LucideIcons.shieldOff, size: 16),
                  label: Text(tr('Bypass all permissions')),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Plan mode

/// After the agent answers in plan mode: approve and run, or keep planning.
class PlanBar extends StatelessWidget {
  const PlanBar({super.key, required this.agent});
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (!agent.planMode || agent.busy || agent.entries.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        decoration: BoxDecoration(color: p.accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(18)),
        child: Row(
          children: [
            Icon(LucideIcons.listChecks, size: 18, color: p.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(tr('Plan mode'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
            ),
            TextButton(onPressed: () => agent.setPlanMode(false), child: Text(tr('Exit'))),
            FilledButton(
              onPressed: agent.approvePlan,
              style: FilledButton.styleFrom(minimumSize: const Size(0, 38)),
              child: Text(tr('Approve & run')),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dev servers

/// A server the agent started: preview it, or share a public link.
class DevServerBanner extends StatefulWidget {
  const DevServerBanner({super.key, required this.agent});
  final AgentController agent;

  @override
  State<DevServerBanner> createState() => _DevServerBannerState();
}

class _DevServerBannerState extends State<DevServerBanner> {
  final opening = <int>{};

  Future<void> _share(int port) async {
    final f = widget.agent.features;
    setState(() => opening.add(port));
    try {
      final url = f.tunnels[port] ?? await f.startTunnel(port);
      await Clipboard.setData(ClipboardData(text: url));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Public link copied: $url'),
            action: SnackBarAction(label: tr('Open'), onPressed: () => widget.agent.client.openUrl(url)),
          ),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => opening.remove(port));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final f = widget.agent.features;
    return ListenableBuilder(
      listenable: f,
      builder: (context, _) {
        if (f.devServers.isEmpty) return const SizedBox.shrink();
        return Column(
          children: [
            for (final e in f.devServers.entries)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                  decoration: BoxDecoration(
                    color: p.success.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: p.success, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          f.tunnels[e.key] ?? 'localhost:${e.key}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontFamily: mono, fontSize: 12.5, color: p.text),
                        ),
                      ),
                      TextButton(
                        onPressed: () => HtmlPreviewScreen.openUrl(context, title: 'localhost:${e.key}', url: e.value),
                        child: Text(tr('Preview')),
                      ),
                      opening.contains(e.key)
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          : IconButton(
                              tooltip: tr('Share a public link'),
                              icon: const Icon(LucideIcons.share2, size: 18),
                              onPressed: () => _share(e.key),
                            ),
                      IconButton(
                        tooltip: tr('Dismiss'),
                        icon: Icon(LucideIcons.x, size: 16, color: p.muted),
                        onPressed: () {
                          if (f.tunnels.containsKey(e.key)) f.stopTunnel(e.key);
                          f.dismissDevServer(e.key);
                        },
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Slash commands

/// Suggestions while the message starts with "/": templates and skills.
class SlashMenu extends StatelessWidget {
  const SlashMenu({super.key, required this.commands, required this.query, required this.onPick});
  final List<SlashCommand> commands;
  final String query;
  final void Function(SlashCommand) onPick;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final q = query.toLowerCase();
    final matches = commands.where((c) => c.name.toLowerCase().contains(q)).take(8).toList();
    if (matches.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: p.bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 20, offset: const Offset(0, 6))],
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 6),
        children: [
          for (final c in matches)
            ListTile(
              dense: true,
              leading: Icon(c.isSkill ? LucideIcons.puzzle : LucideIcons.slash, size: 18, color: p.accent),
              title: Text(
                '/${c.name}${c.hint != null ? '  ${c.hint}' : ''}',
                style: TextStyle(fontFamily: mono, fontSize: 13, color: p.text),
              ),
              subtitle: Text(c.description, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => onPick(c),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Project tools menu

Future<void> showProjectTools(
  BuildContext context,
  AgentController agent, {
  required void Function(String prompt) onPrompt,
}) async {
  void push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
  final memory = '${agent.cwd}/AGENTS.md';
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) {
      void go(Widget w) {
        Navigator.pop(sheet);
        push(w);
      }

      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr('Project'), style: Theme.of(sheet).textTheme.titleLarge),
              const SizedBox(height: 12),
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: LucideIcons.folderOpen,
                    color: const Color(0xFFF76B15),
                    title: tr('Files'),
                    subtitle: tr('Browse and edit the project'),
                    onTap: () => go(FilesScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.search,
                    color: const Color(0xFF3E63DD),
                    title: tr('Search'),
                    subtitle: tr('Find text across every file'),
                    onTap: () => go(SearchScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.history,
                    color: const Color(0xFF7C5CFC),
                    title: tr('Changes & undo'),
                    subtitle: tr('What pi changed, and roll it back'),
                    onTap: () => go(ChangesScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.gitBranch,
                    color: const Color(0xFF111113),
                    title: tr('Git'),
                    subtitle: tr('Commit, push, branches, issues and PRs'),
                    onTap: () => go(GitScreen(agent: agent, onWork: onPrompt)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.brain,
                    color: const Color(0xFFEC4899),
                    title: tr('Project memory'),
                    subtitle: tr('AGENTS.md: rules pi follows in this folder'),
                    onTap: () {
                      final f = File(memory);
                      if (!f.existsSync()) {
                        f.writeAsStringSync('# Project notes for pi\n\n- Stack:\n- How to run:\n- Conventions:\n');
                      }
                      go(EditorScreen(agent: agent, path: memory));
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: LucideIcons.listTodo,
                    color: const Color(0xFF14B8A6),
                    title: tr('Background tasks'),
                    subtitle: tr('Queue, parallel agents and schedules'),
                    onTap: () => go(TasksScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.chartColumn,
                    color: const Color(0xFFF59E0B),
                    title: tr('Usage'),
                    subtitle: tr('Tokens and cost'),
                    onTap: () => go(UsageScreen(agent: agent)),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
