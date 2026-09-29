import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/features.dart';
import 'chat_screen.dart';
import 'illustration.dart';
import 'kit.dart';
import 'theme.dart';

String _basename(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

String _describeSchedule(ScheduleInfo s) {
  final t = s.trigger;
  if (t != null && t['type'] == 'github_issues') {
    return 'GitHub issues labelled ${t['label'] ?? '?'} in ${t['repo'] ?? '?'}';
  }
  if (s.dailyAt != null) return 'daily at ${s.dailyAt}';
  final m = s.everyMinutes;
  if (m == null) return 'manual';
  if (m % 1440 == 0) return m == 1440 ? 'every day' : 'every ${m ~/ 1440} days';
  if (m % 60 == 0) return m == 60 ? 'every hour' : 'every ${m ~/ 60} h';
  return 'every $m min';
}

/// Background agent work: a queue of runs, parallelism, and schedules/triggers
/// that keep pi working while the user is elsewhere.
class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  final _prompt = TextEditingController();
  bool _queueing = false;

  AgentController get agent => widget.agent;
  Features get f => agent.features;

  @override
  void initState() {
    super.initState();
    f.refreshRuns().catchError((Object e) => _error(e));
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  void _error(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }

  Future<void> _guard(Future<void> Function() task) async {
    try {
      await task();
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _queue() async {
    final text = _prompt.text.trim();
    if (text.isEmpty) return;
    setState(() => _queueing = true);
    try {
      final firstLine = text.split('\n').first;
      await f.enqueue(text, title: firstLine.length > 60 ? '${firstLine.substring(0, 60)}…' : firstLine);
      _prompt.clear();
      if (mounted) FocusScope.of(context).unfocus();
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _queueing = false);
    }
  }

  Future<void> _openRun(RunInfo run) async {
    try {
      await agent.openSession(run.sessionFile!);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(agent: agent)));
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _editSchedule([ScheduleInfo? existing]) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ScheduleSheet(existing: existing, defaultCwd: agent.cwd),
    );
    if (result == null) return;
    await _guard(() => f.saveSchedule(result));
  }

  Future<void> _deleteSchedule(ScheduleInfo s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete schedule?'),
        content: Text('"${s.name}" will stop running.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await _guard(() => f.deleteSchedule(s.id));
  }

  Future<void> _runNow(ScheduleInfo s) async {
    await _guard(() => f.runScheduleNow(s.id));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Queued "${s.name}"')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: f,
      builder: (context, _) {
        final runs = f.runs;
        final finished = runs.where((r) => !r.active).length;
        return Scaffold(
          appBar: AppBar(title: const Text('Tasks')),
          body: RefreshIndicator(
            onRefresh: () => _guard(f.refreshRuns),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
              children: [
                const SectionLabel('Run in background', padding: EdgeInsets.fromLTRB(4, 8, 4, 10)),
                SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _prompt,
                        minLines: 2,
                        maxLines: 6,
                        textInputAction: TextInputAction.newline,
                        decoration: const InputDecoration(hintText: 'What should pi do while you are away?'),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Icon(LucideIcons.folder, size: 14, color: p.muted),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              agent.cwd.isEmpty ? 'workspace' : _basename(agent.cwd),
                              overflow: TextOverflow.ellipsis,
                              style: text.bodySmall?.copyWith(fontFamily: mono),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      PrimaryButton(label: 'Queue', icon: LucideIcons.listTodo, busy: _queueing, onPressed: _queue),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Parallel agents', style: text.titleSmall),
                                Text('How many run at once', style: text.bodySmall),
                              ],
                            ),
                          ),
                          SegmentedButton<int>(
                            showSelectedIcon: false,
                            segments: const [
                              ButtonSegment(value: 1, label: Text('1')),
                              ButtonSegment(value: 2, label: Text('2')),
                              ButtonSegment(value: 3, label: Text('3')),
                            ],
                            selected: {f.concurrency.clamp(1, 3)},
                            onSelectionChanged: (s) => _guard(() => f.setConcurrency(s.first)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                SectionLabel(
                  'Runs',
                  trailing: finished > 0
                      ? TextButton.icon(
                          onPressed: () => _guard(f.clearRuns),
                          icon: const Icon(LucideIcons.x, size: 14),
                          label: const Text('Clear finished'),
                        )
                      : null,
                ),
                if (runs.isEmpty)
                  SurfaceCard(
                    child: Column(
                      children: [
                        const Illustration('automate', height: 140),
                        const SizedBox(height: 8),
                        Text('No runs yet. Queue a prompt above.', style: text.bodySmall),
                      ],
                    ),
                  )
                else
                  for (final r in runs) ...[
                    _RunCard(
                      run: r,
                      onCancel: () => _guard(() => f.cancelRun(r.id)),
                      onOpen: r.sessionFile != null ? () => _openRun(r) : null,
                    ),
                    const SizedBox(height: 10),
                  ],
                SectionLabel(
                  'Schedules',
                  trailing: TextButton.icon(
                    onPressed: () => _editSchedule(),
                    icon: const Icon(LucideIcons.plus, size: 14),
                    label: const Text('New schedule'),
                  ),
                ),
                if (f.schedules.isEmpty)
                  SurfaceCard(
                    onTap: () => _editSchedule(),
                    child: Row(
                      children: [
                        IconTile(icon: LucideIcons.calendarClock, color: p.accentAlt),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            'Run a prompt every few hours, daily, or when a labelled GitHub issue appears.',
                            style: text.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  SettingsGroup(
                    children: [
                      for (final s in f.schedules)
                        _ScheduleRow(
                          schedule: s,
                          onTap: () => _editSchedule(s),
                          onToggle: (v) => _guard(() => f.saveSchedule({...s.json, 'enabled': v})),
                          onRunNow: () => _runNow(s),
                          onDelete: () => _deleteSchedule(s),
                        ),
                    ],
                  ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(LucideIcons.info, size: 14, color: p.faint),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Schedules run while AndroPI is alive; a persistent notification keeps it running.',
                        style: text.bodySmall?.copyWith(color: p.muted),
                      ),
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
}

class _RunCard extends StatelessWidget {
  const _RunCard({required this.run, required this.onCancel, this.onOpen});
  final RunInfo run;
  final VoidCallback onCancel;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final Widget status = switch (run.status) {
      'running' => SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.accent)),
      'queued' => Icon(LucideIcons.clock, size: 18, color: p.muted),
      'done' => Icon(LucideIcons.circleCheck, size: 18, color: p.success),
      'error' => Icon(LucideIcons.circleX, size: 18, color: p.danger),
      'cancelled' => Icon(LucideIcons.ban, size: 18, color: p.faint),
      _ => Icon(LucideIcons.circleDashed, size: 18, color: p.muted),
    };
    final sourceColor = switch (run.source) {
      'schedule' => p.accentAlt,
      'trigger' => p.warning,
      _ => p.muted,
    };
    final when = run.finishedAt ?? run.createdAt;
    final summary = run.summary;
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              status,
              const SizedBox(width: 12),
              Expanded(
                child: Text(run.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
              ),
              const SizedBox(width: 8),
              Pill(run.source, color: sourceColor),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 30),
            child: Text(
              [run.status, _ago(when), if (run.cwd.isNotEmpty) _basename(run.cwd)].join(' · '),
              style: text.bodySmall?.copyWith(color: p.muted),
            ),
          ),
          if (summary != null && summary.isNotEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 30),
              child: Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
            ),
          ],
          if (run.active || (onOpen != null && (run.status == 'done' || run.status == 'error')))
            Align(
              alignment: Alignment.centerRight,
              child: run.active
                  ? TextButton.icon(
                      onPressed: onCancel,
                      icon: const Icon(LucideIcons.x, size: 14),
                      label: const Text('Cancel'),
                    )
                  : TextButton.icon(
                      onPressed: onOpen,
                      icon: const Icon(LucideIcons.messageSquare, size: 14),
                      label: const Text('Open chat'),
                    ),
            ),
        ],
      ),
    );
  }
}

