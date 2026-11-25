import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/session.dart';
import '../../core/settings.dart';
import '../../core/settings_spec.dart';
import '../app_theme.dart';
import '../theme/theme_page.dart';
import 'about_page.dart';
import 'accounts_page.dart';
import '../compose/drafts_page.dart';
import 'pref_page.dart';

/// 设置 —— the original `SettingsActivity` hub (g.xml): three categories and
/// eleven entries, in the same order and with the same titles. Every entry now
/// opens a real screen built from `settings_spec.dart`.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);

    final settings = ref.watch(settingsProvider);
    final rows = <Widget>[];
    String? category;
    for (var i = 0; i < settingsRoot.length; i++) {
      final entry = settingsRoot[i];
      if (entry.category != null) {
        category = entry.category;
        rows.add(_section(category!));
      }
      rows.add(_navRow(
        entry.title,
        trailing: _countLabel(entry.route ?? ''),
        onTap: () => _openPage(context, entry.route ?? ''),
      ));
      final lastOfCategory =
          i == settingsRoot.length - 1 || settingsRoot[i + 1].category != null;
      if (lastOfCategory) {
        switch (category) {
          case '显示设置':
            rows.add(_navRow(
              '主题外观',
              trailing: ShareThemePreset.byKey(settings.themeKey).name,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ThemePage()),
              ),
            ));
          case '其他':
            rows.add(_navRow('草稿箱', trailing: '', onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DraftsPage()),
              );
            }));
            rows.add(_navRow('分享', trailing: '', onTap: () => _shareSheet(context)));
        }
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          _accountStrip(context, ref, session),
          ...rows,
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 22, 16, 0),
            child: Text(
              'Share 复刻版 1.5 · 原版 3.9.6 (com.hengye.share)',
              style: TextStyle(fontSize: 11.5, color: ShareColors.textHint),
            ),
          ),
        ],
      ),
    );
  }

  /// Item count read straight from the spec so the hub never drifts.
  String _countLabel(String route) {
    final page = PrefPage.byKey(route);
    if (page == null) return '';
    final n = page.all.where((i) => i.kind != PrefKind.nav).length +
        _extra(route).expand((g) => g.items).length;
    return '$n 项';
  }

  void _openPage(BuildContext context, String route) {
    if (route == 'about') {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const AboutPage()),
      );
      return;
    }
    final page = PrefPage.byKey(route);
    if (page == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PrefPageView(page: page, extra: _extra(page.key), bridges: sharedBridges),
    ));
  }

  /// Rows that are Flutter-port specific and therefore have no counterpart in
  /// `res/xml/g..q.xml`.
  List<PrefGroup> _extra(String pageKey) {
    switch (pageKey) {
      case 'basic':
        return const [
          PrefGroup(title: '复刻版补充', items: [
            PrefItem.toggle('confirm_exit', '退出前确认',
                defaultOn: true, live: true, note: '在首页按返回键时先弹确认框'),
          ]),
        ];
      case 'card':
        return const [
          PrefGroup(title: '复刻版补充', items: [
            PrefItem.toggle('show_source', '显示微博来源', defaultOn: true, live: true),
            PrefItem.toggle('show_verified', '显示认证标识', defaultOn: true, live: true),
          ]),
        ];
      default:
        return const [];
    }
  }

  static final Map<String, PrefBridge> sharedBridges = {
    'confirm_exit': PrefBridge(
      read: (s) => s.confirmBeforeExit,
      write: (n, v) => n.setConfirmBeforeExit(v),
    ),
    'show_source': PrefBridge(
      read: (s) => s.showSource,
      write: (n, v) => n.setShowSource(v),
    ),
    'show_verified': PrefBridge(
      read: (s) => s.showVerified,
      write: (n, v) => n.setShowVerified(v),
    ),
  };

  Widget _accountStrip(BuildContext context, WidgetRef ref, SessionState session) {
    final account = session.account;
    final name = account == null || account.isGuest ? '未登录（访客）' : account.screenName;
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const AccountsPage()),
      ),
      child: Container(
        color: ShareColors.cardBg,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: ShareColors.inputBg,
              backgroundImage: (account != null && account.avatar.isNotEmpty)
                  ? NetworkImage(account.avatar)
                  : null,
              child: (account == null || account.avatar.isEmpty)
                  ? Icon(Icons.person, size: 22, color: ShareColors.textHint)
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text('账号管理 · 多账号切换',
                      style: TextStyle(fontSize: 11.5, color: ShareColors.textSecondary)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: ShareColors.textHint),
          ],
        ),
      ),
    );
  }

  void _shareSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('分享', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Text(
              '原版把 Share 的下载地址分享给好友。复刻版是本地构建，没有发布渠道，'
              '这里展示构建信息方便你记录或贴给朋友。',
              style: TextStyle(fontSize: 13, height: 1.6, color: ShareColors.textSecondary),
            ),
            const SizedBox(height: 14),
            SelectableText(
              'Share 复刻版 1.5 (3.9.6)\nFlutter + Rust · 移动端 + weibo.com/ajax 双协议引擎',
              style: TextStyle(fontSize: 12.5, height: 1.7, color: ShareColors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Text(title, style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary)),
    );
  }

  Widget _navRow(String title, {String? trailing, VoidCallback? onTap}) {
    return ListTile(
      dense: true,
      title: Text(title, style: const TextStyle(fontSize: 15)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailing != null && trailing.isNotEmpty && trailing != '0')
            Text(trailing,
                style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary)),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 18, color: ShareColors.textHint),
          ],
        ],
      ),
      onTap: onTap,
    );
  }
}
