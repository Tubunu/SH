import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/notice.dart';
import '../../core/session.dart';
import '../../core/settings.dart';
import '../app_theme.dart';
import '../detail/status_detail_page.dart';
import '../feed/status_card.dart';
import '../login/login_page.dart';
import '../media/gallery_page.dart';
import '../media/video_page.dart';
import '../common/segment_actions.dart';
import '../profile/user_page.dart';
import '../widgets/weibo_rich_text.dart';

/// Tab 顺序即原版 `StatusNotifyActivity` 的顺序：@我微博 / @我评论 / 收到的评论 / 收到的赞。
const List<NoticeKind> _tabKinds = [
  NoticeKind.atWeibo,
  NoticeKind.atComment,
  NoticeKind.comment,
  NoticeKind.like,
];

const List<String> _tabLabels = ['@我微博', '@我评论', '收到的评论', '收到的赞'];

String _labelFor(NoticeKind kind) {
  final index = _tabKinds.indexOf(kind);
  return index < 0 ? kind.label : _tabLabels[index];
}

/// 通知中心 — 原版 `StatusNotifyActivity`：四类等宽 Tab，各自独立分页。
///
/// [kind] 非空时是旧调用形态（单类通知入口），此时仍展示四个 Tab，
/// 只是默认落在该类对应的位置，保证老调用点不必改动也不会看错内容。
class NoticePage extends ConsumerStatefulWidget {
  final NoticeKind? kind;

  const NoticePage({super.key, this.kind});

  @override
  ConsumerState<NoticePage> createState() => _NoticePageState();
}

class _NoticePageState extends ConsumerState<NoticePage> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late int _index;

  /// 登录页是否还压在本页上面（决定登录成功后要不要替用户关掉它）。
  bool _loginPushed = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.kind == null ? 0 : _tabKinds.indexOf(widget.kind!);
    _index = initial < 0 ? 0 : initial;
    _tabs = TabController(length: _tabKinds.length, vsync: this, initialIndex: _index);
    _tabs.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabs.index == _index) return;
    setState(() => _index = _tabs.index);
  }

  Future<void> _openLogin() async {
    _loginPushed = true;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
    _loginPushed = false;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = ref.watch(sessionProvider).isLoggedIn;

    // LoginPage 登录成功后只改 sessionProvider、自己不出栈；
    // 只有"登录页确实还在栈顶"时才替用户关掉它，避免误关本页。
    ref.listen<SessionState>(sessionProvider, (previous, next) {
      if (!_loginPushed) return;
      if ((previous?.isLoggedIn ?? false) || !next.isLoggedIn) return;
      _loginPushed = false;
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) Navigator.of(context).pop();
    });

    return Scaffold(
      backgroundColor: ShareColors.pageBg,
      appBar: AppBar(
        title: const Text('通知'),
        bottom: loggedIn ? _tabBar() : null,
      ),
      body: loggedIn
          // IndexedStack 让四个列表常驻：切 Tab 保留各自的列表、滚动位置与分页游标。
          ? IndexedStack(
              index: _index,
              children: [
                for (var i = 0; i < _tabKinds.length; i++)
                  _NoticeFeedView(
                    key: ValueKey(_tabKinds[i]),
                    kind: _tabKinds[i],
                    active: _index == i,
                  ),
              ],
            )
          : _guestView(),
    );
  }

  /// AppBar.bottom 需要 PreferredSize，TabBar 本身满足，所以返回类型写窄一点。
  PreferredSizeWidget _tabBar() {
    return TabBar(
      controller: _tabs,
      // isScrollable 保持 false，四个 Tab 才等宽。
      labelColor: ShareColors.accent,
      unselectedLabelColor: ShareColors.textSecondary,
      indicatorColor: ShareColors.accent,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: ShareColors.divider,
      labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      unselectedLabelStyle: const TextStyle(fontSize: 14),
      tabs: [for (final label in _tabLabels) Tab(text: label, height: 40)],
    );
  }

  Widget _guestView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.notifications_none, size: 46, color: ShareColors.textHint),
          const SizedBox(height: 14),
          Text(
            '登录后查看互动消息',
            style: TextStyle(fontSize: 14, color: ShareColors.textSecondary),
          ),
          const SizedBox(height: 6),
          Text(
            '@我、评论、赞都需要登录态才能读取',
            style: TextStyle(fontSize: 12, color: ShareColors.textHint),
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: _openLogin,
            style: FilledButton.styleFrom(
              backgroundColor: ShareColors.accent,
              minimumSize: const Size(140, 40),
            ),
            child: const Text('去登录'),
          ),
        ],
      ),
    );
  }
}

