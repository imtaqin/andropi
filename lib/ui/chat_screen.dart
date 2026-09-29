import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/models.dart';
import '../agent/features.dart';
import 'i18n.dart';
import 'chat_extras.dart';
import 'deploy_sheet.dart';
import 'message_views.dart';

import 'package:simple_icons/simple_icons.dart';

import 'repos_screen.dart';
import 'kit.dart';
import 'illustration.dart';
import 'model_sheet.dart';
import 'tasks_screen.dart';
import 'terminal_screen.dart';
import 'settings_screen.dart';
import 'folder_picker.dart';
import 'theme.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.agent,
    this.initialPrompt,
    this.initialAttachments = const [],
    this.listenOnOpen = false,
  });
  final AgentController agent;

  /// Pre-filled into the composer (quick starts, shares), for the user to finish.
  final String? initialPrompt;
  final List<Attachment> initialAttachments;

  /// Start voice input right away (the widget's Voice button).
  final bool listenOnOpen;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final scroll = ScrollController();
  final input = TextEditingController();
  final focus = FocusNode();
  bool followBottom = true;

  /// The user's finger is on the list (or it is still flinging from it);
  /// auto-follow must not fight them.
  bool dragging = false;
  int lastCount = 0;
  final attachments = <Attachment>[];
  List<SlashCommand>? slash;

  AgentController get agent => widget.agent;

  /// "/par" while typing a command name; null otherwise.
  String? get _slashQuery {
    final t = input.text;
    if (!t.startsWith('/') || t.contains(' ') || t.contains('\n')) return null;
    return t.substring(1);
  }

  @override
  void initState() {
    super.initState();
    agent.addListener(_onAgentChanged);
    final prompt = widget.initialPrompt;
    if (prompt != null) {
      input.text = prompt;
      input.selection = TextSelection.collapsed(offset: prompt.length);
      WidgetsBinding.instance.addPostFrameCallback((_) => focus.requestFocus());
    }
    scroll.addListener(() {
      if (!scroll.hasClients || dragging) return;
      if (_atBottom != followBottom) setState(() => followBottom = _atBottom);
    });
    input.addListener(() {
      if (_slashQuery != null && slash == null) _loadSlash();
      setState(() {});
    });
    attachments.addAll(widget.initialAttachments);
    if (widget.listenOnOpen) WidgetsBinding.instance.addPostFrameCallback((_) => _voice());
    // History may have loaded before this screen existed.
    lastCount = agent.entries.length;
    _jumpToBottom();
  }

  @override
  void dispose() {
    agent.removeListener(_onAgentChanged);
    scroll.dispose();
    input.dispose();
    focus.dispose();
    super.dispose();
  }

  bool get _atBottom => scroll.position.pixels >= scroll.position.maxScrollExtent - 80;

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollStartNotification && n.dragDetails != null) {
      dragging = true;
      if (followBottom) setState(() => followBottom = false);
    } else if (n is ScrollEndNotification && dragging) {
      dragging = false;
      // Landing back at the bottom re-arms following.
      if (scroll.hasClients && _atBottom != followBottom) setState(() => followBottom = _atBottom);
    }
    return false;
  }

  void _onAgentChanged() {
    final grew = agent.entries.length != lastCount;
    lastCount = agent.entries.length;
    if (followBottom || grew && agent.entries.lastOrNull is UserEntry) _jumpToBottom();
  }

  void _jumpToBottom({bool animate = false, int passes = 4}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scroll.hasClients || dragging) return;
      final target = scroll.position.maxScrollExtent;
      if (animate) {
        scroll.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        return;
      }
      scroll.jumpTo(target);
      // A lazy list only estimates its extent until the tail is laid out;
      // settle again next frame if landing there revealed more.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (passes > 1 && scroll.hasClients && scroll.position.maxScrollExtent > target + 1) {
          _jumpToBottom(passes: passes - 1);
        }
      });
    });
  }

  Future<void> _loadSlash() async {
    slash = const [];
    try {
      final list = await agent.features.slashCommands();
      if (mounted) setState(() => slash = list);
    } catch (_) {}
  }

  Future<void> _send() async {
    final text = input.text;
    if (text.trim().isEmpty && attachments.isEmpty) return;
    if (!agent.hasModel) {
      await _connectProvider();
      return;
    }
    final files = List<Attachment>.of(attachments);
    input.clear();
    setState(() => attachments.clear());
    followBottom = true;
    if (files.isEmpty) {
      await agent.send(text);
    } else {
      final prompt = await preparePrompt(text, files, agent.cwd);
      await agent.sendWith(prompt.text, images: prompt.images);
    }
  }

  /// Long-press on send: hand the task to a background agent instead.
  Future<void> _queue() async {
    final text = input.text.trim();
    if (text.isEmpty) return;
    input.clear();
    await agent.features.enqueue(text);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Queued as a background task')),
          action: SnackBarAction(
            label: tr('View'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TasksScreen(agent: agent))),
          ),
        ),
      );
    }
  }

  Future<void> _attach() async {
    final picked = await pickAttachments(context);
    if (picked.isNotEmpty) setState(() => attachments.addAll(picked));
  }

  Future<void> _voice() async {
    try {
      final heard = await agent.client.listen();
      if (heard == null || heard.trim().isEmpty) return;
      final current = input.text.trim();
      input.text = current.isEmpty ? heard : '$current $heard';
      input.selection = TextSelection.collapsed(offset: input.text.length);
      focus.requestFocus();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Voice input: $e')));
    }
  }

  void _prefill(String text) {
    input.text = text;
    input.selection = TextSelection.collapsed(offset: text.length);
    focus.requestFocus();
  }

  /// Long-press on one of your messages: edit & resend, fork, copy.
  Future<void> _userMenu(UserEntry entry, int userIndex) async {
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
                title: tr('Edit & resend'),
                subtitle: tr('Rewind to this message and change it'),
                onTap: () => Navigator.pop(context, 'edit'),
              ),
              SettingsRow(
                icon: LucideIcons.gitFork,
                color: const Color(0xFF7C5CFC),
                title: tr('Fork from here'),
                subtitle: tr('A new chat that branches off before this message'),
                onTap: () => Navigator.pop(context, 'fork'),
              ),
              SettingsRow(
                icon: LucideIcons.copy,
                color: const Color(0xFF6B6B73),
                title: tr('Copy'),
                onTap: () => Navigator.pop(context, 'copy'),
              ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: entry.text));
      return;
    }
    if (agent.busy) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Wait for pi to finish first'))));
      return;
    }
    try {
      final points = await agent.features.forkPoints();
      if (userIndex >= points.length) throw 'This message cannot be edited';
      final entryId = points[userIndex].entryId;
      final text = action == 'edit' ? await agent.editMessage(entryId) : await agent.forkAt(entryId);
      _prefill(text.isEmpty ? entry.text : text);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _connectProvider() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsScreen(agent: agent)));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: agent,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          leading: Navigator.of(context).canPop()
              ? IconButton(
                  tooltip: tr('Back'),
                  icon: const Icon(LucideIcons.chevronLeft, size: 24),
                  onPressed: () => Navigator.of(context).pop(),
                )
              : null,
          title: _Title(agent: agent),
          actions: [
            IconButton(
              tooltip: tr('Terminal'),
              icon: const Icon(LucideIcons.squareTerminal, size: 20),
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => TerminalScreen(agent: agent))),
            ),
            IconButton(
              tooltip: tr('Deploy'),
              icon: const Icon(LucideIcons.rocket, size: 20),
              onPressed: agent.busy ? null : () => showDeploySheet(context, agent),
            ),
            IconButton(
              tooltip: tr('Project tools'),
              icon: const Icon(LucideIcons.layoutGrid, size: 20),
              onPressed: () => showProjectTools(context, agent, onPrompt: _prefill),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  agent.entries.isEmpty
                      ? _EmptyState(
                          agent: agent,
                          onConnect: _connectProvider,
                          onPrompt: (prompt) {
                            input.text = prompt;
                            input.selection = TextSelection.collapsed(offset: prompt.length);
                            focus.requestFocus();
                          },
                          onClone: () =>
                              Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReposScreen(agent: agent))),
                        )
                      : NotificationListener<TranscriptGrew>(
                          onNotification: (_) {
                            if (followBottom) _jumpToBottom();
                            return true;
                          },
                          // Content can also shrink or reflow on its own (a live
                          // code panel folding away when a tool call lands);
                          // stay pinned to the bottom through that too.
                          child: NotificationListener<ScrollMetricsNotification>(
                            onNotification: (n) {
                              if (followBottom && !dragging && n.metrics.pixels != n.metrics.maxScrollExtent) {
                                _jumpToBottom();
                              }
                              return false;
                            },
                            child: NotificationListener<ScrollNotification>(
                              onNotification: _onScroll,
                              child: _transcript(),
                            ),
                          ),
                        ),
                  if (!followBottom)
                    Positioned(
                      right: 16,
                      bottom: 12,
                      child: _RoundButton(
                        icon: LucideIcons.arrowDown,
                        label: tr('Scroll to bottom'),
                        onTap: () => _jumpToBottom(animate: true),
                      ),
                    ),
                ],
              ),
            ),
            DevServerBanner(agent: agent),
            ApprovalCards(features: agent.features),
            PlanBar(agent: agent),
            if (_slashQuery != null && slash != null)
              SlashMenu(commands: slash!, query: _slashQuery!, onPick: (c) => _prefill('/${c.name} ')),
            if (agent.billingNotice != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  agent.billingNotice!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.muted),
                ),
              ),
            _Composer(
              controller: input,
              focus: focus,
              agent: agent,
              onSend: _send,
              onQueue: _queue,
              onAttach: _attach,
              onVoice: _voice,
              attachments: attachments,
              onRemoveAttachment: (a) => setState(() => attachments.remove(a)),
              onPickModel: () => showModelSheet(context, agent),
            ),
          ],
        ),
      ),
    );
  }

  Widget _transcript() {
    final entries = agent.entries;
    return ListView.builder(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        final child = switch (e) {
          UserEntry() => UserMessageView(
            e,
            onLongPress: () => _userMenu(e, entries.take(i).whereType<UserEntry>().length),
          ),
          AssistantEntry() => AssistantMessageView(e, tools: agent.tools, cwd: agent.cwd, live: agent),
          NoticeEntry() => NoticeView(e),
        };
        final gap = i == 0 ? 0.0 : (e is UserEntry ? 28.0 : 14.0);
        return Padding(
          padding: EdgeInsets.only(top: gap),
          child: child,
        );
      },
    );
  }
}

