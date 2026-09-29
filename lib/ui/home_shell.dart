import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/integrations.dart';
import '../agent/models.dart';
import 'i18n.dart';
import 'accounts_screen.dart';
import 'chat_extras.dart';
import 'chat_screen.dart';
import 'folder_picker.dart';
import 'kit.dart';
import 'illustration.dart';
import 'mesh.dart';
import 'new_chat_sheet.dart';
import 'repos_screen.dart';
import 'settings_hub.dart';
import 'settings_screen.dart';
import 'skills_screen.dart';
import 'tasks_screen.dart';
import 'theme.dart';

/// Opens the chat for the agent's current session.
Future<void> openChat(
  BuildContext context,
  AgentController agent, {
  String? prompt,
  List<Attachment> attachments = const [],
  bool listen = false,
}) => Navigator.of(context).push(
  MaterialPageRoute(
    builder: (_) =>
        ChatScreen(agent: agent, initialPrompt: prompt, initialAttachments: attachments, listenOnOpen: listen),
  ),
);

/// The app's home: tabs plus a floating navigation bar.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.agent});
  final AgentController agent;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int tab = 0;
  final subs = <StreamSubscription<Object?>>[];
  AppLifecycleState lifecycle = AppLifecycleState.resumed;
  int approvalsSeen = 0;

  AgentController get agent => widget.agent;
  bool get _inBackground => lifecycle != AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final f = agent.features;
    subs
      ..add(agent.client.records.where((r) => r['type'] == 'launch').listen((_) => _takeLaunch()))
      ..add(
        f.done.stream.listen((preview) {
          if (_inBackground) agent.client.notify(1, 'pi is done', preview.isEmpty ? 'Tap to see the result' : preview);
        }),
      )
      ..add(
        f.runFinished.stream.listen((run) {
          final ok = run.status == 'done';
          agent.client.notify(
            2000 + run.id.hashCode % 1000,
            ok ? 'Task done: ${run.title}' : 'Task ${run.status}: ${run.title}',
            run.summary ?? '',
          );
        }),
      );
    f.addListener(_onFeatures);
    f.refreshRuns().catchError((_) {});
    agent.client.requestNotifications().catchError((_) {});
    // The app may have been opened by a share, the widget or the tile.
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeLaunch());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    agent.features.removeListener(_onFeatures);
    for (final s in subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => lifecycle = state;

  /// Approvals that arrive while the app is in the background become notifications.
  void _onFeatures() {
    final pending = agent.features.approvals;
    if (pending.length > approvalsSeen && _inBackground) {
      agent.client.notify(3, 'pi needs your approval', '${pending.last.toolName}: ${pending.last.summary}');
    }
    approvalsSeen = pending.length;
  }

  Future<void> _takeLaunch() async {
    final launch = await agent.client.takeLaunch();
    if (launch == null || !mounted) return;
    // Close any sheet or page so the new chat opens on top of home.
    Navigator.of(context).popUntil((r) => r.isFirst);
    switch (launch['action']) {
      case 'new_chat':
        await _newChat();
      case 'voice':
        await agent.newSession();
        if (mounted) await openChat(context, agent, listen: true);
      case 'share':
        final files = [
          for (final f in (launch['files'] as List? ?? const []).cast<Map>())
            Attachment(f['path'] as String, f['name'] as String, mime: f['mime'] as String?),
        ];
        await agent.newSession();
        if (mounted) await openChat(context, agent, prompt: launch['text'] as String?, attachments: files);
    }
  }

  Future<void> _newChat() async {
    final before = agent.sessionId;
    await showNewChatSheet(context, agent);
    if (mounted && agent.sessionId != before) await openChat(context, agent);
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      _HomeTab(agent: agent, onSeeAll: () => setState(() => tab = 1), onNewChat: _newChat),
      _ChatsTab(agent: agent),
      SkillsScreen(agent: agent, embedded: true),
      _ProjectsTab(agent: agent),
    ];
    return Scaffold(
      extendBody: true,
      // Every tab stays built (scroll positions survive); the active one fades
      // and drifts in, the others fade out and stop ticking.
      body: Stack(
        children: [
          for (var i = 0; i < tabs.length; i++) _TabLayer(active: i == tab, forward: i >= tab, child: tabs[i]),
        ],
      ),
      bottomNavigationBar: _NavBar(index: tab, onTap: (i) => setState(() => tab = i), onCreate: _newChat),
    );
  }
}

