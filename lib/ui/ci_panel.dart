import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'theme.dart';

/// Live CI state from the host: GitHub Actions runs → jobs → steps, or a
/// Vercel build as a single run.
class CiPanel extends StatelessWidget {
  const CiPanel({super.key, required this.snapshot, this.onOpen});
  final Map<String, dynamic> snapshot;
  final void Function(String url)? onOpen;

  @override
  Widget build(BuildContext context) {
    final runs = (snapshot['runs'] as List? ?? const []).cast<Map>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in runs) ...[_Run(run: r.cast<String, dynamic>(), onOpen: onOpen), const SizedBox(height: 8)],
      ],
    );
  }
}

/// Icon for a GitHub-style status/conclusion pair.
Widget ciStatusIcon(BuildContext context, String? status, String? conclusion, {double size = 16}) {
  final p = context.palette;
  if (status != 'completed') {
    if (status == 'in_progress') {
      return SizedBox.square(
        dimension: size - 3,
        child: CircularProgressIndicator(strokeWidth: 1.8, color: const Color(0xFFE3B341)),
      );
    }
    return Icon(LucideIcons.circle, size: size, color: p.faint);
  }
  return switch (conclusion) {
    'success' => Icon(LucideIcons.circleCheck, size: size, color: p.success),
    'skipped' || 'neutral' => Icon(LucideIcons.circleMinus, size: size, color: p.faint),
    'cancelled' => Icon(LucideIcons.ban, size: size, color: p.faint),
    _ => Icon(LucideIcons.circleX, size: size, color: p.danger),
  };
}

class _Run extends StatelessWidget {
  const _Run({required this.run, this.onOpen});
  final Map<String, dynamic> run;
  final void Function(String url)? onOpen;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final jobs = (run['jobs'] as List? ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
    final url = run['url'] as String?;
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                ciStatusIcon(context, run['status'] as String?, run['conclusion'] as String?),
                const SizedBox(width: 10),
                Expanded(child: Text(run['name'] as String? ?? 'workflow', style: text.titleSmall)),
                if (url != null && onOpen != null)
                  TextButton(
                    onPressed: () => onOpen!(url),
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: p.muted),
                    child: const Text('View'),
                  ),
              ],
            ),
          ),
          if (jobs.isNotEmpty) Divider(height: 1, color: p.border),
          for (final j in jobs) _Job(job: j),
        ],
      ),
    );
  }
}

class _Job extends StatelessWidget {
  const _Job({required this.job});
  final Map<String, dynamic> job;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final status = job['status'] as String?;
    final conclusion = job['conclusion'] as String?;
    final steps = (job['steps'] as List? ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
    // Steps matter while a job runs or after it fails; otherwise one line is enough.
    final expand =
        status == 'in_progress' || (status == 'completed' && conclusion != 'success' && conclusion != 'skipped');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ciStatusIcon(context, status, conclusion, size: 14),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  job['name'] as String? ?? 'job',
                  style: TextStyle(fontFamily: mono, fontSize: 12.5, color: p.text),
                ),
              ),
              if (!expand && steps.isNotEmpty)
                Text('${steps.length} steps', style: TextStyle(fontSize: 11, color: p.faint)),
            ],
          ),
          if (expand)
            for (final s in steps)
              Padding(
                padding: const EdgeInsets.only(left: 24, top: 6),
                child: Row(
                  children: [
                    ciStatusIcon(context, s['status'] as String?, s['conclusion'] as String?, size: 12),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        s['name'] as String? ?? '',
                        style: TextStyle(fontSize: 12, color: s['status'] == 'completed' ? p.muted : p.text),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
