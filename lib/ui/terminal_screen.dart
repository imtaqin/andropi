import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import '../agent/agent_controller.dart';
import 'kit.dart';
import 'theme.dart';

/// A shell with the agent's toolchain (git, ssh, node…). Sessions outlive the
/// screen, so leaving and coming back resumes the same tabs.
class ShellSession {
  ShellSession._(this.pty, this.cwd, this.title, {required this.linux});

  /// Every open tab, in strip order.
  static final sessions = <ShellSession>[];

  /// Index of the tab shown when the screen opens.
  static int selected = 0;

  /// Commands typed in any tab, newest first (best effort, from keystrokes).
  static final history = <String>[];

  /// Bumped when a session exits or the list changes, so open screens redraw.
  static final changes = ValueNotifier<int>(0);

  final Pty pty;
  String cwd;
  String title;

  /// Started with `box`: the Linux container, where cd-to-project doesn't apply.
  final bool linux;
  final terminal = Terminal(maxLines: 10000);
  bool exited = false;
  String _line = '';

  static Future<ShellSession> start(AgentController agent, String cwd, {String? title, bool linux = false}) async {
    final env = await agent.client.environment();
    final home = env['HOME']!;
    // mksh reads $ENV for interactive shells: a short prompt and a few aliases.
    final rc = File('$home/.andropirc');
    rc.writeAsStringSync(r'''
PS1='${PWD##*/} $ '
alias ll='ls -la'
alias la='ls -A'
alias gs='git status'
''');
    final pty = Pty.start(
      '/system/bin/sh',
      arguments: ['-i'],
      workingDirectory: cwd,
      environment: {...env, 'TERM': 'xterm-256color', 'ENV': rc.path},
      rows: 40,
      columns: 80,
    );
    final session = ShellSession._(pty, cwd, title ?? (linux ? 'linux' : 'sh'), linux: linux);
    session._wire();
    return session;
  }

