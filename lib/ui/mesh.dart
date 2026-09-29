import 'package:flutter/material.dart';

import 'theme.dart';

/// A flat pastel tile for cards and thumbnails. The same [seed] always
/// gives the same colour.
class MeshArt extends StatelessWidget {
  const MeshArt({super.key, required this.seed, this.radius = 20, this.child});
  final String seed;
  final double radius;
  final Widget? child;

  static const _palettes = <List<Color>>[
    [Color(0xFFFFD8C2)], // peach
    [Color(0xFFFFC9DE)], // pink
    [Color(0xFFD9D2FF)], // lavender
    [Color(0xFFC6EFEA)], // mint
    [Color(0xFFDDF4B8)], // lime
    [Color(0xFFFFE8A8)], // butter
    [Color(0xFFCDE4FF)], // sky
    [Color(0xFFF3D9FF)], // lilac
  ];

  static List<Color> colorsFor(String seed) => _palettes[_hash(seed) % _palettes.length];

  static int _hash(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h;
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ColoredBox(
        color: colorsFor(seed)[0],
        child: child == null ? const SizedBox.expand() : Stack(fit: StackFit.passthrough, children: [child!]),
      ),
    );
  }
}

/// Coloured icon badge with a ring in the background colour, meant to overlap
/// the edge of a [MeshArt] image.
class RingBadge extends StatelessWidget {
  const RingBadge({super.key, required this.icon, required this.color, this.size = 40});
  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(size * 0.34),
        border: Border.all(color: p.surface, width: 3),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.45, color: Colors.white),
    );
  }
}

/// A round avatar: a photo when available, else initials on mesh art.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.url, this.size = 40});
  final String name;
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initials = name.trim().isEmpty
        ? '?'
        : name.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0].toUpperCase()).join();
    return SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: url != null
            ? Image.network(url!, fit: BoxFit.cover, errorBuilder: (_, _, _) => _initials(initials))
            : _initials(initials),
      ),
    );
  }

  Widget _initials(String text) => MeshArt(
    seed: name,
    radius: size,
    child: Center(
      child: Text(
        text,
        style: TextStyle(fontSize: size * 0.38, fontWeight: FontWeight.w700, color: Colors.white),
      ),
    ),
  );
}
