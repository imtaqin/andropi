import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';
import 'package:flutter/services.dart';

import '../agent/agent_controller.dart';
import '../agent/integrations.dart';
import 'code_view.dart';
import 'kit.dart';
import 'task_log.dart';
import 'theme.dart';

/// GitHub, Vercel, the device SSH key and saved servers.
class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  Integrations get it => widget.agent.integrations;

  @override
  void initState() {
    super.initState();
    it.refresh();
  }

  void _snack(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _guard(Future<void> Function() action, {String? success}) async {
    try {
      await action();
      if (success != null && mounted) _snack(success);
    } catch (e) {
      if (mounted) _snack(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: it,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Accounts & servers'),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Divider(height: 1, color: p.border),
          ),
        ),
        body: !it.loaded
            ? const Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)))
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  const _Header('GitHub'),
                  it.github == null
                      ? _GithubConnect(
                          agent: widget.agent,
                          onError: _snack,
                          onDone: () => _snack('GitHub connected'),
                          tokenFallback: _TokenConnect(
                            icon: SimpleIcons.github,
                            title: 'Connect GitHub',
                            body:
                                'Clone your repositories, push commits and publish to GitHub Pages. '
                                'Create a classic token with the repo and workflow scopes, then paste it here.',
                            linkLabel: 'Create a token',
                            onLink: () => widget.agent.client.openUrl(
                              'https://github.com/settings/tokens/new?scopes=repo,workflow,read:org&description=AndroPI',
                            ),
                            hint: 'ghp_… or github_pat_…',
                            onConnect: (t) => _guard(() => it.githubLogin(t), success: 'GitHub connected'),
                          ),
                        )
                      : _Connected(
                          avatarUrl: it.github!.avatarUrl,
                          icon: SimpleIcons.github,
                          title: it.github!.name ?? it.github!.login,
                          subtitle: '@${it.github!.login} · git push and Pages enabled',
                          onDisconnect: () => _guard(it.githubLogout),
                        ),
                  const _Header('Vercel'),
                  it.vercelUser == null
                      ? _TokenConnect(
                          icon: SimpleIcons.vercel,
                          title: 'Connect Vercel',
                          body: 'Deploy any project folder to Vercel from the chat. Create an access token and paste it here.',
                          linkLabel: 'Create a token',
                          onLink: () => widget.agent.client.openUrl('https://vercel.com/account/tokens'),
                          hint: 'Vercel access token',
                          onConnect: (t) => _guard(() => it.vercelLogin(t), success: 'Vercel connected'),
                        )
                      : _Connected(
                          icon: SimpleIcons.vercel,
                          title: it.vercelUser!,
                          subtitle: 'Deploys enabled',
                          onDisconnect: () => _guard(it.vercelLogout),
                        ),
                  const _Header('SSH key'),
                  _SshKeyCard(integrations: it, openUrl: widget.agent.client.openUrl),
                  _Header(
                    'Servers',
                    trailing: TextButton.icon(
                      onPressed: () => _editHost(null),
                      icon: const Icon(LucideIcons.plus, size: 18),
                      label: const Text('Add'),
                    ),
                  ),
                  if (it.hosts.isEmpty)
                    _Card(
                      child: Text(
                        'Save a server to deploy over SSH. The agent can reach it too, as `ssh <name>`.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  for (final h in it.hosts) _HostTile(host: h, onEdit: () => _editHost(h), onTest: () => _testHost(h)),
                ],
              ),
      ),
    );
  }

  Future<void> _testHost(SshHost h) async {
    if (it.publicKey == null) await it.ensureSshKey();
    if (!mounted) return;
    await runWithLog<void>(
      context,
      title: 'Connecting to ${h.name}',
      task: (log, _) => it.testHost(h.id, onLine: log),
    );
  }

  Future<void> _editHost(SshHost? h) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _HostSheet(host: h),
    );
    if (result == null) return;
    if (result['delete'] == true) {
      await _guard(() => it.deleteHost(h!.id));
    } else {
      await _guard(() => it.saveHost({if (h != null) 'id': h.id, ...result}));
    }
  }
}

class _Header extends StatelessWidget {
  const _Header(this.label, {this.trailing});
  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(4, 24, 0, trailing == null ? 8 : 0),
    child: Row(
      children: [
        Expanded(child: Text(label.toUpperCase(), style: Theme.of(context).textTheme.labelSmall)),
        ?trailing,
      ],
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border),
      ),
      child: child,
    );
  }
}

