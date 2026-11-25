import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/deep_link.dart';
import 'common/in_app_web_page.dart';
import 'detail/status_detail_page.dart';
import 'profile/user_page.dart';
import 'search/search_page.dart';

/// 监听系统传来的深链接（冷启动 + 运行期），翻译成应用内页面。
///
/// 原版通过 `SchemeDispatchActivity` / `HttpDispatchActivity` 做同样的事：
/// `sinaweibo://detail?mblogid=…` 打开正文，`weibo.com/<uid>` 打开主页。
class DeepLinkListener extends ConsumerStatefulWidget {
  final Widget child;

  const DeepLinkListener({super.key, required this.child});

  @override
  ConsumerState<DeepLinkListener> createState() => _DeepLinkListenerState();
}

class _DeepLinkListenerState extends ConsumerState<DeepLinkListener> {
  final AppLinks _links = AppLinks();
  StreamSubscription<Uri>? _subscription;

  /// 部分平台会把冷启动链接在 stream 里再发一次，这里去重。
  String? _lastHandled;
  DateTime _lastHandledAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    try {
      final initial = await _links.getInitialLink();
      if (initial != null) await _handle(initial);
    } catch (_) {
      // 没有链接或平台不支持时静默跳过。
    }
    _subscription = _links.uriLinkStream.listen(
      (uri) => _handle(uri),
      onError: (_) {},
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _handle(Uri uri) async {
    final key = uri.toString();
    final now = DateTime.now();
    if (key == _lastHandled && now.difference(_lastHandledAt).inSeconds < 3) return;
    _lastHandled = key;
    _lastHandledAt = now;

    final target = DeepLinkTarget.parse(uri);
    if (target == null) {
      _openWeb(uri, '链接');
      return;
    }

    final navigator = Navigator.of(context);
    try {
      switch (target.kind) {
        case DeepLinkKind.status:
          final status = await WeiboApi.instance.status(target.value);
          if (!mounted) return;
          navigator.push(MaterialPageRoute(
            builder: (_) => StatusDetailPage(status: status),
          ));
        case DeepLinkKind.user:
          if (!mounted) return;
          navigator.push(MaterialPageRoute(
            builder: (_) => UserPage(uid: target.value),
          ));
        case DeepLinkKind.userName:
          final uid = await WeiboApi.instance.userIdByName(target.keyword);
          if (!mounted) return;
          if (uid == null) {
            _toast('找不到用户「${target.keyword}」');
            return;
          }
          navigator.push(MaterialPageRoute(
            builder: (_) => UserPage(uid: uid, initialName: target.keyword),
          ));
        case DeepLinkKind.search:
          if (!mounted) return;
          navigator.push(MaterialPageRoute(
            builder: (_) => SearchPage(initialKeyword: target.keyword),
          ));
      }
    } catch (e) {
      if (!mounted) return;
      // 打不开就退到内置浏览器，至少不让链接变成死路。
      _toast(_humanize(e));
      _openWeb(uri, '链接');
    }
  }

  void _openWeb(Uri uri, String title) {
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => InAppWebPage(url: uri.toString(), title: title),
    ));
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  String _humanize(Object error) {
    final text = error.toString();
    final marker = text.indexOf('AnyhowException(');
    if (marker >= 0) {
      return text
          .substring(marker + 'AnyhowException('.length)
          .replaceAll(RegExp(r'\)+$'), '')
          .trim();
    }
    return text;
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
