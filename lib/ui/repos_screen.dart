import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/integrations.dart';
import 'accounts_screen.dart';
import 'task_log.dart';
import 'theme.dart';

/// Pick a GitHub repository, clone it into the workspace and start a session in it.
class ReposScreen extends StatefulWidget {
  const ReposScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<ReposScreen> createState() => _ReposScreenState();
}

class _ReposScreenState extends State<ReposScreen> {
  Integrations get it => widget.agent.integrations;
  Future<List<RepoInfo>>? repos;
  String query = '';

  @override
  void initState() {
    super.initState();
    if (it.github != null) repos = it.repos();
  }

  Future<void> _open(RepoInfo repo) async {
    final path = await runWithLog<String>(
      context,
      title: repo.cloned ? 'Opening ${repo.name}' : 'Cloning ${repo.fullName}',
      task: (log, _) => it.clone(repo.fullName, onLine: log),
    );
    if (path == null || !mounted) return;
    await widget.agent.newSession(dir: path);
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Open a repository'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: p.border),
        ),
      ),
      body: it.github == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(SimpleIcons.github, size: 32, color: p.muted),
                    const SizedBox(height: 12),
                    Text('Connect GitHub to see your repositories', style: text.titleSmall),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () async {
                        await Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => AccountsScreen(agent: widget.agent)));
                        if (mounted && it.github != null) {
                          setState(() {
                            repos = it.repos();
                          });
                        }
                      },
                      child: const Text('Connect GitHub'),
                    ),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: TextField(
                    onChanged: (v) => setState(() => query = v.toLowerCase()),
                    decoration: const InputDecoration(
                      hintText: 'Search repositories',
                      prefixIcon: Icon(LucideIcons.search, size: 18),
                    ),
                  ),
                ),
                Expanded(
                  child: FutureBuilder<List<RepoInfo>>(
                    future: repos,
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return Center(child: Text(snap.error.toString(), style: text.bodySmall));
                      }
                      if (!snap.hasData) {
                        return const Center(
                          child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        );
                      }
                      final list = snap.data!
                          .where((r) => query.isEmpty || r.fullName.toLowerCase().contains(query))
                          .toList();
                      return RefreshIndicator(
                        onRefresh: () async {
                          final next = it.repos();
                          setState(() {
                            repos = next;
                          });
                          await next;
                        },
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                          itemCount: list.length,
                          separatorBuilder: (_, _) => Divider(height: 1, indent: 16, endIndent: 16, color: p.border),
                          itemBuilder: (context, i) => _RepoTile(repo: list[i], onTap: () => _open(list[i])),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _RepoTile extends StatelessWidget {
  const _RepoTile({required this.repo, required this.onTap});
  final RepoInfo repo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final meta = [
      ?repo.language,
      if (repo.stars > 0) '★ ${repo.stars}',
      if (repo.pushedAt != null) _ago(repo.pushedAt!),
    ].join('  ·  ');
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(repo.isPrivate ? LucideIcons.lock : LucideIcons.bookMarked, size: 18, color: p.muted),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(repo.fullName, style: text.titleSmall),
                  if (repo.description != null) ...[
                    const SizedBox(height: 3),
                    Text(repo.description!, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                  ],
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(meta, style: text.labelSmall?.copyWith(color: p.faint)),
                  ],
                ],
              ),
            ),
            if (repo.cloned)
              Container(
                margin: const EdgeInsets.only(left: 8, top: 2),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: p.border),
                ),
                child: Text('On device', style: text.labelSmall),
              ),
          ],
        ),
      ),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inHours < 1) return 'updated just now';
    if (d.inDays < 1) return 'updated ${d.inHours}h ago';
    if (d.inDays < 30) return 'updated ${d.inDays}d ago';
    return 'updated ${t.year}-${t.month.toString().padLeft(2, '0')}';
  }
}