class _TabLayer extends StatefulWidget {
  const _TabLayer({required this.active, required this.forward, required this.child});
  final bool active;
  final bool forward;
  final Widget child;

  @override
  State<_TabLayer> createState() => _TabLayerState();
}

class _TabLayerState extends State<_TabLayer> {
  /// True once an inactive tab has finished fading out; only then is it
  /// taken offstage (and its tickers paused), so the fade itself can run.
  late bool hidden = !widget.active;

  @override
  void didUpdateWidget(_TabLayer old) {
    super.didUpdateWidget(old);
    if (widget.active && hidden) setState(() => hidden = false);
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    return Offstage(
      offstage: hidden && !active,
      child: TickerMode(
        enabled: active || !hidden,
        child: IgnorePointer(
          ignoring: !active,
          child: AnimatedOpacity(
            opacity: active ? 1 : 0,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            onEnd: () {
              if (!widget.active && mounted) setState(() => hidden = true);
            },
            child: AnimatedSlide(
              offset: active ? Offset.zero : Offset(widget.forward ? 0.04 : -0.04, 0),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Navigation bar: two tabs, a raised create button, two tabs.

class _NavBar extends StatelessWidget {
  const _NavBar({required this.index, required this.onTap, required this.onCreate});
  final int index;
  final void Function(int) onTap;
  final VoidCallback onCreate;

  static const _items = [
    (LucideIcons.house, 'Home'),
    (LucideIcons.messagesSquare, 'Chats'),
    (LucideIcons.compass, 'Skills'),
    (LucideIcons.layoutGrid, 'Projects'),
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    Widget item(int i) =>
        _NavItem(icon: _items[i].$1, label: _items[i].$2, selected: i == index, onTap: () => onTap(i));
    return SafeArea(
      top: false,
      child: SizedBox(
        height: 96,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.bottomCenter,
          children: [
            Positioned(
              left: 18,
              right: 18,
              bottom: 12,
              child: Container(
                height: 68,
                decoration: BoxDecoration(
                  color: p.nav,
                  borderRadius: BorderRadius.circular(34),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.22), blurRadius: 26, offset: const Offset(0, 12)),
                  ],
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [item(0), item(1)]),
                    ),
                    const SizedBox(width: 76), // room for the create button
                    Expanded(
                      child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [item(2), item(3)]),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(bottom: 30, child: _CreateButton(onTap: onCreate)),
          ],
        ),
      ),
    );
  }
}

/// A tab icon; the selected one sits in a white circle that pops in.
class _NavItem extends StatefulWidget {
  const _NavItem({required this.icon, required this.label, required this.selected, required this.onTap});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool pressed = false;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF111113);
    final selected = widget.selected;
    return Semantics(
      button: true,
      selected: selected,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => pressed = true),
        onTapCancel: () => setState(() => pressed = false),
        onTapUp: (_) {
          setState(() => pressed = false);
          HapticFeedback.selectionClick();
          widget.onTap();
        },
        child: SizedBox.square(
          dimension: 52,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // The white disc grows in with a little overshoot.
              AnimatedScale(
                scale: selected ? 1 : 0,
                duration: const Duration(milliseconds: 380),
                curve: selected ? Curves.easeOutBack : Curves.easeInCubic,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                ),
              ),
              AnimatedScale(
                scale: pressed ? 0.8 : (selected ? 1.08 : 1),
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutBack,
                child: TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: selected ? ink : Colors.white.withValues(alpha: 0.78)),
                  duration: const Duration(milliseconds: 220),
                  builder: (context, color, _) => Icon(widget.icon, size: 21, color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The raised round "new chat" button in the middle of the bar.
class _CreateButton extends StatefulWidget {
  const _CreateButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_CreateButton> createState() => _CreateButtonState();
}

class _CreateButtonState extends State<_CreateButton> {
  bool pressed = false;
  double turns = 0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      button: true,
      label: tr('New chat'),
      child: GestureDetector(
        onTapDown: (_) => setState(() => pressed = true),
        onTapCancel: () => setState(() => pressed = false),
        onTapUp: (_) {
          HapticFeedback.mediumImpact();
          setState(() {
            pressed = false;
            turns += 0.25;
          });
          widget.onTap();
        },
        child: AnimatedScale(
          scale: pressed ? 0.9 : 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutBack,
          child: Container(
            width: 66,
            height: 66,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: p.accent,
              border: Border.all(color: p.bg, width: 5),
              boxShadow: [
                BoxShadow(color: p.accent.withValues(alpha: 0.45), blurRadius: 22, offset: const Offset(0, 8)),
              ],
            ),
            child: AnimatedRotation(
              turns: turns,
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutBack,
              child: const Icon(LucideIcons.plus, size: 28, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Home

class _Quick {
  const _Quick(this.title, this.icon, this.color, this.category, this.art, {this.prompt, this.clone = false});
  final String title;

  /// Storyset illustration shown on the card.
  final String art;
  final IconData icon;
  final Color color;
  final String category;
  final String? prompt;
  final bool clone;
}

const _quick = [
  _Quick(
    'Build a web app',
    LucideIcons.layoutTemplate,
    Color(0xFFFF7A1A),
    'Build',
    'projects',
    prompt: 'Build me a polished, mobile-first web app: ',
  ),
  _Quick('Chat with the smartest agent', LucideIcons.sparkles, Color(0xFF7C5CFC), 'Code', 'ai'),
  _Quick('Clone a GitHub repo', SimpleIcons.github, Color(0xFF111113), 'Code', 'git', clone: true),
  _Quick(
    'Design a modern UI',
    LucideIcons.palette,
    Color(0xFF14B8A6),
    'Build',
    'design',
    prompt: 'Using the ui-designer skill, design and build a modern screen for: ',
  ),
  _Quick(
    'Python in Linux',
    SimpleIcons.python,
    Color(0xFF3B82F6),
    'Ops',
    'python',
    prompt: 'Set up a Python project in the Linux container and write a script that ',
  ),
  _Quick('Fix a bug', LucideIcons.bug, Color(0xFFEF4444), 'Code', 'bug', prompt: 'Help me find and fix this bug: '),
  _Quick(
    'Deploy a site',
    LucideIcons.rocket,
    Color(0xFFEC4899),
    'Ops',
    'launch',
    prompt: 'Deploy this project and give me the live URL. Project: ',
  ),
  _Quick(
    'Automate a task',
    LucideIcons.zap,
    Color(0xFFF59E0B),
    'Ops',
    'automate',
    prompt: 'Write a script that automates: ',
  ),
];

class _HomeTab extends StatefulWidget {
  const _HomeTab({required this.agent, required this.onSeeAll, required this.onNewChat});
  final AgentController agent;
  final VoidCallback onSeeAll;
  final VoidCallback onNewChat;

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> {
  String category = 'All';
  late Future<List<SessionSummary>> recent = widget.agent.listSessions();

  AgentController get agent => widget.agent;

  void _refresh() => setState(() {
    recent = agent.listSessions();
  });

  Future<void> _run(_Quick q) async {
    if (q.clone) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReposScreen(agent: agent)));
      _refresh();
      return;
    }
    if (q.prompt == null) {
      widget.onNewChat();
      return;
    }
    // Each quick start gets its own project folder.
    final ws = agent.info['workspace'] as String? ?? '';
    final slug = q.title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');
    final n = DateTime.now();
    final dir = Directory('$ws/$slug-${n.month}${n.day}-${n.hour}${n.minute.toString().padLeft(2, '0')}')
      ..createSync(recursive: true);
    await agent.newSession(dir: dir.path);
    if (mounted) await openChat(context, agent, prompt: q.prompt);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([agent, agent.integrations, agent.features]),
      builder: (context, _) {
        final gh = agent.integrations.github;
        final running = agent.features.runs.where((r) => r.active).length;
        final name = (gh?.name ?? gh?.login ?? 'there').split(' ').first;
        final quick = _quick.where((q) => category == 'All' || q.category == category).toList();
        return SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 130),
              children: [
                Row(
                  children: [
                    _CircleButton(
                      icon: LucideIcons.alignLeft,
                      label: tr('Settings'),
                      onTap: () async {
                        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsHub(agent: agent)));
                        _refresh();
                      },
                    ),
                    const Spacer(),
                    Badge(
                      isLabelVisible: running > 0,
                      label: Text('$running'),
                      backgroundColor: p.accent,
                      child: _CircleButton(
                        icon: LucideIcons.listTodo,
                        label: tr('Tasks'),
                        onTap: () =>
                            Navigator.of(context).push(MaterialPageRoute(builder: (_) => TasksScreen(agent: agent))),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: () =>
                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => AccountsScreen(agent: agent))),
                      child: Avatar(name: gh?.name ?? gh?.login ?? 'AndroPI', url: gh?.avatarUrl, size: 44),
                    ),
                  ],
                ),
                const SizedBox(height: 26),
                Text('${tr('Hello,')}\n$name', style: text.displayMedium),
                const SizedBox(height: 8),
                Text(
                  agent.hasModel ? tr('What should we build today?') : tr('Connect a model to get started.'),
                  style: text.bodyLarge?.copyWith(color: p.muted),
                ),
                if (!agent.hasModel) ...[const SizedBox(height: 18), _ConnectCard(agent: agent)],
                const SizedBox(height: 22),
                SizedBox(
                  height: 38,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final c in const ['All', 'Build', 'Code', 'Ops'])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _PillChip(
                            label: tr(c == 'All' ? 'All types' : c),
                            selected: category == c,
                            onTap: () => setState(() => category = c),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 218,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    itemCount: quick.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, i) => _QuickCard(q: quick[i], onTap: () => _run(quick[i])),
                  ),
                ),
                const SizedBox(height: 30),
                Row(
                  children: [
                    Expanded(child: Text(tr('Recent'), style: text.titleLarge)),
                    TextButton(
                      onPressed: widget.onSeeAll,
                      style: TextButton.styleFrom(foregroundColor: const Color(0xFF3E63DD)),
                      child: Text(tr('See all')),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                FutureBuilder<List<SessionSummary>>(
                  future: recent,
                  builder: (context, snap) {
                    final list = (snap.data ?? const <SessionSummary>[])
                        .where((s) => s.messageCount > 0)
                        .take(5)
                        .toList();
                    if (!snap.hasData) return const SizedBox(height: 60);
                    if (list.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(tr('Your chats will show up here.'), style: text.bodySmall),
                      );
                    }
                    return Column(
                      children: [
                        for (final s in list)
                          _SessionRow(
                            session: s,
                            workspace: agent.info['workspace'] as String? ?? '',
                            onTap: () async {
                              if (s.id != agent.sessionId) await agent.openSession(s.path);
                              if (context.mounted) await openChat(context, agent);
                              _refresh();
                            },
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Shown until a model provider is connected.
class _ConnectCard extends StatelessWidget {
  const _ConnectCard({required this.agent});
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF111113), borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          const Positioned(right: -8, bottom: -6, child: Illustration('connect', height: 128)),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Connect a model',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.3),
                ),
                const SizedBox(height: 6),
                Text(
                  'Sign in to a provider or add an API key: Anthropic, OpenAI, Gemini, OpenRouter and more.',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13, height: 1.45),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF111113),
                    minimumSize: const Size(0, 44),
                  ),
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsScreen(agent: agent))),
                  child: Text(tr('Choose a model')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.icon, required this.onTap, required this.label});
  final IconData icon;
  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: p.surface,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox.square(dimension: 44, child: Icon(icon, size: 20, color: p.text)),
        ),
      ),
    );
  }
}

class _PillChip extends StatelessWidget {
  const _PillChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: selected ? p.text : Colors.transparent,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Text(
            label,
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: selected ? p.inverse : p.muted),
          ),
        ),
      ),
    );
  }
}