/// 单个 Tab 的通知流。
///
/// [NoticeKind.atWeibo] 渲染真实 `StatusCard`（返回体本身是微博列表）；
/// 另外三类渲染带引用微博的评论/赞行。
class _NoticeFeedView extends ConsumerStatefulWidget {
  final NoticeKind kind;

  /// 只有被选中的 Tab 才发请求：打开通知页时不一次性打四个接口。
  final bool active;

  const _NoticeFeedView({super.key, required this.kind, required this.active});

  @override
  ConsumerState<_NoticeFeedView> createState() => _NoticeFeedViewState();
}

class _NoticeFeedViewState extends ConsumerState<_NoticeFeedView> {
  final ScrollController _scroll = ScrollController();

  List<Notice> _notices = const [];
  List<Status> _statuses = const [];
  int _page = 1;
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _started = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    if (widget.active) _start();
  }

  @override
  void didUpdateWidget(covariant _NoticeFeedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active) _start();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _start() {
    if (_started) return;
    _started = true;
    _refresh();
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 320) {
      _loadMore();
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final feed = await WeiboApi.instance.notices(widget.kind);
      if (!mounted) return;
      setState(() {
        _notices = feed.notices;
        _statuses = feed.statuses;
        _total = feed.total;
        _page = 1;
        _hasMore = feed.hasMore;
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
    if (_loadingMore || !_hasMore || _loading) return;
    setState(() => _loadingMore = true);
    try {
      final feed = await WeiboApi.instance.notices(widget.kind, page: _page + 1);
      if (!mounted) return;
      setState(() {
        _notices = [..._notices, ...feed.notices];
        _statuses = [..._statuses, ...feed.statuses];
        _page += 1;
        _hasMore = feed.hasMore;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _hasMore = false;
        _loadingMore = false;
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

  void _openStatus(Status status) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => StatusDetailPage(status: status)),
    );
  }

  void _openGallery(Status status, int index) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => GalleryPage(pics: status.pics, initialIndex: index)),
    );
  }

  void _openVideo(Status status) {
    final url = status.videoUrl ?? '';
    if (url.isEmpty && (status.videoObjectId ?? '').isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoPage(
          url: url,
          objectId: status.videoObjectId,
          cover: status.videoCover,
          title: status.textRaw,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: ShareColors.accent,
      onRefresh: _refresh,
      child: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 90),
          Icon(Icons.cloud_off, size: 42, color: ShareColors.textHint),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: ShareColors.textSecondary),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: TextButton(onPressed: _refresh, child: const Text('重试')),
          ),
        ],
      );
    }

    final empty = _statuses.isEmpty && _notices.isEmpty;
    if (empty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          Icon(Icons.notifications_none, size: 44, color: ShareColors.textHint),
          const SizedBox(height: 12),
          Text(
            '暂无${_labelFor(widget.kind)}',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: ShareColors.textSecondary),
          ),
        ],
      );
    }

    final rows = widget.kind == NoticeKind.atWeibo ? _statusRows() : _noticeRows();

    return ListView.separated(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: rows.length + 1,
      separatorBuilder: (_, _) => Container(height: 0.6, color: ShareColors.divider),
      itemBuilder: (context, index) {
        if (index == rows.length) return _footer();
        return rows[index];
      },
    );
  }

  Widget _footer() {
    if (_loadingMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: ShareColors.textHint),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Center(
        child: Text(
          _hasMore ? '上拉加载更多' : (_total > 0 ? '共 ${formatCount(_total)} 条' : '没有更多了'),
          style: TextStyle(fontSize: 11.5, color: ShareColors.textHint),
        ),
      ),
    );
  }

  List<Widget> _statusRows() {
    return _statuses.map((status) {
      return StatusCard(
        status: status,
        onTap: () => _openStatus(status),
        onComment: () => _openStatus(status),
        onRepost: () => _openStatus(status),
        onAvatarTap: () => _openStatus(status),
        onImageTap: (index) => _openGallery(status, index),
        onVideoTap: () => _openVideo(status),
      );
    }).toList();
  }

  List<Widget> _noticeRows() {
    return _notices.map((notice) {
      return _NoticeTile(
        notice: notice,
        onTap: notice.status == null ? null : () => _openStatus(notice.status!),
      );
    }).toList();
  }
}

