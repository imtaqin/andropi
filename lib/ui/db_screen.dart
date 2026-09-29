import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/features.dart';
import 'kit.dart';
import 'theme.dart';

/// A small SQLite browser: tables with row counts, a data grid, and a SQL
/// console. Queries run on the host (sqlite3), so the app needs no driver.
class DbScreen extends StatefulWidget {
  const DbScreen({super.key, required this.agent, required this.path});
  final AgentController agent;
  final String path;

  @override
  State<DbScreen> createState() => _DbScreenState();
}

class _DbScreenState extends State<DbScreen> {
  List<DbTable>? tables;
  Object? tablesError;

  String? table;
  DbResult? tableData;
  Object? tableError;
  bool tableBusy = false;

  final sql = TextEditingController();
  final history = <String>[];
  DbResult? sqlResult;
  Object? sqlError;
  bool sqlBusy = false;

  AgentController get agent => widget.agent;

  @override
  void initState() {
    super.initState();
    _loadTables();
  }

  @override
  void dispose() {
    sql.dispose();
    super.dispose();
  }

  Future<void> _loadTables() async {
    setState(() {
      tables = null;
      tablesError = null;
    });
    try {
      final t = await agent.features.dbTables(widget.path);
      if (mounted) setState(() => tables = t);
    } catch (e) {
      if (mounted) setState(() => tablesError = e);
    }
  }

  Future<void> _openTable(String name) async {
    setState(() {
      table = name;
      tableData = null;
      tableError = null;
      tableBusy = true;
    });
    try {
      final r = await agent.features.dbQuery(widget.path, 'SELECT * FROM "${name.replaceAll('"', '""')}" LIMIT 200');
      if (mounted && table == name) setState(() => tableData = r);
    } catch (e) {
      if (mounted && table == name) setState(() => tableError = e);
    } finally {
      if (mounted && table == name) setState(() => tableBusy = false);
    }
  }

  Future<void> _runSql() async {
    final q = sql.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      sqlBusy = true;
      sqlError = null;
      history.remove(q);
      history.insert(0, q);
      if (history.length > 10) history.removeLast();
    });
    try {
      final r = await agent.features.dbQuery(widget.path, q);
      if (mounted) setState(() => sqlResult = r);
    } catch (e) {
      if (mounted) {
        setState(() {
          sqlResult = null;
          sqlError = e;
        });
      }
    } finally {
      if (mounted) setState(() => sqlBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final name = widget.path.split('/').last;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(name),
              Text(
                widget.path.replaceFirst(RegExp(r'^.*/files/home'), '~'),
                style: TextStyle(fontFamily: mono, fontSize: 11.5, color: p.muted),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Reload',
              icon: const Icon(LucideIcons.rotateCcw, size: 20),
              onPressed: () {
                _loadTables();
                final t = table;
                if (t != null) _openTable(t);
              },
            ),
            const SizedBox(width: 4),
          ],
          bottom: TabBar(
            labelColor: p.text,
            unselectedLabelColor: p.muted,
            indicatorColor: p.text,
            dividerColor: p.border,
            tabs: const [
              Tab(text: 'Tables'),
              Tab(text: 'SQL'),
            ],
          ),
        ),
        body: TabBarView(children: [_tablesTab(context), _sqlTab(context)]),
      ),
    );
  }

  Widget _tablesTab(BuildContext context) {
    final t = table;
    if (t != null) {
      return Column(
        children: [
          _TableBar(
            name: t,
            onBack: () => setState(() {
              table = null;
              tableData = null;
              tableError = null;
            }),
          ),
          Expanded(
            child: tableError != null
                ? _ErrorBox(error: tableError!)
                : tableBusy || tableData == null
                ? const _Spinner()
                : _Grid(result: tableData!),
          ),
        ],
      );
    }
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final list = tables;
    if (tablesError != null) return _ErrorBox(error: tablesError!);
    if (list == null) return const _Spinner();
    if (list.isEmpty) {
      return Center(
        child: Text('No tables in this database', style: text.bodyMedium?.copyWith(color: p.muted)),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
      children: [
        SettingsGroup(
          children: [
            for (final t in list)
              SettingsRow(
                icon: t.type == 'view' ? LucideIcons.eye : LucideIcons.table,
                color: t.type == 'view' ? p.accentAlt : p.accent,
                title: t.name,
                subtitle: t.type,
                trailing: t.rows == null ? null : Pill('${t.rows} rows'),
                onTap: () => _openTable(t.name),
              ),
          ],
        ),
      ],
    );
  }

  Widget _sqlTab(BuildContext context) {
    final p = context.palette;
    final r = sqlResult;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: sql,
            minLines: 3,
            maxLines: 8,
            keyboardType: TextInputType.multiline,
            style: const TextStyle(fontFamily: mono, fontSize: 13),
            decoration: const InputDecoration(hintText: 'SELECT * FROM ...'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final h in history)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ActionChip(
                            label: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 180),
                              child: Text(
                                h.replaceAll(RegExp(r'\s+'), ' '),
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontFamily: mono, fontSize: 11.5),
                              ),
                            ),
                            avatar: Icon(LucideIcons.history, size: 13, color: p.muted),
                            visualDensity: VisualDensity.compact,
                            onPressed: () => setState(() => sql.text = h),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 110,
                child: PrimaryButton(label: 'Run', icon: LucideIcons.play, busy: sqlBusy, onPressed: _runSql),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: p.border),
        Expanded(
          child: sqlError != null
              ? _ErrorBox(error: sqlError!)
              : sqlBusy
              ? const _Spinner()
              : r == null
              ? Center(
                  child: Text(
                    'Run a query to see results',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: p.muted),
                  ),
                )
              : r.columns.isEmpty
              ? Center(
                  child: Pill('${r.changes ?? 0} rows changed', color: p.success, icon: LucideIcons.check),
                )
              : _Grid(result: r),
        ),
      ],
    );
  }
}