class _QuickCard extends StatelessWidget {
  const _QuickCard({required this.q, required this.onTap});
  final _Quick q;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SizedBox(
      width: 164,
      child: Material(
        color: p.surface,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 122,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: MeshArt(
                          seed: q.title,
                          radius: 19,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                            child: Center(child: Illustration(q.art, height: 112)),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 10,
                        bottom: -18,
                        child: RingBadge(icon: q.icon, color: q.color),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 26, 10, 0),
                  child: Text(
                    tr(q.title),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.3),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session, required this.workspace, required this.onTap, this.onLongPress});
  final SessionSummary session;
  final String workspace;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final folder = sessionFolder(session.cwd, workspace);
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 52,
              child: MeshArt(
                seed: session.id,
                radius: 16,
                child: Center(
                  child: Icon(
                    folder != null ? LucideIcons.folderGit2 : LucideIcons.messageSquare,
                    size: 20,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(session.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
                  const SizedBox(height: 3),
                  Text(
                    folder ?? tr('Quick chat'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: folder != null ? mono : null, fontSize: 12, color: p.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(_ago(session.modified), style: TextStyle(fontSize: 11.5, color: p.faint)),
          ],
        ),
      ),
    );
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  final id = Appearance.instance.language == 'id';
  if (d.inMinutes < 1) return id ? 'baru saja' : 'now';
  if (d.inHours < 1) return id ? '${d.inMinutes} mnt lalu' : '${d.inMinutes}m ago';
  if (d.inDays < 1) return id ? '${d.inHours} jam lalu' : '${d.inHours}h ago';
  if (d.inDays < 7) return id ? '${d.inDays} hr lalu' : '${d.inDays}d ago';
  return '${t.day}/${t.month}';
}

// ---------------------------------------------------------------------------
// Chats

class _ChatsTab extends StatefulWidget {
  const _ChatsTab({required this.agent});
  final AgentController agent;

  @override
  State<_ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<_ChatsTab> {
  late Future<List<SessionSummary>> sessions = widget.agent.listSessions();
  String query = '';

  AgentController get agent => widget.agent;

  void _reload() => setState(() {
    sessions = agent.listSessions();
  });

  Future<void> _menu(SessionSummary s) async {
    final active = s.id == agent.sessionId;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: SettingsGroup(
            children: [
              SettingsRow(
                icon: LucideIcons.pencil,
                color: const Color(0xFF3E63DD),
                title: tr('Rename'),
                onTap: () => Navigator.pop(context, 'rename'),
              ),
              SettingsRow(
                icon: LucideIcons.trash2,
                color: context.palette.danger,
                title: tr('Delete'),
                subtitle: active ? 'Open another chat first' : null,
                destructive: true,
                onTap: active ? null : () => Navigator.pop(context, 'delete'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'rename') {
      final controller = TextEditingController(text: s.name ?? s.title);
      final name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr('Rename chat')),
          content: TextField(controller: controller, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(tr('Save'))),
          ],
        ),
      );
      controller.dispose();
      if (name != null && name.trim().isNotEmpty) await agent.renameSession(s.path, name.trim());
    } else if (action == 'delete') {
      await agent.deleteSession(s.path);
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ws = agent.info['workspace'] as String? ?? '';
    return SafeArea(
      bottom: false,
      child: FutureBuilder<List<SessionSummary>>(
        future: sessions,
        builder: (context, snap) {
          final q = query.toLowerCase();
          final all = (snap.data ?? const <SessionSummary>[])
              .where((s) => s.messageCount > 0)
              .where((s) => q.isEmpty || s.title.toLowerCase().contains(q) || s.cwd.toLowerCase().contains(q))
              .toList();
          final groups = <String, List<SessionSummary>>{};
          for (final s in all) {
            groups.putIfAbsent(_bucket(s.modified), () => []).add(s);
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 130),
              children: [
                Text(tr('Chats'), style: text.displaySmall),
                const SizedBox(height: 16),
                TextField(
                  onChanged: (v) => setState(() {
                    query = v;
                  }),
                  decoration: InputDecoration(
                    hintText: tr('Search anything'),
                    prefixIcon: const Icon(LucideIcons.search, size: 18),
                  ),
                ),
                if (!snap.hasData)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else if (all.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 40),
                    child: Column(
                      children: [
                        if (q.isEmpty) const Illustration('chat', height: 200),
                        const SizedBox(height: 12),
                        Text(
                          q.isEmpty ? 'No chats yet. Tap + to start one.' : 'Nothing matches.',
                          style: text.bodySmall,
                        ),
                      ],
                    ),
                  ),
                for (final e in groups.entries) ...[
                  SectionLabel(e.key, padding: const EdgeInsets.fromLTRB(2, 22, 2, 4)),
                  for (final s in e.value)
                    _SessionRow(
                      session: s,
                      workspace: ws,
                      onLongPress: () => _menu(s),
                      onTap: () async {
                        if (s.id != agent.sessionId) await agent.openSession(s.path);
                        if (context.mounted) await openChat(context, agent);
                        _reload();
                      },
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  static String _bucket(DateTime t) {
    final now = DateTime.now();
    final days = DateTime(now.year, now.month, now.day).difference(DateTime(t.year, t.month, t.day)).inDays;
    if (days <= 0) return 'Today';
    if (days == 1) return 'Yesterday';
    if (days < 7) return 'This week';
    if (days < 30) return 'This month';
    return 'Older';
  }
}

// ---------------------------------------------------------------------------
// Projects

class _ProjectsTab extends StatefulWidget {
  const _ProjectsTab({required this.agent});
  final AgentController agent;

  @override
  State<_ProjectsTab> createState() => _ProjectsTabState();
}

class _ProjectsTabState extends State<_ProjectsTab> {
  String query = '';

  AgentController get agent => widget.agent;
  Integrations get it => agent.integrations;

  @override
  void initState() {
    super.initState();
    it.refreshProjects().catchError((_) {});
  }

  Future<void> _open(ProjectInfo project) async {
    final sessions = await agent.listSessions();
    final latest = sessions.where((s) => s.cwd == project.path && s.messageCount > 0).firstOrNull;
    if (latest != null) {
      if (latest.id != agent.sessionId) await agent.openSession(latest.path);
    } else {
      await agent.newSession(dir: project.path);
    }
    if (mounted) await openChat(context, agent);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: it,
      builder: (context, _) {
        final projects = it.projects.where((x) => query.isEmpty || x.name.toLowerCase().contains(query)).toList();
        return SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: it.refreshProjects,
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  sliver: SliverList.list(
                    children: [
                      Text(tr('Projects'), style: text.displaySmall),
                      const SizedBox(height: 16),
                      TextField(
                        onChanged: (v) => setState(() {
                          query = v.toLowerCase();
                        }),
                        decoration: InputDecoration(
                          hintText: tr('Search projects'),
                          prefixIcon: const Icon(LucideIcons.search, size: 18),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                await Navigator.of(context)
                                    .push(MaterialPageRoute(builder: (_) => ReposScreen(agent: agent)));
                                it.refreshProjects();
                              },
                              icon: const Icon(SimpleIcons.github, size: 16),
                              label: Text(tr('Clone repo')),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final dir = await FolderPicker.pick(context, agent);
                                if (dir == null) return;
                                await agent.newSession(dir: dir);
                                if (context.mounted) await openChat(context, agent);
                              },
                              icon: const Icon(LucideIcons.folderOpen, size: 16),
                              label: Text(tr('Open folder')),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
                if (projects.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(40),
                      child: Column(
                        children: [
                          const Illustration('projects', height: 200),
                          const SizedBox(height: 12),
                          Text(tr('Projects you create or clone appear here.'), style: text.bodySmall),
                        ],
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 130),
                    sliver: SliverGrid.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 18,
                        crossAxisSpacing: 14,
                        childAspectRatio: 0.82,
                      ),
                      itemCount: projects.length,
                      itemBuilder: (context, i) {
                        final pr = projects[i];
                        return GestureDetector(
                          onTap: () => _open(pr),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: MeshArt(
                                  seed: pr.name,
                                  radius: 22,
                                  child: Stack(
                                    children: [
                                      Center(
                                        child: Icon(
                                          pr.isGit ? LucideIcons.folderGit2 : LucideIcons.folder,
                                          size: 44,
                                          color: const Color(0xFF111113).withValues(alpha: 0.55),
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Align(
                                          alignment: Alignment.topRight,
                                          child: pr.isGit
                                              ? Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                  decoration: BoxDecoration(
                                                    color: Colors.white.withValues(alpha: 0.85),
                                                    borderRadius: BorderRadius.circular(99),
                                                  ),
                                                  child: Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      const Icon(
                                                        LucideIcons.gitBranch,
                                                        size: 11,
                                                        color: Color(0xFF111113),
                                                      ),
                                                      const SizedBox(width: 4),
                                                      Text(
                                                        pr.branch ?? 'git',
                                                        style: const TextStyle(
                                                          fontSize: 10.5,
                                                          fontWeight: FontWeight.w600,
                                                          color: Color(0xFF111113),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                )
                                              : null,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(pr.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
                              const SizedBox(height: 2),
                              Text(
                                pr.githubSlug ?? (pr.dirty ? 'uncommitted changes' : 'local folder'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11.5, color: p.muted),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
