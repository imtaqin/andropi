import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/features.dart';
import 'kit.dart';
import 'theme.dart';

String _money(num v) {
  if (v == 0) return r'$0.00';
  return v < 0.01 ? '\$${v.toStringAsFixed(4)}' : '\$${v.toStringAsFixed(2)}';
}

String _compact(num n) {
  String trim(double v) => v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '');
  if (n >= 1e9) return '${trim(n / 1e9)}B';
  if (n >= 1e6) return '${trim(n / 1e6)}M';
  if (n >= 1e3) return '${trim(n / 1e3)}k';
  return '${n.round()}';
}

num _num(Object? o) => o is num ? o : 0;

/// Token and cost usage across sessions, per day and per model, plus the
/// daily budget that stops runaway spend.
class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  int _days = 7;
  List<UsageRow>? _rows;
  Map<String, dynamic>? _session;
  Object? _error;

  AgentController get agent => widget.agent;

  @override
  void initState() {
    super.initState();
    _load();
    agent.features.sessionStats().then((s) {
      if (mounted) setState(() => _session = s);
    }, onError: (_) {});
    agent.integrations.refreshSettings().then((_) {
      if (mounted) setState(() {});
    }, onError: (_) {});
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final rows = await agent.features.usage(days: _days);
      if (mounted) setState(() => _rows = rows);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  num get _budget => _num(agent.integrations.settings?.json['dailyBudget']);

  Future<void> _editBudget() async {
    final ctrl = TextEditingController(text: _budget == 0 ? '' : '$_budget');
    final value = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Daily budget'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('pi stops starting new requests once today\'s spend reaches this. Leave empty for no limit.'),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              decoration: const InputDecoration(prefixText: r'$ ', hintText: 'No limit'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, double.tryParse(ctrl.text.trim()) ?? 0),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (value == null) return;
    try {
      await agent.integrations.updateSettings({'dailyBudget': value < 0 ? 0 : value});
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(title: const Text('Usage')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
          children: [
            Wrap(
              spacing: 8,
              children: [
                for (final d in const [7, 30])
                  ChoiceChip(
                    label: Text('$d days'),
                    selected: _days == d,
                    onSelected: (_) {
                      setState(() => _days = d);
                      _load();
                    },
                  ),
              ],
            ),
            const SizedBox(height: 14),
            if (_error != null)
              SurfaceCard(
                child: Text('$_error', style: text.bodySmall?.copyWith(color: p.danger)),
              )
            else if (rows == null)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              ..._summary(context, rows),
            const SectionLabel('This chat'),
            _sessionCard(context),
            const SectionLabel('Limits'),
            SettingsGroup(
              children: [
                SettingsRow(
                  icon: LucideIcons.wallet,
                  color: p.warning,
                  title: 'Daily budget',
                  subtitle: _budget == 0 ? 'No limit' : '${_money(_budget)} per day',
                  onTap: _editBudget,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _summary(BuildContext context, List<UsageRow> rows) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final cost = rows.fold<double>(0, (a, r) => a + r.cost);
    final input = rows.fold<int>(0, (a, r) => a + r.input);
    final output = rows.fold<int>(0, (a, r) => a + r.output);
    final requests = rows.fold<int>(0, (a, r) => a + r.requests);
    final useCost = cost > 0;

    final today = DateTime.now();
    final days = [
      for (var i = _days - 1; i >= 0; i--)
        DateTime(today.year, today.month, today.day - i).toIso8601String().substring(0, 10),
    ];
    final perDay = {for (final d in days) d: 0.0};
    for (final r in rows) {
      if (perDay.containsKey(r.day)) {
        perDay[r.day] = perDay[r.day]! + (useCost ? r.cost : (r.input + r.output).toDouble());
      }
    }

    final byModel = <String, ({String provider, String model, int tokens, double cost})>{};
    for (final r in rows) {
      final k = '${r.provider}/${r.model}';
      final prev = byModel[k];
      byModel[k] = (
        provider: r.provider,
        model: r.model,
        tokens: (prev?.tokens ?? 0) + r.input + r.output,
        cost: (prev?.cost ?? 0) + r.cost,
      );
    }
    final models = byModel.values.toList()
      ..sort((a, b) => useCost ? b.cost.compareTo(a.cost) : b.tokens.compareTo(a.tokens));

    return [
      Row(
        children: [
          Expanded(
            child: _StatCard(icon: LucideIcons.coins, color: p.accent, label: 'Cost', value: _money(cost)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _StatCard(
              icon: LucideIcons.activity,
              color: p.accentAlt,
              label: 'Requests',
              value: _compact(requests),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: _StatCard(
              icon: LucideIcons.arrowUpFromLine,
              color: p.success,
              label: 'Input tokens',
              value: _compact(input),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _StatCard(
              icon: LucideIcons.arrowDownToLine,
              color: p.warning,
              label: 'Output tokens',
              value: _compact(output),
            ),
          ),
        ],
      ),
      SectionLabel(useCost ? 'Cost per day' : 'Tokens per day'),
      SurfaceCard(
        child: _BarChart(values: [for (final d in days) perDay[d]!], labels: days, format: useCost ? _money : _compact),
      ),
      const SectionLabel('By model'),
      if (models.isEmpty)
        SurfaceCard(child: Text('No requests in this period.', style: text.bodySmall))
      else
        SettingsGroup(
          children: [
            for (final m in models)
              SettingsRow(
                leading: BrandTile(id: m.provider, size: 30),
                title: m.model.isEmpty ? 'unknown' : m.model,
                subtitle: '${m.provider} · ${_compact(m.tokens)} tokens',
                trailing: Text(_money(m.cost), style: text.titleSmall?.copyWith(fontFamily: mono)),
              ),
          ],
        ),
    ];
  }

  Widget _sessionCard(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final s = _session;
    if (s == null) {
      return SurfaceCard(child: Text('No active chat.', style: text.bodySmall));
    }
    final tokens = s['tokens'];
    final total = tokens is Map ? _num(tokens['total']) : _num(tokens);
    final cost = _num(s['cost']);
    final ctx = s['context'] is Map ? (s['context'] as Map).cast<String, dynamic>() : null;
    final ctxTokens = ctx?['tokens'] is num ? ctx!['tokens'] as num : null;
    final window = ctx?['contextWindow'] is num ? ctx!['contextWindow'] as num : null;
    var percent = ctx?['percent'] is num ? (ctx!['percent'] as num).toDouble() : null;
    if (percent == null && ctxTokens != null && window != null && window > 0) percent = ctxTokens / window * 100;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(icon: LucideIcons.messageSquare, color: p.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${_compact(total)} tokens', style: text.titleMedium),
                    Text(_money(cost), style: text.bodySmall?.copyWith(fontFamily: mono)),
                  ],
                ),
              ),
            ],
          ),
          if (percent != null) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: Text('Context window', style: text.bodySmall)),
                Text(
                  [
                    if (ctxTokens != null && window != null) '${_compact(ctxTokens)} / ${_compact(window)}',
                    '${percent.toStringAsFixed(0)}%',
                  ].join(' · '),
                  style: text.bodySmall?.copyWith(fontFamily: mono),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: (percent / 100).clamp(0, 1).toDouble(),
                minHeight: 8,
                backgroundColor: p.border,
                color: percent > 85 ? p.danger : (percent > 60 ? p.warning : p.accent),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.icon, required this.color, required this.label, required this.value});
  final IconData icon;
  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SurfaceCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconTile(icon: icon, color: color, size: 30),
          const SizedBox(height: 12),
          Text(value, style: text.titleLarge?.copyWith(fontFamily: mono)),
          const SizedBox(height: 2),
          Text(label, style: text.bodySmall),
        ],
      ),
    );
  }
}

/// Flat bars, one per day; the tallest is labelled.
class _BarChart extends StatelessWidget {
  const _BarChart({required this.values, required this.labels, required this.format});
  final List<double> values;
  final List<String> labels;
  final String Function(num) format;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final max = values.fold<double>(0, (a, v) => v > a ? v : a);
    final gap = values.length > 14 ? 3.0 : 8.0;
    String short(String d) => d.length >= 10 ? d.substring(5) : d;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(max == 0 ? 'Nothing yet' : 'Peak ${format(max)}', style: text.bodySmall?.copyWith(fontFamily: mono)),
        const SizedBox(height: 12),
        SizedBox(
          height: 120,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < values.length; i++) ...[
                if (i > 0) SizedBox(width: gap),
                Expanded(
                  child: Tooltip(
                    message: '${labels[i]}: ${format(values[i])}',
                    child: Container(
                      height: max == 0 ? 3 : (values[i] / max * 116).clamp(3, 116).toDouble(),
                      decoration: BoxDecoration(
                        color: values[i] == 0 ? p.border : p.accent,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(short(labels.first), style: text.labelSmall),
            const Spacer(),
            Text(short(labels.last), style: text.labelSmall),
          ],
        ),
      ],
    );
  }
}
