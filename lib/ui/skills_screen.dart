import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/integrations.dart';
import 'kit.dart';
import 'message_views.dart';
import 'task_log.dart';
import 'theme.dart';

/// Curated places to browse skills from.
const _collections = [
  ('anthropics/skills', 'Anthropic', 'Documents, design, web testing, MCP'),
  ('badlogic/pi-skills', 'pi skills', 'Made for the pi agent'),
];

/// Agent Skills: SKILL.md folders pi loads when a task calls for them.
class SkillsScreen extends StatefulWidget {
  const SkillsScreen({super.key, required this.agent, this.embedded = false});
  final AgentController agent;

  /// Shown as a home tab: large title, room for the floating nav bar.
  final bool embedded;

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  Integrations get it => widget.agent.integrations;
  late Future<List<SkillInfo>> installed = it.skills();
  late Future<List<SkillHit>> recommended = it.searchSkills('');
  Future<List<SkillHit>>? results;
  final query = TextEditingController();
  final link = TextEditingController();
  Timer? debounce;
  final installing = <String>{};
  String lastQuery = '';

  @override
  void initState() {
    super.initState();
    // A listener, not onChanged: pasted and IME-committed text count too.
    query.addListener(() {
      if (query.text == lastQuery) return;
      lastQuery = query.text;
      _onQuery(query.text);
    });
  }

  @override
  void dispose() {
    debounce?.cancel();
    query.dispose();
    link.dispose();
    super.dispose();
  }

