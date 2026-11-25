import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/settings.dart';
import '../../core/share_core.dart';
import '../app_theme.dart';
import '../detail/status_detail_page.dart';
import '../dm/dm_chat_page.dart';
import '../feed/status_card.dart';
import '../media/gallery_page.dart';
import '../media/video_page.dart';
import 'profile_search_page.dart';
import 'social_manage_page.dart';

/// 个人主页 — the original `PersonalHomepageActivity`.
///
/// `/ajax/profile/info` is public, but Weibo now gates `/ajax/statuses/mymblog`
/// behind a login (it answers 「登录状态已失效，请重新登录」 for visitors), so the
/// timeline tab shows that exact sentence instead of an empty list.
class UserPage extends ConsumerStatefulWidget {
  final String uid;
  final String? initialName;
  final String? initialAvatar;

  const UserPage({
    super.key,
    required this.uid,
    this.initialName,
    this.initialAvatar,
  });

  @override
  ConsumerState<UserPage> createState() => _UserPageState();
}

class _UserPageState extends ConsumerState<UserPage> {
  static const List<(int feature, String label)> _feedTabs = [
    (0, '全部'),
    (1, '原创'),
    (2, '图片'),
    (3, '视频'),
  ];

  final ScrollController _scroll = ScrollController();

  User? _user;
  List<Status> _statuses = const [];
  bool _loadingProfile = true;
  bool _loadingStatuses = true;
  bool _loadingMore = false;
  bool _following = false;
  bool _followBusy = false;
  bool _hasMore = true;
  int _feature = 0;
  int _page = 1;
  String? _maxId;
  String? _profileError;
  String? _statusError;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _following = false;
    _loadProfile();
    _loadStatuses();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 320) {
      _loadMore();
    }
  }

  Future<void> _loadProfile() async {
    setState(() {
      _loadingProfile = true;
      _profileError = null;
    });
    try {
      final user = await WeiboApi.instance.profile(widget.uid);
      if (!mounted) return;
      setState(() {
        _user = user;
        _following = user?.following ?? false;
        _loadingProfile = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _profileError = _humanize(e);
        _loadingProfile = false;
      });
    }
  }

  Future<void> _loadStatuses() async {
    setState(() {
      _loadingStatuses = true;
      _statusError = null;
      _maxId = null;
      _hasMore = true;
    });
    try {
      final page = await WeiboApi.instance.userStatuses(
        widget.uid,
        feature: _feature,
      );
      if (!mounted) return;
      setState(() {
        _statuses = page.items;
        _maxId = page.maxId;
        _hasMore = page.hasMore;
        _page = 1;
        if (_user == null && page.items.isNotEmpty && page.items.first.user != null) {
          _user = page.items.first.user;
          _following = _user?.following ?? _following;
        }
        _loadingStatuses = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusError = _humanize(e);
        _loadingStatuses = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loadingStatuses || _statusError != null) return;
    setState(() => _loadingMore = true);
    try {
      final page = await WeiboApi.instance.userStatuses(
        widget.uid,
        page: _page + 1,
        feature: _feature,
        maxId: _maxId,
      );
      if (!mounted) return;
      setState(() {
        final seen = _statuses.map((s) => s.id).toSet();
        final fresh = page.items.where((s) => !seen.contains(s.id)).toList();
        _statuses = [..._statuses, ...fresh];
        _page += 1;
        _maxId = page.maxId;
        _hasMore = page.hasMore && fresh.isNotEmpty;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _hasMore = false;
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _toggleFollow() async {
    if (_followBusy) return;
    setState(() => _followBusy = true);
    try {
      await WeiboApi.instance.follow(widget.uid, _following);
      if (!mounted) return;
      setState(() {
        _following = !_following;
        _followBusy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _followBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_humanize(e))),
      );
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

  void _openDetail(Status status) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => StatusDetailPage(status: status)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = _user?.name ?? widget.initialName ?? '主页';
    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [
          // 原版 `PersonalStatusSearchActivity` 就是从主页右上角进来的。
          // 访客也能点：`/ajax/profile/searchblog` 只在登录态返回数据，
          // 届时页面会照原样显示服务端那句「登录状态已失效，请重新登录」。
          IconButton(
            tooltip: '搜索 TA 的微博',
            icon: const Icon(Icons.search, size: 22),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ProfileSearchPage(uid: widget.uid, ownerName: name),
              ),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'friends') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => MyFriendPage(uid: widget.uid)),
                );
              } else if (v == 'followers') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => MyFriendPage(uid: widget.uid, showFollowers: true),
                  ),
                );
              } else if (v == 'block' || v == 'unblock') {
                try {
                  await ShareCore.instance.blockUser(
                    widget.uid,
                    block: v == 'block',
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(v == 'block' ? '已拉黑该用户' : '已取消拉黑')),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('操作失败：$e')),
                    );
                  }
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'friends', child: Text('查看 TA 的关注')),
              PopupMenuItem(value: 'followers', child: Text('查看 TA 的粉丝')),
              PopupMenuItem(value: 'block', child: Text('加入黑名单')),
              PopupMenuItem(value: 'unblock', child: Text('移出黑名单')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        color: ShareColors.accent,
        onRefresh: () async {
          await Future.wait([_loadProfile(), _loadStatuses()]);
        },
        child: ListView.builder(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: 1 + _rows.length,
          itemBuilder: (context, index) {
            if (index == 0) return _header();
            return _rows[index - 1];
          },
        ),
      ),
    );
  }

  List<Widget> get _rows {
    final rows = <Widget>[];
    rows.add(Container(height: 0.6, color: ShareColors.divider));
    rows.add(_statusSectionHeader());

    if (_loadingStatuses) {
      rows.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      ));
      return rows;
    }

    if (_statusError != null) {
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(28, 40, 28, 40),
        child: Column(
          children: [
            Icon(Icons.lock_outline, size: 34, color: ShareColors.textHint),
            const SizedBox(height: 10),
            Text(
              _statusError!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: ShareColors.textSecondary, height: 1.5),
            ),
            const SizedBox(height: 10),
            TextButton(onPressed: _loadStatuses, child: const Text('重试')),
          ],
        ),
      ));
      return rows;
    }

    if (_statuses.isEmpty) {
      final emptyMsg = switch (_feature) {
        1 => '暂无原创微博',
        2 => '暂无图片微博',
        3 => '暂无视频微博',
        _ => '还没有发过微博',
      };
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 46),
        child: Center(
          child: Text(emptyMsg,
              style: TextStyle(fontSize: 13, color: ShareColors.textHint)),
        ),
      ));
      return rows;
    }

    for (final status in _statuses) {
      rows.add(StatusCard(
        status: status,
        onTap: () => _openDetail(status),
        onComment: () => _openDetail(status),
        onRepost: () => _openDetail(status),
        onImageTap: (index) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => GalleryPage(pics: status.pics, initialIndex: index),
            ),
          );
        },
        onVideoTap: () {
          final target = (status.videoUrl == null &&
                  (status.videoObjectId ?? '').isEmpty &&
                  status.retweeted != null)
              ? status.retweeted!
              : status;
          final url = target.videoUrl ?? '';
          if (url.isEmpty && (target.videoObjectId ?? '').isEmpty) return;
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => VideoPage(
                url: url,
                objectId: target.videoObjectId,
                cover: target.videoCover,
                title: target.textRaw,
              ),
            ),
          );
        },
      ));
      rows.add(Container(height: 0.6, color: ShareColors.divider));
    }

    rows.add(Padding(
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
    ));
    return rows;
  }

  Widget _statusSectionHeader() {
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: ShareColors.cardBg,
        border: Border(bottom: BorderSide(color: ShareColors.divider, width: 0.6)),
      ),
      padding: const EdgeInsets.only(left: 6, right: 14),
      child: Row(
        children: [
          for (final (feature, label) in _feedTabs)
            InkWell(
              onTap: () {
                if (_feature == feature) return;
                setState(() => _feature = feature);
                _loadStatuses();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: _feature == feature ? ShareColors.accent : Colors.transparent,
                      width: 2.2,
                    ),
                  ),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: _feature == feature ? FontWeight.w600 : FontWeight.w400,
                    color: _feature == feature
                        ? ShareColors.accent
                        : ShareColors.textSecondary,
                  ),
                ),
              ),
            ),
          const Spacer(),
          if (_user != null)
            Text('共 ${formatCount(_user!.statuses)} 条',
                style: TextStyle(fontSize: 11.5, color: ShareColors.textHint)),
        ],
      ),
    );
  }

  Widget _header() {
    final user = _user;
    final settings = ref.watch(settingsProvider);
    final avatarUrl = user?.avatar ?? widget.initialAvatar ?? '';

    return Container(
      color: ShareColors.cardBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              _cover(user),
              Positioned(
                left: 14,
                bottom: -26,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: ShareColors.cardBg, width: 3),
                  ),
                  child: ClipOval(
                    child: SizedBox(
                      width: 68,
                      height: 68,
                      child: avatarUrl.isNotEmpty
                          ? Image.network(
                              avatarUrl,
                              fit: BoxFit.cover,
                              cacheWidth: 220,
                              errorBuilder: (_, _, _) => ColoredBox(
                                color: ShareColors.placeholder,
                                child: Icon(Icons.person,
                                    size: 30, color: ShareColors.textHint),
                              ),
                            )
                          : ColoredBox(
                              color: ShareColors.placeholder,
                              child:
                                  Icon(Icons.person, size: 30, color: ShareColors.textHint),
                            ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 14,
                bottom: 10,
                child: _headerActions(user),
              ),
            ],
          ),
          const SizedBox(height: 34),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        user?.displayName ?? widget.initialName ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: ShareColors.textPrimary,
                        ),
                      ),
                    ),
                    if (user != null && user.verified && settings.showVerified) ...[
                      const SizedBox(width: 5),
                      Icon(
                        Icons.verified,
                        size: 16,
                        color: user.verifiedType == 2 || user.verifiedType == 3
                            ? const Color(0xFF4285F4)
                            : const Color(0xFFF5A623),
                      ),
                    ],
                  ],
                ),
                if (user != null && user.verifiedReason.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    user.verifiedReason,
                    style: TextStyle(fontSize: 12, color: ShareColors.textSecondary),
                  ),
                ],
                if (user != null && user.description.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    user.description,
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.4,
                      color: ShareColors.textPrimary,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                if (user != null)
                  Row(
                    children: [
                      _stat(
                        '关注',
                        user.friends,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => MyFriendPage(
                              uid: user.id.isNotEmpty ? user.id : widget.uid,
                              showFollowers: false,
                            ),
                          ),
                        ),
                      ),
                      _stat(
                        '粉丝',
                        user.followers,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => MyFriendPage(
                              uid: user.id.isNotEmpty ? user.id : widget.uid,
                              showFollowers: true,
                            ),
                          ),
                        ),
                      ),
                      _stat('微博', user.statuses),
                    ],
                  ),
                if (_loadingProfile)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.6, color: ShareColors.textHint),
                    ),
                  ),
                if (_profileError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(
                      _profileError!,
                      style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary),
                    ),
                  ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cover(User? user) {
    final cover = user?.cover ?? '';
    return SizedBox(
      height: 132,
      width: double.infinity,
      child: cover.isNotEmpty
          ? Image.network(
              cover,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _coverFallback(),
            )
          : _coverFallback(),
    );
  }

  Widget _coverFallback() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            ShareColors.accent.withValues(alpha: 0.85),
            ShareColors.accent.withValues(alpha: 0.45),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
    );
  }

  Widget _headerActions(User? user) {
    if (user == null) return const SizedBox.shrink();
    final myUid = ref.watch(sessionProvider).account?.uid ?? '';
    final targetUid = user.id.isNotEmpty ? user.id : widget.uid;
    final isSelf = myUid.isNotEmpty && myUid == targetUid;

    if (isSelf) {
      return SizedBox(
        height: 30,
        child: OutlinedButton(
          onPressed: () async {
            final updated = await Navigator.of(context).push<bool>(
              MaterialPageRoute(builder: (_) => EditProfilePage(user: user)),
            );
            if (updated == true && mounted) _loadProfile();
          },
          style: OutlinedButton.styleFrom(
            foregroundColor: ShareColors.textPrimary,
            side: BorderSide(color: ShareColors.line, width: 0.8),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
            backgroundColor: ShareColors.cardBg.withValues(alpha: 0.9),
          ),
          child: const Text('编辑资料', style: TextStyle(fontSize: 13)),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 30,
          child: OutlinedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => DmChatPage(
                  uid: targetUid,
                  peerName: user.displayName,
                  peerAvatar: user.avatar,
                ),
              ),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: ShareColors.textPrimary,
              side: BorderSide(color: ShareColors.line, width: 0.8),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              backgroundColor: ShareColors.cardBg.withValues(alpha: 0.9),
            ),
            child: const Text('发私信', style: TextStyle(fontSize: 13)),
          ),
        ),
        const SizedBox(width: 8),
        _followButton(user),
      ],
    );
  }

  Widget _followButton(User? user) {
    if (user == null) return const SizedBox.shrink();
    final followed = _following;
    return SizedBox(
      height: 30,
      child: OutlinedButton(
        onPressed: _followBusy ? null : _toggleFollow,
        style: OutlinedButton.styleFrom(
          foregroundColor: followed ? ShareColors.textSecondary : ShareColors.accent,
          side: BorderSide(
            color: followed ? ShareColors.line : ShareColors.accent,
            width: 0.8,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          backgroundColor: ShareColors.cardBg.withValues(alpha: 0.9),
        ),
        child: Text(
          _followBusy ? '…' : (followed ? '已关注' : '关注'),
          style: const TextStyle(fontSize: 13),
        ),
      ),
    );
  }

  Widget _stat(String label, int value, {VoidCallback? onTap}) {
    final content = Padding(
      padding: const EdgeInsets.only(right: 20, top: 2, bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            formatCount(value),
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: ShareColors.textPrimary,
            ),
          ),
          const SizedBox(width: 3),
          Text(label, style: TextStyle(fontSize: 12, color: ShareColors.textSecondary)),
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: content,
    );
  }
}
