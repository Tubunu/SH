import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/settings.dart';
import '../../core/notice.dart';
import '../../core/session.dart';
import '../app_theme.dart';
import '../dm/dm_list_page.dart';
import 'notice_page.dart';

/// 消息 tab — the hub the original app exposed through its drawer
/// (`通知` → `StatusNotifyActivity`, `私信` → `DirectMessageUsersActivity`).
///
/// Badges come from `/ajax/message/unreadHint`; when the server reports nothing
/// we simply show no number instead of inventing one.
class MessagePage extends ConsumerStatefulWidget {
  const MessagePage({super.key});

  @override
  ConsumerState<MessagePage> createState() => _MessagePageState();
}

class _MessagePageState extends ConsumerState<MessagePage> {
  UnreadHint _hint = const UnreadHint();
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadUnread());
  }

  Future<void> _loadUnread() async {
    if (!ref.read(sessionProvider).isLoggedIn) return;
    setState(() => _loading = true);
    try {
      final hint = await WeiboApi.instance.unreadHint();
      if (!mounted) return;
      setState(() {
        _hint = hint;
        _loading = false;
      });
    } catch (_) {
      // Badges are decorative: a failure must not break the hub.
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted) _loadUnread();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final loggedIn = session.isLoggedIn;

    return Scaffold(
      appBar: AppBar(
        title: const Text('消息'),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(right: 14),
              child: Center(
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
              ),
            ),
        ],
      ),
      body: RefreshIndicator(
        color: ShareColors.accent,
        onRefresh: _loadUnread,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (!loggedIn) _guestBanner(),
            const SizedBox(height: 8),
            _group([
              _entry(
                icon: Icons.chat_bubble_outline,
                title: '私信',
                subtitle: '与好友的一对一会话',
                badge: _hint.dm,
                onTap: () => _open(const DmListPage()),
              ),
            ]),
            const SizedBox(height: 10),
            _group([
              // 原版 `StatusNotifyActivity` 是一个页面四类 Tab，这里不再拆成四个入口。
              _entry(
                icon: Icons.alternate_email,
                title: '互动消息',
                subtitle: '@我微博 / @我评论 / 收到的评论 / 收到的赞',
                badge: _noticeTotal(),
                onTap: () => _open(const NoticePage()),
              ),
            ]),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _guestBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ShareColors.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: ShareColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '当前是访客身份，只有部分通知可见，登录后数据完整。',
              style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  /// 四个分类里被设置允许显示数字的那部分之和。
  int _noticeTotal() {
    var sum = 0;
    for (final kind in NoticeKind.values) {
      sum += _redDot(kind, _hint.countFor(kind));
    }
    return sum;
  }

  /// 数字红点提醒类型 (remind_unread_type): 1 评论 / 2 @我 / 3 点赞.
  /// A kind that is switched off still lists its items — only the number goes.
  int _redDot(NoticeKind kind, int raw) {
    final types = ref.read(settingsProvider).redDotTypes;
    final need = switch (kind) {
      NoticeKind.comment => 1,
      NoticeKind.atWeibo || NoticeKind.atComment => 2,
      NoticeKind.like => 3,
    };
    return types.contains(need) ? raw : 0;
  }

  Widget _group(List<Widget> rows) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) {
        children.add(Divider(
          height: 0.6,
          thickness: 0.6,
          indent: 52,
          color: ShareColors.divider,
        ));
      }
      children.add(rows[i]);
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ShareColors.cardBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: ShareColors.divider.withValues(alpha: 0.7),
          width: 0.5,
        ),
      ),
      child: Column(children: children),
    );
  }

  Widget _entry({
    required IconData icon,
    required String title,
    required String subtitle,
    required int badge,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: ShareColors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 17, color: ShareColors.accent),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 15,
                          color: ShareColors.textPrimary,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(fontSize: 11.5, color: ShareColors.textHint)),
                ],
              ),
            ),
            if (badge > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                constraints: const BoxConstraints(minWidth: 18),
                decoration: BoxDecoration(
                  color: ShareColors.accent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  badge > 99 ? '99+' : '$badge',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 10.5, color: Colors.white),
                ),
              ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 18, color: ShareColors.textHint),
          ],
        ),
      ),
    );
  }
}