/// Signs in to GitHub with the device flow: show a short code, the user approves it on github.com.
/// Pasting a personal access token stays available underneath.
class _GithubConnect extends StatefulWidget {
  const _GithubConnect({required this.agent, required this.onError, required this.onDone, required this.tokenFallback});
  final AgentController agent;
  final void Function(String message) onError;
  final VoidCallback onDone;
  final Widget tokenFallback;

  @override
  State<_GithubConnect> createState() => _GithubConnectState();
}

class _GithubConnectState extends State<_GithubConnect> {
  bool starting = false;
  bool showToken = false;
  ({String deviceCode, String userCode, String verificationUri, int expiresIn, int interval})? flow;
  int attempt = 0;

  @override
  void dispose() {
    attempt++;
    super.dispose();
  }

  Future<void> _start() async {
    final it = widget.agent.integrations;
    final mine = ++attempt;
    setState(() => starting = true);
    try {
      final f = await it.githubDeviceStart();
      if (!mounted || mine != attempt) return;
      setState(() => flow = f);
      await Clipboard.setData(ClipboardData(text: f.userCode));
      await widget.agent.client.openUrl(f.verificationUri);
      final ok = await it.githubDeviceWait(f.deviceCode, f.interval, cancelled: () => !mounted || mine != attempt);
      if (ok && mounted) widget.onDone();
    } catch (e) {
      if (mounted && mine == attempt) widget.onError('$e');
    } finally {
      if (mounted && mine == attempt) {
        setState(() {
          starting = false;
          flow = null;
        });
      }
    }
  }

  void _cancel() => setState(() {
    attempt++;
    starting = false;
    flow = null;
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final f = flow;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconTile(icon: SimpleIcons.github, color: p.text, size: 36),
                  const SizedBox(width: 10),
                  Text('Connect GitHub', style: text.titleSmall),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                f == null
                    ? 'Clone your repositories, push commits and publish to GitHub Pages. '
                          'Sign in on github.com with a one-time code; no token to create.'
                    : 'Enter this code on GitHub. It is already copied, just paste it and approve.',
                style: text.bodySmall,
              ),
              const SizedBox(height: 14),
              if (f == null)
                PrimaryButton(
                  label: 'Sign in with GitHub',
                  icon: SimpleIcons.github,
                  busy: starting,
                  onPressed: starting ? null : _start,
                )
              else ...[
                GestureDetector(
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: f.userCode));
                    widget.onError('Code copied');
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(16)),
                    alignment: Alignment.center,
                    child: Text(
                      f.userCode,
                      style: TextStyle(
                        fontFamily: mono,
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 4,
                        color: p.text,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => widget.agent.client.openUrl(f.verificationUri),
                        icon: const Icon(LucideIcons.externalLink, size: 16),
                        label: const Text('Open GitHub'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(onPressed: _cancel, child: const Text('Cancel')),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: p.muted)),
                    const SizedBox(width: 8),
                    Text('Waiting for you to approve on GitHub…', style: text.bodySmall),
                  ],
                ),
              ],
              if (f == null)
                TextButton(
                  onPressed: () => setState(() => showToken = !showToken),
                  style: TextButton.styleFrom(foregroundColor: p.muted),
                  child: Text(showToken ? 'Hide token option' : 'Use a personal access token instead'),
                ),
            ],
          ),
        ),
        if (showToken && f == null) ...[const SizedBox(height: 10), widget.tokenFallback],
      ],
    );
  }
}

class _TokenConnect extends StatefulWidget {
  const _TokenConnect({
    required this.icon,
    required this.title,
    required this.body,
    required this.linkLabel,
    required this.onLink,
    required this.hint,
    required this.onConnect,
  });
  final IconData icon;
  final String title;
  final String body;
  final String linkLabel;
  final VoidCallback onLink;
  final String hint;
  final Future<void> Function(String token) onConnect;

  @override
  State<_TokenConnect> createState() => _TokenConnectState();
}

class _TokenConnectState extends State<_TokenConnect> {
  final token = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (token.text.trim().isEmpty) return;
    setState(() => busy = true);
    await widget.onConnect(token.text);
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconTile(icon: widget.icon, color: p.text, size: 36),
              const SizedBox(width: 10),
              Text(widget.title, style: text.titleSmall),
            ],
          ),
          const SizedBox(height: 8),
          Text(widget.body, style: text.bodySmall),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: widget.onLink,
              style: TextButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: p.text),
              icon: const Icon(LucideIcons.externalLink, size: 15),
              label: Text(widget.linkLabel),
            ),
          ),
          TextField(
            controller: token,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(hintText: widget.hint),
            onSubmitted: (_) => _connect(),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: busy ? null : _connect,
            child: busy
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Connect'),
          ),
        ],
      ),
    );
  }
}

