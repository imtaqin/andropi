import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/features.dart';
import 'diff_view.dart';
import 'illustration.dart';
import 'kit.dart';
import 'message_views.dart';
import 'task_log.dart';
import 'theme.dart';

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 30) return '${d.inDays}d ago';
  if (d.inDays < 365) return '${d.inDays ~/ 30}mo ago';
  return '${d.inDays ~/ 365}y ago';
}

enum _Section { staged, unstaged, untracked }

/// Source control for the current project: stage and commit, branches,
/// pull/push, history, and GitHub issues the agent can pick up.
class GitScreen extends StatefulWidget {
  const GitScreen({super.key, required this.agent, this.onWork});
  final AgentController agent;

  /// Hands a GitHub issue to the agent as a prompt; the screen pops afterwards.
  final void Function(String prompt)? onWork;

  @override
  State<GitScreen> createState() => _GitScreenState();
}

class _GitScreenState extends State<GitScreen> {
  Features get _f => widget.agent.features;

  GitStatus? _status;
  List<GitCommit>? _log;
  String? _repo;
  List<GithubIssue>? _issues;
  Object? _issuesError;
  int _tab = 0;
  bool _commitAll = false;
  bool _committing = false;
  final _busyPaths = <String>{};
  final _message = TextEditingController();

  bool get _github => _status?.remote?.contains('github.com') ?? false;

