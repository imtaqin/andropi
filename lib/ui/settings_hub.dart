import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';

import '../agent/agent_controller.dart';
import 'accounts_screen.dart';
import 'backup_screen.dart';
import 'chat_extras.dart';
import 'container_screen.dart';
import 'kit.dart';
import 'i18n.dart';
import 'illustration.dart';
import 'mcp_screen.dart';
import 'mesh.dart';
import 'network_screen.dart';
import 'settings_screen.dart';
import 'skills_screen.dart';
import 'tasks_screen.dart';
import 'templates_screen.dart';
import 'theme.dart';
import 'usage_screen.dart';

/// The settings home: everything the agent can use, grouped.
class SettingsHub extends StatefulWidget {
  const SettingsHub({super.key, required this.agent});
  final AgentController agent;

  @override
  State<SettingsHub> createState() => _SettingsHubState();
}

class _SettingsHubState extends State<SettingsHub> {
  int? skillCount;

  AgentController get agent => widget.agent;

  @override
  void initState() {
    super.initState();
    final it = agent.integrations;
    it.refresh().catchError((_) {});
    it.refreshContainer().catchError((_) => it.container!);
    it.refreshSettings().catchError((_) => it.settings!);
    it.skills().then((s) {
      if (mounted) setState(() => skillCount = s.length);
    }, onError: (_) {});
  }