class _TableBar extends StatelessWidget {
  const _TableBar({required this.name, required this.onBack});
  final String name;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      padding: const EdgeInsets.fromLTRB(4, 2, 16, 2),
      child: Row(
        children: [
          IconButton(icon: const Icon(LucideIcons.chevronLeft, size: 20), onPressed: onBack),
          Icon(LucideIcons.table, size: 16, color: p.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              style: const TextStyle(fontFamily: mono, fontSize: 13.5, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text('first 200 rows', style: TextStyle(fontSize: 12, color: p.muted)),
        ],
      ),
    );
  }
}

/// Header row above a scrolling body; both scroll together horizontally.
class _Grid extends StatelessWidget {
  const _Grid({required this.result});
  final DbResult result;

  static const _maxChars = 40;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final cols = result.columns;
    final rows = result.rows;
    final widths = [
      for (var i = 0; i < cols.length; i++)
        _width([cols[i], for (final r in rows.take(50)) i < r.length ? _str(r[i]) : '']),
    ];
    final total = widths.fold<double>(0, (a, b) => a + b);
    const cellPad = EdgeInsets.symmetric(horizontal: 10, vertical: 7);

    Widget cell(BuildContext context, Object? v, double w) {
      final s = _str(v);
      final long = s.length > _maxChars || s.contains('\n');
      return InkWell(
        onTap: long ? () => _showValue(context, s) : null,
        child: Container(
          width: w,
          padding: cellPad,
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: p.border)),
          ),
          child: Text(
            v == null ? 'NULL' : s.replaceAll('\n', ' '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: mono,
              fontSize: 12,
              color: v == null ? p.faint : p.text,
              fontStyle: v == null ? FontStyle.italic : FontStyle.normal,
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text('${rows.length} rows · ${cols.length} columns', style: TextStyle(fontSize: 12, color: p.muted)),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: total,
              child: Column(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: p.surface,
                      border: Border(
                        top: BorderSide(color: p.border),
                        bottom: BorderSide(color: p.border),
                      ),
                    ),
                    child: Row(
                      children: [
                        for (var i = 0; i < cols.length; i++)
                          Container(
                            width: widths[i],
                            padding: cellPad,
                            decoration: BoxDecoration(
                              border: Border(right: BorderSide(color: p.border)),
                            ),
                            child: Text(
                              cols[i],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontFamily: mono, fontSize: 12, fontWeight: FontWeight.w700),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.only(bottom: 40),
                      itemCount: rows.length,
                      itemBuilder: (context, r) => Container(
                        decoration: BoxDecoration(
                          color: r.isOdd ? p.surface.withValues(alpha: 0.5) : null,
                          border: Border(bottom: BorderSide(color: p.border.withValues(alpha: 0.6))),
                        ),
                        child: Row(
                          children: [
                            for (var i = 0; i < cols.length; i++)
                              cell(context, i < rows[r].length ? rows[r][i] : null, widths[i]),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String _str(Object? v) => v == null ? 'NULL' : '$v';

  static double _width(List<String> samples) {
    var n = 4;
    for (final s in samples) {
      final l = s.length > _maxChars ? _maxChars : s.length;
      if (l > n) n = l;
    }
    return n * 7.4 + 22;
  }

  static void _showValue(BuildContext context, String value) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: SingleChildScrollView(
            child: SelectableText(value, style: const TextStyle(fontFamily: mono, fontSize: 12.5)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              Navigator.of(context).pop();
            },
            child: const Text('Copy'),
          ),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: p.danger.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: p.danger.withValues(alpha: 0.3)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.circleAlert, size: 16, color: p.danger),
              const SizedBox(width: 10),
              Expanded(
                child: SelectableText(
                  '$error',
                  style: TextStyle(fontFamily: mono, fontSize: 12.5, color: p.danger),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) =>
      const Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)));
}