class _NoticeTile extends ConsumerWidget {
  final Notice notice;
  final VoidCallback? onTap;

  const _NoticeTile({required this.notice, this.onTap});

  void _openUser(BuildContext context) {
    final user = notice.from;
    if (user == null || user.id.isEmpty) return;
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
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final user = notice.from;
    final status = notice.status;
    final isLike = notice.kind == NoticeKind.like;

    final actionLabel = switch (notice.kind) {
      NoticeKind.like => '赞了你的微博',
      NoticeKind.atComment => '在评论里提到了你',
      NoticeKind.comment => notice.myComment != null ? '回复了你的评论' : '评论了你的微博',
      NoticeKind.atWeibo => '提到了你',
    };

    return InkWell(
      onTap: onTap,
      child: Container(
        color: ShareColors.cardBg,
        // 左右 16dp 与原版卡片版式对齐。
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => _openUser(context),
              child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: SizedBox(
                width: 36,
                height: 36,
                child: user != null && user.avatar.isNotEmpty
                    ? Image.network(
                        user.avatar,
                        fit: BoxFit.cover,
                        cacheWidth: 110,
                        errorBuilder: (_, _, _) => ColoredBox(
                          color: ShareColors.placeholder,
                          child: Icon(Icons.person, size: 18, color: ShareColors.textHint),
                        ),
                      )
                    : ColoredBox(
                        color: ShareColors.placeholder,
                        child: Icon(Icons.person, size: 18, color: ShareColors.textHint),
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
                        child: GestureDetector(
                          onTap: () => _openUser(context),
                          child: Text(
                            user?.displayName ?? '微博用户',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: ShareColors.link,
                            ),
                          ),
                        ),
                      ),
                      if (user != null && user.verified && settings.showVerified) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.verified, size: 13, color: ShareColors.accent),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (isLike)
                        Padding(
                          padding: const EdgeInsets.only(right: 3),
                          child: Icon(Icons.favorite, size: 12, color: ShareColors.accent),
                        ),
                      Text(
                        actionLabel,
                        style: TextStyle(fontSize: 12, color: ShareColors.textSecondary),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatWeiboTime(notice.createdAt),
                        style: TextStyle(fontSize: 11.5, color: ShareColors.textHint),
                      ),
                    ],
                  ),
                  if (notice.textHtml.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    WeiboRichText(
                      html: notice.textHtml,
                      fontSize: settings.fontSize,
                      color: ShareColors.textPrimary,
                      onTapSegment: (segment) => openRichSegment(context, segment),
                    ),
                  ],
                  if (notice.myComment != null && notice.myComment!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                      decoration: BoxDecoration(
                        color: ShareColors.repostBg,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(
                            text: '我：',
                            style: TextStyle(color: ShareColors.textSecondary, fontSize: 13),
                          ),
                          TextSpan(
                            text: RichTextParser.toPlain(notice.myComment!)
                                .replaceAll(RegExp(r'\s+'), ' ')
                                .trim(),
                            style: TextStyle(color: ShareColors.textSecondary, fontSize: 13),
                          ),
                        ]),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  if (status != null && !isLike) ...[
                    const SizedBox(height: 6),
                    _quotedStatus(status),
                  ],
                  if (status != null && isLike) ...[
                    const SizedBox(height: 6),
                    _quotedStatus(status),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _quotedStatus(Status status) {
    final author = status.user?.displayName ?? '';
    final text = RichTextParser.toPlain(status.textHtml)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: ShareColors.repostBg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(children: [
              if (author.isNotEmpty)
                TextSpan(
                  text: '$author：',
                  style: TextStyle(color: ShareColors.link, fontSize: 13),
                ),
              TextSpan(
                text: text,
                style: TextStyle(color: ShareColors.textSecondary, fontSize: 13),
              ),
            ]),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          if (status.pics.isNotEmpty) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                width: 66,
                height: 66,
                child: Image.network(
                  status.pics.first.url,
                  fit: BoxFit.cover,
                  cacheWidth: 200,
                  errorBuilder: (_, _, _) => ColoredBox(color: ShareColors.placeholder),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
