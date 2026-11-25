import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/settings.dart';
import '../../core/share_core.dart';
import '../../core/stopic.dart';
import '../profile/user_page.dart';
import '../search/search_page.dart';
import '../stopic/stopic_detail_page.dart';
import 'in_app_web_page.dart';

/// Opens whatever a rich-text segment points at, handling:
/// - `#超话名[超话]#` -> Super Topic detail
/// - `#topic#` -> search
/// - `@mention` -> UserPage
/// - `http(s)://...` -> expands `t.cn/` short links via Rust mobile engine when
///   `browser_https` is enabled, then opens in-app browser
Future<void> openRichSegment(
  BuildContext context,
  RichSegment segment, {
  AppSettings? settings,
}) async {
  switch (segment.kind) {
    case RichKind.topic:
      final raw = segment.text.replaceAll('#', '').trim();
      if (raw.isEmpty) return;
      if (raw.endsWith('[超话]')) {
        final name = raw.substring(0, raw.length - 4).trim();
        if (name.isNotEmpty) {
          _push(
            context,
            StopicDetailPage(
              stopic: Stopic(pageId: name, title: name),
            ),
          );
          return;
        }
      }
      _push(context, SearchPage(initialKeyword: raw));

    case RichKind.mention:
      final name = segment.text.replaceAll('@', '').trim();
      if (name.isEmpty) return;
      final messenger = ScaffoldMessenger.of(context);
      final navigator = Navigator.of(context);
      String? uid;
      try {
        uid = await WeiboApi.instance.userIdByName(name);
      } catch (_) {
        uid = null;
      }
      if (uid == null || uid.isEmpty) {
        messenger.showSnackBar(SnackBar(content: Text('没有找到 @$name')));
        return;
      }
      navigator.push(
        MaterialPageRoute(
          builder: (_) => UserPage(uid: uid!, initialName: name),
        ),
      );

    case RichKind.link:
      final rawUrl = _absolute(segment.href ?? segment.text);
      if (rawUrl == null) return;
      var targetUrl = rawUrl;
      if ((settings?.browserHttps ?? true) && rawUrl.contains('t.cn/')) {
        try {
          final expanded = await ShareCore.instance.shortUrlExpand(rawUrl);
          final list = expanded['urls'];
          if (list is List && list.isNotEmpty && list.first is Map) {
            final longUrl = '${list.first['url_long'] ?? ''}'.trim();
            if (longUrl.startsWith('http')) targetUrl = longUrl;
          }
        } catch (_) {}
      }
      if (!context.mounted) return;
      _push(context, InAppWebPage(url: targetUrl, title: segment.text));

    case RichKind.emoji:
    case RichKind.text:
      break;
  }
}

void _push(BuildContext context, Widget page) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
}

void openUserProfile(BuildContext context, User? user) {
  if (user == null || user.id.isEmpty) return;
  _push(
    context,
    UserPage(uid: user.id, initialName: user.name, initialAvatar: user.avatar),
  );
}

String? _absolute(String? href) {
  final raw = href?.trim() ?? '';
  if (raw.isEmpty) return null;
  if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
  if (raw.startsWith('//')) return 'https:$raw';
  if (raw.startsWith('/')) return 'https://weibo.com$raw';
  return 'https://$raw';
}