  void _onQuery(String v) {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      setState(() {
        results = v.trim().isEmpty ? null : it.searchSkills(v.trim());
      });
    });
  }

  void _reload() => setState(() {
    installed = it.skills();
    recommended = it.searchSkills('');
    if (query.text.trim().isNotEmpty) results = it.searchSkills(query.text.trim());
  });

  /// Quiet install from a result row; the row shows progress.
  Future<void> _installHit(SkillHit hit) async {
    setState(() => installing.add(hit.spec));
    try {
      await it.installSkill(hit.spec);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Installed ${hit.name}')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) {
        installing.remove(hit.spec);
        _reload();
      }
    }
  }

  Future<void> _installLink(String source) async {
    if (source.trim().isEmpty) return;
    FocusScope.of(context).unfocus();
    final added = await runWithLog<List<SkillInfo>>(
      context,
      title: 'Installing skill',
      task: (log, _) => it.installSkill(source, onLine: log),
    );
    if (added != null) {
      link.clear();
      _reload();
    }
  }

  Future<void> _browse(String repo, String title) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BrowseSheet(integrations: it, repo: repo, title: title, onInstall: _installLink),
    );
    _reload();
  }

  Future<void> _open(SkillInfo s) async {
    final body = await File('${s.path}/SKILL.md').readAsString().catchError((_) => '');
    if (!mounted) return;
    final remove = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          children: [
            Row(
              children: [
                _SkillIcon(builtin: s.builtin, origin: s.source),
                const SizedBox(width: 12),
                Expanded(child: Text(s.name, style: Theme.of(context).textTheme.titleLarge)),
                TextButton.icon(
                  onPressed: () => Navigator.pop(context, true),
                  style: TextButton.styleFrom(foregroundColor: context.palette.danger),
                  icon: const Icon(LucideIcons.trash2, size: 16),
                  label: const Text('Remove'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              s.source,
              style: TextStyle(fontFamily: mono, fontSize: 11.5, color: context.palette.faint),
            ),
            const SizedBox(height: 16),
            MarkdownText(body.replaceFirst(RegExp(r'^---[\s\S]*?\n---\s*'), '')),
          ],
        ),
      ),
    );
    if (remove == true) {
      await it.removeSkill(s.path);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final searching = results != null;
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('Skills')),
      body: ListView(
        padding: widget.embedded
            ? EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + 12, 20, 130)
            : const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          if (widget.embedded) ...[Text('Skills', style: text.displaySmall), const SizedBox(height: 16)],
          TextField(
            controller: query,
            textInputAction: TextInputAction.search,
            onSubmitted: (v) {
              debounce?.cancel();
              setState(() {
                results = v.trim().isEmpty ? null : it.searchSkills(v.trim());
              });
            },
            decoration: InputDecoration(
              hintText: 'Search skills: design, pdf, testing…',
              prefixIcon: const Icon(LucideIcons.search, size: 18),
              suffixIcon: query.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(LucideIcons.x, size: 16),
                      onPressed: () {
                        query.clear();
                        setState(() => results = null);
                      },
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Searches Anthropic and pi collections, skills.md${it.github != null ? ', and all of GitHub' : ''}.',
            style: text.bodySmall,
          ),
          if (searching) ...[
            const SectionLabel('Results'),
            _HitList(future: results!, installing: installing, onInstall: _installHit, emptyText: 'No skills match.'),
          ] else ...[
            const SectionLabel('Recommended'),
            _HitList(
              future: recommended.then((l) => l.where((h) => !h.installed).take(6).toList()),
              installing: installing,
              onInstall: _installHit,
              emptyText: 'You have all the recommended skills.',
            ),
            const SectionLabel('Installed'),
            FutureBuilder<List<SkillInfo>>(
              future: installed,
              builder: (context, snap) {
                if (!snap.hasData) return const _Loading();
                final list = snap.data!;
                if (list.isEmpty) return Text('No skills yet.', style: text.bodySmall);
                return SettingsGroup(
                  children: [
                    for (final s in list)
                      SettingsRow(
                        leading: _SkillIcon(builtin: s.builtin, origin: s.source),
                        title: s.name,
                        subtitle: s.description,
                        trailing: s.builtin ? Pill('AndroPI', color: p.accent) : null,
                        onTap: () => _open(s),
                      ),
                  ],
                );
              },
            ),
            const SectionLabel('Add from a link'),
            SurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'A GitHub repo or folder (owner/repo/path), a skills.md name, or a link to a SKILL.md.',
                    style: text.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: link,
                          autocorrect: false,
                          style: const TextStyle(fontFamily: mono, fontSize: 13),
                          decoration: const InputDecoration(
                            hintText: 'owner/repo/skills/name',
                            prefixIcon: Icon(LucideIcons.link, size: 16),
                          ),
                          onSubmitted: _installLink,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: () => _installLink(link.text), child: const Text('Add')),
                    ],
                  ),
                ],
              ),
            ),
            const SectionLabel('Browse'),
            SettingsGroup(
              children: [
                for (final (repo, title, blurb) in _collections)
                  SettingsRow(
                    leading: IconTile(icon: SimpleIcons.github, color: p.text),
                    title: title,
                    subtitle: '$repo · $blurb',
                    onTap: () => _browse(repo, title),
                  ),
                SettingsRow(
                  icon: LucideIcons.store,
                  color: const Color(0xFF14B8A6),
                  title: 'skills.md',
                  subtitle: 'Hosted skills; most need the skills.md CLI',
                  trailing: Icon(LucideIcons.externalLink, size: 16, color: p.faint),
                  onTap: () => widget.agent.client.openUrl('https://skills.md'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'pi sees each skill\'s name and description, and reads the full instructions only when a task needs '
              'them. Force one in chat with /skill:name.',
              style: text.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(24),
    child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
  );
}

/// The mark for where a skill comes from.
class _SkillIcon extends StatelessWidget {
  const _SkillIcon({required this.origin, this.builtin = false});
  final String origin;
  final bool builtin;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final o = origin.toLowerCase();
    if (builtin || o == 'andropi') return IconTile(icon: LucideIcons.sparkles, color: p.accent);
    if (o.contains('anthropic')) return IconTile(icon: SimpleIcons.anthropic, color: const Color(0xFFD97757));
    if (o.contains('skills.md')) return const IconTile(icon: LucideIcons.store, color: Color(0xFF14B8A6));
    if (o.contains('pi skills') || o.contains('pi-skills')) return IconTile(icon: LucideIcons.pi, color: p.accentAlt);
    if (o.contains('/') || o.contains('github')) return IconTile(icon: SimpleIcons.github, color: p.text);
    return const IconTile(icon: LucideIcons.puzzle, color: Color(0xFFEC4899));
  }
}

class _HitList extends StatelessWidget {
  const _HitList({required this.future, required this.installing, required this.onInstall, required this.emptyText});
  final Future<List<SkillHit>> future;
  final Set<String> installing;
  final Future<void> Function(SkillHit) onInstall;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return FutureBuilder<List<SkillHit>>(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) return Text('${snap.error}', style: text.bodySmall);
        if (!snap.hasData) return const _Loading();
        final hits = snap.data!;
        if (hits.isEmpty) return Text(emptyText, style: text.bodySmall);
        return Column(
          children: [
            for (final h in hits) ...[
              SurfaceCard(
                padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SkillIcon(origin: h.origin),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(h.name, style: text.titleSmall),
                          const SizedBox(height: 2),
                          Text(
                            h.origin,
                            style: TextStyle(fontFamily: mono, fontSize: 11, color: p.faint),
                          ),
                          if (h.description.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(h.description, maxLines: 3, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                          ],
                          if (h.note != null) ...[
                            const SizedBox(height: 6),
                            Pill(h.note!, color: p.warning, icon: LucideIcons.info),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (h.installed)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Icon(LucideIcons.circleCheck, size: 20, color: p.success),
                      )
                    else if (installing.contains(h.spec))
                      const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    else
                      IconButton(
                        tooltip: 'Install ${h.name}',
                        onPressed: () => onInstall(h),
                        icon: Icon(LucideIcons.download, size: 18, color: p.accent),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ],
        );
      },
    );
  }
}

class _BrowseSheet extends StatefulWidget {
  const _BrowseSheet({required this.integrations, required this.repo, required this.title, required this.onInstall});
  final Integrations integrations;
  final String repo;
  final String title;
  final Future<void> Function(String source) onInstall;

  @override
  State<_BrowseSheet> createState() => _BrowseSheetState();
}

class _BrowseSheetState extends State<_BrowseSheet> {
  late Future<List<RemoteSkill>> list = widget.integrations.browseSkills(widget.repo);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Row(
              children: [
                IconTile(icon: SimpleIcons.github, color: p.text),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.title, style: text.titleMedium),
                      Text(
                        widget.repo,
                        style: TextStyle(fontFamily: mono, fontSize: 11.5, color: p.faint),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<List<RemoteSkill>>(
              future: list,
              builder: (context, snap) {
                if (snap.hasError) {
                  return Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text('${snap.error}', style: text.bodySmall),
                  );
                }
                if (!snap.hasData) return const _Loading();
                final skills = snap.data!;
                return ListView.separated(
                  controller: scroll,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: skills.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final s = skills[i];
                    return SurfaceCard(
                      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                      child: Row(
                        children: [
                          _SkillIcon(origin: widget.repo),
                          const SizedBox(width: 12),
                          Expanded(child: Text(s.name, style: text.titleSmall)),
                          s.installed
                              ? Pill('Installed', color: p.success, icon: LucideIcons.check)
                              : TextButton.icon(
                                  onPressed: () async {
                                    await widget.onInstall(s.source);
                                    if (mounted) {
                                      setState(() {
                                        list = widget.integrations.browseSkills(widget.repo);
                                      });
                                    }
                                  },
                                  icon: const Icon(LucideIcons.download, size: 15),
                                  label: const Text('Install'),
                                ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