class _Connected extends StatelessWidget {
  const _Connected({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onDisconnect,
    this.avatarUrl,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onDisconnect;
  final String? avatarUrl;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return _Card(
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: p.raised,
            foregroundImage: avatarUrl == null ? null : NetworkImage(avatarUrl!),
            child: Icon(icon, size: 18, color: p.text),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleSmall),
                const SizedBox(height: 2),
                Text(subtitle, style: text.bodySmall),
              ],
            ),
          ),
          TextButton(
            onPressed: onDisconnect,
            style: TextButton.styleFrom(foregroundColor: p.danger),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
  }
}

class _SshKeyCard extends StatefulWidget {
  const _SshKeyCard({required this.integrations, required this.openUrl});
  final Integrations integrations;
  final Future<void> Function(String url) openUrl;

  @override
  State<_SshKeyCard> createState() => _SshKeyCardState();
}

class _SshKeyCardState extends State<_SshKeyCard> {
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final key = widget.integrations.publicKey;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            key == null
                ? 'Generate a key for this device, then add its public half to your servers or GitHub.'
                : 'Add this public key to ~/.ssh/authorized_keys on your servers, or to GitHub for SSH remotes.',
            style: text.bodySmall,
          ),
          const SizedBox(height: 12),
          if (key == null)
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () async {
                      setState(() => busy = true);
                      try {
                        await widget.integrations.ensureSshKey();
                      } finally {
                        if (mounted) setState(() => busy = false);
                      }
                    },
              icon: const Icon(LucideIcons.keyRound, size: 18),
              label: const Text('Generate key'),
            )
          else ...[
            CodeBox(text: key, label: 'id_ed25519.pub', lineNumbers: false),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: key));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Public key copied')));
                    },
                    icon: const Icon(LucideIcons.copy, size: 16),
                    label: const Text('Copy'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: key));
                      widget.openUrl('https://github.com/settings/ssh/new');
                    },
                    icon: const Icon(LucideIcons.externalLink, size: 16),
                    label: const Text('Add to GitHub'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _HostTile extends StatelessWidget {
  const _HostTile({required this.host, required this.onEdit, required this.onTest});
  final SshHost host;
  final VoidCallback onEdit;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: p.border),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onEdit,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                Icon(LucideIcons.server, size: 20, color: p.muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(host.name, style: text.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        [host.address, if (host.path != null) host.path!].join('  ·  '),
                        style: TextStyle(fontFamily: mono, fontSize: 11.5, color: p.muted),
                      ),
                    ],
                  ),
                ),
                TextButton(onPressed: onTest, child: const Text('Test')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HostSheet extends StatefulWidget {
  const _HostSheet({this.host});
  final SshHost? host;

  @override
  State<_HostSheet> createState() => _HostSheetState();
}

class _HostSheetState extends State<_HostSheet> {
  late final name = TextEditingController(text: widget.host?.name);
  late final host = TextEditingController(text: widget.host?.host);
  late final port = TextEditingController(text: '${widget.host?.port ?? 22}');
  late final user = TextEditingController(text: widget.host?.user);
  late final path = TextEditingController(text: widget.host?.path);

  @override
  void dispose() {
    for (final c in [name, host, port, user, path]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    Widget field(TextEditingController c, String label, {String? hint, TextInputType? type, bool mono = false}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            controller: c,
            keyboardType: type,
            autocorrect: false,
            style: mono ? const TextStyle(fontFamily: 'GeistMono', fontSize: 14) : null,
            decoration: InputDecoration(labelText: label, hintText: hint),
          ),
        );
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.host == null ? 'Add server' : 'Edit server', style: text.titleLarge),
              const SizedBox(height: 16),
              field(name, 'Name', hint: 'my-vps'),
              Row(
                children: [
                  Expanded(flex: 3, child: field(host, 'Host', hint: '203.0.113.10', mono: true)),
                  const SizedBox(width: 10),
                  Expanded(child: field(port, 'Port', type: TextInputType.number, mono: true)),
                ],
              ),
              field(user, 'User', hint: 'root', mono: true),
              field(path, 'Deploy folder (optional)', hint: '/var/www/html', mono: true),
              const SizedBox(height: 6),
              FilledButton(
                onPressed: () => Navigator.of(context).pop({
                  'name': name.text,
                  'host': host.text,
                  'port': int.tryParse(port.text) ?? 22,
                  'user': user.text,
                  'path': path.text,
                }),
                child: const Text('Save'),
              ),
              if (widget.host != null) ...[
                const SizedBox(height: 8),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: p.danger),
                  onPressed: () => Navigator.of(context).pop({'delete': true}),
                  child: const Text('Remove server'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
