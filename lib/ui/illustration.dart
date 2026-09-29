import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'theme.dart';

/// Storyset illustrations (https://storyset.com, free with attribution),
/// recoloured from their default blue to the app accent.
class Illustration extends StatelessWidget {
  const Illustration(this.name, {super.key, this.height = 220});
  final String name;
  final double height;

  static const _storysetBlue = '#407bff';
  static final _cache = <String, Future<String>>{};

  static String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  Future<String> _load(Color accent) {
    final key = '$name/${accent.toARGB32()}';
    return _cache[key] ??= rootBundle
        .loadString('assets/illustrations/$name.svg')
        .then((svg) => svg.replaceAll(RegExp(_storysetBlue, caseSensitive: false), _hex(accent)));
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.accent;
    return SizedBox(
      height: height,
      child: FutureBuilder<String>(
        future: _load(accent),
        builder: (context, snap) =>
            snap.hasData ? SvgPicture.string(snap.data!, height: height, fit: BoxFit.contain) : const SizedBox.shrink(),
      ),
    );
  }
}

/// The credit Storyset's licence asks for.
class StorysetCredit extends StatelessWidget {
  const StorysetCredit({super.key, required this.openUrl});
  final Future<void> Function(String url) openUrl;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      onTap: () => openUrl('https://storyset.com'),
      child: Text.rich(
        TextSpan(
          style: TextStyle(fontSize: 11, color: p.faint),
          children: [
            const TextSpan(text: 'Illustrations by '),
            TextSpan(
              text: 'Storyset',
              style: TextStyle(color: p.muted, decoration: TextDecoration.underline, decorationColor: p.faint),
            ),
          ],
        ),
      ),
    );
  }
}