  @override
  void initState() {
    super.initState();
    _message.addListener(() => setState(() {}));
    _refresh();
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  void _error(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }

  void _snack(String s, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s), action: action));
  }

  Future<void> _refresh() async {
    try {
      final s = await _f.gitStatus();
      if (!mounted) return;
      setState(() => _status = s);
      if (!s.isRepo) return;
      if (_tab == 1 || _log != null) await _loadLog();
      if (_tab == 2 || _issues != null) await _loadIssues();
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _loadLog() async {
    try {
      final l = await _f.gitLog();
      if (mounted) setState(() => _log = l);
    } catch (e) {
      if (mounted) setState(() => _log ??= const []);
      _error(e);
    }
  }

  Future<void> _loadIssues() async {
    if (!_github) return;
    try {
      final (repo, list) = await _f.issues();
      if (mounted) {
        setState(() {
          _repo = repo;
          _issues = list;
          _issuesError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _issuesError = e);
    }
  }

  void _setTab(int i) {
    setState(() => _tab = i);
    if (i == 1 && _log == null) _loadLog();
    if (i == 2 && _issues == null && _issuesError == null) _loadIssues();
  }

  // Actions -------------------------------------------------------------------

  Future<void> _apply(Future<GitStatus> Function() op, {Iterable<String> paths = const []}) async {
    setState(() => _busyPaths.addAll(paths));
    try {
      final s = await op();
      if (mounted) setState(() => _status = s);
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _busyPaths.removeAll(paths));
    }
  }

  Future<void> _discard(GitFile file) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: Text(
          file.untracked
              ? '${file.path} is untracked and will be deleted. This cannot be undone.'
              : 'Your changes to ${file.path} will be lost. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Discard', style: TextStyle(color: context.palette.danger)),
          ),
        ],
      ),
    );
    if (ok == true) await _apply(() => _f.gitDiscard([file.path]), paths: [file.path]);
  }

  Future<void> _commit() async {
    final msg = _message.text.trim();
    if (msg.isEmpty) return;
    setState(() => _committing = true);
    try {
      final hash = await _f.gitCommit(msg, all: _commitAll);
      _message.clear();
      _snack('Committed ${hash.length > 7 ? hash.substring(0, 7) : hash}');
      _log = null;
      await _refresh();
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  Future<void> _pullPush({required bool push}) async {
    await runWithLog<void>(
      context,
      title: push ? 'Push' : 'Pull',
      task: (log, _) => push ? _f.gitPush(onLine: log) : _f.gitPull(onLine: log),
      openUrl: widget.agent.client.openUrl,
    );
    _log = null;
    await _refresh();
  }

  Future<void> _branches() async {
    final s = await showModalBottomSheet<GitStatus>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BranchSheet(features: _f),
    );
    if (s != null && mounted) {
      setState(() {
        _status = s;
        _log = null;
      });
      await _refresh();
    }
  }

  Future<void> _showDiff(GitFile file, _Section section) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (context, scroll) =>
            _DiffSheet(features: _f, file: file, staged: section == _Section.staged, scroll: scroll),
      ),
    );
  }

  Future<void> _createPr() async {
    final url = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PrSheet(features: _f, branch: _status?.branch ?? ''),
    );
    if (url == null) return;
    _snack(
      'Pull request created',
      action: SnackBarAction(label: 'Open', onPressed: () => widget.agent.client.openUrl(url)),
    );
  }

  void _work(GithubIssue issue) {
    final body = issue.body.trim();
    final prompt = [
      'Work on GitHub issue #${issue.number}: ${issue.title}',
      if (body.isNotEmpty) body,
      issue.url,
      'Create a branch, implement the fix with tests, commit, and open a pull request that closes the issue.',
    ].join('\n\n');
    widget.onWork?.call(prompt);
    Navigator.of(context).pop();
  }

  Future<void> _openIssue(GithubIssue issue) async {
    final work = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, scroll) => _IssueSheet(
          issue: issue,
          scroll: scroll,
          onOpen: () => widget.agent.client.openUrl(issue.url),
          canWork: widget.onWork != null && !issue.isPr,
        ),
      ),
    );
    if (work == true && mounted) _work(issue);
  }

  // Build ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final s = _status;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Git'),
        actions: [IconButton(tooltip: 'Refresh', icon: const Icon(LucideIcons.refreshCw), onPressed: _refresh)],
      ),
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : !s.isRepo
          ? _notRepo(context)
          : Column(
              children: [
                Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 0), child: _header(context, s)),
                Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: _tabs(context, s)),
                Expanded(
                  child: switch (_tab) {
                    0 => _changesTab(context, s),
                    1 => _historyTab(context),
                    _ => _issuesTab(context),
                  },
                ),
              ],
            ),
    );
  }

  Widget _notRepo(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(32, 60, 32, 40),
        children: [
          const Illustration('git', height: 160),
          const SizedBox(height: 20),
          Text('Not a git repository', textAlign: TextAlign.center, style: text.titleMedium),
          const SizedBox(height: 6),
          Text(
            "This folder isn't a git repository. Ask pi to run `git init`, or clone a repo.",
            textAlign: TextAlign.center,
            style: text.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, GitStatus s) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _branches,
            child: Row(
              children: [
                IconTile(icon: LucideIcons.gitBranch, color: p.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.branch.isEmpty ? '(detached)' : s.branch,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium?.copyWith(fontFamily: mono),
                      ),
                      Text(
                        s.upstream ?? 'No upstream',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(fontFamily: mono),
                      ),
                    ],
                  ),
                ),
                Icon(LucideIcons.chevronsUpDown, size: 18, color: p.faint),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Pill('${s.ahead}', icon: LucideIcons.arrowUp, color: s.ahead > 0 ? p.accentAlt : null),
              const SizedBox(width: 6),
              Pill('${s.behind}', icon: LucideIcons.arrowDown, color: s.behind > 0 ? p.warning : null),
              const Spacer(),
              _SmallButton(icon: LucideIcons.download, label: 'Pull', onTap: () => _pullPush(push: false)),
              const SizedBox(width: 8),
              _SmallButton(icon: LucideIcons.upload, label: 'Push', onTap: () => _pullPush(push: true)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tabs(BuildContext context, GitStatus s) {
    final count = s.files.length;
    final labels = ['Changes${count > 0 ? ' ($count)' : ''}', 'History', 'Issues & PRs'];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            _TabChip(label: labels[i], selected: _tab == i, onTap: () => _setTab(i)),
          ],
        ],
      ),
    );
  }

  // Changes tab ---------------------------------------------------------------

  Widget _changesTab(BuildContext context, GitStatus s) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final staged = s.files.where((f) => f.staged).toList();
    final unstaged = s.files.where((f) => f.unstaged && !f.untracked).toList();
    final untracked = s.files.where((f) => f.untracked).toList();
    final canCommit = _message.text.trim().isNotEmpty && (staged.isNotEmpty || (_commitAll && s.files.isNotEmpty));

    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                if (s.files.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 40),
                    child: Column(
                      children: [
                        Icon(LucideIcons.circleCheck, size: 36, color: p.success),
                        const SizedBox(height: 12),
                        Text('Working tree clean', style: text.titleMedium),
                        const SizedBox(height: 4),
                        Text('No changes to commit', style: text.bodySmall),
                      ],
                    ),
                  ),
                if (staged.isNotEmpty)
                  _section(
                    context,
                    'Staged',
                    staged,
                    _Section.staged,
                    action: ('Unstage all', () => _apply(() => _f.gitUnstage(null))),
                  ),
                if (unstaged.isNotEmpty)
                  _section(
                    context,
                    'Unstaged',
                    unstaged,
                    _Section.unstaged,
                    action: ('Stage all', () => _apply(() => _f.gitStage(null))),
                  ),
                if (untracked.isNotEmpty)
                  _section(
                    context,
                    'Untracked',
                    untracked,
                    _Section.untracked,
                    action: ('Stage all', () => _apply(() => _f.gitStage(untracked.map((f) => f.path).toList()))),
                  ),
                if (s.files.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text('Long-press a file to discard its changes.', style: text.bodySmall),
                  ),
              ],
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: p.bg,
            border: Border(top: BorderSide(color: p.border)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _message,
                  minLines: 1,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(hintText: 'Commit message'),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => setState(() => _commitAll = !_commitAll),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _commitAll ? LucideIcons.squareCheck : LucideIcons.square,
                              size: 18,
                              color: _commitAll ? p.text : p.muted,
                            ),
                            const SizedBox(width: 6),
                            Text('Commit all changes', style: text.bodySmall?.copyWith(color: p.text)),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (_github)
                      TextButton.icon(
                        onPressed: _createPr,
                        icon: const Icon(LucideIcons.gitPullRequest, size: 16),
                        label: const Text('Create pull request'),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                PrimaryButton(
                  label: 'Commit',
                  icon: LucideIcons.gitCommitHorizontal,
                  busy: _committing,
                  onPressed: canCommit ? _commit : null,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _section(
    BuildContext context,
    String title,
    List<GitFile> files,
    _Section section, {
    required (String, VoidCallback) action,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(
          '$title (${files.length})',
          padding: const EdgeInsets.fromLTRB(4, 16, 0, 6),
          trailing: TextButton(onPressed: action.$2, child: Text(action.$1)),
        ),
        SettingsGroup(children: [for (final f in files) _fileRow(context, f, section)]),
      ],
    );
  }

  Widget _fileRow(BuildContext context, GitFile f, _Section section) {
    final p = context.palette;
    final staged = section == _Section.staged;
    final busy = _busyPaths.contains(f.path);
    final slash = f.path.lastIndexOf('/');
    final name = slash >= 0 ? f.path.substring(slash + 1) : f.path;
    final dir = slash >= 0 ? f.path.substring(0, slash) : '';
    final code = f.code.trim().isEmpty ? '?' : f.code.trim();
    final letter = section == _Section.untracked ? 'U' : code.substring(0, 1);
    final color = switch (letter) {
      'A' || 'U' => p.success,
      'D' => p.danger,
      'R' || 'C' => p.accentAlt,
      _ => p.warning,
    };
    return InkWell(
      onTap: () => _showDiff(f, section),
      onLongPress: section == _Section.staged ? null : () => _discard(f),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              height: 40,
              child: busy
                  ? Center(
                      child: SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: p.muted),
                      ),
                    )
                  : IconButton(
                      tooltip: staged ? 'Unstage' : 'Stage',
                      icon: Icon(
                        staged ? LucideIcons.squareCheck : LucideIcons.square,
                        size: 20,
                        color: staged ? p.text : p.muted,
                      ),
                      onPressed: () =>
                          _apply(() => staged ? _f.gitUnstage([f.path]) : _f.gitStage([f.path]), paths: [f.path]),
                    ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: mono, fontSize: 13, fontWeight: FontWeight.w600, color: p.text),
                  ),
                  if (dir.isNotEmpty)
                    Text(
                      dir,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: mono, fontSize: 11, color: p.muted),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
              child: Text(
                letter,
                style: TextStyle(fontFamily: mono, fontSize: 11.5, fontWeight: FontWeight.w700, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // History tab ---------------------------------------------------------------

  Widget _historyTab(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final log = _log;
    if (log == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          if (log.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Text('No commits yet', textAlign: TextAlign.center, style: text.bodyMedium),
            )
          else
            SettingsGroup(
              children: [
                for (final c in log)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(8)),
                          child: Text(
                            c.hash.length > 7 ? c.hash.substring(0, 7) : c.hash,
                            style: TextStyle(fontFamily: mono, fontSize: 11.5, color: p.accent),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(c.subject, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.titleSmall),
                              const SizedBox(height: 2),
                              Text(
                                '${c.author} · ${_ago(c.time)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  // Issues tab ----------------------------------------------------------------

  Widget _issuesTab(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    Widget message(String title, String body) => RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(32, 40, 32, 40),
        children: [
          const Illustration('bug', height: 140),
          const SizedBox(height: 16),
          Text(title, textAlign: TextAlign.center, style: text.titleMedium),
          const SizedBox(height: 6),
          Text(body, textAlign: TextAlign.center, style: text.bodySmall),
        ],
      ),
    );

    if (!_github) {
      return message(
        'No GitHub remote',
        'Issues and pull requests are shown when this repository has a github.com remote.',
      );
    }
    if (_issuesError != null && _issues == null) return message("Couldn't load issues", '$_issuesError');
    final issues = _issues;
    if (issues == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          if (_repo != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
              child: Row(
                children: [
                  Icon(SimpleIcons.github, size: 14, color: p.muted),
                  const SizedBox(width: 6),
                  Text(_repo!, style: text.bodySmall?.copyWith(fontFamily: mono)),
                ],
              ),
            ),
          if (issues.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Text('No open issues or pull requests', textAlign: TextAlign.center, style: text.bodyMedium),
            )
          else
            SettingsGroup(
              children: [
                for (final i in issues)
                  InkWell(
                    onTap: () => _openIssue(i),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Icon(
                              i.isPr ? LucideIcons.gitPullRequest : LucideIcons.circleDot,
                              size: 18,
                              color: i.isPr ? p.accent : p.success,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(i.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.titleSmall),
                                const SizedBox(height: 4),
                                Text(
                                  ['#${i.number}', if (i.author != null) i.author!, _ago(i.updatedAt)].join(' · '),
                                  style: text.bodySmall,
                                ),
                                if (i.labels.isNotEmpty || i.isPr) ...[
                                  const SizedBox(height: 6),
                                  Wrap(
                                    spacing: 4,
                                    runSpacing: 4,
                                    children: [
                                      if (i.isPr) Pill('PR', color: p.accent),
                                      for (final l in i.labels) Pill(l),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (i.comments > 0) ...[
                            const SizedBox(width: 8),
                            Icon(LucideIcons.messageSquare, size: 14, color: p.muted),
                            const SizedBox(width: 3),
                            Text('${i.comments}', style: text.bodySmall),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _TabChip extends StatelessWidget {
  const _TabChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: selected ? p.text : p.surface,
      borderRadius: BorderRadius.circular(99),
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Text(
            label,
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: selected ? p.inverse : p.text),
          ),
        ),
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.raised,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: p.text),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lists local and remote branches; pops with the new status after a checkout.
class _BranchSheet extends StatefulWidget {
  const _BranchSheet({required this.features});
  final Features features;

  @override
  State<_BranchSheet> createState() => _BranchSheetState();
}

class _BranchSheetState extends State<_BranchSheet> {
  List<GitBranch>? _branches;
  String? _busy;
  final _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
    widget.features.gitBranches().then(
      (b) {
        if (mounted) setState(() => _branches = b);
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() => _branches = const []);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      },
    );
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _checkout(String name, {bool create = false}) async {
    setState(() => _busy = name);
    try {
      final s = await widget.features.gitCheckout(name, create: create);
      if (mounted) Navigator.of(context).pop(s);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = null);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// A remote branch like `origin/feature` checks out as local `feature`, which
  /// git sets up to track the remote.
  String _localName(GitBranch b) {
    if (!b.remote) return b.name;
    var n = b.name.startsWith('remotes/') ? b.name.substring(8) : b.name;
    final slash = n.indexOf('/');
    if (slash >= 0) n = n.substring(slash + 1);
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final branches = _branches;
    final local = branches?.where((b) => !b.remote).toList() ?? const <GitBranch>[];
    final localNames = local.map((b) => b.name).toSet();
    final remote =
        branches?.where((b) => b.remote && !b.name.endsWith('/HEAD') && !b.name.contains(' -> ')).toList() ??
        const <GitBranch>[];

    Widget row(GitBranch b) {
      final target = _localName(b);
      return SettingsRow(
        icon: b.remote ? LucideIcons.cloud : LucideIcons.gitBranch,
        color: b.current ? p.accent : p.muted,
        title: b.name,
        subtitle: b.remote && localNames.contains(target) ? 'Local branch $target exists' : null,
        trailing: _busy == b.name || _busy == target
            ? SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: p.muted))
            : b.current
            ? Icon(LucideIcons.check, size: 18, color: p.accent)
            : const SizedBox.shrink(),
        onTap: b.current || _busy != null ? null : () => _checkout(target),
      );
    }

    final name = _name.text.trim();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            children: [
              Text('Branches', style: text.titleLarge),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _name,
                      autocorrect: false,
                      style: const TextStyle(fontFamily: mono, fontSize: 14),
                      decoration: const InputDecoration(hintText: 'New branch name'),
                      onSubmitted: (v) => v.trim().isEmpty ? null : _checkout(v.trim(), create: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    style: IconButton.styleFrom(backgroundColor: p.text, foregroundColor: p.inverse),
                    tooltip: 'Create branch',
                    onPressed: name.isEmpty || _busy != null ? null : () => _checkout(name, create: true),
                    icon: const Icon(LucideIcons.plus, size: 18),
                  ),
                ],
              ),
              if (branches == null)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                if (local.isNotEmpty) ...[
                  const SectionLabel('Local'),
                  SettingsGroup(children: [for (final b in local) row(b)]),
                ],
                if (remote.isNotEmpty) ...[
                  const SectionLabel('Remote'),
                  SettingsGroup(children: [for (final b in remote) row(b)]),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DiffSheet extends StatefulWidget {
  const _DiffSheet({required this.features, required this.file, required this.staged, required this.scroll});
  final Features features;
  final GitFile file;
  final bool staged;
  final ScrollController scroll;

  @override
  State<_DiffSheet> createState() => _DiffSheetState();
}

class _DiffSheetState extends State<_DiffSheet> {
  late final Future<String> _patch = widget.features.gitDiff(file: widget.file.path, staged: widget.staged);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        Text(widget.file.path, style: text.titleMedium?.copyWith(fontFamily: mono)),
        const SizedBox(height: 4),
        Text(widget.staged ? 'Staged changes' : 'Unstaged changes', style: text.bodySmall),
        const SizedBox(height: 14),
        FutureBuilder<String>(
          future: _patch,
          builder: (context, snap) {
            if (snap.hasError) return Text('${snap.error}', style: text.bodySmall);
            if (!snap.hasData) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.data!.trim().isEmpty && widget.file.untracked) {
              return Text('New untracked file. Stage it to see its contents as a diff.', style: text.bodySmall);
            }
            return DiffView(patch: snap.data!);
          },
        ),
      ],
    );
  }
}

/// Title/body/base form; pops with the new pull request's URL.
class _PrSheet extends StatefulWidget {
  const _PrSheet({required this.features, required this.branch});
  final Features features;
  final String branch;

  @override
  State<_PrSheet> createState() => _PrSheetState();
}

class _PrSheetState extends State<_PrSheet> {
  late final _title = TextEditingController(text: widget.branch.replaceAll(RegExp(r'[-_/]+'), ' ').trim());
  final _body = TextEditingController();
  final _base = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _base.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      final base = _base.text.trim();
      final url = await widget.features.createPr(_title.text.trim(), _body.text, base: base.isEmpty ? null : base);
      if (mounted) Navigator.of(context).pop(url);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Create pull request', style: text.titleLarge),
            const SizedBox(height: 4),
            Text('From ${widget.branch}. Push the branch first if it is new.', style: text.bodySmall),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'Title'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _body,
              minLines: 4,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'Description (Markdown)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _base,
              autocorrect: false,
              style: const TextStyle(fontFamily: mono, fontSize: 14),
              decoration: const InputDecoration(hintText: 'Base branch (default branch if empty)'),
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              label: 'Create pull request',
              icon: LucideIcons.gitPullRequest,
              busy: _busy,
              onPressed: _title.text.trim().isEmpty ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// Issue or PR details; pops with `true` when the user wants the agent to work on it.
class _IssueSheet extends StatelessWidget {
  const _IssueSheet({required this.issue, required this.scroll, required this.onOpen, required this.canWork});
  final GithubIssue issue;
  final ScrollController scroll;
  final VoidCallback onOpen;
  final bool canWork;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            children: [
              Row(
                children: [
                  Icon(
                    issue.isPr ? LucideIcons.gitPullRequest : LucideIcons.circleDot,
                    size: 16,
                    color: issue.isPr ? p.accent : p.success,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${issue.isPr ? 'Pull request' : 'Issue'} #${issue.number}',
                    style: text.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(issue.title, style: text.titleLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  if (issue.author != null) Pill(issue.author!, icon: LucideIcons.user),
                  Pill(_ago(issue.updatedAt), icon: LucideIcons.clock),
                  if (issue.comments > 0) Pill('${issue.comments}', icon: LucideIcons.messageSquare),
                  for (final l in issue.labels) Pill(l, color: p.accentAlt),
                ],
              ),
              const SizedBox(height: 16),
              if (issue.body.trim().isEmpty)
                Text('No description provided.', style: text.bodySmall)
              else
                MarkdownText(issue.body),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(54)),
                    onPressed: onOpen,
                    icon: const Icon(LucideIcons.externalLink, size: 16),
                    label: const Text('Open on GitHub'),
                  ),
                ),
                if (canWork) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: PrimaryButton(
                      label: 'Work on this',
                      icon: LucideIcons.hammer,
                      onPressed: () => Navigator.of(context).pop(true),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
