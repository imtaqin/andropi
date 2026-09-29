import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/features.dart';
import 'illustration.dart';
import 'kit.dart';
import 'theme.dart';

/// Prompt templates: reusable prompts the user runs as `/name args` in chat.
class TemplatesScreen extends StatefulWidget {
  const TemplatesScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<TemplatesScreen> createState() => _TemplatesScreenState();
}

class _TemplatesScreenState extends State<TemplatesScreen> {
  List<PromptTemplate>? _templates;
  Object? _error;

  Features get f => widget.agent.features;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await f.templates();
      t.sort((a, b) => a.name.compareTo(b.name));
      if (mounted) {
        setState(() {
          _templates = t;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _snack(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _edit([PromptTemplate? existing]) async {
    final result = await showModalBottomSheet<_TemplateDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TemplateSheet(existing: existing, taken: {...?_templates?.map((t) => t.name)}),
    );
    if (result == null) return;
    try {
      await f.saveTemplate(
        result.name,
        result.description,
        result.body,
        argumentHint: result.hint.isEmpty ? null : result.hint,
      );
      if (existing != null && existing.name != result.name) await f.deleteTemplate(existing.name);
      await _load();
    } catch (e) {
      _snack('$e');
    }
  }

  Future<bool> _delete(PromptTemplate t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete /${t.name}?'),
        content: const Text('The slash command will no longer be available in chat.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return false;
    try {
      await f.deleteTemplate(t.name);
      await _load();
      return true;
    } catch (e) {
      _snack('$e');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final list = _templates;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prompt templates'),
        actions: [IconButton(tooltip: 'New template', onPressed: _edit, icon: const Icon(LucideIcons.plus))],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
          children: [
            SurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconTile(icon: LucideIcons.slash, color: p.accent),
                      const SizedBox(width: 12),
                      Expanded(child: Text('Slash commands', style: text.titleMedium)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Type /name followed by arguments in chat and pi expands the template.',
                    style: text.bodyMedium?.copyWith(color: p.muted),
                  ),
                  const SizedBox(height: 12),
                  for (final (code, meaning) in const [
                    (r'$1, $2', 'the first, second argument'),
                    (r'$@', 'all arguments'),
                    (r'${1:-default}', 'argument 1, or default when missing'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 118,
                            child: Text(
                              code,
                              style: text.bodySmall?.copyWith(fontFamily: mono, color: p.text),
                            ),
                          ),
                          Expanded(child: Text(meaning, style: text.bodySmall)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            SectionLabel(
              'Templates',
              trailing: TextButton.icon(
                onPressed: _edit,
                icon: const Icon(LucideIcons.plus, size: 14),
                label: const Text('New template'),
              ),
            ),
            if (_error != null)
              SurfaceCard(
                child: Text('$_error', style: text.bodySmall?.copyWith(color: p.danger)),
              )
            else if (list == null)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (list.isEmpty)
              SurfaceCard(
                onTap: _edit,
                child: Column(
                  children: [
                    const Illustration('ai', height: 140),
                    const SizedBox(height: 8),
                    Text('No templates yet. Save a prompt you use often.', style: text.bodySmall),
                  ],
                ),
              )
            else
              for (final t in list) ...[
                Dismissible(
                  key: ValueKey(t.name),
                  direction: DismissDirection.endToStart,
                  confirmDismiss: (_) => _delete(t),
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    decoration: BoxDecoration(color: p.danger, borderRadius: BorderRadius.circular(24)),
                    child: const Icon(LucideIcons.trash2, color: Colors.white),
                  ),
                  child: SurfaceCard(
                    padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
                    onTap: () => _edit(t),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '/${t.name}${t.argumentHint?.isNotEmpty == true ? ' ${t.argumentHint}' : ''}',
                                style: text.titleSmall?.copyWith(fontFamily: mono),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (t.description.isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Text(
                                  t.description,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodySmall,
                                ),
                              ],
                            ],
                          ),
                        ),
                        PopupMenuButton<String>(
                          icon: Icon(LucideIcons.ellipsis, size: 18, color: p.muted),
                          onSelected: (v) => v == 'edit' ? _edit(t) : _delete(t),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('Edit')),
                            PopupMenuItem(value: 'delete', child: Text('Delete')),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
          ],
        ),
      ),
    );
  }
}

typedef _TemplateDraft = ({String name, String description, String hint, String body});

class _TemplateSheet extends StatefulWidget {
  const _TemplateSheet({this.existing, required this.taken});
  final PromptTemplate? existing;
  final Set<String> taken;

  @override
  State<_TemplateSheet> createState() => _TemplateSheetState();
}

class _TemplateSheetState extends State<_TemplateSheet> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _description = TextEditingController(text: widget.existing?.description ?? '');
  late final _hint = TextEditingController(text: widget.existing?.argumentHint ?? '');
  late final _body = TextEditingController(text: widget.existing?.body ?? '');
  String? _problem;

  @override
  void dispose() {
    for (final c in [_name, _description, _hint, _body]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim().replaceFirst(RegExp(r'^/'), '');
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*$').hasMatch(name)) {
      setState(() => _problem = 'Name: letters, digits, - and _ (no spaces).');
      return;
    }
    if (name != widget.existing?.name && widget.taken.contains(name)) {
      setState(() => _problem = '/$name already exists.');
      return;
    }
    if (_body.text.trim().isEmpty) {
      setState(() => _problem = 'The template needs a body.');
      return;
    }
    Navigator.pop<_TemplateDraft>(context, (
      name: name,
      description: _description.text.trim(),
      hint: _hint.text.trim(),
      body: _body.text,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.existing == null ? 'New template' : 'Edit template', style: text.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              autocorrect: false,
              style: const TextStyle(fontFamily: mono),
              decoration: const InputDecoration(labelText: 'Name', prefixText: '/', hintText: 'review'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _description,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Description', hintText: 'Review a file for bugs'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _hint,
              autocorrect: false,
              style: const TextStyle(fontFamily: mono),
              decoration: const InputDecoration(labelText: 'Argument hint', hintText: '<file> [focus]'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _body,
              minLines: 6,
              maxLines: 16,
              style: const TextStyle(fontFamily: mono, fontSize: 13),
              decoration: const InputDecoration(
                labelText: 'Body',
                alignLabelWithHint: true,
                hintText: r'Review $1 for bugs, focusing on ${2:-correctness}.',
              ),
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
