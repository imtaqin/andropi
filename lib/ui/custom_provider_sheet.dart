import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/models.dart';
import 'theme.dart';

/// Adds or edits one endpoint from models.json: any server speaking an API pi
/// already implements, e.g. an OpenAI-compatible one on the local network.
/// Resolves true once the endpoint was saved or removed.
Future<bool?> showCustomProviderSheet(BuildContext context, AgentController agent, {CustomProviderInfo? provider}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _CustomProviderSheet(agent: agent, provider: provider),
    ),
  );
}

class _CustomProviderSheet extends StatefulWidget {
  const _CustomProviderSheet({required this.agent, required this.provider});
  final AgentController agent;
  final CustomProviderInfo? provider;

  @override
  State<_CustomProviderSheet> createState() => _CustomProviderSheetState();
}

class _CustomProviderSheetState extends State<_CustomProviderSheet> {
  final name = TextEditingController();
  final baseUrl = TextEditingController();
  final apiKey = TextEditingController();
  final models = TextEditingController();
  final contextWindow = TextEditingController();
  final maxTokens = TextEditingController();

  String api = 'openai-completions';
  List<CustomApiInfo> apis = const [];
  bool images = false;
  bool obscure = true;
  bool busy = false;
  bool fetching = false;
  String? error;

  @override
  void initState() {
    super.initState();
    final provider = widget.provider;
    api = provider?.api ?? 'openai-completions';
    images = provider?.images ?? false;
    if (provider != null) {
      name.text = provider.name;
      baseUrl.text = provider.baseUrl;
      models.text = provider.modelIds.join('\n');
    }
    widget.agent.loadCustomApis().then((list) {
      if (mounted) setState(() => apis = list);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    for (final c in [name, baseUrl, apiKey, models, contextWindow, maxTokens]) {
      c.dispose();
    }
    super.dispose();
  }

  List<Map<String, String>> _parsedModels() {
    final out = <Map<String, String>>[];
    final seen = <String>{};
    for (final line in models.text.split(RegExp(r'[\n,]+'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split('|');
      final id = parts.first.trim();
      if (id.isEmpty || !seen.add(id)) continue;
      final label = parts.length > 1 ? parts.sublist(1).join('|').trim() : '';
      out.add({if (label.isNotEmpty) 'name': label, 'id': id});
    }
    return out;
  }

  Future<void> _save() async {
    final parsed = _parsedModels();
    if (name.text.trim().isEmpty || baseUrl.text.trim().isEmpty || parsed.isEmpty) {
      setState(() => error = 'Name, base URL and at least one model are required.');
      return;
    }
    final window = int.tryParse(contextWindow.text.trim());
    final output = int.tryParse(maxTokens.text.trim());
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.agent.saveCustomProvider({
        // Round-tripping the id keeps an edit in place of the original entry.
        if (widget.provider != null) 'id': widget.provider!.id,
        'name': name.text.trim(),
        'baseUrl': baseUrl.text.trim(),
        'api': api,
        'apiKey': apiKey.text.trim(),
        'images': images,
        if (window != null && window > 0) 'contextWindow': window,
        if (output != null && output > 0) 'maxTokens': output,
        'models': parsed,
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _remove() async {
    final confirm = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Remove ${widget.provider!.name}?', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'Only this endpoint is deleted; its models disappear from the model list. Nothing else on the device changes.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: context.palette.danger),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Remove endpoint'),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => busy = true);
    try {
      await widget.agent.deleteCustomProvider(widget.provider!.id);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _fetch() async {
    final url = baseUrl.text.trim();
    if (url.isEmpty) {
      setState(() => error = 'Enter the base URL first.');
      return;
    }
    setState(() {
      fetching = true;
      error = null;
    });
    try {
      final found = await widget.agent.discoverModels(baseUrl: url, apiKey: apiKey.text.trim());
      final lines = [
        for (final m in found)
          (m['name'] as String? ?? '').isEmpty || m['name'] == m['id']
              ? '${m['id']}'
              : '${m['id']} | ${m['name']}',
      ];
      if (!mounted) return;
      setState(() => models.text = lines.join('\n'));
      if (lines.isEmpty) setState(() => error = 'The server listed no models.');
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => fetching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final editing = widget.provider != null;
    Widget field(
      TextEditingController c,
      String label, {
      String? hint,
      int lines = 1,
      bool simple = false,
      bool secret = false,
      TextInputType? type,
    }) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            controller: c,
            maxLines: lines,
            minLines: lines,
            keyboardType: type,
            autocorrect: false,
            enableSuggestions: false,
            obscureText: secret && obscure,
            style: simple ? const TextStyle(fontFamily: mono, fontSize: 13.5) : null,
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              suffixIcon: secret
                  ? IconButton(
                      icon: Icon(obscure ? LucideIcons.eye : LucideIcons.eyeOff, size: 18),
                      onPressed: () => setState(() => obscure = !obscure),
                    )
                  : null,
            ),
          ),
        );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(editing ? 'Edit endpoint' : 'Add endpoint', style: text.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Any OpenAI-compatible server: Ollama, LM Studio, vLLM, a proxy or a company gateway.',
                style: text.bodySmall,
              ),
              const SizedBox(height: 16),
              field(name, 'Name', hint: 'Home Ollama'),
              field(
                baseUrl,
                'Base URL',
                hint: 'http://192.168.1.20:11434/v1',
                simple: true,
                type: TextInputType.url,
              ),
              DropdownButtonFormField<String>(
                initialValue: apis.any((a) => a.id == api) || apis.isEmpty ? api : null,
                decoration: const InputDecoration(labelText: 'Protocol'),
                items: [
                  for (final a in apis.isEmpty ? [CustomApiInfo({'id': api, 'label': api})] : apis)
                    DropdownMenuItem(value: a.id, child: Text(a.label, maxLines: 2, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: apis.isEmpty ? null : (v) => setState(() => api = v ?? api),
              ),
              const SizedBox(height: 12),
              field(
                apiKey,
                'API key',
                hint: editing && widget.provider?.hasKey == true
                    ? 'Key saved earlier — leave empty to keep it'
                    : 'Leave empty for a server that needs none',
                secret: true,
              ),
              const SizedBox(height: 6),
              Text('Stored on this device in models.json and never included in backups.', style: text.bodySmall),
              const SizedBox(height: 16),
              field(
                models,
                'Models (one per line: id or id | name)',
                hint: 'qwen2.5-coder:7b | Qwen Coder\nllama3.1:8b',
                lines: 4,
                simple: true,
                type: TextInputType.multiline,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: fetching ? null : _fetch,
                  icon: fetching
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 1.8),
                        )
                      : const Icon(LucideIcons.download, size: 16),
                  label: Text(fetching ? 'Asking the server...' : 'Fetch models from the server'),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: field(
                      contextWindow,
                      'Context window',
                      hint: '128000',
                      simple: true,
                      type: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: field(
                      maxTokens,
                      'Max output',
                      hint: '16384',
                      simple: true,
                      type: TextInputType.number,
                    ),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Image input', style: text.titleSmall),
                subtitle: Text('Let attachments and screenshots reach this endpoint', style: text.bodySmall),
                value: images,
                onChanged: (v) => setState(() => images = v),
              ),
              if (error != null) ...[
                const SizedBox(height: 4),
                Text(error!, style: text.bodySmall?.copyWith(color: p.danger)),
              ],
              const SizedBox(height: 14),
              FilledButton(onPressed: busy ? null : _save, child: busy ? const _Busy() : Text(editing ? 'Save' : 'Add endpoint')),
              if (editing) ...[
                const SizedBox(height: 8),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: p.danger),
                  onPressed: busy ? null : _remove,
                  child: const Text('Remove endpoint'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 16,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}