import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/keyword_filter.dart';
import '../../core/settings.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../app_theme.dart';
import '../common/long_image_page.dart';
import '../common/segment_actions.dart';
import '../common/share_actions.dart';
import '../compose/emoji_panel.dart';
import '../feed/status_card.dart';
import '../profile/user_page.dart';
import '../media/gallery_page.dart';
import 'comment_floor_page.dart';
import 'likers_list.dart';
import 'repost_list_page.dart';
import '../widgets/weibo_rich_text.dart';

class StatusDetailPage extends ConsumerStatefulWidget {
  final Status status;

  const StatusDetailPage({super.key, required this.status});

  @override
  ConsumerState<StatusDetailPage> createState() => _StatusDetailPageState();
}

class _StatusDetailPageState extends ConsumerState<StatusDetailPage> {
  late Status _status;
  final List<Comment> _comments = [];
  final TextEditingController _input = TextEditingController();
  final ScrollController _commentScroll = ScrollController();

  /// 当前吸顶 Tab：0 转发 / 1 评论 / 2 赞。原版详情页默认落在「评论」。
  int _tab = 1;

  /// 只挂载访问过的 Tab（IndexedStack 会保留已挂载子树的 State 与滚动位置），
  /// 首次进入时不必同时打三个列表接口。
  final Set<int> _visited = {1};

