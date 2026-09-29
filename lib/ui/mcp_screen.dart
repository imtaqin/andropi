import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/features.dart';
import 'illustration.dart';
import 'kit.dart';
import 'theme.dart';

/// A starting point for a common MCP server.
class _Preset {
  const _Preset(this.name, this.icon, {this.command, this.url, this.inContainer = true});
  final String name;
  final IconData icon;
  final String? command;
  final String? url;
  final bool inContainer;
}

/// MCP servers: connect pi to outside tools through Model Context Protocol.
class McpScreen extends StatefulWidget {
  const McpScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<McpScreen> createState() => _McpScreenState();
}

class _McpScreenState extends State<McpScreen> {
  final _expanded = <String>{};

  AgentController get agent => widget.agent;
  Features get f => agent.features;

  List<_Preset> get _presets {
    final ws = agent.info['workspace'] as String? ?? '/workspace';
    return [
      const _Preset('Memory', LucideIcons.brain, command: 'npx -y @modelcontextprotocol/server-memory'),
      const _Preset('Fetch', LucideIcons.globe, command: 'uvx mcp-server-fetch'),
      _Preset('Filesystem', LucideIcons.folderOpen, command: 'npx -y @modelcontextprotocol/server-filesystem $ws'),
      const _Preset('Context7 docs', LucideIcons.bookOpen, url: 'https://mcp.context7.com/mcp', inContainer: false),
    ];
  }

  @override
  void initState() {
    super.initState();
    f.refreshMcp().catchError((Object e) => _error(e));
  }

  void _error(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }

