import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/models.dart';
import 'settings_screen.dart';
import 'theme.dart';

Future<void> showModelSheet(BuildContext context, AgentController agent) {
  agent.refreshProviders();
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _ModelSheet(agent: agent),
  );
}

class _ModelSheet extends StatefulWidget {
  const _ModelSheet({required this.agent});
  final AgentController agent;

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.agent,
      builder: (context, _) {
        final agent = widget.agent;
        final q = query.toLowerCase();
        final filtered = agent.models
            .where((m) => q.isEmpty || m.name.toLowerCase().contains(q) || m.key.toLowerCase().contains(q))
            .toList();
        final byProvider = <String, List<ModelInfo>>{};
        for (final m in filtered) {
          byProvider.putIfAbsent(m.provider, () => []).add(m);
        }
        final names = {for (final pr in agent.providers) pr.id: pr.name};

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          builder: (context, scroll) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Row(
                  children: [
                    Expanded(child: Text('Model', style: text.titleLarge)),
                    TextButton(
                      onPressed: () {
                        final nav = Navigator.of(context)..pop();
                        nav.push(MaterialPageRoute(builder: (_) => SettingsScreen(agent: agent)));
                      },
                      child: const Text('Providers'),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: TextField(
                  onChanged: (v) => setState(() => query = v),
                  decoration: const InputDecoration(
                    hintText: 'Search models',
                    prefixIcon: Icon(LucideIcons.search, size: 18),
                  ),
                ),
              ),
              Expanded(
                child: agent.models.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            'No models yet. Connect a provider to see its models here.',
                            style: text.bodyMedium?.copyWith(color: p.muted),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView(
                        controller: scroll,
                        padding: const EdgeInsets.only(bottom: 24),
                        children: [
                          for (final entry in byProvider.entries) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
                              child: Text((names[entry.key] ?? entry.key).toUpperCase(), style: text.labelSmall),
                            ),
                            for (final m in entry.value) _ModelTile(model: m, agent: agent),
                          ],
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({required this.model, required this.agent});
  final ModelInfo model;
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final selected = agent.model?.key == model.key;
    final details = [
      if (model.contextWindow != null && model.contextWindow! > 0) '${(model.contextWindow! / 1000).round()}k context',
      if (model.reasoning) 'reasoning',
      if (model.acceptsImages) 'vision',
    ].join('  ·  ');
    return ListTile(
      onTap: () async {
        Navigator.of(context).pop();
        await agent.setModel(model);
      },
      title: Text(model.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: details.isEmpty ? null : Text(details),
      trailing: selected ? Icon(LucideIcons.check, size: 18, color: p.text) : null,
    );
  }
}
