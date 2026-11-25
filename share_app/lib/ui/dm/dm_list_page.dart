import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/dm.dart';
import '../../core/session.dart';
import '../app_theme.dart';
import '../common/in_app_web_page.dart';
import '../login/login_page.dart';
import 'dm_chat_page.dart';

/// 私信会话列表 — the original `DirectMessageUsersActivity`.
class DmListPage extends ConsumerStatefulWidget {
  const DmListPage({super.key});

  @override
  ConsumerState<DmListPage> createState() => _DmListPageState();
}

class _DmListPageState extends ConsumerState<DmListPage> {
  List<DmConversation> _items = const [];
  bool _loading = true;
  String? _error;

  /// 私信没有推送通道（WeSync 未接入），会话列表靠 60s 静默轮询跟上新消息。
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 60), (_) => _tick());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    // 被聊天页等路由盖住时不算可见，这一轮跳过，避免后台白拉接口。
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    _load(silent: true);
  }

  Future<void> _load({bool silent = false}) async {
    // 访客态 `/webim/2/*` 只会回 21301，干脆不发请求。
    if (!ref.read(sessionProvider).isLoggedIn) {
      if (mounted && _loading) setState(() => _loading = false);
      return;
    }
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final list = await WeiboApi.instance.dmConversations();
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // 静默刷新失败时保留已有列表；没有内容可保住时把服务端原话摆出来。
        if (!silent || _items.isEmpty) _error = _humanize(e);
      });
    }
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

  Future<void> _open(DmConversation conversation) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DmChatPage(
          uid: conversation.uid,
          peerName: conversation.name,
          peerAvatar: conversation.avatar,
        ),
      ),
    );
    if (mounted) _load(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = ref.watch(sessionProvider).isLoggedIn;

    return Scaffold(
      appBar: AppBar(title: const Text('私信')),
      body: RefreshIndicator(
        color: ShareColors.accent,
        onRefresh: () => _load(),
        child: _body(loggedIn),
      ),
    );
  }

  Widget _body(bool loggedIn) {
    if (!loggedIn) {
      return _messageState(
        icon: Icons.lock_outline,
        text: '私信需要登录后使用。\n登录后可在此查看全部会话。',
      );
    }
    if (_loading) {
      return const Center(
        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null) {
      return _messageState(
        icon: Icons.cloud_off,
        text: '$_error\n\n若使用手机号短信登录，部分私信接口需要补充网页授权或直接在网页版私信中查看。',
        action: Column(
          children: [
            TextButton(onPressed: () => _load(), child: const Text('重试')),
            TextButton(
              onPressed: () async {
                final ok = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(builder: (_) => const LoginPage()),
                );
                if (ok == true && mounted) _load();
              },
              child: const Text('补充网页授权 / 重新登录'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const InAppWebPage(
                    url: 'https://api.weibo.com/chat',
                    title: '私信',
                  ),
                ),
              ),
              child: const Text('在网页版私信中打开'),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return _messageState(icon: Icons.forum_outlined, text: '还没有私信会话');
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _items.length,
      separatorBuilder: (_, _) => Container(
        height: 0.6,
        color: ShareColors.divider,
        margin: const EdgeInsets.only(left: 70),
      ),
      itemBuilder: (context, index) {
        final item = _items[index];
        return InkWell(
          onTap: () => _open(item),
          child: Container(
            color: ShareColors.cardBg,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: item.avatar.isNotEmpty
                        ? Image.network(
                            item.avatar,
                            fit: BoxFit.cover,
                            cacheWidth: 140,
                            errorBuilder: (_, _, _) => ColoredBox(
                              color: ShareColors.placeholder,
                              child: Icon(Icons.person, color: ShareColors.textHint),
                            ),
                          )
                        : ColoredBox(
                            color: ShareColors.placeholder,
                            child: Icon(Icons.person, color: ShareColors.textHint),
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              item.name.isEmpty ? item.uid : item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: ShareColors.textPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            formatDmTime(item.timeMs),
                            style: TextStyle(fontSize: 11, color: ShareColors.textHint),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              item.preview.isEmpty ? '[暂无消息]' : item.preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: ShareColors.textSecondary),
                            ),
                          ),
                          if (item.unread > 0) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              constraints: const BoxConstraints(minWidth: 17),
                              decoration: BoxDecoration(
                                color: ShareColors.accent,
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Text(
                                item.unread > 99 ? '99+' : '${item.unread}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 10, color: Colors.white),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _messageState({required IconData icon, required String text, Widget? action}) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 100),
        Icon(icon, size: 44, color: ShareColors.textHint),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: ShareColors.textSecondary, height: 1.5),
          ),
        ),
        if (action != null) Center(child: action),
      ],
    );
  }
}
