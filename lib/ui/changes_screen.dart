import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/features.dart';
import 'diff_view.dart';
import 'illustration.dart';
import 'kit.dart';
import 'theme.dart';

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 30) return '${d.inDays}d ago';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

/// What the agent changed since a checkpoint, with a one-tap undo. Checkpoints
/// are shadow snapshots taken before the agent's first edit in each run, so
/// this works whether or not the folder is a git repository.
class ChangesScreen extends StatefulWidget {
  const ChangesScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<ChangesScreen> createState() => _ChangesScreenState();
}

class _ChangesScreenState extends State<ChangesScreen> {
  Features get _f => widget.agent.features;

  List<CheckpointInfo>? _checkpoints;
  String? _selected;
  ChangeSet? _changes;
  Map<String, String> _patches = const {};
  final _open = <String>{};
  final _loadingFile = <String>{};
  bool _loadingChanges = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _error(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }

  CheckpointInfo? get _current => _checkpoints?.where((c) => c.id == _selected).firstOrNull;

  Future<void> _refresh() async {
    try {
      final list = await _f.checkpoints();
      list.sort((a, b) => b.time.compareTo(a.time));
      if (!mounted) return;
      setState(() {
        _checkpoints = list;
        if (!list.any((c) => c.id == _selected)) _selected = list.firstOrNull?.id;
      });
      await _loadChanges();
    } catch (e) {
      if (mounted) setState(() => _checkpoints ??= const []);
      _error(e);
    }
  }