  void _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (!mounted) return;
    agent.integrations.skills().then((s) {
      if (mounted) setState(() => skillCount = s.length);
    }, onError: (_) {});
  }

  Future<void> _setAppLock(bool on) async {
    if (on) {
      // Confirm the phone can unlock before turning it on, so nobody locks themselves out.
      try {
        final auth = LocalAuthentication();
        if (!await auth.isDeviceSupported()) throw tr('No screen lock is set on this phone.');
        if (!await auth.authenticate(localizedReason: tr('Unlock AndroPI'))) return;
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        return;
      }
    }
    Appearance.instance.update(appLock: on);
  }

  Future<void> _pickFallbacks() async {
    final it = agent.integrations;
    final chosen = [
      for (final m in it.settings?.fallbackModels ?? const <Map<String, dynamic>>[]) '${m['provider']}/${m['model']}',
    ];
    final models = agent.models;
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (context, scroll) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
                child: Row(
                  children: [
                    Expanded(child: Text(tr('Fallback models'), style: Theme.of(context).textTheme.titleLarge)),
                    TextButton(onPressed: () => Navigator.pop(context, chosen), child: Text(tr('Save'))),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  tr('Used when the current model hits a limit or errors'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scroll,
                  children: [
                    for (final m in models)
                      CheckboxListTile(
                        value: chosen.contains(m.key),
                        title: Text(m.name),
                        subtitle: Text(
                          chosen.contains(m.key) ? '#${chosen.indexOf(m.key) + 1} · ${m.provider}' : m.provider,
                        ),
                        onChanged: (v) => setSheet(() => v == true ? chosen.add(m.key) : chosen.remove(m.key)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (result == null) return;
    await it.updateSettings({
      'fallbackModels': [
        for (final k in result) {'provider': k.substring(0, k.indexOf('/')), 'model': k.substring(k.indexOf('/') + 1)},
      ],
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([agent, agent.integrations, agent.features, Appearance.instance]),
      builder: (context, _) {
        final it = agent.integrations;
        final look = Appearance.instance;
        final connected = agent.providers.where((x) => x.configured).toList();
        final c = it.container;
        final dnsLabel = switch (it.settings?.dns) {
          'system' => 'System DNS',
          'google' => 'Google DoH',
          'custom' => 'Custom DoH',
          _ => 'Cloudflare DoH',
        };
        return Scaffold(
          appBar: AppBar(title: Text(tr('Settings'))),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
            children: [
              SurfaceCard(
                child: Row(
                  children: [
                    const LogoMark(size: 48),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('AndroPI', style: text.titleLarge),
                          const SizedBox(height: 2),
                          Text(
                            'pi ${agent.info['version'] ?? ''} · Node ${agent.info['node'] ?? ''}',
                            style: TextStyle(fontFamily: mono, fontSize: 12, color: p.muted),
                          ),
                        ],
                      ),
                    ),
                    Pill(agent.busy ? 'Working' : 'Ready', color: agent.busy ? p.warning : p.success, dot: true),
                  ],
                ),
              ),
              SectionLabel(tr('AI')),
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: LucideIcons.brain,
                    color: p.accent,
                    title: tr('Models & providers'),
                    subtitle: connected.isEmpty
                        ? 'Connect a provider to start'
                        : '${connected.map((x) => x.name).join(', ')}${agent.model != null ? ' · ${agent.model!.name}' : ''}',
                    onTap: () => _open(SettingsScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.puzzle,
                    color: const Color(0xFFEC4899),
                    title: tr('Skills'),
                    subtitle: skillCount == null ? 'Instructions the agent loads on demand' : '$skillCount installed',
                    onTap: () => _open(SkillsScreen(agent: agent)),
                  ),
                ],
              ),
              SectionLabel(tr('Workspace')),
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: c?.distro == 'alpine' ? SimpleIcons.alpinelinux : SimpleIcons.debian,
                    color: c?.distro == 'alpine' ? const Color(0xFF0D597F) : const Color(0xFFD70A53),
                    title: tr('Linux container'),
                    subtitle: c == null
                        ? 'Debian or Alpine with apt / apk'
                        : c.installed
                        ? '${c.image}${c.enabled ? ' · agent shell' : ''}'
                        : 'Not installed · run apt, pip, npm and more',
                    trailing: c?.enabled == true ? Pill('On', color: p.success, dot: true) : null,
                    onTap: () => _open(ContainerScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.keyRound,
                    color: const Color(0xFFF59E0B),
                    title: tr('Accounts & servers'),
                    subtitle: [
                      if (it.github != null) 'GitHub @${it.github!.login}',
                      if (it.vercelUser != null) 'Vercel',
                      if (it.hosts.isNotEmpty) '${it.hosts.length} server${it.hosts.length == 1 ? '' : 's'}',
                    ].join(' · ').ifEmpty('GitHub, Vercel, SSH keys and servers'),
                    onTap: () => _open(AccountsScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.globe,
                    color: const Color(0xFF06B6D4),
                    title: tr('Web & DNS'),
                    subtitle: '$dnsLabel · web search for the agent',
                    onTap: () => _open(NetworkScreen(agent: agent)),
                  ),
                ],
              ),
              SectionLabel(tr('Agent behaviour')),
              _Segmented<String>(
                label: tr('Approvals'),
                value: it.settings?.approvalMode ?? agent.approvalMode,
                options: {'ask_all': tr('Ask all'), 'ask_risky': tr('Risky only'), 'auto': tr('Bypass all')},
                onChanged: (v) async {
                  if (v == 'auto' && !await confirmBypass(context)) return;
                  await it.updateSettings({'approvalMode': v});
                  agent.approvalMode = v;
                },
              ),
              if ((it.settings?.approvalMode ?? agent.approvalMode) == 'auto')
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                  child: Row(
                    children: [
                      Icon(LucideIcons.shieldOff, size: 14, color: p.warning),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          tr('All permissions bypassed: pi never asks before acting.'),
                          style: text.bodySmall?.copyWith(color: p.warning),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: LucideIcons.lifeBuoy,
                    color: const Color(0xFF8B5CF6),
                    title: tr('Fallback models'),
                    subtitle: (it.settings?.fallbackModels ?? const []).isEmpty
                        ? tr('Used when the current model hits a limit or errors')
                        : it.settings!.fallbackModels.map((m) => m['model']).join(' → '),
                    onTap: _pickFallbacks,
                  ),
                  SettingsRow(
                    icon: LucideIcons.chartColumn,
                    color: const Color(0xFF10B981),
                    title: tr('Usage & budget'),
                    subtitle: (it.settings?.dailyBudget ?? 0) > 0
                        ? '\$${it.settings!.dailyBudget.toStringAsFixed(2)} / day'
                        : tr('Tokens, cost and a daily limit'),
                    onTap: () => _open(UsageScreen(agent: agent)),
                  ),
                ],
              ),
              SectionLabel(tr('Automation')),
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: LucideIcons.listTodo,
                    color: const Color(0xFF3E63DD),
                    title: tr('Background tasks'),
                    subtitle: tr('Queue, parallel agents and schedules'),
                    onTap: () => _open(TasksScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.plug,
                    color: const Color(0xFFF97316),
                    title: tr('MCP servers'),
                    subtitle: agent.features.mcpServers.isEmpty
                        ? tr('Extra tools from Model Context Protocol servers')
                        : '${agent.features.mcpServers.length} server${agent.features.mcpServers.length == 1 ? '' : 's'}',
                    onTap: () => _open(McpScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.squareSlash,
                    color: const Color(0xFF64748B),
                    title: tr('Prompt templates'),
                    subtitle: tr('Slash commands like /review and /test'),
                    onTap: () => _open(TemplatesScreen(agent: agent)),
                  ),
                ],
              ),
              SectionLabel(tr('Data & security')),
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: LucideIcons.archive,
                    color: const Color(0xFF0EA5E9),
                    title: tr('Backup & restore'),
                    subtitle: tr('Chats, settings, skills and keys in one file'),
                    onTap: () => _open(BackupScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.fingerprint,
                    color: const Color(0xFFE11D48),
                    title: tr('App lock'),
                    subtitle: tr('Fingerprint or screen lock when opening AndroPI'),
                    trailing: Switch(value: look.appLock, onChanged: _setAppLock),
                    onTap: () => _setAppLock(!look.appLock),
                  ),
                ],
              ),
              SectionLabel(tr('Appearance')),
              _Segmented<ThemeMode>(
                value: look.value,
                options: {ThemeMode.light: tr('Light'), ThemeMode.dark: tr('Dark'), ThemeMode.system: tr('System')},
                onChanged: look.set,
              ),
              const SizedBox(height: 10),
              _Segmented<double>(
                label: tr('Text size'),
                value: look.textScale,
                options: {0.9: tr('Small'), 1.0: tr('Default'), 1.12: tr('Large'), 1.25: tr('Huge')},
                onChanged: (v) => look.update(textScale: v),
              ),
              const SizedBox(height: 10),
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: LucideIcons.rows3,
                    color: p.muted,
                    title: tr('Compact layout'),
                    subtitle: tr('Tighter spacing, more on screen'),
                    trailing: Switch(
                      value: look.compact,
                      onChanged: (v) => look.update(compact: v),
                    ),
                    onTap: () => look.update(compact: !look.compact),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: Row(
                      children: [
                        Expanded(child: Text(tr('Accent colour'), style: text.titleSmall)),
                        for (var i = 0; i < accentChoices.length; i++)
                          GestureDetector(
                            onTap: () => look.update(accent: i),
                            child: Container(
                              margin: const EdgeInsets.only(left: 8),
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Theme.of(context).brightness == Brightness.light
                                    ? accentChoices[i].$1
                                    : accentChoices[i].$2,
                                border: Border.all(color: look.accent == i ? p.text : Colors.transparent, width: 2.5),
                              ),
                              child: look.accent == i ? Icon(LucideIcons.check, size: 14, color: p.inverse) : null,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _Segmented<String>(
                label: tr('Language'),
                value: look.language,
                options: languages,
                onChanged: (v) => look.update(language: v),
              ),
              SectionLabel(tr('Made by')),
              _DeveloperCard(openUrl: agent.client.openUrl),
              SectionLabel(tr('About')),
              SettingsGroup(
                children: [
                  _InfoRow('Workspace', agent.info['workspace']?.toString() ?? '—'),
                  _InfoRow('Agent directory', agent.info['agentDir']?.toString() ?? '—'),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: StorysetCredit(openUrl: agent.client.openUrl),
                  ),
                  SettingsRow(
                    icon: LucideIcons.rotateCcw,
                    color: p.muted,
                    title: tr('Restart agent'),
                    subtitle: tr('Reload the runtime, keeping your chats'),
                    onTap: agent.busy ? null : agent.restart,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 3),
          SelectableText(
            value,
            style: TextStyle(fontFamily: mono, fontSize: 12, height: 1.5, color: p.text),
          ),
        ],
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// A full-width segmented control with an optional caption above it.
class _Segmented<T> extends StatelessWidget {
  const _Segmented({required this.value, required this.options, required this.onChanged, this.label});
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
            child: Text(label!, style: Theme.of(context).textTheme.labelMedium),
          ),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<T>(
            showSelectedIcon: false,
            segments: [
              for (final e in options.entries)
                ButtonSegment(
                  value: e.key,
                  label: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ],
            selected: {options.containsKey(value) ? value : options.keys.first},
            onSelectionChanged: (s) => onChanged(s.first),
          ),
        ),
      ],
    );
  }
}

/// Who builds AndroPI, with links to their GitHub and site.
class _DeveloperCard extends StatelessWidget {
  const _DeveloperCard({required this.openUrl});
  final Future<void> Function(String url) openUrl;

  static const github = 'https://github.com/fdciabdul';
  static const site = 'https://imtaqin.id';

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return SurfaceCard(
      onTap: () => openUrl(github),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Avatar(name: 'imtaqin', url: 'https://avatars.githubusercontent.com/u/31664438?v=4', size: 52),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('imtaqin', style: text.titleLarge),
                    Text(
                      '@fdciabdul',
                      style: TextStyle(fontFamily: mono, fontSize: 12.5, color: p.muted),
                    ),
                  ],
                ),
              ),
              Icon(SimpleIcons.github, size: 22, color: p.text),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            tr('Developer from Bogor, Indonesia. Builds AndroPI, security tools, bots and scrapers.'),
            style: text.bodyMedium?.copyWith(color: p.muted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _LinkChip(icon: SimpleIcons.github, label: 'github.com/fdciabdul', onTap: () => openUrl(github)),
              _LinkChip(icon: LucideIcons.globe, label: 'imtaqin.id', onTap: () => openUrl(site)),
              _LinkChip(
                icon: LucideIcons.folderGit2,
                label: tr('Repositories'),
                onTap: () => openUrl('$github?tab=repositories'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LinkChip extends StatelessWidget {
  const _LinkChip({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.raised,
      borderRadius: BorderRadius.circular(99),
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: p.text),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: p.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
