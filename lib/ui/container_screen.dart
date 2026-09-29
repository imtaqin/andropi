import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/integrations.dart';
import 'kit.dart';
import 'task_log.dart';
import 'terminal_screen.dart';
import 'theme.dart';

class _Distro {
  const _Distro(this.id, this.name, this.icon, this.color, this.blurb, this.size);
  final String id;
  final String name;
  final IconData icon;
  final Color color;
  final String blurb;
  final String size;
}

const _distros = [
  _Distro(
    'debian',
    'Debian',
    SimpleIcons.debian,
    Color(0xFFD70A53),
    'apt, glibc. Best compatibility: pip wheels, Node native modules.',
    '~30 MB',
  ),
  _Distro(
    'alpine',
    'Alpine',
    SimpleIcons.alpinelinux,
    Color(0xFF0D597F),
    'apk, musl. Tiny and fast; some prebuilt binaries won\'t run.',
    '~4 MB',
  ),
];

/// Install and manage the Linux userland the agent can use.
class ContainerScreen extends StatefulWidget {
  const ContainerScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<ContainerScreen> createState() => _ContainerScreenState();
}

class _ContainerScreenState extends State<ContainerScreen> {
  Integrations get it => widget.agent.integrations;
  String choice = 'debian';
  bool switching = false;

  @override
  void initState() {
    super.initState();
    it.refreshContainer().catchError((_) => it.container!);
  }

  Future<void> _install() async {
    final d = _distros.firstWhere((x) => x.id == choice);
    final ok = await runWithLog<bool>(
      context,
      title: 'Installing ${d.name}',
      task: (log, _) async {
        await it.installContainer(choice, onLine: log);
        return true;
      },
    );
    if (ok == true && mounted) await _setShell(true);
  }

  Future<void> _setShell(bool on) async {
    setState(() => switching = true);
    try {
      await it.setContainerShell(on);
      await widget.agent.refreshState();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => switching = false);
    }
  }

  Future<void> _remove() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove the container?'),
        content: const Text('Everything installed inside it is deleted. Your workspace files are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.palette.danger, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await it.removeContainer();
    await widget.agent.refreshState();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: it,
      builder: (context, _) {
        final c = it.container;
        final installed = c?.installed == true;
        final d = _distros.firstWhere((x) => x.id == (c?.distro ?? choice), orElse: () => _distros.first);
        return Scaffold(
          appBar: AppBar(title: const Text('Linux container')),
          body: c == null
              ? const Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
                  children: [
                    SurfaceCard(
                      highlight: installed && c.enabled,
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              IconTile(
                                icon: installed ? d.icon : LucideIcons.container,
                                color: installed ? d.color : p.accent,
                                size: 48,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(installed ? d.name : 'Real Linux on your phone', style: text.titleMedium),
                                    const SizedBox(height: 3),
                                    Text(
                                      installed ? c.image ?? '' : 'Install packages with apt or apk',
                                      style: TextStyle(
                                        fontFamily: installed ? mono : null,
                                        fontSize: 12.5,
                                        color: p.muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (installed)
                                Pill(
                                  c.enabled ? 'Agent shell' : 'Installed',
                                  color: c.enabled ? p.success : p.muted,
                                  dot: true,
                                ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'Runs through proot: no root or Termux needed. Your home folder and workspace are the same '
                            'paths inside, so the agent can `apt install python3 nodejs` and work on your files directly.',
                            style: text.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (!installed) ...[
                      const SectionLabel('Choose a distribution'),
                      for (final x in _distros) ...[
                        _DistroCard(distro: x, selected: choice == x.id, onTap: () => setState(() => choice = x.id)),
                        const SizedBox(height: 10),
                      ],
                      const SizedBox(height: 8),
                      PrimaryButton(
                        label: 'Install ${_distros.firstWhere((x) => x.id == choice).name}',
                        icon: LucideIcons.download,
                        onPressed: _install,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Downloads the official image from Docker Hub, then installs git, curl, ssh and certificates.',
                        textAlign: TextAlign.center,
                        style: text.bodySmall,
                      ),
                    ] else ...[
                      const SectionLabel('Agent'),
                      SettingsGroup(
                        children: [
                          SettingsRow(
                            icon: LucideIcons.squareTerminal,
                            color: p.accent,
                            title: 'Use as the agent\'s shell',
                            subtitle: c.enabled
                                ? 'Every command pi runs happens inside ${d.name}'
                                : 'pi uses the Android shell; `box` still reaches Linux',
                            trailing: switching
                                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : Switch(value: c.enabled, onChanged: widget.agent.busy ? null : _setShell),
                          ),
                          SettingsRow(
                            icon: LucideIcons.terminal,
                            color: const Color(0xFF22C55E),
                            title: 'Open a Linux shell',
                            subtitle: 'Terminal inside the container',
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => TerminalScreen(agent: widget.agent, command: 'box'),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SectionLabel('Try'),
                      SurfaceCard(
                        padding: const EdgeInsets.all(14),
                        child: SelectableText(
                          d.id == 'alpine'
                              ? 'apk add python3 py3-pip nodejs npm build-base'
                              : 'apt-get update\napt-get install -y python3 python3-pip nodejs npm build-essential',
                          style: TextStyle(fontFamily: mono, fontSize: 12.5, height: 1.6, color: p.text),
                        ),
                      ),
                      const SectionLabel('Manage'),
                      SettingsGroup(
                        children: [
                          SettingsRow(
                            icon: LucideIcons.trash2,
                            color: p.danger,
                            title: 'Remove container',
                            subtitle: 'Frees the space; workspace files stay',
                            destructive: true,
                            onTap: widget.agent.busy ? null : _remove,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
        );
      },
    );
  }
}

class _DistroCard extends StatelessWidget {
  const _DistroCard({required this.distro, required this.selected, required this.onTap});
  final _Distro distro;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return SurfaceCard(
      highlight: selected,
      onTap: onTap,
      child: Row(
        children: [
          IconTile(icon: distro.icon, color: distro.color, size: 44),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(distro.name, style: text.titleSmall),
                    const SizedBox(width: 8),
                    Text(
                      distro.size,
                      style: TextStyle(fontFamily: mono, fontSize: 11, color: p.faint),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(distro.blurb, style: text.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 8),
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? p.accent : null,
              border: selected ? null : Border.all(color: p.border, width: 2),
            ),
            child: selected ? const Icon(LucideIcons.check, size: 13, color: Colors.white) : null,
          ),
        ],
      ),
    );
  }
}
