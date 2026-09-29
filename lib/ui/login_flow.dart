import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';

import '../agent/agent_controller.dart';
import '../agent/models.dart';
import 'theme.dart';

/// Runs pi's login for [provider] and renders each step of its interaction
/// (prompts, browser links, device codes) inline. Resolves true on success.
Future<bool?> showLoginSheet(BuildContext context, AgentController agent, ProviderInfo provider, String method) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: false,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _LoginSheet(agent: agent, provider: provider, method: method),
    ),
  );
}

class _LoginSheet extends StatefulWidget {
  const _LoginSheet({required this.agent, required this.provider, required this.method});
  final AgentController agent;
  final ProviderInfo provider;
  final String method;

  @override
  State<_LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends State<_LoginSheet> {
  StreamSubscription<Map<String, dynamic>>? sub;
  final field = TextEditingController();

  int? authId;
  Map<String, dynamic>? prompt;
  Map<String, dynamic>? link; // auth_url or device_code event
  String? progress;
  String? error;
  bool obscure = true;

  @override
  void initState() {
    super.initState();
    sub = widget.agent.authRecords.stream.listen(_onRecord);
    _run();
  }

  @override
  void dispose() {
    sub?.cancel();
    field.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    try {
      await widget.agent.login(widget.provider.id, widget.method);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      final message = e.toString();
      if (message.contains('cancelled')) {
        Navigator.of(context).pop(false);
      } else {
        setState(() {
          error = message;
          prompt = null;
        });
      }
    }
  }

  void _onRecord(Map<String, dynamic> r) {
    if (r['provider'] != null && r['provider'] != widget.provider.id) return;
    setState(() {
      switch (r['type']) {
        case 'auth_prompt':
          authId = r['authId'] as int;
          prompt = (r['prompt'] as Map).cast<String, dynamic>();
          field.clear();
        case 'auth_dismiss':
          if (r['authId'] == authId) prompt = null;
        case 'auth_event':
          final e = (r['event'] as Map).cast<String, dynamic>();
          switch (e['type']) {
            case 'auth_url' || 'device_code':
              link = e;
            case 'progress' || 'info':
              progress = e['message'] as String?;
          }
      }
    });
  }

  void _answer(String? value) {
    final id = authId;
    if (id == null) return;
    widget.agent.answerAuth(id, value);
    setState(() {
      prompt = null;
      authId = null;
      progress = value == null ? null : 'Checking…';
    });
  }

  void _cancel() {
    if (authId != null) {
      _answer(null);
    } else {
      Navigator.of(context).pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final isKey = widget.method == 'api_key';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.provider.name, style: text.titleLarge),
            const SizedBox(height: 4),
            Text(isKey ? 'Connect with an API key' : 'Sign in with your account', style: text.bodySmall),
            const SizedBox(height: 20),
            if (error != null) ...[
              Text(error!, style: text.bodyMedium?.copyWith(color: p.danger)),
              const SizedBox(height: 16),
              FilledButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Close')),
            ] else ...[
              if (link != null) ...[_linkPanel(context), const SizedBox(height: 16)],
              if (prompt != null)
                _promptPanel(context)
              else
                Row(
                  children: [
                    const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 1.8)),
                    const SizedBox(width: 12),
                    Expanded(child: Text(progress ?? 'Waiting for provider…', style: text.bodyMedium)),
                    TextButton(onPressed: _cancel, child: const Text('Cancel')),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _linkPanel(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final e = link!;
    final isDevice = e['type'] == 'device_code';
    final url = (isDevice ? e['verificationUri'] : e['url']) as String;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            isDevice
                ? 'Open the link and enter this code.'
                : (e['instructions'] as String? ?? 'Open the link to continue in your browser.'),
            style: text.bodyMedium,
          ),
          if (isDevice) ...[
            const SizedBox(height: 12),
            SelectableText(
              e['userCode'] as String,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: mono,
                fontSize: 24,
                fontWeight: FontWeight.w600,
                letterSpacing: 3,
                color: p.text,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => widget.agent.client.openUrl(url),
                  child: const Text('Open browser'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: isDevice ? e['userCode'] as String : url));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
                },
                child: Text(isDevice ? 'Copy code' : 'Copy link'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _promptPanel(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final pr = prompt!;
    final type = pr['type'] as String;

    if (type == 'select') {
      final options = (pr['options'] as List).cast<Map>();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(pr['message'] as String? ?? 'Choose an option', style: text.bodyMedium),
          const SizedBox(height: 8),
          for (final o in options)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              title: Text(o['label'] as String),
              subtitle: o['description'] == null ? null : Text(o['description'] as String),
              trailing: Icon(LucideIcons.chevronRight, color: p.faint),
              onTap: () => _answer(o['id'] as String),
            ),
          const SizedBox(height: 8),
          TextButton(onPressed: _cancel, child: const Text('Cancel')),
        ],
      );
    }

    final secret = type == 'secret';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(pr['message'] as String? ?? '', style: text.bodyMedium),
        const SizedBox(height: 10),
        TextField(
          controller: field,
          autofocus: true,
          obscureText: secret && obscure,
          autocorrect: false,
          enableSuggestions: false,
          style: TextStyle(fontFamily: mono, fontSize: 14, color: p.text),
          onSubmitted: (v) => _answer(v),
          decoration: InputDecoration(
            hintText: pr['placeholder'] as String?,
            suffixIcon: secret
                ? IconButton(
                    icon: Icon(obscure ? LucideIcons.eye : LucideIcons.eyeOff, size: 18),
                    onPressed: () => setState(() => obscure = !obscure),
                  )
                : IconButton(
                    tooltip: 'Paste',
                    icon: const Icon(LucideIcons.clipboardPaste, size: 18),
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null) field.text = data!.text!.trim();
                    },
                  ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(onPressed: _cancel, child: const Text('Cancel')),
            ),
            const SizedBox(width: 8),
            Expanded(
              // Empty answers are valid for optional fields such as a local server's API key.
              child: FilledButton(onPressed: () => _answer(field.text.trim()), child: const Text('Continue')),
            ),
          ],
        ),
      ],
    );
  }
}
