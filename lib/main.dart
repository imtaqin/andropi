import 'package:flutter/material.dart';

import 'agent/agent_client.dart';
import 'agent/agent_controller.dart';
import 'ui/app_lock.dart';
import 'ui/home_shell.dart';
import 'ui/onboarding.dart';
import 'ui/kit.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final agent = AgentController(AgentClient())..boot();
  runApp(AndroPiApp(agent: agent));
}

class AndroPiApp extends StatelessWidget {
  const AndroPiApp({super.key, required this.agent});
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    final appearance = Appearance.instance;
    return ListenableBuilder(
      listenable: appearance,
      builder: (context, _) => MaterialApp(
        title: 'AndroPI',
        debugShowCheckedModeBanner: false,
        themeMode: appearance.value,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(appearance.textScale * MediaQuery.textScalerOf(context).scale(14) / 14),
          ),
          child: AppLockGate(child: child!),
        ),
        home: ListenableBuilder(
          listenable: agent,
          builder: (context, _) => AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: !appearance.onboarded
                ? OnboardingScreen(agent: agent)
                : switch (agent.status) {
                    BootStatus.ready => HomeShell(agent: agent),
                    BootStatus.starting => const _Boot(),
                    BootStatus.failed => _BootFailed(agent: agent),
                  },
          ),
        ),
      ),
    );
  }
}

class _Boot extends StatelessWidget {
  const _Boot();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LogoMark(size: 56),
            const SizedBox(height: 20),
            SizedBox(width: 120, child: LinearProgressIndicator(minHeight: 2, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 14),
            Text('Starting agent', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _BootFailed extends StatelessWidget {
  const _BootFailed({required this.agent});
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 32),
              Text('The agent could not start', style: text.headlineSmall),
              const SizedBox(height: 8),
              Text('Details from the runtime are below.', style: text.bodyMedium?.copyWith(color: p.muted)),
              const SizedBox(height: 20),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: p.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: p.border),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      agent.bootError ?? 'Unknown error',
                      style: TextStyle(fontFamily: mono, fontSize: 12, height: 1.5, color: p.text),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: agent.boot, child: const Text('Try again')),
            ],
          ),
        ),
      ),
    );
  }
}