  bool _loadingComments = true;
  bool _loadingMore = false;
  bool _sending = false;
  String? _commentError;
  String? _nextMaxId;
  int _commentPage = 1;
  bool _hasMore = true;
  int _flow = 0;
  Comment? _replyTarget;
  PageController? _pageController;
  final FocusNode _inputFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _status = widget.status;
    _flow = ref.read(settingsProvider).commentByTime ? 1 : 0;
    _pageController = PageController(initialPage: _tab);
    _commentScroll.addListener(_onScroll);
    _bootstrap();
  }

  @override
  void dispose() {
    _commentScroll.removeListener(_onScroll);
    _commentScroll.dispose();
    _pageController?.dispose();
    _inputFocus.dispose();
    _input.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_commentScroll.position.pixels > _commentScroll.position.maxScrollExtent - 300) {
      _loadMoreComments();
    }
  }

  void _selectTab(int index, {bool animatePage = true}) {
    if (index == _tab) return;
    setState(() {
      _tab = index;
      _visited.add(index);
    });
    if (animatePage && _pageController?.hasClients == true) {
      _pageController!.animateToPage(
        index,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _bootstrap() async {
    final detailKey = _status.mblogid.isNotEmpty ? _status.mblogid : _status.id;
    final commentsFuture = _loadComments(reset: true);
    var gotFresh = false;
    try {
      final fresh = await WeiboApi.instance.status(detailKey);
      if (mounted && fresh.id.isNotEmpty) {
        gotFresh = true;
        setState(() => _status = fresh);
      }
    } catch (_) {
      // Keep the timeline copy when the detail request is rate limited.
    }
    if (!gotFresh) {
      try {
        final expanded = await WeiboApi.instance.expandStatusLongText(_status);
        if (mounted) setState(() => _status = expanded);
      } catch (_) {}
    }
    await commentsFuture;
  }

  Future<void> _loadComments({bool reset = false}) async {
    if (reset) {
      setState(() {
        _loadingComments = true;
        _commentError = null;
        _hasMore = true;
        _nextMaxId = null;
        _commentPage = 1;
      });
      _comments.clear();
    }
    final targetPage = reset ? 1 : _commentPage;
    try {
      final page = await WeiboApi.instance.comments(
        statusId: _status.id,
        authorUid: _status.user?.id ?? '',
        flow: _flow,
        maxId: reset ? null : _nextMaxId,
        page: targetPage,
      );
      if (!mounted) return;
      setState(() {
        final existing = _comments.map((c) => c.id).toSet();
        final fresh = hideCommentsByKeyword(
          page.items,
          ref.read(settingsProvider).hiddenKeywords,
        ).where((c) => c.id.isEmpty || !existing.contains(c.id));
        _comments.addAll(fresh);
        _nextMaxId = page.maxId;
        _commentPage = targetPage + 1;
        _hasMore = page.hasMore;
        _loadingComments = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingComments = false;
        _loadingMore = false;
        _commentError = _humanize(e);
      });
    }
  }

  Future<void> _loadMoreComments() async {
    // 上一页失败时先停住，避免滚动反复触发同一个失败请求。
    if (_loadingMore || !_hasMore || _loadingComments || _commentError != null) return;
    setState(() => _loadingMore = true);
    await _loadComments();
  }

  Future<void> _sendComment() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    if (!ref.read(sessionProvider).isLoggedIn) {
      _toast('请先登录后再评论');
      return;
    }
    setState(() => _sending = true);
    final focus = FocusScope.of(context);
    final replyTo = _replyTarget;
    try {
      if (replyTo != null && replyTo.id.isNotEmpty) {
        await WeiboApi.instance.commentReply(_status.id, replyTo.id, text);
      } else {
        await WeiboApi.instance.comment(_status.id, text);
      }
      if (!mounted) return;
      final account = ref.read(sessionProvider).account;
      _input.clear();
      focus.unfocus();
      setState(() {
        _status = _status.copyWith(comments: _status.comments + 1);
        if (replyTo != null) {
          final idx = _comments.indexWhere((c) => c.id == replyTo.id);
          if (idx >= 0) {
            final target = _comments[idx];
            final optimisticReply = Comment(
              id: 'local_${DateTime.now().millisecondsSinceEpoch}',
              rootId: target.id,
              createdAt: '刚刚',
              textHtml: text,
              user: account == null
                  ? null
                  : User(
                      id: account.uid,
                      name: account.screenName.isNotEmpty
                          ? account.screenName
                          : '我',
                      avatar: account.avatar,
                    ),
            );
            _comments[idx] = target.copyWith(
              replyCount: target.replyCount + 1,
              replies: [...target.replies, optimisticReply],
            );
          }
        }
        _replyTarget = null;
        _sending = false;
      });
      await _loadComments(reset: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _toast(_humanize(e));
    }
  }

  Future<void> _toggleCommentLike(Comment comment) async {
    final index = _comments.indexWhere((c) => c.id == comment.id);
    if (index < 0) return;
    final prev = _comments[index];
    final nextLiked = !prev.likedByMe;
    final nextCount = (prev.likeCount + (nextLiked ? 1 : -1)).clamp(0, 1 << 30);
    setState(() {
      _comments[index] = prev.copyWith(likedByMe: nextLiked, likeCount: nextCount);
    });
    try {
      await WeiboApi.instance.likeComment(prev.id, undo: prev.likedByMe);
    } catch (e) {
      if (!mounted) return;
      setState(() => _comments[index] = prev);
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

  @override
  Widget build(BuildContext context) {
    final swipeTabs = ref.watch(settingsProvider).statusDetailTabScroll;
    return Scaffold(
      appBar: AppBar(
        title: const Text('微博正文'),
        actions: [
          IconButton(
            tooltip: '生成长图',
            icon: const Icon(Icons.image_outlined, size: 21),
            onPressed: _openLongImage,
          ),
          PopupMenuButton<String>(
            onSelected: (action) {
              switch (action) {
                case 'long_image':
                  _openLongImage();
                case 'copy':
                  ShareActions.copyText(context, _status.textRaw, toast: '微博内容已复制');
                case 'link':
                  ShareActions.copyText(
                    context,
                    ShareActions.statusLink(_status),
                    toast: '链接已复制',
                  );
                case 'share':
                  ShareActions.shareStatus(context, _status);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'long_image', child: Text('生成长图')),
              PopupMenuItem(value: 'copy', child: Text('复制全文')),
              PopupMenuItem(value: 'link', child: Text('复制链接')),
              PopupMenuItem(value: 'share', child: Text('分享微博')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: swipeTabs
                ? PageView(
                    controller: _pageController,
                    onPageChanged: (i) => _selectTab(i, animatePage: false),
                    children: [
                      _tabSlot(0, RepostTabList(statusId: _status.id, headSlivers: _headSlivers())),
                      _tabSlot(1, _commentView()),
                      _tabSlot(2, LikersList(statusId: _status.id, headSlivers: _headSlivers())),
                    ],
                  )
                : IndexedStack(
                    index: _tab,
                    children: [
                      _tabSlot(0, RepostTabList(statusId: _status.id, headSlivers: _headSlivers())),
                      _tabSlot(1, _commentView()),
                      _tabSlot(2, LikersList(statusId: _status.id, headSlivers: _headSlivers())),
                    ],
                  ),
          ),
          // 输入框只属于「评论」，转发 / 赞 两个 Tab 底部没有东西。
          if (_tab == 1) _inputBar(),
        ],
      ),
    );
  }

  void _openLongImage() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LongImagePage(status: _status, initialComments: _comments),
      ),
    );
  }

  /// 未访问过的 Tab 用空盒子占位，避免一进详情页就打满三个接口。
  Widget _tabSlot(int index, Widget child) {
    if (!_visited.contains(index)) return const SizedBox.shrink();
    return child;
  }

  /// 三个 Tab 共用的头部：正文卡片 + 互动条，然后才是吸顶的 Tab 栏。
  /// 每个 Tab 各持一份（各自滚动），滚动时卡片跟着走，Tab 栏钉在 AppBar 下沿。
  List<Widget> _headSlivers() {
    return [
      SliverToBoxAdapter(
        child: Column(
          children: [
            StatusCard(
              status: _status,
              showActions: false,
              fullText: true,
              onAvatarTap: () => _openUser(_status.user),
              onImageTap: (i) => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => GalleryPage(pics: _status.pics, initialIndex: i),
                ),
              ),
              onVideoTap: () => ShareActions.openStatusVideo(context, _status),
            ),
            _interactionBar(),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: SizedBox(height: 8, child: ColoredBox(color: ShareColors.pageBg)),
      ),
      _stickyTabBar(),
    ];
  }

  Widget _stickyTabBar() {
    return SliverPersistentHeader(
      pinned: true,
      delegate: _DetailTabBarDelegate(
        index: _tab,
        counts: [_status.reposts, _status.comments, _status.attitudes],
        onTap: _selectTab,
      ),
    );
  }

  Widget _commentView() {
    return CustomScrollView(
      controller: _commentScroll,
      slivers: [
        ..._headSlivers(),
        SliverToBoxAdapter(child: _commentsHeader()),
        ..._commentSlivers(),
      ],
    );
  }

  Widget _interactionBar() {
    return Container(
      color: ShareColors.cardBg,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          _barAction(Icons.repeat_rounded, formatCount(_status.reposts), _repostMenu),
          _barAction(Icons.mode_comment_outlined, formatCount(_status.comments), null),
          _barAction(
            _status.liked ? Icons.thumb_up_alt : Icons.thumb_up_alt_outlined,
            formatCount(_status.attitudes),
            () => _like(),
            highlighted: _status.liked,
          ),
          _barAction(
            _status.favorited ? Icons.star : Icons.star_border,
            '收藏',
            () => _favorite(),
            highlighted: _status.favorited,
          ),
        ],
      ),
    );
  }

  Widget _barAction(IconData icon, String label, VoidCallback? onTap, {bool highlighted = false}) {
    final color = highlighted ? ShareColors.accent : ShareColors.textSecondary;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: color),
              SizedBox(width: 5),
              Text(label, style: TextStyle(fontSize: 13, color: color)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _like() async {
    final previous = _status;
    setState(() {
      _status = _status.copyWith(
        liked: !previous.liked,
        attitudes: previous.attitudes + (previous.liked ? -1 : 1),
      );
    });
    try {
      await WeiboApi.instance.like(previous.id, previous.liked);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = previous);
      _toast(_humanize(e));
    }
  }

  Future<void> _favorite() async {
    final previous = _status;
    setState(() => _status = _status.copyWith(favorited: !previous.favorited));
    try {
      await WeiboApi.instance.favorite(previous.id, previous.favorited);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = previous);
      _toast(_humanize(e));
    }
  }

  void _repostMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: ShareColors.cardBg,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.repeat_rounded, size: 20),
              title: const Text('转发微博'),
              onTap: () {
                Navigator.pop(ctx);
                _repost();
              },
            ),
            ListTile(
              leading: const Icon(Icons.forum_outlined, size: 20),
              title: Text('查看转发列表（${formatCount(_status.reposts)}）'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => RepostListPage(status: _status)),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _repost() async {
    if (!ref.read(sessionProvider).isLoggedIn) {
      _toast('请先登录后再转发');
      return;
    }
    final controller = TextEditingController();
    var alsoComment = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Expanded(child: Text('转发微博')),
              IconButton(
                icon: const Icon(Icons.sentiment_satisfied_alt_outlined, size: 20),
                tooltip: '插入表情',
                onPressed: () => showEmojiPanel(ctx, (token) {
                  final sel = controller.selection;
                  final current = controller.text;
                  final start = sel.start < 0 ? current.length : sel.start;
                  final end = sel.end < 0 ? current.length : sel.end;
                  final next = current.replaceRange(start, end, token);
                  controller.value = TextEditingValue(
                    text: next,
                    selection: TextSelection.collapsed(offset: start + token.length),
                  );
                }),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                maxLines: 3,
                decoration: const InputDecoration(hintText: '说点什么…（可留空）'),
              ),
              const SizedBox(height: 6),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: alsoComment,
                onChanged: (v) => setDialogState(() => alsoComment = v ?? false),
                title: const Text('同时评论给原作者', style: TextStyle(fontSize: 13.5)),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('转发')),
          ],
        ),
      ),
    );
    final repostText = controller.text.trim();
    controller.dispose();
    if (confirmed != true) return;
    try {
      await WeiboApi.instance.repost(
        _status.id,
        repostText,
        alsoComment: alsoComment,
      );
      if (!mounted) return;
      setState(() => _status = _status.copyWith(reposts: _status.reposts + 1));
      _toast('转发成功');
    } catch (e) {
      _toast(_humanize(e));
    }
  }

  Widget _commentsHeader() {
    return Container(
      color: ShareColors.cardBg,
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
      child: Row(
        children: [
          Text(
            // 计数已经显示在吸顶 Tab 上，这里只标排序，不重复数字。
            _flow == 0 ? '热门评论' : '最新评论',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          Spacer(),
          TextButton(
            onPressed: () {
              setState(() => _flow = _flow == 0 ? 1 : 0);
              _loadComments(reset: true);
            },
            child: Text(_flow == 0 ? '按热度' : '按时间',
                style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
          ),
        ],
      ),
    );
  }

  List<Widget> _commentSlivers() {
    if (_loadingComments) {
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
    if (_commentError != null && _comments.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: Column(
              children: [
                // 服务端原话直接展示，不替换成「加载失败」之类的空话。
                Text(
                  _commentError!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => _loadComments(reset: true),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ];
    }
    if (_comments.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: Text('还没有评论，快来抢沙发',
                  style: TextStyle(fontSize: 13, color: ShareColors.textHint)),
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
                indent: 58,
                color: ShareColors.divider,
              );
            }
            return _commentTile(_comments[index ~/ 2]);
          },
          childCount: _comments.length * 2 - 1,
        ),
      ),
      SliverToBoxAdapter(child: _commentsFooter()),
    ];
  }

  void _openUser(User? user) {
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

  void _openCommentFloor(Comment comment, {bool focusReply = false}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CommentFloorPage(
          root: comment,
          statusAuthor: _status.user?.name ?? '',
          statusId: _status.id,
          focusReplyInput: focusReply,
        ),
      ),
    );
  }

  Widget _commentTile(Comment comment) {
    final settings = ref.watch(settingsProvider);
    final hideAvatar = settings.hideCommentAvatar;
    final allowCommentPics = settings.choiceOf('show_comment_photo_options') != 3;
    final inlineReplies = settings.commentFloor ? comment.replies : const <Comment>[];
    final totalReplies =
        comment.replyCount > inlineReplies.length ? comment.replyCount : inlineReplies.length;

    return InkWell(
      onTap: () => _openCommentFloor(comment),
      child: Container(
      color: ShareColors.cardBg,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!hideAvatar) ...[
            GestureDetector(
              onTap: () => _openUser(comment.user),
              child: ClipRRect(
              borderRadius: BorderRadius.circular(17),
              child: SizedBox(
                width: 34,
                height: 34,
                child: comment.user?.avatar.isNotEmpty == true
                    ? Image.network(comment.user!.avatar, fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => ColoredBox(
                              color: ShareColors.placeholder,
                              child: Icon(Icons.person, size: 18, color: ShareColors.textHint),
                            ))
                    : ColoredBox(color: ShareColors.placeholder),
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
                        comment.user?.displayName ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          color: ShareColors.link,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (comment.likedByAuthor) ...[
                      const SizedBox(width: 5),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                        decoration: BoxDecoration(
                          color: ShareColors.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text('博主',
                            style: TextStyle(fontSize: 9, color: ShareColors.accent)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                WeiboRichText(
                  html: comment.textHtml,
                  fontSize: 15,
                  color: ShareColors.textPrimary,
                  onTapSegment: (segment) => openRichSegment(context, segment),
                ),
                if (allowCommentPics && comment.pics.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (int i = 0; i < comment.pics.length; i++)
                        GestureDetector(
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => GalleryPage(
                                pics: comment.pics,
                                initialIndex: i,
                              ),
                            ),
                          ),
                          onLongPress: () => ShareActions.showPicLongPressMenu(
                            context,
                            comment.pics,
                            i,
                            deduplicateName: settings.samePhotoName,
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.network(
                              comment.pics[i].url,
                              width: 78,
                              height: 78,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Container(
                                width: 78,
                                height: 78,
                                color: ShareColors.placeholder,
                                child: Icon(
                                  Icons.broken_image_outlined,
                                  size: 18,
                                  color: ShareColors.textHint,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      formatWeiboTime(comment.createdAt),
                      style: TextStyle(fontSize: 11.5, color: ShareColors.textHint),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        setState(() => _replyTarget = comment);
                        _inputFocus.requestFocus();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Text(
                          comment.replyCount > 0 ? '回复 (${comment.replyCount})' : '回复',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _toggleCommentLike(comment),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              comment.likedByMe
                                  ? Icons.thumb_up_alt
                                  : Icons.thumb_up_alt_outlined,
                              size: 13,
                              color: comment.likedByMe
                                  ? ShareColors.accent
                                  : ShareColors.textHint,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              comment.likeCount > 0 ? formatCount(comment.likeCount) : '',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: comment.likedByMe
                                    ? ShareColors.accent
                                    : ShareColors.textHint,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (inlineReplies.isNotEmpty)
                  GestureDetector(
                    onTap: () => _openCommentFloor(comment),
                    child: Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
                      decoration: BoxDecoration(
                        color: ShareColors.repostBg,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (int i = 0; i < inlineReplies.length && i < 3; i++) ...[
                            if (i > 0) const SizedBox(height: 5),
                            _inlineReplyPreview(inlineReplies[i], settings),
                          ],
                          if (totalReplies > 0) ...[
                            const SizedBox(height: 6),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '共 ${formatCount(totalReplies)} 条回复',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: ShareColors.link,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 15,
                                  color: ShareColors.link,
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                else if (comment.replyCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: GestureDetector(
                      onTap: () => _openCommentFloor(comment),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '查看 ${formatCount(comment.replyCount)} 条回复',
                            style: TextStyle(
                              fontSize: 12,
                              color: ShareColors.link,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 15,
                            color: ShareColors.link,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _inlineReplyPreview(Comment reply, AppSettings settings) {
    final author = reply.user?.displayName.trim() ?? '';
    final replyTo = reply.replyTo?.user?.displayName.trim() ?? '';
    final plainBody = RichTextParser.toPlain(reply.textHtml).trimLeft();
    final hasExplicitTarget = replyTo.isNotEmpty &&
        !plainBody.startsWith('回复@$replyTo') &&
        !plainBody.startsWith('回复 @$replyTo');
    final prefix = author.isEmpty
        ? (hasExplicitTarget ? '回复 @$replyTo：' : '')
        : (hasExplicitTarget ? '@$author 回复 @$replyTo：' : '@$author：');

    return WeiboRichText(
      html: '$prefix${reply.textHtml}',
      fontSize: 13,
      maxLines: 3,
      color: ShareColors.textPrimary,
      onTapSegment: (segment) => openRichSegment(context, segment, settings: settings),
    );
  }

  Widget _commentsFooter() {
    if (_commentError != null) {
      // 已经有评论时翻页失败只占页脚，不清空已加载的内容。
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          children: [
            Text(
              _commentError!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: ShareColors.textSecondary),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => _loadComments(reset: true),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_loadingMore) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.8)),
        ),
      );
    }
    return SizedBox(height: 20);
  }

  Widget _inputBar() {
    final reply = _replyTarget;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: ShareColors.cardBg,
          border: Border(top: BorderSide(color: ShareColors.line, width: 0.5)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reply != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Text(
                      '正在回复 @${reply.user?.displayName ?? ''}',
                      style: TextStyle(fontSize: 12, color: ShareColors.accent),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => setState(() => _replyTarget = null),
                      child: Icon(Icons.close, size: 16, color: ShareColors.textHint),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 34),
                  icon: Icon(
                    Icons.sentiment_satisfied_alt_outlined,
                    size: 21,
                    color: ShareColors.textSecondary,
                  ),
                  tooltip: '插入表情',
                  onPressed: () => showEmojiPanel(context, (token) {
                    final sel = _input.selection;
                    final current = _input.text;
                    final start = sel.start < 0 ? current.length : sel.start;
                    final end = sel.end < 0 ? current.length : sel.end;
                    final updated = current.replaceRange(start, end, token);
                    _input.value = TextEditingValue(
                      text: updated,
                      selection: TextSelection.collapsed(
                        offset: start + token.length,
                      ),
                    );
                  }),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: ShareColors.inputBg,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    alignment: Alignment.centerLeft,
                    child: TextField(
                      controller: _input,
                      focusNode: _inputFocus,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendComment(),
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: reply != null
                            ? '回复 @${reply.user?.displayName ?? ''}…'
                            : '写评论…',
                        hintStyle: TextStyle(fontSize: 14, color: ShareColors.textHint),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _sending ? null : _sendComment,
                  child: _sending
                      ? const SizedBox(
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('发送'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 详情页吸顶 Tab 栏：三等分，选中项 accent 文字 + 2dp 短下划线（原版
/// `StatusDetailActivity` 的 `tab_detail` 就是这个规格）。
class _DetailTabBarDelegate extends SliverPersistentHeaderDelegate {
  final int index;
  final List<int> counts;
  final ValueChanged<int> onTap;

  const _DetailTabBarDelegate({
    required this.index,
    required this.counts,
    required this.onTap,
  });

  static const double _height = 44;
  static const List<String> _labels = ['转发', '评论', '赞'];

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Material(
      color: ShareColors.cardBg,
      child: Container(
        height: _height,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: ShareColors.divider, width: 1)),
        ),
        child: Row(
          children: [
            for (var i = 0; i < _labels.length; i++)
              Expanded(
                child: InkWell(
                  onTap: () => onTap(i),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '${_labels[i]} ${formatCount(counts[i])}',
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: i == index ? FontWeight.w600 : FontWeight.w400,
                          color: i == index ? ShareColors.accent : ShareColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Container(
                        width: 18,
                        height: 2,
                        color: i == index ? ShareColors.accent : Colors.transparent,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _DetailTabBarDelegate old) {
    if (old.index != index) return true;
    for (var i = 0; i < counts.length; i++) {
      if (old.counts[i] != counts[i]) return true;
    }
    return false;
  }
}