  Future<void> _loadChanges() async {
    final id = _selected;
    if (id == null) {
      setState(() => _changes = null);
      return;
    }
    setState(() => _loadingChanges = true);
    try {
      final c = await _f.changes(checkpoint: id);
      if (!mounted || id != _selected) return;
      setState(() {
        _changes = c;
        _patches = {for (final s in splitPatch(c.patch)) s.path: s.patch};
      });
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _loadingChanges = false);
    }
  }

  void _select(String id) {
    if (id == _selected) return;
    setState(() {
      _selected = id;
      _changes = null;
      _patches = const {};
      _open.clear();
    });
    _loadChanges();
  }

  Future<void> _toggle(DiffFile file) async {
    if (_open.remove(file.path)) {
      setState(() {});
      return;
    }
    setState(() => _open.add(file.path));
    if (_patches.containsKey(file.path) || file.binary) return;
    setState(() => _loadingFile.add(file.path));
    try {
      final c = await _f.changes(checkpoint: _selected, file: file.path);
      if (mounted) setState(() => _patches = {..._patches, file.path: c.patch});
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _loadingFile.remove(file.path));
    }
  }

  Future<void> _undo() async {
    final cp = _current;
    if (cp == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Undo these changes?'),
        content: Text(
          'Files will be put back the way they were at "${cp.label}". '
          'The current state is saved as a checkpoint first, so you can undo this again.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Undo changes')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await _f.restore(cp.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Restored "${cp.label}"')));
      setState(() => _selected = null);
      await _refresh();
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final ctrl = TextEditingController();
    final label = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create checkpoint'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Label, e.g. Before refactor'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, ctrl.text), child: const Text('Create')),
        ],
      ),
    );
    ctrl.dispose();
    final l = label?.trim();
    if (l == null || l.isEmpty) return;
    try {
      await _f.createCheckpoint(l);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Checkpoint "$l" saved')));
      setState(() => _selected = null);
      await _refresh();
    } catch (e) {
      _error(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _checkpoints;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Changes'),
        actions: [
          IconButton(tooltip: 'Create checkpoint', icon: const Icon(LucideIcons.bookmarkPlus), onPressed: _create),
          IconButton(tooltip: 'Refresh', icon: const Icon(LucideIcons.refreshCw), onPressed: _refresh),
        ],
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(onRefresh: _refresh, child: list.isEmpty ? _empty(context) : _content(context, list)),
    );
  }

  Widget _empty(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(32, 60, 32, 40),
      children: [
        const Illustration('git', height: 160),
        const SizedBox(height: 20),
        Text('No checkpoints yet', textAlign: TextAlign.center, style: text.titleMedium),
        const SizedBox(height: 6),
        Text(
          'Checkpoints appear when the agent starts changing files',
          textAlign: TextAlign.center,
          style: text.bodySmall,
        ),
        const SizedBox(height: 24),
        Center(
          child: OutlinedButton.icon(
            onPressed: _create,
            icon: const Icon(LucideIcons.bookmarkPlus, size: 16),
            label: const Text('Create checkpoint now'),
          ),
        ),
      ],
    );
  }

  Widget _content(BuildContext context, List<CheckpointInfo> list) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final cp = _current;
    final changes = _changes;
    final adds = changes?.files.fold<int>(0, (s, f) => s + f.additions) ?? 0;
    final dels = changes?.files.fold<int>(0, (s, f) => s + f.deletions) ?? 0;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
      children: [
        const SectionLabel('Checkpoints', padding: EdgeInsets.fromLTRB(4, 8, 4, 10)),
        SizedBox(
          height: 64,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) => _CheckpointChip(
              checkpoint: list[i],
              selected: list[i].id == _selected,
              latest: i == 0,
              onTap: () => _select(list[i].id),
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (cp != null)
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    IconTile(icon: LucideIcons.history, color: p.accent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Changes since', style: text.bodySmall),
                          Text(cp.label, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.titleMedium),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    Pill(_ago(cp.time), icon: LucideIcons.clock),
                    if (changes != null) ...[
                      Pill('${changes.files.length} ${changes.files.length == 1 ? 'file' : 'files'}'),
                      Pill('+$adds', color: p.success),
                      Pill('-$dels', color: p.danger),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                PrimaryButton(
                  label: 'Undo these changes',
                  icon: LucideIcons.undo2,
                  busy: _busy,
                  onPressed: changes == null || changes.files.isEmpty ? null : _undo,
                ),
              ],
            ),
          ),
        const SectionLabel('Files'),
        if (_loadingChanges && changes == null)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (changes == null || changes.files.isEmpty)
          SurfaceCard(
            child: Row(
              children: [
                Icon(LucideIcons.check, size: 18, color: p.success),
                const SizedBox(width: 10),
                Expanded(child: Text('Nothing changed since this checkpoint', style: text.bodyMedium)),
              ],
            ),
          )
        else
          for (final f in changes.files) ...[_fileTile(context, f), const SizedBox(height: 8)],
      ],
    );
  }

  Widget _fileTile(BuildContext context, DiffFile f) {
    final p = context.palette;
    final open = _open.contains(f.path);
    final slash = f.path.lastIndexOf('/');
    final name = slash >= 0 ? f.path.substring(slash + 1) : f.path;
    final dir = slash >= 0 ? f.path.substring(0, slash) : '';
    return Container(
      decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => _toggle(f),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: [
                  Icon(open ? LucideIcons.chevronDown : LucideIcons.chevronRight, size: 16, color: p.faint),
                  const SizedBox(width: 8),
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
                  DiffStat(additions: f.additions, deletions: f.deletions, binary: f.binary),
                ],
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: _loadingFile.contains(f.path)
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : f.binary
                  ? DiffView(patch: 'Binary files a/${f.path} and b/${f.path} differ', showHeaders: false)
                  : DiffView(patch: _patches[f.path] ?? '', showHeaders: false),
            ),
        ],
      ),
    );
  }
}

class _CheckpointChip extends StatelessWidget {
  const _CheckpointChip({required this.checkpoint, required this.selected, required this.latest, required this.onTap});
  final CheckpointInfo checkpoint;
  final bool selected;
  final bool latest;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fg = selected ? p.inverse : p.text;
    final sub = selected ? p.inverse.withValues(alpha: 0.7) : p.muted;
    return Material(
      color: selected ? p.text : p.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 120, maxWidth: 220),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                checkpoint.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: fg),
              ),
              const SizedBox(height: 3),
              Text(
                [
                  if (latest) 'Latest',
                  _ago(checkpoint.time),
                  '${checkpoint.files} ${checkpoint.files == 1 ? 'file' : 'files'}',
                ].join(' · '),
                maxLines: 1,
                style: TextStyle(fontSize: 11.5, color: sub),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