class _ScheduleRow extends StatelessWidget {
  const _ScheduleRow({
    required this.schedule,
    required this.onTap,
    required this.onToggle,
    required this.onRunNow,
    required this.onDelete,
  });
  final ScheduleInfo schedule;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRunNow;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final s = schedule;
    final isTrigger = s.trigger != null;
    final last = s.lastRun;
    return SettingsRow(
      leading: isTrigger
          ? IconTile(icon: SimpleIcons.github, color: p.text)
          : IconTile(icon: LucideIcons.calendarClock, color: s.enabled ? p.accentAlt : p.faint),
      title: s.name,
      subtitle: '${_describeSchedule(s)}${last != null ? ' · last run ${_ago(last)}' : ''}',
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(value: s.enabled, onChanged: onToggle),
          PopupMenuButton<String>(
            icon: Icon(LucideIcons.ellipsis, size: 18, color: p.muted),
            onSelected: (v) => switch (v) {
              'run' => onRunNow(),
              'edit' => onTap(),
              _ => onDelete(),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'run', child: Text('Run now')),
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }
}

enum _Kind { interval, daily, github }

/// Create/edit form for a schedule; pops the json map to save.
class _ScheduleSheet extends StatefulWidget {
  const _ScheduleSheet({this.existing, required this.defaultCwd});
  final ScheduleInfo? existing;
  final String defaultCwd;

