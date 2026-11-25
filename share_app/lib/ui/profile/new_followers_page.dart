import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../app_theme.dart';
import 'user_page.dart';

/// 新增粉丝 —— 原版 `MyFollowersActivity`（`relate=fans&newFollowerCount=`）。
///
/// 接口返回的是**纯数组**（`List<User>`），没有 `has_more` 之类的标志位，
/// 所以到底与否只能靠「本页返回条数是否满 count」来判断：不满即为最后一页。
class NewFollowersPage extends StatefulWidget {
  final String uid;

  const NewFollowersPage({super.key, required this.uid});

  @override
  State<NewFollowersPage> createState() => _NewFollowersPageState();
}

class _NewFollowersPageState extends State<NewFollowersPage> {
  /// 每页条数。既用于请求，也用于「本页是否已满」的判定，两处必须是同一个值。
  static const int _count = 20;

  final List<User> _users = [];
  final Set<String> _following = {};
  final Set<String> _busy = {};
  final ScrollController _scroll = ScrollController();

  int _page = 1;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 320) {
        _loadMore();
      }
    });
    _loadFirst();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadFirst() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await WeiboApi.instance.newFollowers(widget.uid, page: 1, count: _count);
      if (!mounted) return;
      setState(() {
        _users
          ..clear()
          ..addAll(list);
        _following
          ..clear()
          ..addAll(list.where((u) => u.following).map((u) => u.id));
        _page = 1;
        _hasMore = list.length >= _count;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _humanize(e);
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final list = await WeiboApi.instance
          .newFollowers(widget.uid, page: _page + 1, count: _count);
      if (!mounted) return;
      setState(() {
        _page += 1;
        _users.addAll(list.where((u) => !_users.any((e) => e.id == u.id)));
        // 服务端给了 following 就采信它；没给（false）时保留本地已关注状态，
        // 否则翻一页回来会把刚点过的「已关注」又变成「关注」。
        for (final u in list) {
          if (u.following) _following.add(u.id);
        }
        _hasMore = list.length >= _count;
        _loadingMore = false;
      });
    } catch (_) {
      // 翻页失败不当作「到底」，用户再滑一次会重试。
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// 乐观更新：先改本地状态再发请求，失败回滚并把服务端原话抛出来。
  Future<void> _toggleFollow(User user) async {
    if (_busy.contains(user.id)) return;
    final wasFollowing = _following.contains(user.id);
    setState(() {
      _busy.add(user.id);
      if (wasFollowing) {
        _following.remove(user.id);
      } else {
        _following.add(user.id);
      }
    });
    try {
      await WeiboApi.instance.follow(user.id, wasFollowing);
      if (!mounted) return;
      setState(() => _busy.remove(user.id));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy.remove(user.id);
        if (wasFollowing) {
          _following.add(user.id);
        } else {
          _following.remove(user.id);
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_humanize(e))),
      );
    }
  }

  void _openUser(User user) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => UserPage(
        uid: user.id,
        initialName: user.name,
        initialAvatar: user.avatar,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('新增粉丝')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _users.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null && _users.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.people_outline, size: 40, color: ShareColors.textHint),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.5, color: ShareColors.textSecondary),
              ),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _loadFirst, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_users.isEmpty) {
      return Center(
        child: Text(
          '还没有新的粉丝',
          style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
        ),
      );
    }

    return RefreshIndicator(
      color: ShareColors.accent,
      onRefresh: _loadFirst,
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _users.length + 1,
        itemBuilder: (context, index) {
          if (index == _users.length) return _footer();
          return _row(_users[index], first: index == 0);
        },
      ),
    );
  }

  Widget _footer() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Center(
        child: _loadingMore
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              )
            : Text(
                _hasMore ? '上拉加载更多' : '没有更多了',
                style: TextStyle(fontSize: 11.5, color: ShareColors.textHint),
              ),
      ),
    );
  }

  Widget _row(User user, {required bool first}) {
    return Container(
      color: ShareColors.cardBg,
      child: Column(
        children: [
          if (!first) Container(height: 1, color: ShareColors.divider),
          InkWell(
            onTap: () => _openUser(user),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  ClipOval(
                    child: SizedBox(
                      width: 36,
                      height: 36,
                      child: user.avatar.isEmpty
                          ? ColoredBox(color: ShareColors.placeholder)
                          : Image.network(
                              user.avatar,
                              fit: BoxFit.cover,
                              cacheWidth: 108,
                              errorBuilder: (_, _, _) => ColoredBox(
                                color: ShareColors.placeholder,
                                child:
                                    Icon(Icons.person, size: 18, color: ShareColors.textHint),
                              ),
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
                            Flexible(
                              child: Text(
                                user.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
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
                        // 简介为空时整行不占位，行高跟着内容走。
                        if (user.description.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            user.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: ShareColors.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  _followButton(user),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _followButton(User user) {
    final followed = _following.contains(user.id);
    final busy = _busy.contains(user.id);
    return SizedBox(
      height: 28,
      child: TextButton(
        onPressed: busy ? null : () => _toggleFollow(user),
        style: TextButton.styleFrom(
          backgroundColor: followed ? ShareColors.cardBg : ShareColors.accent,
          foregroundColor: followed ? ShareColors.textSecondary : Colors.white,
          disabledForegroundColor: ShareColors.textHint,
          side: BorderSide(
            color: followed ? ShareColors.line : ShareColors.accent,
            width: 0.8,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Text(followed ? '已关注' : '关注', style: const TextStyle(fontSize: 13)),
      ),
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
}
