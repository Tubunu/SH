import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/api.dart';
import '../../core/settings.dart';
import '../app_theme.dart';

/// A thin in-app browser that reuses the session the native layer already
/// holds, so pages that require the signed-in account work without a second
/// login.
///
/// Used as a guaranteed-working escape hatch for features whose native API a
/// visitor session cannot reach (currently 私信).
class InAppWebPage extends ConsumerStatefulWidget {
  final String url;
  final String title;

  const InAppWebPage({super.key, required this.url, required this.title});

  @override
  ConsumerState<InAppWebPage> createState() => _InAppWebPageState();
}

class _InAppWebPageState extends ConsumerState<InAppWebPage> {
  late final WebViewController _controller;
  final WebViewCookieManager _cookies = WebViewCookieManager();

  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(ShareColors.cardBg)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          _injectNightMode();
          if (mounted) setState(() => _ready = true);
        },
        onWebResourceError: (e) {
          if (e.isForMainFrame == true && mounted) {
            setState(() => _error = '页面加载失败：${e.description}');
          }
        },
      ));
    _bootstrap();
  }

  /// 强制内置浏览器跟随应用开启夜间模式 — inverts the page when the app is in a
  /// dark theme, so official pages stop flashing white.
  Future<void> _injectNightMode() async {
    if (!mounted) return;
    final settings = ref.read(settingsProvider);
    final dark = ShareThemePreset.byKey(settings.themeKey).dark;
    if (!dark || !settings.webviewNight) return;
    await _controller.runJavaScript('''
      (function() {
        if (document.getElementById('__share_night')) return;
        var style = document.createElement('style');
        style.id = '__share_night';
        style.innerHTML = 'html{filter:invert(1) hue-rotate(180deg);background:#000}'
          + 'img,video,canvas,svg{filter:invert(1) hue-rotate(180deg)}';
        document.documentElement.appendChild(style);
      })();
    ''');
  }

  Future<void> _bootstrap() async {
    try {
      final header = await WeiboApi.instance.activeCookie();
      if (header.isNotEmpty) {
        for (final pair in header.split(';')) {
          final index = pair.indexOf('=');
          if (index <= 0) continue;
          final name = pair.substring(0, index).trim();
          final value = pair.substring(index + 1).trim();
          if (name.isEmpty || value.isEmpty) continue;
          for (final domain in const ['.weibo.com', '.weibo.cn']) {
            try {
              await _cookies.setCookie(WebViewCookie(
                name: name,
                value: value,
                domain: domain,
                path: '/',
              ));
            } catch (_) {
              // Some WebView implementations reject certain domains; the
              // others still apply.
            }
          }
        }
      }
    } catch (_) {
      // Cookie seeding is best effort — the page may still work anonymously.
    }
    await _controller.loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          if (_error != null)
            Container(
              width: double.infinity,
              color: ShareColors.accent.withValues(alpha: 0.10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Text(
                _error!,
                style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary),
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                WebViewWidget(controller: _controller),
                if (!_ready)
                  const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