  Future<void> _edit({McpServer? existing, _Preset? preset}) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _McpSheet(existing: existing, preset: preset),
    );
    if (result == null) return;
    try {
      await f.saveMcp(result);
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _delete(McpServer s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove server?'),
        content: Text('"${s.name}" and its tools will be removed from pi.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await f.deleteMcp(s.id);
    } catch (e) {
      _error(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: f,
      builder: (context, _) {
        final servers = f.mcpServers;
        return Scaffold(
          appBar: AppBar(
            title: const Text('MCP servers'),
            actions: [IconButton(tooltip: 'Add server', onPressed: () => _edit(), icon: const Icon(LucideIcons.plus))],
          ),
          body: RefreshIndicator(
            onRefresh: () => f.refreshMcp().catchError((Object e) => _error(e)),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
              children: [
                SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          IconTile(icon: LucideIcons.plug, color: p.accent),
                          const SizedBox(width: 12),
                          Expanded(child: Text('Model Context Protocol', style: text.titleMedium)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Connect pi to databases, docs, browsers and more through Model Context Protocol servers; '
                        'their tools show up as mcp_<server>_<tool>.',
                        style: text.bodyMedium?.copyWith(color: p.muted),
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final pr in _presets)
                            ActionChip(
                              avatar: Icon(pr.icon, size: 16),
                              label: Text(pr.name),
                              onPressed: () => _edit(preset: pr),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                SectionLabel(
                  'Servers',
                  trailing: TextButton.icon(
                    onPressed: () => _edit(),
                    icon: const Icon(LucideIcons.plus, size: 14),
                    label: const Text('Add server'),
                  ),
                ),
                if (servers.isEmpty)
                  SurfaceCard(
                    child: Column(
                      children: [
                        const Illustration('connect', height: 140),
                        const SizedBox(height: 8),
                        Text('No servers yet. Pick a preset above to start.', style: text.bodySmall),
                      ],
                    ),
                  )
                else
                  for (final s in servers) ...[
                    _ServerCard(
                      server: s,
                      expanded: _expanded.contains(s.id),
                      onToggleTools: () => setState(() {
                        if (!_expanded.remove(s.id)) _expanded.add(s.id);
                      }),
                      onEdit: () => _edit(existing: s),
                      onDelete: () => _delete(s),
                      onEnabled: (v) => f.saveMcp({...s.json, 'enabled': v}).catchError((Object e) => _error(e)),
                    ),
                    const SizedBox(height: 10),
                  ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.server,
    required this.expanded,
    required this.onToggleTools,
    required this.onEdit,
    required this.onDelete,
    required this.onEnabled,
  });
  final McpServer server;
  final bool expanded;
  final VoidCallback onToggleTools;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onEnabled;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final s = server;
    final tools = s.tools;
    final status = s.enabled ? s.status : 'disabled';
    final Widget indicator = switch (status) {
      'connected' => _Dot(color: p.success),
      'connecting' => SizedBox.square(
        dimension: 12,
        child: CircularProgressIndicator(strokeWidth: 1.6, color: p.accent),
      ),
      'error' => _Dot(color: p.danger),
      _ => _Dot(color: p.faint),
    };
    final detail = s.type == 'http' ? (s.url ?? '') : (s.command ?? '');
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
      onTap: onEdit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(icon: s.type == 'http' ? LucideIcons.globe : LucideIcons.squareTerminal, color: p.accentAlt),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.name, style: text.titleSmall),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        indicator,
                        const SizedBox(width: 6),
                        Text(
                          status == 'connected' ? 'connected · ${tools.length} tools' : status,
                          style: text.bodySmall?.copyWith(color: status == 'error' ? p.danger : p.muted),
                        ),
                        if (s.inContainer && s.type != 'http') ...[
                          const SizedBox(width: 8),
                          Pill('container', color: p.muted),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              Switch(value: s.enabled, onChanged: onEnabled),
              PopupMenuButton<String>(
                icon: Icon(LucideIcons.ellipsis, size: 18, color: p.muted),
                onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Remove')),
                ],
              ),
            ],
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(fontFamily: mono, color: p.muted),
            ),
          ],
          if (status == 'error' && s.error != null) ...[
            const SizedBox(height: 8),
            Text(
              s.error!,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(color: p.danger),
            ),
          ],
          if (tools.isNotEmpty) ...[
            const SizedBox(height: 4),
            TextButton.icon(
              style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
              onPressed: onToggleTools,
              icon: Icon(expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 14),
              label: Text(expanded ? 'Hide tools' : 'Show ${tools.length} tools'),
            ),
            if (expanded)
              Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final t in tools)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${t['name'] ?? ''}',
                              style: text.bodyMedium?.copyWith(fontFamily: mono, fontWeight: FontWeight.w600),
                            ),
                            if ((t['description'] as String? ?? '').isNotEmpty)
                              Text(
                                t['description'] as String,
                                maxLines: 3,
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
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// One editable key/value row.
class _Pair {
  _Pair(String k, String v) : key = TextEditingController(text: k), value = TextEditingController(text: v);
  final TextEditingController key;
  final TextEditingController value;

  void dispose() {
    key.dispose();
    value.dispose();
  }
}

/// Add/edit form for a server; pops the json map to save.
class _McpSheet extends StatefulWidget {
  const _McpSheet({this.existing, this.preset});
  final McpServer? existing;
  final _Preset? preset;

  @override
  State<_McpSheet> createState() => _McpSheetState();
}

class _McpSheetState extends State<_McpSheet> {
  late final TextEditingController _name;
  late final TextEditingController _command;
  late final TextEditingController _url;
  late String _type;
  late bool _inContainer;
  late bool _enabled;
  final _env = <_Pair>[];
  final _headers = <_Pair>[];
  String? _problem;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    final pr = widget.preset;
    _name = TextEditingController(text: e?.name ?? pr?.name.toLowerCase().split(' ').first ?? '');
    _command = TextEditingController(text: e?.command ?? pr?.command ?? '');
    _url = TextEditingController(text: e?.url ?? pr?.url ?? '');
    _type = e?.type ?? (pr?.url != null ? 'http' : 'stdio');
    if (_type != 'http') _type = 'stdio';
    _inContainer = e?.inContainer ?? pr?.inContainer ?? true;
    _enabled = e?.enabled ?? true;
    for (final kv in (e?.env ?? const {}).entries) {
      _env.add(_Pair(kv.key, kv.value));
    }
    for (final kv in (e?.headers ?? const {}).entries) {
      _headers.add(_Pair(kv.key, kv.value));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _url.dispose();
    for (final pair in [..._env, ..._headers]) {
      pair.dispose();
    }
    super.dispose();
  }

  Map<String, String> _collect(List<_Pair> pairs) => {
    for (final pair in pairs)
      if (pair.key.text.trim().isNotEmpty) pair.key.text.trim(): pair.value.text,
  };

  void _save() {
    final name = _name.text.trim();
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name)) {
      setState(() => _problem = 'Name: letters, digits, - and _ only.');
      return;
    }
    final http = _type == 'http';
    if (http && !(Uri.tryParse(_url.text.trim())?.hasScheme ?? false)) {
      setState(() => _problem = 'Enter a full URL (https://…).');
      return;
    }
    if (!http && _command.text.trim().isEmpty) {
      setState(() => _problem = 'Enter the command to start the server.');
      return;
    }
    Navigator.pop(context, <String, dynamic>{
      'id': ?widget.existing?.id,
      'name': name,
      'type': _type,
      'enabled': _enabled,
      if (http) ...{'url': _url.text.trim(), 'headers': _collect(_headers)},
      if (!http) ...{'command': _command.text.trim(), 'inContainer': _inContainer, 'env': _collect(_env)},
    });
  }

  Widget _pairsEditor(List<_Pair> pairs, {required String title, required String keyHint, required String valueHint}) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: text.titleSmall)),
            TextButton.icon(
              onPressed: () => setState(() => pairs.add(_Pair('', ''))),
              icon: const Icon(LucideIcons.plus, size: 14),
              label: const Text('Add'),
            ),
          ],
        ),
        for (final pair in pairs)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: pair.key,
                    autocorrect: false,
                    style: const TextStyle(fontFamily: mono, fontSize: 13),
                    decoration: InputDecoration(hintText: keyHint, isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: pair.value,
                    autocorrect: false,
                    style: const TextStyle(fontFamily: mono, fontSize: 13),
                    decoration: InputDecoration(hintText: valueHint, isDense: true),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() {
                    pairs.remove(pair);
                    pair.dispose();
                  }),
                  icon: Icon(LucideIcons.x, size: 16, color: p.muted),
                ),
              ],
            ),
          ),
        if (pairs.any((x) => x.value.text == '•••'))
          Text('••• keeps the saved value unchanged.', style: text.bodySmall?.copyWith(color: p.muted)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final http = _type == 'http';
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.existing == null ? 'Add MCP server' : 'Edit ${widget.existing!.name}', style: text.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'memory'),
            ),
            const SizedBox(height: 14),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'stdio', label: Text('Command'), icon: Icon(LucideIcons.squareTerminal, size: 16)),
                ButtonSegment(value: 'http', label: Text('HTTP'), icon: Icon(LucideIcons.globe, size: 16)),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() {
                _type = s.first;
                _problem = null;
              }),
            ),
            const SizedBox(height: 14),
            if (!http) ...[
              TextField(
                controller: _command,
                autocorrect: false,
                minLines: 1,
                maxLines: 3,
                style: const TextStyle(fontFamily: mono, fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Command line',
                  hintText: 'npx -y @modelcontextprotocol/server-memory',
                ),
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _inContainer,
                onChanged: (v) => setState(() => _inContainer = v),
                title: Text('Run inside the Linux container (needed for npx/uvx)', style: text.bodyMedium),
              ),
              const SizedBox(height: 6),
              _pairsEditor(_env, title: 'Environment variables', keyHint: 'API_KEY', valueHint: 'value'),
            ] else ...[
              TextField(
                controller: _url,
                autocorrect: false,
                keyboardType: TextInputType.url,
                style: const TextStyle(fontFamily: mono, fontSize: 13),
                decoration: const InputDecoration(labelText: 'URL', hintText: 'https://example.com/mcp'),
              ),
              const SizedBox(height: 14),
              _pairsEditor(_headers, title: 'Headers', keyHint: 'Authorization', valueHint: 'Bearer …'),
            ],
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
              title: Text('Enabled', style: text.bodyMedium),
            ),
            if (_problem != null) ...[
              const SizedBox(height: 6),
              Text(_problem!, style: text.bodySmall?.copyWith(color: p.danger)),
            ],
            const SizedBox(height: 16),
            PrimaryButton(label: 'Save', icon: LucideIcons.check, onPressed: _save),
          ],
        ),
      ),
    );
  }
}
