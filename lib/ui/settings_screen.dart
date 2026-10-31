import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/models.dart';
import 'custom_provider_sheet.dart';
import 'login_flow.dart';
import 'kit.dart';
import 'theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String query = '';

  @override
  void initState() {
    super.initState();
    widget.agent.refreshProviders();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.agent,
      builder: (context, _) {
        final agent = widget.agent;
        final q = query.toLowerCase();
        final connected = agent.providers.where((x) => x.configured).toList();
        final others = agent.providers
            .where((x) => !x.configured && (q.isEmpty || x.name.toLowerCase().contains(q) || x.id.contains(q)))
            .toList();

        return Scaffold(
          appBar: AppBar(
            title: const Text('Models & providers'),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(1),
              child: Divider(height: 1, color: p.border),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              const _Header('Connected'),
              if (connected.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text('No providers yet. Pick one below.', style: text.bodySmall),
                ),
              for (final pr in connected) _ProviderTile(provider: pr, agent: agent),
              const _Header('Add provider'),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: TextField(
                  onChanged: (v) => setState(() => query = v),
                  decoration: const InputDecoration(
                    hintText: 'Search providers',
                    prefixIcon: Icon(LucideIcons.search, size: 18),
                  ),
                ),
              ),
              for (final pr in others) _ProviderTile(provider: pr, agent: agent),
              _Header(
                'Custom endpoints',
                trailing: TextButton.icon(
                  onPressed: () => _addEndpoint(context),
                  icon: const Icon(LucideIcons.plus, size: 18),
                  label: const Text('Add'),
                ),
              ),
              if (agent.customProviders.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    'Point the app at any server that speaks an OpenAI-compatible API: Ollama, LM Studio, '
                    'vLLM, a proxy or your own gateway.',
                    style: text.bodySmall,
                  ),
                ),
              for (final c in agent.customProviders) _CustomTile(endpoint: c, agent: agent),
              const _Header('Environment'),
              _InfoRow('pi', agent.info['version']?.toString() ?? '—'),
              _InfoRow('Node.js', agent.info['node']?.toString() ?? '—'),
              _InfoRow('Workspace', agent.info['workspace']?.toString() ?? '—', mono: true),
              _InfoRow('Agent directory', agent.info['agentDir']?.toString() ?? '—', mono: true),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: OutlinedButton(onPressed: agent.busy ? null : agent.restart, child: const Text('Restart agent')),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _addEndpoint(BuildContext context) async {
    final saved = await showCustomProviderSheet(context, widget.agent);
    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Endpoint saved')));
    }
  }
}

/// One endpoint defined in models.json: edit it or remove it.
class _CustomTile extends StatelessWidget {
  const _CustomTile({required this.endpoint, required this.agent});
  final CustomProviderInfo endpoint;
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: BrandTile(id: endpoint.id, size: 38),
      title: Text(endpoint.name, style: Theme.of(context).textTheme.titleSmall),
      subtitle: Text('${endpoint.modelIds.length} models  ·  ${endpoint.summary}'),
      trailing: Icon(LucideIcons.chevronRight, size: 18, color: p.faint),
      onTap: () async {
        final changed = await showCustomProviderSheet(context, agent, provider: endpoint);
        if (changed == true && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Endpoint updated')));
        }
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.label, {this.trailing});
  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(20, 24, 20, trailing == null ? 8 : 0),
    child: Row(
      children: [
        Expanded(child: Text(label.toUpperCase(), style: Theme.of(context).textTheme.labelSmall)),
        ?trailing,
      ],
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value, {this.mono = false});
  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: text.labelMedium),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: mono
                ? TextStyle(fontFamily: 'GeistMono', fontSize: 12.5, color: p.text, height: 1.5)
                : text.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _ProviderTile extends StatelessWidget {
  const _ProviderTile({required this.provider, required this.agent});
  final ProviderInfo provider;
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final subtitle = provider.configured ? (provider.oauth ? 'Signed in' : 'API key') : '${provider.modelCount} models';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: BrandTile(id: provider.id, size: 38),
      title: Text(provider.name, style: Theme.of(context).textTheme.titleSmall),
      subtitle: Text(subtitle),
      trailing: provider.configured
          ? Pill('Connected', color: p.success, dot: true)
          : Icon(LucideIcons.chevronRight, size: 18, color: p.faint),
      onTap: () => _open(context),
    );
  }

  Future<void> _open(BuildContext context) async {
    final methods = provider.methods;
    // Our own endpoint is edited (or removed) in its own sheet, not disconnected.
    if (provider.custom) {
      CustomProviderInfo? endpoint;
      for (final c in agent.customProviders) {
        if (c.id == provider.id) endpoint = c;
      }
      endpoint ??= CustomProviderInfo({
        'id': provider.id,
        'name': provider.name,
        'baseUrl': '',
        'api': 'openai-completions',
        'models': const [],
      });
      await showCustomProviderSheet(context, agent, provider: endpoint);
      return;
    }
    if (provider.configured) {
      final disconnect = await showModalBottomSheet<bool>(
        context: context,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(provider.name, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('Remove the stored credential from this device.', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 20),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: context.palette.danger),
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Disconnect'),
                ),
              ],
            ),
          ),
        ),
      );
      if (disconnect == true) await agent.logout(provider.id);
      return;
    }
    if (methods.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${provider.name} uses ambient credentials and cannot be set up here.')));
      return;
    }
    var method = methods.first;
    if (methods.length > 1) {
      final picked = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('Sign in with account'),
                subtitle: const Text('Use your subscription through the browser'),
                onTap: () => Navigator.of(context).pop('oauth'),
              ),
              ListTile(
                title: const Text('Use an API key'),
                subtitle: const Text('Paste a key from the provider console'),
                onTap: () => Navigator.of(context).pop('api_key'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (picked == null) return;
      method = picked;
    }
    if (!context.mounted) return;
    final ok = await showLoginSheet(context, agent, provider, method);
    if (ok == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${provider.name} connected')));
    }
  }
}