class _Title extends StatelessWidget {
  const _Title({required this.agent});
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final name = agent.sessionName?.trim();
    final firstUser = agent.entries.whereType<UserEntry>().firstOrNull?.text.split('\n').first;
    final title = (name != null && name.isNotEmpty) ? name : (firstUser ?? 'New chat');
    // Sessions inside a project folder show which one.
    final project = sessionFolder(agent.cwd, agent.info['workspace'] as String? ?? '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        if (project != null || agent.model != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (project != null) ...[
                Icon(LucideIcons.folderGit2, size: 12, color: p.accent),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    project,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: mono, fontSize: 11.5, color: p.muted),
                  ),
                ),
              ] else
                Flexible(
                  child: Text(
                    agent.model!.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: p.faint, fontWeight: FontWeight.w500),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.agent, required this.onConnect, required this.onPrompt, required this.onClone});
  final AgentController agent;
  final VoidCallback onConnect;
  final void Function(String prompt) onPrompt;
  final VoidCallback onClone;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final ready = agent.hasModel;
    final suggestions = [
      (
        LucideIcons.layoutTemplate,
        const Color(0xFF8B5CF6),
        'Build a web app',
        'A polished single-page app I can preview',
        'Build me a polished, mobile-first web app: ',
      ),
      (SimpleIcons.github, p.text, 'Clone a repo', 'Pick one of your GitHub repositories', null),
      (
        SimpleIcons.python,
        const Color(0xFF3B82F6),
        'Set up Python',
        'Install Python and packages in Linux',
        'Set up a Python environment in the Linux container with requests and rich, then write a hello script.',
      ),
      (
        LucideIcons.folderSearch,
        const Color(0xFF14B8A6),
        'Explore workspace',
        'Summarize what is on this device',
        'Look around the workspace and give me a short tour of what is there.',
      ),
    ];
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight - 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Illustration('ai', height: 190),
              const SizedBox(height: 24),
              Text(
                ready ? 'What should we build?' : 'Connect a model to begin',
                style: text.displaySmall?.copyWith(fontSize: 26),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                ready
                    ? 'pi codes, runs commands, installs packages and deploys, right here on your phone.'
                    : 'The agent runs on your phone. Sign in to a provider or add an API key to choose its model.',
                style: text.bodyMedium?.copyWith(color: p.muted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              if (!ready)
                SizedBox(
                  width: 260,
                  child: PrimaryButton(label: tr('Connect a model'), icon: LucideIcons.sparkles, onPressed: onConnect),
                )
              else
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.35,
                  children: [
                    for (final (icon, color, title, blurb, prompt) in suggestions)
                      SurfaceCard(
                        padding: const EdgeInsets.all(14),
                        onTap: prompt == null ? onClone : () => onPrompt(prompt),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            IconTile(icon: icon, color: color, size: 32),
                            const Spacer(),
                            Text(title, style: text.titleSmall),
                            const SizedBox(height: 2),
                            Text(blurb, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focus,
    required this.agent,
    required this.onSend,
    required this.onQueue,
    required this.onAttach,
    required this.onVoice,
    required this.attachments,
    required this.onRemoveAttachment,
    required this.onPickModel,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final AgentController agent;
  final VoidCallback onSend;
  final VoidCallback onQueue;
  final VoidCallback onAttach;
  final VoidCallback onVoice;
  final List<Attachment> attachments;
  final void Function(Attachment) onRemoveAttachment;
  final VoidCallback onPickModel;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hasText = controller.text.trim().isNotEmpty || attachments.isNotEmpty;
    final busy = agent.busy;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: ListenableBuilder(
          listenable: focus,
          builder: (context, child) => AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: focus.hasFocus ? p.accent.withValues(alpha: 0.55) : p.border),
              boxShadow: [
                BoxShadow(
                  color: (focus.hasFocus ? p.accent : Colors.black).withValues(alpha: focus.hasFocus ? 0.18 : 0.12),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                  spreadRadius: -8,
                ),
              ],
            ),
            child: child,
          ),
          child: Column(
            children: [
              if (attachments.isNotEmpty) AttachmentStrip(items: attachments, onRemove: onRemoveAttachment),
              TextField(
                controller: controller,
                focusNode: focus,
                minLines: 1,
                maxLines: 8,
                textCapitalization: TextCapitalization.sentences,
                style: Theme.of(context).textTheme.bodyLarge,
                decoration: InputDecoration(
                  hintText: busy ? tr('Queue a follow-up…') : tr('Ask pi to build, fix or deploy…'),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: Row(
                  children: [
                    _IconChip(icon: LucideIcons.plus, label: tr('Attach'), onTap: onAttach),
                    const SizedBox(width: 6),
                    Flexible(
                      child: _Chip(
                        leading: agent.model == null ? null : BrandTile(id: agent.model!.provider, size: 20),
                        label: agent.model?.name ?? 'Choose model',
                        icon: LucideIcons.chevronsUpDown,
                        onTap: onPickModel,
                      ),
                    ),
                    if (agent.thinkingLevels.length > 1) ...[const SizedBox(width: 6), _ThinkingChip(agent: agent)],
                    const SizedBox(width: 6),
                    _IconChip(
                      icon: LucideIcons.listChecks,
                      label: agent.planMode ? 'Plan mode on' : 'Plan mode',
                      active: agent.planMode,
                      onTap: () => agent.setPlanMode(!agent.planMode),
                    ),
                    const Spacer(),
                    if (busy && !hasText)
                      _RoundButton(icon: LucideIcons.square, label: tr('Stop'), filled: true, onTap: agent.abort)
                    else if (!hasText)
                      _RoundButton(icon: LucideIcons.mic, label: tr('Voice'), filled: false, onTap: onVoice)
                    else
                      _RoundButton(
                        onLongPress: onQueue,
                        icon: LucideIcons.arrowUp,
                        label: tr('Send'),
                        filled: true,
                        onTap: hasText ? onSend : null,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A round icon-only chip for composer actions.
class _IconChip extends StatelessWidget {
  const _IconChip({required this.icon, required this.label, required this.onTap, this.active = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: Material(
          color: active ? p.accent : p.raised,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox.square(dimension: 34, child: Icon(icon, size: 17, color: active ? Colors.white : p.text)),
          ),
        ),
      ),
    );
  }
}

class _ThinkingChip extends StatelessWidget {
  const _ThinkingChip({required this.agent});
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    final on = agent.thinkingLevel != 'off';
    return PopupMenuButton<String>(
      tooltip: tr('Thinking level'),
      initialValue: agent.thinkingLevel,
      onSelected: agent.setThinking,
      position: PopupMenuPosition.over,
      elevation: 0,
      itemBuilder: (_) => [
        for (final level in agent.thinkingLevels)
          PopupMenuItem(value: level, height: 40, child: Text(_levelLabel(level))),
      ],
      child: IgnorePointer(
        child: _Chip(
          leading: Icon(LucideIcons.brain, size: 14, color: on ? context.palette.accent : context.palette.muted),
          label: _levelLabel(agent.thinkingLevel),
          onTap: () {},
        ),
      ),
    );
  }

  static String _levelLabel(String level) => switch (level) {
    'off' => 'Off',
    'minimal' => 'Minimal',
    'low' => 'Low',
    'medium' => 'Medium',
    'high' => 'High',
    'xhigh' => 'Max',
    _ => level,
  };
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onTap, this.icon, this.leading});
  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.raised,
      borderRadius: BorderRadius.circular(99),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(99),
        child: Container(
          height: 34,
          padding: EdgeInsets.fromLTRB(leading == null ? 12 : 6, 0, 10, 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 6)],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(color: p.text),
                ),
              ),
              if (icon != null) ...[const SizedBox(width: 4), Icon(icon, size: 13, color: p.faint)],
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.onTap,
    required this.label,
    this.filled = false,
    this.onLongPress,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = onTap != null;
    final active = filled && enabled;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? p.accent : (filled ? p.raised : p.surface),
          border: filled ? null : Border.all(color: p.border),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: p.accent.withValues(alpha: 0.45),
                    blurRadius: 14,
                    spreadRadius: -4,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            onLongPress: onLongPress,
            child: Icon(icon, size: 18, color: active ? Colors.white : (filled ? p.faint : p.text)),
          ),
        ),
      ),
    );
  }
}
