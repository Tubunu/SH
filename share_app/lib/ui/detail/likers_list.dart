import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/settings.dart';
import '../app_theme.dart';
import '../profile/user_page.dart';

/// 详情页「赞」Tab —— 原版这一栏只列点赞的人，不重复渲染微博卡片。
///
/// [headSlivers] 是详情页共用头部（正文卡片 + 吸顶 Tab 栏），挂在列表最前面，
/// 这样三个 Tab 都能把头部滚上去，只留 Tab 栏贴住 AppBar 下沿。
class LikersList extends ConsumerStatefulWidget {
  final String statusId;
  final List<Widget> headSlivers;

  const LikersList({
    super.key,
    required this.statusId,
    this.headSlivers = const [],
  });

  @override
  ConsumerState<LikersList> createState() => _LikersListState();
}

class _LikersListState extends ConsumerState<LikersList> {
  final List<User> _users = [];
  final ScrollController _scroll = ScrollController();

  /// uid -> 是否已关注。接口返回体不保证带 `following`，本地留一份覆盖值，
  /// 这样翻页回来同一行不会闪回「关注」。
  final Map<String, bool> _following = {};
  final Set<String> _busy = {};

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void didUpdateWidget(covariant LikersList old) {
    super.didUpdateWidget(old);
    if (widget.statusId != old.statusId) {
      _load(reset: true);
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) {
      _load();
    }
  }

  Future<void> _load({bool reset = false}) async {
    // 上一页失败后先停下，等用户点「重试」，否则滚动会反复打同一个失败请求。
    if (!reset && (_loading || _loadingMore || !_hasMore || _error != null)) return;
    if (reset) {
      setState(() {
        _loading = true;
        _loadingMore = false;
        _error = null;
        _hasMore = true;
        _page = 1;
        _users.clear();
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final users = await WeiboApi.instance.statusLikers(widget.statusId, page: _page);
      if (!mounted) return;
      setState(() {
        _users.addAll(users);
        for (final user in users) {
          _following.putIfAbsent(user.id, () => user.following);
        }
        // 接口不返回总数，只能按「这页是否装满」判断还有没有下一页。
        _hasMore = users.length >= 20;
        _page += 1;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = _humanize(e);
      });
    }
  }

  Future<void> _toggleFollow(User user, bool following) async {
    if (_busy.contains(user.id)) return;
    if (!ref.read(sessionProvider).isLoggedIn) {
      _toast('请先登录后再关注');
      return;
    }
    // 先改本地再发请求：原版点下去按钮立刻变，失败才回滚。
    setState(() {
      _busy.add(user.id);
      _following[user.id] = !following;
    });
    try {
      await WeiboApi.instance.follow(user.id, following);
      if (!mounted) return;
      setState(() => _busy.remove(user.id));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy.remove(user.id);
        _following[user.id] = following;
      });
      _toast(_humanize(e));
    }
  }

  void _toast(String message) {
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

  void _openUser(User user) {
    if (user.id.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserPage(
          uid: user.id,
          initialName: user.name,
          initialAvatar: user.avatar,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      controller: _scroll,
      slivers: [...widget.headSlivers, ..._contentSlivers()],
    );
  }

  List<Widget> _contentSlivers() {
    if (_loading) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 30),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        ),
      ];
    }
    if (_error != null && _users.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            child: Column(
              children: [
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => _load(reset: true),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ];
    }
    if (_users.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: Text(
                '还没有人赞',
                style: TextStyle(fontSize: 13, color: ShareColors.textHint),
              ),
            ),
          ),
        ),
      ];
    }

    return [
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            if (index.isOdd) {
              return Divider(
                height: 1,
                thickness: 1,
                indent: 62,
                color: ShareColors.divider,
              );
            }
            return _userRow(_users[index ~/ 2]);
          },
          childCount: _users.length * 2 - 1,
        ),
      ),
      SliverToBoxAdapter(child: _footer()),
    ];
  }

  Widget _footer() {
    if (_error != null) {
      // 已有内容时翻页失败只占页脚，不清空已经看到的人。
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          children: [
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: ShareColors.textSecondary),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => _load(reset: true),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Center(
        child: _loadingMore
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 1.8),
              )
            : Text(
                _hasMore ? '' : '没有更多了',
                style: TextStyle(fontSize: 12, color: ShareColors.textHint),
              ),
      ),
    );
  }

  Widget _userRow(User user) {
    final following = _following[user.id] ?? user.following;
    final busy = _busy.contains(user.id);
    final hideAvatar = ref.watch(settingsProvider).hideCommentAvatar;
    // 认证说明优先；没有认证就退到简介，两者都空就不占第二行。
    final subtitle = user.verifiedReason.isNotEmpty
        ? user.verifiedReason
        : user.description;

    return InkWell(
      onTap: () => _openUser(user),
      child: Container(
        color: ShareColors.cardBg,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          children: [
            if (!hideAvatar) ...[
              ClipOval(
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: user.avatar.isEmpty
                      ? _avatarFallback()
                      : Image.network(
                          user.avatar,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _avatarFallback(),
                        ),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          user.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: ShareColors.textPrimary,
                          ),
                        ),
                      ),
                      if (user.verified) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.verified, size: 13, color: ShareColors.accent),
                      ],
                    ],
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: ShareColors.textSecondary),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            _followButton(user, following, busy),
          ],
        ),
      ),
    );
  }

  Widget _followButton(User user, bool following, bool busy) {
    return GestureDetector(
      onTap: busy ? null : () => _toggleFollow(user, following),
      child: Container(
        width: 58,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: following ? Colors.transparent : ShareColors.accent,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: following ? ShareColors.divider : ShareColors.accent,
          ),
        ),
        child: Text(
          following ? '已关注' : '关注',
          style: TextStyle(
            fontSize: 12,
            color: following ? ShareColors.textSecondary : Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _avatarFallback() {
    return ColoredBox(
      color: ShareColors.placeholder,
      child: Icon(Icons.person, size: 20, color: ShareColors.textHint),
    );
  }
}
