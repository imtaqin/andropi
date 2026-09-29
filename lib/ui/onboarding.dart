import 'package:flutter/material.dart';

import '../agent/agent_controller.dart';
import 'kit.dart';
import 'illustration.dart';
import 'theme.dart';

/// First-run welcome: what AndroPI is, then straight to connecting a model.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final pages = PageController();
  int page = 0;

  static const _slides = [
    ('ai', 'Boost your\nproductivity', 'Chat with a coding agent that runs right on your phone.'),
    ('linux', 'Real Linux,\nin your pocket', 'Install Python, Node and more with apt. No root needed.'),
    ('search', 'Search, build\nand preview', 'pi looks things up on the web and shows your pages live.'),
    ('launch', 'Ship it\nanywhere', 'Deploy to Vercel, GitHub Pages or your own server.'),
  ];

  // Home takes over from here and offers to connect a model if none is set.
  void _start() => Appearance.instance.finishOnboarding();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final last = page == _slides.length - 1;
    return Scaffold(
      body: Stack(
        children: [
          // Soft colour washes behind everything, like the cards' mesh art.
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Row(
                    children: [
                      Material(
                        color: p.surface,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: _start,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                            child: Text('Skip', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                          ),
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: pages,
                    itemCount: _slides.length,
                    onPageChanged: (i) => setState(() => page = i),
                    itemBuilder: (context, i) {
                      final (art, title, body) = _slides[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _Hero(illustration: art),
                            const SizedBox(height: 40),
                            Text(title, textAlign: TextAlign.center, style: text.displayMedium),
                            const SizedBox(height: 14),
                            Text(
                              body,
                              textAlign: TextAlign.center,
                              style: text.bodyLarge?.copyWith(color: p.muted),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < _slides.length; i++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i == page ? const Color(0xFF3E63DD) : Colors.transparent,
                          border: Border.all(color: i == page ? const Color(0xFF3E63DD) : p.faint, width: 1.5),
                        ),
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 10),
                  child: PrimaryButton(
                    label: last ? 'Get started' : 'Next',
                    onPressed: last
                        ? _start
                        : () => pages.nextPage(duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: StorysetCredit(openUrl: widget.agent.client.openUrl),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.illustration});
  final String illustration;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SizedBox(
      width: 300,
      height: 280,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // A soft blob behind the scene.
          Container(
            width: 270,
            height: 250,
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: 0.12),
              borderRadius: const BorderRadius.all(Radius.elliptical(150, 125)),
            ),
          ),
          Illustration(illustration, height: 270),
          const Positioned(left: 4, top: 60, child: _Dot(color: Color(0xFF3E63DD), size: 14)),
          const Positioned(right: 2, top: 30, child: _Dot(color: Color(0xFFFF8C42), size: 8)),
          const Positioned(right: 10, bottom: 80, child: _Dot(color: Color(0xFF30A46C), size: 12)),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.size});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
