import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'ci_panel.dart';
import 'theme.dart';

/// Runs [task] in a bottom sheet that streams its output, then shows either
/// the error or whatever [onDone] builds from the result.
Future<T?> runWithLog<T>(
  BuildContext context, {
  required String title,
  required Future<T> Function(void Function(String line) log, void Function(Map<String, dynamic> ci) ci) task,
  Widget Function(BuildContext context, T result)? onDone,
  void Function(String url)? openUrl,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => _TaskSheet<T>(title: title, task: task, onDone: onDone, openUrl: openUrl),
  );
}

class _TaskSheet<T> extends StatefulWidget {
  const _TaskSheet({required this.title, required this.task, this.onDone, this.openUrl});
  final String title;
  final Future<T> Function(void Function(String line) log, void Function(Map<String, dynamic> ci) ci) task;
  final void Function(String url)? openUrl;
  final Widget Function(BuildContext context, T result)? onDone;

  @override
  State<_TaskSheet<T>> createState() => _TaskSheetState<T>();
}

class _TaskSheetState<T> extends State<_TaskSheet<T>> {
  final lines = <String>[];
  final scroll = ScrollController();
  bool running = true;
  Map<String, dynamic>? ci;
  Object? error;
  T? result;

  @override
  void initState() {
    super.initState();
    widget
        .task(_log, (c) {
          if (mounted) setState(() => ci = c);
        })
        .then(
          (r) => setState(() {
            running = false;
            result = r;
          }),
          onError: (Object e) => setState(() {
            running = false;
            error = e;
          }),
        );
  }

  void _log(String line) {
    if (!mounted) return;
    setState(() {
      // Progress redraws (e.g. git's "Receiving objects: 42%") replace the
      // previous line instead of piling up.
      final key = line.split(':').first;
      if (lines.isNotEmpty && line.contains('%') && lines.last.split(':').first == key) {
        lines[lines.length - 1] = line;
      } else {
        lines.add(line);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final Widget status = running
        ? SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: p.muted))
        : error != null
        ? Icon(LucideIcons.circleAlert, size: 20, color: p.danger)
        : Icon(LucideIcons.circleCheck, size: 20, color: p.success);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                status,
                const SizedBox(width: 10),
                Expanded(child: Text(widget.title, style: text.titleMedium)),
              ],
            ),
            const SizedBox(height: 14),
            if (ci != null)
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.4),
                child: SingleChildScrollView(
                  child: CiPanel(snapshot: ci!, onOpen: widget.openUrl),
                ),
              ),
            Container(
              height: ci != null ? 140 : 220,
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: p.border),
              ),
              child: ListView.builder(
                controller: scroll,
                padding: const EdgeInsets.all(12),
                itemCount: lines.length + (error != null ? 1 : 0),
                itemBuilder: (context, i) {
                  final isError = i == lines.length;
                  // The error repeats the command's last output; the log above has it.
                  final message = lines.isEmpty ? error.toString() : error.toString().split('\n').first;
                  return Text(
                    isError ? message : lines[i],
                    style: TextStyle(
                      fontFamily: mono,
                      fontSize: 11.5,
                      height: 1.5,
                      color: isError ? p.danger : p.muted,
                    ),
                  );
                },
              ),
            ),
            if (!running && error == null && result != null && widget.onDone != null) ...[
              const SizedBox(height: 14),
              widget.onDone!(context, result as T),
            ],
            const SizedBox(height: 14),
            FilledButton(
              onPressed: running ? null : () => Navigator.of(context).pop(error == null ? result : null),
              child: Text(running ? 'Working…' : (error == null ? 'Done' : 'Close')),
            ),
          ],
        ),
      ),
    );
  }
}