  void _wire() {
    pty.output.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(terminal.write);
    pty.exitCode.then((code) {
      exited = true;
      terminal.write('\r\n[process exited with code $code]\r\n');
      changes.value++;
    });
    terminal.onOutput = input;
    terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);
  }

  /// Keystrokes from the terminal view: sent to the shell and tracked for history.
  void input(String data) {
    _track(data);
    pty.write(const Utf8Encoder().convert(data));
  }

  void type(String text) => pty.write(const Utf8Encoder().convert(text));

  /// Types [command] followed by Enter and remembers it.
  void run(String command) {
    _remember(command);
    _line = '';
    type('$command\r');
  }

  void kill() => pty.kill();

  void _track(String data) {
    data = data.replaceAll('\x1b[200~', '').replaceAll('\x1b[201~', '');
    // Arrow keys and other escape sequences: the shell may edit or recall a
    // line we can't see, so stop guessing until the next Enter.
    if (data.startsWith('\x1b')) {
      if (data.length > 1) _line = '';
      return;
    }
    for (final ch in data.runes) {
      if (ch == 0x0d || ch == 0x0a) {
        _remember(_line);
        _line = '';
      } else if (ch == 0x7f || ch == 0x08) {
        if (_line.isNotEmpty) _line = String.fromCharCodes(_line.runes.toList()..removeLast());
      } else if (ch == 0x03 || ch == 0x15) {
        _line = '';
      } else if (ch >= 0x20) {
        _line += String.fromCharCode(ch);
      }
    }
  }

  static void _remember(String command) {
    final c = command.trim();
    if (c.isEmpty) return;
    history
      ..remove(c)
      ..insert(0, c);
    if (history.length > 30) history.removeRange(30, history.length);
  }
}

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key, required this.agent, this.command});
  final AgentController agent;

  /// Run in a new tab on open, e.g. `box` to enter the Linux container.
  final String? command;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  Object? error;
  bool starting = false;
  final focus = FocusNode();
  final controller = TerminalController();
  final tabScroll = ScrollController();
  bool ctrl = false;

  AgentController get agent => widget.agent;
  List<ShellSession> get sessions => ShellSession.sessions;

  ShellSession? get session => sessions.isEmpty ? null : sessions[ShellSession.selected.clamp(0, sessions.length - 1)];

  String get _cwd => agent.cwd.isEmpty ? (agent.info['workspace'] as String? ?? '/') : agent.cwd;

  @override
  void initState() {
    super.initState();
    ShellSession.changes.addListener(_changed);
    final command = widget.command;
    if (command != null || session == null) starting = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (command != null) {
        _newTab(command: command, linux: command.trim() == 'box');
      } else if (session == null) {
        _newTab();
      } else {
        _select(ShellSession.selected.clamp(0, sessions.length - 1));
      }
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ShellSession.changes.removeListener(_changed);
    for (final s in sessions) {
      s.terminal.onOutput = s.input;
    }
    focus.dispose();
    controller.dispose();
    tabScroll.dispose();
    super.dispose();
  }

  /// Ctrl from the key bar applies to the next typed character.
  void _bind(ShellSession s) {
    s.terminal.onOutput = (data) {
      if (ctrl && data.length == 1) {
        final c = data.toLowerCase().codeUnitAt(0);
        if (c >= 0x61 && c <= 0x7a) data = String.fromCharCode(c - 0x60);
        if (mounted) setState(() => ctrl = false);
      }
      s.input(data);
    };
  }

  void _select(int i) {
    final s = sessions[i];
    ShellSession.selected = i;
    _bind(s);
    // Follow the chat into its project.
    final cwd = _cwd;
    if (!s.linux && !s.exited && s.cwd != cwd) {
      s.type("cd '${cwd.replaceAll("'", r"'\''")}'\r");
      s.cwd = cwd;
    }
    setState(() {});
    focus.requestFocus();
  }

  Future<ShellSession?> _newTab({String? command, bool linux = false, String? title, int? replace}) async {
    setState(() {
      starting = true;
      error = null;
    });
    ShellSession s;
    try {
      s = await ShellSession.start(agent, _cwd, title: title, linux: linux);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e;
          starting = false;
        });
      }
      return null;
    }
    if (replace != null && replace < sessions.length) {
      sessions[replace] = s;
    } else {
      sessions.add(s);
    }
    final index = sessions.indexOf(s);
    ShellSession.changes.value++;
    if (command != null) s.run(command);
    if (!mounted) return s;
    starting = false;
    _select(index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (tabScroll.hasClients) tabScroll.jumpTo(tabScroll.position.maxScrollExtent);
    });
    return s;
  }

  void _close(int i) {
    final s = sessions.removeAt(i);
    s.kill();
    if (ShellSession.selected >= sessions.length) ShellSession.selected = sessions.length - 1;
    if (ShellSession.selected < 0) ShellSession.selected = 0;
    ShellSession.changes.value++;
    if (sessions.isNotEmpty) _select(ShellSession.selected);
  }

  Future<void> _restart() async {
    final s = session;
    if (s == null) {
      await _newTab();
      return;
    }
    final i = sessions.indexOf(s);
    s.kill();
    await _newTab(linux: s.linux, title: s.title, command: s.linux ? 'box' : null, replace: i);
  }

  Future<void> _rename(int i) async {
    final s = sessions[i];
    final field = TextEditingController(text: s.title);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename tab'),
        content: TextField(controller: field, autofocus: true, onSubmitted: (v) => Navigator.of(context).pop(v)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(field.text), child: const Text('Rename')),
        ],
      ),
    );
    field.dispose();
    if (name != null && name.trim().isNotEmpty) {
      s.title = name.trim();
      ShellSession.changes.value++;
    }
  }

  Future<void> _runTests() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final t = await agent.features.detectTests();
      if (t == null) {
        messenger.showSnackBar(const SnackBar(content: Text('No test setup found')));
        return;
      }
      await _newTab(command: t.command, title: t.framework.isEmpty ? 'tests' : t.framework);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  void _key(TerminalKey key) {
    session?.terminal.keyInput(key, ctrl: ctrl);
    if (ctrl) setState(() => ctrl = false);
    focus.requestFocus();
  }

  void _text(String s) {
    session?.terminal.textInput(s);
    focus.requestFocus();
  }

  Future<void> _sshMenu() async {
    final hosts = agent.integrations.hosts;
    if (hosts.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Add a server under Accounts & servers first')));
      return;
    }
    final name = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final h in hosts)
              ListTile(
                leading: const Icon(LucideIcons.server),
                title: Text(h.name),
                subtitle: Text(h.address, style: const TextStyle(fontFamily: mono, fontSize: 12)),
                onTap: () => Navigator.of(context).pop(h.name),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (name != null) session?.run('ssh $name');
    focus.requestFocus();
  }

  Future<void> _historySheet() async {
    final items = ShellSession.history;
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No commands yet')));
      return;
    }
    final command = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 8),
            children: [
              const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 0), child: SectionLabel('Command history')),
              for (final c in items)
                ListTile(
                  dense: true,
                  leading: const Icon(LucideIcons.history, size: 18),
                  title: Text(
                    c,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: mono, fontSize: 13),
                  ),
                  onTap: () => Navigator.of(context).pop(c),
                ),
            ],
          ),
        ),
      ),
    );
    if (command != null) session?.run(command);
    focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final s = session;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Terminal'),
            if (s != null)
              Text(
                s.linux ? 'Linux container' : s.cwd.replaceFirst(RegExp(r'^.*/files/home'), '~'),
                style: TextStyle(fontFamily: mono, fontSize: 11.5, color: p.muted),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Command history',
            icon: const Icon(LucideIcons.history, size: 20),
            onPressed: _historySheet,
          ),
          IconButton(tooltip: 'SSH to a server', icon: const Icon(LucideIcons.server, size: 20), onPressed: _sshMenu),
          IconButton(tooltip: 'Restart shell', icon: const Icon(LucideIcons.rotateCcw, size: 20), onPressed: _restart),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(preferredSize: const Size.fromHeight(49), child: _tabStrip(p)),
      ),
      body: error != null && s == null
          ? Center(child: Text('Could not start a shell: $error'))
          : s == null
          ? starting
                ? const Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                : Center(
                    child: SizedBox(
                      width: 220,
                      child: PrimaryButton(label: 'New shell', icon: LucideIcons.plus, onPressed: () => _newTab()),
                    ),
                  )
          : Column(
              children: [
                Expanded(
                  child: TerminalView(
                    s.terminal,
                    key: ObjectKey(s),
                    controller: controller,
                    focusNode: focus,
                    autofocus: true,
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                    keyboardType: TextInputType.visiblePassword,
                    keyboardAppearance: dark ? Brightness.dark : Brightness.light,
                    textStyle: const TerminalStyle(fontFamily: mono, fontSize: 12.5),
                    theme: dark ? _darkTheme(p) : _lightTheme(p),
                  ),
                ),
                _KeyBar(
                  ctrl: ctrl,
                  onCtrl: () => setState(() => ctrl = !ctrl),
                  onKey: _key,
                  onText: _text,
                  onHistory: _historySheet,
                  onPaste: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    if (data?.text != null) s.terminal.paste(data!.text!);
                  },
                ),
              ],
            ),
    );
  }

  Widget _tabStrip(Palette p) {
    Widget pill({required Widget child, required bool on, VoidCallback? onTap, VoidCallback? onLongPress}) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: on ? p.text : p.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          onLongPress: onLongPress,
          child: SizedBox(height: 32, child: child),
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            controller: tabScroll,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            children: [
              for (var i = 0; i < sessions.length; i++)
                Builder(
                  builder: (context) {
                    final s = sessions[i];
                    final on = s == session;
                    final fg = on ? p.inverse : (s.exited ? p.faint : p.text);
                    return pill(
                      on: on,
                      onTap: () => _select(i),
                      onLongPress: () => _rename(i),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: 12),
                          Icon(s.linux ? LucideIcons.box : LucideIcons.squareTerminal, size: 14, color: fg),
                          const SizedBox(width: 6),
                          Text(
                            s.title,
                            style: TextStyle(
                              fontFamily: mono,
                              fontSize: 12.5,
                              color: fg,
                              decoration: s.exited ? TextDecoration.lineThrough : null,
                            ),
                          ),
                          InkResponse(
                            radius: 14,
                            onTap: () => _close(i),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
                              child: Icon(LucideIcons.x, size: 13, color: on ? p.inverse : p.muted),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              PopupMenuButton<String>(
                tooltip: 'New tab',
                position: PopupMenuPosition.under,
                onSelected: (v) => switch (v) {
                  'linux' => _newTab(command: 'box', linux: true),
                  'tests' => _runTests(),
                  _ => _newTab(),
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'android',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(LucideIcons.smartphone, size: 18),
                      title: Text('Android shell'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'linux',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(LucideIcons.box, size: 18),
                      title: Text('Linux shell (box)'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'tests',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(LucideIcons.flaskConical, size: 18),
                      title: Text('Run tests'),
                    ),
                  ),
                ],
                child: Container(
                  height: 32,
                  width: 40,
                  decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(16)),
                  alignment: Alignment.center,
                  child: starting
                      ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(LucideIcons.plus, size: 16, color: p.text),
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: p.border),
      ],
    );
  }

  static TerminalTheme _darkTheme(Palette p) => TerminalTheme(
    cursor: p.text,
    selection: const Color(0x553D7BFF),
    foreground: p.text,
    background: p.bg,
    black: const Color(0xFF1C1C1F),
    red: const Color(0xFFFF7B72),
    green: const Color(0xFF7EE787),
    yellow: const Color(0xFFE3B341),
    blue: const Color(0xFF79C0FF),
    magenta: const Color(0xFFD2A8FF),
    cyan: const Color(0xFF56D4DD),
    white: const Color(0xFFC9D1D9),
    brightBlack: const Color(0xFF6E7681),
    brightRed: const Color(0xFFFFA198),
    brightGreen: const Color(0xFF56D364),
    brightYellow: const Color(0xFFF2CC60),
    brightBlue: const Color(0xFFA5D6FF),
    brightMagenta: const Color(0xFFE2C5FF),
    brightCyan: const Color(0xFFB3F0FF),
    brightWhite: const Color(0xFFFFFFFF),
    searchHitBackground: const Color(0xFFE3B341),
    searchHitBackgroundCurrent: const Color(0xFF7EE787),
    searchHitForeground: const Color(0xFF0B0B0C),
  );

  static TerminalTheme _lightTheme(Palette p) => TerminalTheme(
    cursor: p.text,
    selection: const Color(0x333D7BFF),
    foreground: p.text,
    background: p.bg,
    black: const Color(0xFF24292F),
    red: const Color(0xFFCF222E),
    green: const Color(0xFF116329),
    yellow: const Color(0xFF9A6700),
    blue: const Color(0xFF0550AE),
    magenta: const Color(0xFF8250DF),
    cyan: const Color(0xFF1B7C83),
    white: const Color(0xFF6E7781),
    brightBlack: const Color(0xFF57606A),
    brightRed: const Color(0xFFA40E26),
    brightGreen: const Color(0xFF1A7F37),
    brightYellow: const Color(0xFF633C01),
    brightBlue: const Color(0xFF218BFF),
    brightMagenta: const Color(0xFFA475F9),
    brightCyan: const Color(0xFF3192AA),
    brightWhite: const Color(0xFF8C959F),
    searchHitBackground: const Color(0xFFFFDF5D),
    searchHitBackgroundCurrent: const Color(0xFF2DA44E),
    searchHitForeground: const Color(0xFF0B0B0C),
  );
}

/// The keys a phone keyboard lacks.
class _KeyBar extends StatelessWidget {
  const _KeyBar({
    required this.ctrl,
    required this.onCtrl,
    required this.onKey,
    required this.onText,
    required this.onPaste,
    required this.onHistory,
  });
  final bool ctrl;
  final VoidCallback onCtrl;
  final void Function(TerminalKey) onKey;
  final void Function(String) onText;
  final VoidCallback onPaste;
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    Widget key(String label, VoidCallback onTap, {bool active = false, IconData? icon}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: active ? p.text : p.raised,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: Container(
            constraints: const BoxConstraints(minWidth: 40),
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            child: icon != null
                ? Icon(icon, size: 16, color: active ? p.inverse : p.text)
                : Text(
                    label,
                    style: TextStyle(fontFamily: mono, fontSize: 12.5, color: active ? p.inverse : p.text),
                  ),
          ),
        ),
      ),
    );
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(top: BorderSide(color: p.border)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              key('esc', () => onKey(TerminalKey.escape)),
              key('tab', () => onKey(TerminalKey.tab)),
              key('ctrl', onCtrl, active: ctrl),
              key('', () => onKey(TerminalKey.arrowUp), icon: LucideIcons.chevronUp),
              key('', () => onKey(TerminalKey.arrowDown), icon: LucideIcons.chevronDown),
              key('', () => onKey(TerminalKey.arrowLeft), icon: LucideIcons.chevronLeft),
              key('', () => onKey(TerminalKey.arrowRight), icon: LucideIcons.chevronRight),
              for (final c in ['/', '-', '|', '~', r'$', '*', '&', '>', '"', "'"]) key(c, () => onText(c)),
              key('', onPaste, icon: LucideIcons.clipboardPaste),
              key('', onHistory, icon: LucideIcons.history),
            ],
          ),
        ),
      ),
    );
  }
}