  @override
  State<_ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends State<_ScheduleSheet> {
  static const _presets = [15, 30, 60, 180, 720, 1440];

  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _prompt = TextEditingController(text: widget.existing?.prompt ?? '');
  late final _minutes = TextEditingController(text: '${widget.existing?.everyMinutes ?? 60}');
  late final _repo = TextEditingController(text: widget.existing?.trigger?['repo'] as String? ?? '');
  late final _label = TextEditingController(text: widget.existing?.trigger?['label'] as String? ?? '');
  late _Kind _kind;
  late TimeOfDay _time;
  String? _problem;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _kind = e?.trigger != null
        ? _Kind.github
        : e?.dailyAt != null
        ? _Kind.daily
        : _Kind.interval;
    _time = const TimeOfDay(hour: 9, minute: 0);
    final at = e?.dailyAt?.split(':');
    if (at != null && at.length == 2) {
      _time = TimeOfDay(hour: int.tryParse(at[0]) ?? 9, minute: int.tryParse(at[1]) ?? 0);
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _prompt, _minutes, _repo, _label]) {
      c.dispose();
    }
    super.dispose();
  }

  String _hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _presetLabel(int m) => m < 60 ? '${m}m' : (m < 1440 ? '${m ~/ 60}h' : '${m ~/ 1440}d');

  void _save() {
    final name = _name.text.trim();
    final prompt = _prompt.text.trim();
    if (name.isEmpty || prompt.isEmpty) {
      setState(() => _problem = 'Name and prompt are required.');
      return;
    }
    final e = widget.existing;
    final out = <String, dynamic>{
      'id': ?e?.id,
      'name': name,
      'prompt': prompt,
      'cwd': e?.cwd.isNotEmpty == true ? e!.cwd : widget.defaultCwd,
      'enabled': e?.enabled ?? true,
      'everyMinutes': null,
      'dailyAt': null,
      'trigger': null,
    };
    switch (_kind) {
      case _Kind.interval:
        final m = int.tryParse(_minutes.text.trim());
        if (m == null || m < 15) {
          setState(() => _problem = 'Interval must be at least 15 minutes.');
          return;
        }
        out['everyMinutes'] = m;
      case _Kind.daily:
        out['dailyAt'] = _hhmm(_time);
      case _Kind.github:
        final repo = _repo.text.trim();
        final label = _label.text.trim();
        if (!RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(repo) || label.isEmpty) {
          setState(() => _problem = 'Enter the repo as owner/repo and a label.');
          return;
        }
        out['trigger'] = {'type': 'github_issues', 'repo': repo, 'label': label};
    }
    Navigator.pop(context, out);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final minutes = int.tryParse(_minutes.text.trim());
    final cwd = widget.existing?.cwd.isNotEmpty == true ? widget.existing!.cwd : widget.defaultCwd;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.existing == null ? 'New schedule' : 'Edit schedule', style: text.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _prompt,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(labelText: 'Prompt', alignLabelWithHint: true),
            ),
            const SizedBox(height: 16),
            SegmentedButton<_Kind>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: _Kind.interval, label: Text('Interval')),
                ButtonSegment(value: _Kind.daily, label: Text('Daily')),
                ButtonSegment(value: _Kind.github, label: Text('GitHub trigger')),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() {
                _kind = s.first;
                _problem = null;
              }),
            ),
            const SizedBox(height: 14),
            ...switch (_kind) {
              _Kind.interval => [
                TextField(
                  controller: _minutes,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: 'Every (minutes)', helperText: 'At least 15'),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in _presets)
                      ChoiceChip(
                        label: Text(_presetLabel(m)),
                        selected: minutes == m,
                        onSelected: (_) => setState(() => _minutes.text = '$m'),
                      ),
                  ],
                ),
              ],
              _Kind.daily => [
                SurfaceCard(
                  padding: const EdgeInsets.all(14),
                  onTap: () async {
                    final t = await showTimePicker(context: context, initialTime: _time);
                    if (t != null) setState(() => _time = t);
                  },
                  child: Row(
                    children: [
                      Icon(LucideIcons.clock, size: 18, color: p.muted),
                      const SizedBox(width: 12),
                      Expanded(child: Text('Every day at', style: text.bodyMedium)),
                      Text(_hhmm(_time), style: text.titleMedium?.copyWith(fontFamily: mono)),
                    ],
                  ),
                ),
              ],
              _Kind.github => [
                TextField(
                  controller: _repo,
                  autocorrect: false,
                  style: const TextStyle(fontFamily: mono),
                  decoration: const InputDecoration(labelText: 'Repository', hintText: 'owner/repo'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _label,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Label', hintText: 'pi'),
                ),
                const SizedBox(height: 6),
                Text(
                  'pi picks up new issues with this label. The issue is added to your prompt.',
                  style: text.bodySmall,
                ),
              ],
            },
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(LucideIcons.folder, size: 14, color: p.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    cwd.isEmpty ? 'workspace' : cwd,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(fontFamily: mono),
                  ),
                ),
              ],
            ),
            if (_problem != null) ...[
              const SizedBox(height: 10),
              Text(_problem!, style: text.bodySmall?.copyWith(color: p.danger)),
            ],
            const SizedBox(height: 18),
            PrimaryButton(label: 'Save', icon: LucideIcons.check, onPressed: _save),
          ],
        ),
      ),
    );
  }
}
