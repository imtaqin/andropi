import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';

import 'theme.dart';

/// Shared building blocks for the AndroPI look.

/// The app mark: the Android-headed π symbol, with no tile behind it.
class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 40, this.glow = true});
  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Image.asset('assets/brand/logo.png', filterQuality: FilterQuality.medium),
  );
}

/// Primary call to action: solid, high-contrast, full width.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, required this.onPressed, this.icon, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = onPressed != null && !busy;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: p.text,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: enabled ? onPressed : null,
          child: SizedBox(
            height: 54,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy)
                  SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: p.inverse))
                else if (icon != null)
                  Icon(icon, size: 18, color: p.inverse),
                if (busy || icon != null) const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(color: p.inverse, fontWeight: FontWeight.w600, fontSize: 15),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A soft grey surface; tappable when [onTap] is set.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.onTap,
    this.highlight = false,
  });
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: highlight ? BorderSide(color: p.text, width: 1.5) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// A rounded square holding an icon, tinted by [color] (or the accent).
class IconTile extends StatelessWidget {
  const IconTile({super.key, required this.icon, this.color, this.size = 36, this.solid = false});
  final IconData icon;
  final Color? color;
  final double size;

  /// Solid tiles use a white glyph on the colour (brand marks); soft ones tint.
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final c = color ?? p.accent;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: solid ? c : c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(size * 0.3),
        border: solid ? null : Border.all(color: c.withValues(alpha: 0.22)),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.5, color: solid ? Colors.white : c),
    );
  }
}

/// Small uppercase label above a group.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.label, {super.key, this.trailing, this.padding = const EdgeInsets.fromLTRB(4, 24, 4, 10)});
  final String label;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Row(
      children: [
        Expanded(child: Text(label.toUpperCase(), style: Theme.of(context).textTheme.labelSmall)),
        ?trailing,
      ],
    ),
  );
}

/// Inset grouped rows, separated by hairlines.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 66, endIndent: 16, color: p.border),
            children[i],
          ],
        ],
      ),
    );
  }
}

class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.icon,
    this.leading,
    this.color,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.destructive = false,
  });
  final String title;
  final IconData? icon;
  final Widget? leading;
  final Color? color;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            leading ?? (icon != null ? IconTile(icon: icon!, color: color, size: 36) : const SizedBox.shrink()),
            if (leading != null || icon != null) const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: text.titleSmall?.copyWith(color: destructive ? p.danger : null)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else if (onTap != null)
              Icon(LucideIcons.chevronRight, size: 18, color: p.faint),
          ],
        ),
      ),
    );
  }
}

/// A compact status pill.
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.color, this.icon, this.dot = false});
  final String label;
  final Color? color;
  final IconData? icon;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final c = color ?? p.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: c.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ] else if (icon != null) ...[
            Icon(icon, size: 12, color: c),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: c),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Brand marks and tool icons

class Brand {
  const Brand(this.icon, this.color);
  final IconData icon;
  final Color color;
}

/// The provider's own mark when Simple Icons has it; a neutral glyph otherwise.
Brand providerBrand(BuildContext context, String id) {
  final p = context.palette;
  final dark = Theme.of(context).brightness == Brightness.dark;
  // Near-black brand colours vanish on the dark theme; lift them to the text colour.
  Color c(Color brand) => dark && brand.computeLuminance() < 0.05 ? p.text : brand;
  final key = id.toLowerCase();
  if (key.contains('anthropic')) return Brand(SimpleIcons.anthropic, c(SimpleIconColors.anthropic));
  if (key.contains('claude')) return Brand(SimpleIcons.claude, c(SimpleIconColors.claude));
  if (key.contains('google') || key.contains('gemini') || key.contains('vertex')) {
    return Brand(SimpleIcons.googlegemini, c(SimpleIconColors.googlegemini));
  }
  if (key.contains('xiaomi') || key.contains('mimo')) return Brand(SimpleIcons.xiaomi, c(SimpleIconColors.xiaomi));
  if (key.contains('deepseek')) return Brand(SimpleIcons.deepseek, c(SimpleIconColors.deepseek));
  if (key.contains('openrouter')) return Brand(SimpleIcons.openrouter, c(SimpleIconColors.openrouter));
  if (key.contains('mistral')) return Brand(SimpleIcons.mistralai, c(SimpleIconColors.mistralai));
  if (key.contains('ollama')) return Brand(SimpleIcons.ollama, c(SimpleIconColors.ollama));
  if (key.contains('hugging')) return Brand(SimpleIcons.huggingface, c(SimpleIconColors.huggingface));
  if (key.contains('nvidia')) return Brand(SimpleIcons.nvidia, c(SimpleIconColors.nvidia));
  if (key.contains('perplexity')) return Brand(SimpleIcons.perplexity, c(SimpleIconColors.perplexity));
  if (key.contains('cloudflare')) return Brand(SimpleIcons.cloudflare, c(SimpleIconColors.cloudflare));
  if (key.contains('meta') || key.contains('llama')) return Brand(SimpleIcons.meta, c(SimpleIconColors.meta));
  if (key == 'xai' || key.contains('grok')) return Brand(SimpleIcons.x, c(SimpleIconColors.x));
  if (key.contains('github')) return Brand(SimpleIcons.github, c(SimpleIconColors.github));
  if (key.contains('vercel')) return Brand(SimpleIcons.vercel, c(SimpleIconColors.vercel));
  if (key.contains('openai') || key.contains('azure') || key.contains('codex')) {
    return Brand(LucideIcons.sparkle, p.text);
  }
  if (key.contains('bedrock') || key.contains('amazon')) return Brand(LucideIcons.cloud, const Color(0xFFFF9900));
  if (key.contains('llama.cpp') || key.contains('local')) return Brand(LucideIcons.cpu, p.muted);
  return Brand(LucideIcons.bot, p.muted);
}

/// Brand mark rendered in a soft tile.
class BrandTile extends StatelessWidget {
  const BrandTile({super.key, required this.id, this.size = 36});
  final String id;
  final double size;

  @override
  Widget build(BuildContext context) {
    final b = providerBrand(context, id);
    return IconTile(icon: b.icon, color: b.color, size: size);
  }
}

IconData toolIcon(String? name) => switch (name) {
  'bash' => LucideIcons.squareTerminal,
  'read' => LucideIcons.fileText,
  'write' => LucideIcons.filePlus2,
  'edit' => LucideIcons.filePen,
  'grep' => LucideIcons.textSearch,
  'find' || 'ls' => LucideIcons.folderSearch,
  'web_search' => LucideIcons.search,
  'web_fetch' => LucideIcons.globe,
  _ => LucideIcons.wrench,
};
