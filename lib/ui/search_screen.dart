import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/features.dart';
import 'editor_screen.dart';
import 'illustration.dart';
import 'kit.dart';
import 'theme.dart';

/// Project-wide search (ripgrep on the host), grouped by file; a match opens
/// the editor at that line.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.agent, this.initialQuery});
  final AgentController agent;
  final String? initialQuery;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final query = TextEditingController(text: widget.initialQuery ?? '');
  final glob = TextEditingController();
  Timer? _debounce;
  bool regex = false;
  bool matchCase = false;
  bool busy = false;
  bool truncated = false;
  Object? error;
  List<SearchMatch>? matches;
  int _seq = 0;

  AgentController get agent => widget.agent;

  @override
  void initState() {
    super.initState();
    if (query.text.trim().isNotEmpty) _run();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    query.dispose();
    glob.dispose();
    super.dispose();
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _run);
  }

  Future<void> _run() async {
    _debounce?.cancel();
    final q = query.text;
    if (q.trim().isEmpty) {
      setState(() {
        matches = null;
        error = null;
        busy = false;
      });
      return;
    }
    final seq = ++_seq;
    setState(() => busy = true);
    try {
      final g = glob.text.trim();
      final (m, t) = await agent.features.search(q, regex: regex, caseSensitive: matchCase, glob: g.isEmpty ? null : g);
      if (!mounted || seq != _seq) return;
      setState(() {
        matches = m;
        truncated = t;
        error = null;
        busy = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        error = e;
        busy = false;
      });
    }
  }

  /// The pattern used to highlight hits in a line, or null when it can't be built.
  RegExp? _pattern() {
    final q = query.text;
    if (q.isEmpty) return null;
    try {
      return RegExp(regex ? q : RegExp.escape(q), caseSensitive: matchCase);
    } catch (_) {
      return null;
    }
  }

  void _open(SearchMatch m) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditorScreen(agent: agent, path: '${agent.cwd}/${m.path}', line: m.line),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final list = matches;
    final groups = <String, List<SearchMatch>>{};
    for (final m in list ?? const <SearchMatch>[]) {
      groups.putIfAbsent(m.path, () => []).add(m);
    }
    final pattern = _pattern();

    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: query,
              autofocus: true,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontFamily: mono, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search in project',
                prefixIcon: const Icon(LucideIcons.search, size: 18),
                suffixIcon: busy
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : query.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(LucideIcons.x, size: 18),
                        onPressed: () {
                          query.clear();
                          _run();
                        },
                      ),
              ),
              onChanged: (_) => _schedule(),
              onSubmitted: (_) => _run(),
            ),
          ),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _Toggle(
                  label: 'Regex',
                  icon: LucideIcons.regex,
                  on: regex,
                  onTap: () {
                    setState(() => regex = !regex);
                    _run();
                  },
                ),
                const SizedBox(width: 8),
                _Toggle(
                  label: 'Match case',
                  icon: LucideIcons.caseSensitive,
                  on: matchCase,
                  onTap: () {
                    setState(() => matchCase = !matchCase);
                    _run();
                  },
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: glob,
                    style: const TextStyle(fontFamily: mono, fontSize: 12.5),
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '*.dart',
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                      prefixIcon: Icon(LucideIcons.asterisk, size: 14),
                      prefixIconConstraints: BoxConstraints(minWidth: 30),
                    ),
                    onChanged: (_) => _schedule(),
                    onSubmitted: (_) => _run(),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Divider(height: 1, color: p.border),
          Expanded(
            child: error != null
                ? ListView(
                    padding: const EdgeInsets.all(16),
                    children: [Pill('$error', color: p.danger, icon: LucideIcons.circleAlert)],
                  )
                : list == null || list.isEmpty
                ? _Empty(message: list == null ? 'Search every file in ${_folder()}' : 'No matches')
                : ListView(
                    padding: const EdgeInsets.fromLTRB(0, 8, 0, 40),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(
                          truncated ? 'Showing first 500 matches' : '${list.length} matches in ${groups.length} files',
                          style: text.bodySmall?.copyWith(color: truncated ? p.warning : p.muted),
                        ),
                      ),
                      for (final e in groups.entries) ...[
                        _FileHeader(path: e.key, count: e.value.length),
                        for (final m in e.value) _MatchRow(match: m, pattern: pattern, onTap: () => _open(m)),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  String _folder() {
    final cwd = agent.cwd;
    if (cwd.isEmpty) return 'the project';
    return cwd.split('/').where((s) => s.isNotEmpty).lastOrNull ?? 'the project';
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.icon, required this.on, required this.onTap});
  final String label;
  final IconData icon;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: on ? p.text : p.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: on ? p.inverse : p.muted),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 12.5, color: on ? p.inverse : p.text)),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileHeader extends StatelessWidget {
  const _FileHeader({required this.path, required this.count});
  final String path;
  final int count;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final slash = path.lastIndexOf('/');
    final dir = slash < 0 ? '' : path.substring(0, slash + 1);
    final name = path.substring(slash + 1);
    return Container(
      color: p.surface,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Icon(LucideIcons.fileCode, size: 15, color: p.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: dir,
                    style: TextStyle(color: p.muted),
                  ),
                  TextSpan(
                    text: name,
                    style: TextStyle(color: p.text, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              style: const TextStyle(fontFamily: mono, fontSize: 12.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Pill('$count'),
        ],
      ),
    );
  }
}

class _MatchRow extends StatelessWidget {
  const _MatchRow({required this.match, required this.pattern, required this.onTap});
  final SearchMatch match;
  final RegExp? pattern;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final line = match.text.replaceAll('\t', '  ').trimRight();
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              child: Text(
                '${match.line}',
                textAlign: TextAlign.right,
                style: TextStyle(fontFamily: mono, fontSize: 12, color: p.faint),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text.rich(
                TextSpan(children: _spans(line, p)),
                style: TextStyle(fontFamily: mono, fontSize: 12.5, color: p.text, height: 1.4),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 16),
          ],
        ),
      ),
    );
  }

  List<TextSpan> _spans(String line, Palette p) {
    final re = pattern;
    if (re == null) return [TextSpan(text: line)];
    final out = <TextSpan>[];
    var last = 0;
    for (final m in re.allMatches(line)) {
      if (m.end == m.start) continue;
      if (m.start > last) out.add(TextSpan(text: line.substring(last, m.start)));
      out.add(
        TextSpan(
          text: line.substring(m.start, m.end),
          style: TextStyle(fontWeight: FontWeight.w700, backgroundColor: p.accent.withValues(alpha: 0.18)),
        ),
      );
      last = m.end;
    }
    if (last < line.length) out.add(TextSpan(text: line.substring(last)));
    return out;
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 40),
      children: [
        const Illustration('search', height: 150),
        const SizedBox(height: 16),
        Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: p.muted),
        ),
      ],
    );
  }
}
