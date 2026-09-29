import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'theme.dart';

/// Renders HTML in a WebView. With [live], it re-renders as the source grows,
/// so a page the agent is still writing builds up in front of the user.
class HtmlPreviewScreen extends StatefulWidget {
  const HtmlPreviewScreen({super.key, required this.title, required this.source, this.baseDir, this.live, this.url});

  /// A running server to show instead of HTML source (dev servers on localhost).
  final String? url;

  /// Opens a live URL, e.g. a dev server the agent started.
  static Future<void> openUrl(BuildContext context, {required String title, required String url}) =>
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => HtmlPreviewScreen(title: title, source: () => '', url: url),
        ),
      );

  final String title;
  final String Function() source;

  /// Directory relative links (css, js, images) resolve against.
  final String? baseDir;
  final Listenable? live;

  static Future<void> open(
    BuildContext context, {
    required String title,
    required String Function() source,
    String? baseDir,
    Listenable? live,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HtmlPreviewScreen(title: title, source: source, baseDir: baseDir, live: live),
      ),
    );
  }

  @override
  State<HtmlPreviewScreen> createState() => _HtmlPreviewScreenState();
}

class _HtmlPreviewScreenState extends State<HtmlPreviewScreen> {
  late final WebViewController controller;
  String? loaded;
  Timer? debounce;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => loading = true),
          onPageFinished: (_) => setState(() => loading = false),
        ),
      );
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      // Lets pages the agent wrote load their sibling css/js/images.
      platform.setAllowFileAccess(true);
    }
    widget.live?.addListener(_onSourceChanged);
    _reload();
  }

  @override
  void dispose() {
    widget.live?.removeListener(_onSourceChanged);
    debounce?.cancel();
    super.dispose();
  }

  void _onSourceChanged() {
    if (debounce?.isActive ?? false) return;
    debounce = Timer(const Duration(milliseconds: 400), _reload);
  }

  void _reload({bool force = false}) {
    if (widget.url != null) {
      controller.loadRequest(Uri.parse(widget.url!));
      return;
    }
    if (!mounted) return;
    final html = widget.source();
    if (!force && html == loaded) return;
    loaded = html;
    final base = widget.baseDir == null ? null : Uri.directory(widget.baseDir!).toString();
    controller.loadHtmlString(html, baseUrl: base);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Flexible(child: Text(widget.title, overflow: TextOverflow.ellipsis)),
            if (widget.live != null) ...[
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: p.success.withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(color: p.success, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 5),
                    Text('Live', style: TextStyle(fontSize: 11, color: p.success)),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(LucideIcons.refreshCw, size: 20),
            onPressed: () => _reload(force: true),
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: loading
              ? LinearProgressIndicator(minHeight: 2, color: p.muted, backgroundColor: p.border)
              : Divider(height: 2, thickness: 1, color: p.border),
        ),
      ),
      // Hybrid composition lets Android draw the WebView itself. The default
      // texture mode copies every frame into Flutter, which for animated pages
      // means a buffer lock (and a "lockHardwareCanvas" log line) per frame.
      body: controller.platform is AndroidWebViewController
          ? WebViewWidget.fromPlatformCreationParams(
              params: AndroidWebViewWidgetCreationParams(
                controller: controller.platform as AndroidWebViewController,
                displayWithHybridComposition: true,
              ),
            )
          : WebViewWidget(controller: controller),
    );
  }
}
