import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/settings.dart';
import '../app_theme.dart';
import '../common/segment_actions.dart';
import '../common/share_actions.dart';
import '../common/text_boom_dialog.dart';
import '../compose/emoji_panel.dart';
import '../media/gallery_page.dart';
import '../profile/user_page.dart';
import '../widgets/weibo_rich_text.dart';

/// 评论楼层页 / 跟评详情页（对应原版 Share `StatusCommentFloorActivity`）。
///
/// 使用双协议 `/2/comments/build_comments`（`fetch_level=1&is_mix=1`）+
/// Web `commentReplies` 兜底，支持：
/// * 预填充摘要跟评并分页拉取全部楼中楼回复（支持按热度 / 按时间切换）
/// * 评论配图缩略图点击看大图 + 长按保存原图
/// * 点击任意跟评直接 `@对方` 发起二级回复，支持插入表情
/// * 根评论与子回复点赞、长按复制 / 自由分词（TextBoom）
class CommentFloorPage extends ConsumerStatefulWidget {
  final Comment root;
  final String statusAuthor;
  final String statusId;
  final bool focusReplyInput;

  const CommentFloorPage({
    super.key,
    required this.root,
    this.statusAuthor = '',
    this.statusId = '',
    this.focusReplyInput = false,
  });

  @override
  ConsumerState<CommentFloorPage> createState() => _CommentFloorPageState();
}

class _CommentFloorPageState extends ConsumerState<CommentFloorPage> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  late Comment _root = widget.root;
  final List<Comment> _replies = <Comment>[];
  Comment? _replyTarget;

  int _flow = 0; // 0 = 按热度, 1 = 按时间
  bool _loading = true;
  bool _loadingMore = false;
  bool _sending = false;
  bool _hasMore = true;
  String? _maxId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _flow = ref.read(settingsProvider).commentByTime ? 1 : 0;
    if (widget.root.replies.isNotEmpty) {
      _replies.addAll(widget.root.replies);
    }
    _scroll.addListener(_onScroll);
    _loadInitial();
    if (widget.focusReplyInput) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loading || _loadingMore || !_hasMore) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 220) {
      _loadMore();
    }
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _error = null;
      _maxId = null;
      _hasMore = true;
    });
    try {
      final page = await WeiboApi.instance.repliesPaged(
        _root.id,
        flow: _flow,
      );
      if (!mounted) return;
      setState(() {
        if (page.items.isNotEmpty || _root.replies.isEmpty) {
          _replies
            ..clear()
            ..addAll(page.items);
        }
        _maxId = page.maxId;
        _hasMore = page.hasMore && page.maxId != null && page.maxId!.isNotEmpty;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final cursor = _maxId;
    if (_loading || _loadingMore || !_hasMore || cursor == null || cursor.isEmpty) {
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final page = await WeiboApi.instance.repliesPaged(
        _root.id,
        maxId: cursor,
        flow: _flow,
      );
      if (!mounted) return;
      final existingIds = _replies.map((e) => e.id).toSet();
      final added = page.items.where((e) => !existingIds.contains(e.id)).toList();
      setState(() {
        _replies.addAll(added);
        final nextCursor = page.maxId;
        final cursorAdvanced = nextCursor != null && nextCursor.isNotEmpty && nextCursor != cursor;
        _maxId = cursorAdvanced ? nextCursor : null;
        _hasMore = page.hasMore && cursorAdvanced && added.isNotEmpty;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _toggleSort() {
    setState(() => _flow = _flow == 0 ? 1 : 0);
    _loadInitial();
  }

  Future<void> _toggleLike(Comment comment, {bool isRoot = false}) async {
    final nextLiked = !comment.likedByMe;
    final nextCount = math.max(0, comment.likeCount + (nextLiked ? 1 : -1));
    final updated = comment.copyWith(likedByMe: nextLiked, likeCount: nextCount);

    setState(() {
      if (isRoot) {
        _root = updated;
      } else {
        final idx = _replies.indexWhere((c) => c.id == comment.id);
        if (idx >= 0) _replies[idx] = updated;
      }
    });

    try {
      await WeiboApi.instance.likeComment(comment.id, undo: !nextLiked);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (isRoot) {
          _root = comment;
        } else {
          final idx = _replies.indexWhere((c) => c.id == comment.id);
          if (idx >= 0) _replies[idx] = comment;
        }
      });
      _toast('点赞失败：$e');
    }
  }

  Future<void> _submitReply() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;

    final effectiveStatusId =
        widget.statusId.isNotEmpty ? widget.statusId : _root.rootId;
    if (effectiveStatusId.isEmpty) {
      _toast('缺少原微博 ID，无法提交回复');
      return;
    }

    final target = _replyTarget ?? _root;
    final settings = ref.read(settingsProvider);
    final account = ref.read(sessionProvider).account;
    setState(() => _sending = true);

    try {
      await WeiboApi.instance.commentReply(effectiveStatusId, target.id, text);
      if (!mounted) return;

      final optimistic = Comment(
        id: 'local_${DateTime.now().millisecondsSinceEpoch}',
        rootId: _root.id,
        createdAt: '刚刚',
        textHtml: text,
        user: account == null
            ? null
            : User(
                id: account.uid,
                name: account.screenName.isNotEmpty ? account.screenName : '我',
                avatar: account.avatar,
              ),
        replyTo: _replyTarget,
      );

      _input.clear();
      setState(() {
        _sending = false;
        _replyTarget = null;
        _root = _root.copyWith(
          replyCount: math.max(_root.replyCount, _replies.length) + 1,
        );
        if (settings.commentByTime || _flow == 1) {
          _replies.insert(0, optimistic);
        } else {
          _replies.add(optimistic);
        }
      });
      _focus.unfocus();
      _toast('回复成功');
      // 轻延迟刷新，拉回服务端真实评论 ID 与楼层顺序
      Future<void>.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _loadInitial();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _toast('回复失败：$e');
    }
  }

  void _selectReplyTarget(Comment? target) {
    setState(() => _replyTarget = target);
    _focus.requestFocus();
  }

  void _insertEmoji(String token) {
    final sel = _input.selection;
    final current = _input.text;
    final start = sel.start < 0 ? current.length : sel.start;
    final end = sel.end < 0 ? current.length : sel.end;
    final updated = current.replaceRange(start, end, token);
    _input.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + token.length),
    );
  }

  bool _allowCommentPhotos(AppSettings settings) =>
      settings.choiceOf('show_comment_photo_options') != 3;

  void _openUser(User? user) {
    if (user == null || user.id.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UserPage(
          uid: user.id,
          initialName: user.name,
          initialAvatar: user.avatar,
        ),
      ),
    );
  }

  void _showCommentActions(Comment c, {bool isRoot = false}) {
    final plain = RichTextParser.toPlain(c.textHtml).trim();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: ShareColors.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.reply_rounded, color: ShareColors.textPrimary),
              title: Text(
                '回复 @${c.user?.name ?? '用户'}',
                style: TextStyle(color: ShareColors.textPrimary, fontSize: 14.5),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _selectReplyTarget(isRoot ? null : c);
              },
            ),
            ListTile(
              leading: Icon(Icons.copy_rounded, color: ShareColors.textPrimary),
              title: Text(
                '复制评论内容',
                style: TextStyle(color: ShareColors.textPrimary, fontSize: 14.5),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                Clipboard.setData(ClipboardData(text: plain.isEmpty ? c.textHtml : plain));
                _toast('已复制评论文字');
              },
            ),
            ListTile(
              leading: Icon(Icons.text_fields_rounded, color: ShareColors.textPrimary),
              title: Text(
                '自由复制 / 分词（TextBoom）',
                style: TextStyle(color: ShareColors.textPrimary, fontSize: 14.5),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                TextBoomDialog.show(context, c.textHtml);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final total = math.max(_root.replyCount, _replies.length);
    final allowPics = _allowCommentPhotos(settings);

    return Scaffold(
      backgroundColor: ShareColors.pageBg,
      appBar: AppBar(
        title: Text(total > 0 ? '${formatCount(total)} 条回复' : '评论详情'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Center(
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: _toggleSort,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: ShareColors.inputBg,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.sort_rounded, size: 14, color: ShareColors.textSecondary),
                      const SizedBox(width: 4),
                      Text(
                        _flow == 0 ? '按热度' : '按时间',
                        style: TextStyle(
                          fontSize: 12,
                          color: ShareColors.textSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              color: ShareColors.accent,
              onRefresh: _loadInitial,
              child: CustomScrollView(
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: _buildRootCard(settings, allowPics: allowPics),
                  ),
                  SliverToBoxAdapter(
                    child: Container(height: 8, color: ShareColors.pageBg),
                  ),
                  SliverToBoxAdapter(
                    child: Container(
                      color: ShareColors.cardBg,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                      child: Row(
                        children: [
                          Text(
                            '全部回复',
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: ShareColors.textPrimary,
                            ),
                          ),
                          if (total > 0) ...[
                            const SizedBox(width: 6),
                            Text(
                              formatCount(total),
                              style: TextStyle(
                                fontSize: 12.5,
                                color: ShareColors.textSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Divider(height: 0.5, thickness: 0.5, color: ShareColors.divider),
                  ),
                  if (_loading && _replies.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: CircularProgressIndicator(strokeWidth: 2.2)),
                    )
                  else if (_error != null && _replies.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _emptyOrError(
                        _error!,
                        actionLabel: '重试',
                        onTap: _loadInitial,
                      ),
                    )
                  else if (_replies.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _emptyOrError('暂无更多跟评，点击下方抢个楼层'),
                    )
                  else
                    SliverList.separated(
                      itemCount: _replies.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 0.5,
                        thickness: 0.5,
                        color: ShareColors.divider,
                        indent: settings.hideCommentAvatar ? 16 : 56,
                      ),
                      itemBuilder: (context, index) => _replyTile(
                        _replies[index],
                        settings,
                        allowPics: allowPics,
                      ),
                    ),
                  if (_replies.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        child: Center(
                          child: _loadingMore
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Text(
                                  _hasMore ? '上拉加载更多回复' : '没有更多回复了',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: ShareColors.textHint,
                                  ),
                                ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          _buildReplyBar(),
        ],
      ),
    );
  }

  Widget _buildRootCard(AppSettings settings, {required bool allowPics}) {
    final user = _root.user;
    final showAvatar = !settings.hideCommentAvatar;
    final isAuthor = widget.statusAuthor.isNotEmpty &&
        user != null &&
        user.name == widget.statusAuthor;

    return InkWell(
      onTap: () => _selectReplyTarget(null),
      onLongPress: () => _showCommentActions(_root, isRoot: true),
      child: Container(
        color: ShareColors.cardBg,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showAvatar) ...[
              GestureDetector(
                onTap: () => _openUser(user),
                child: _avatarWidget(user?.avatar, size: 38, radius: settings.avatarRadius),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: GestureDetector(
                          onTap: () => _openUser(user),
                          child: Text(
                            user?.name ?? '匿名用户',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: ShareColors.textPrimary,
                            ),
                          ),
                        ),
                      ),
                      if (isAuthor) ...[
                        const SizedBox(width: 6),
                        _tagPill('作者', ShareColors.accent),
                      ],
                      if (_root.floor > 0) ...[
                        const Spacer(),
                        Text(
                          '#${_root.floor}',
                          style: TextStyle(fontSize: 11.5, color: ShareColors.textHint),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  WeiboRichText(
                    html: _root.textHtml,
                    fontSize: 15,
                    color: ShareColors.textPrimary,
                    onTapSegment: (seg) => openRichSegment(context, seg, settings: settings),
                  ),
                  if (allowPics && _root.pics.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _commentPicsStrip(_root.pics, settings),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text(
                        formatWeiboTime(_root.createdAt),
                        style: TextStyle(fontSize: 11.5, color: ShareColors.textHint),
                      ),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () => _selectReplyTarget(null),
                        child: Text(
                          '回复',
                          style: TextStyle(
                            fontSize: 12,
                            color: ShareColors.link,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (_root.likedByAuthor) ...[
                        const SizedBox(width: 8),
                        _tagPill('作者赞过', Colors.orange),
                      ],
                      const Spacer(),
                      _likeButton(_root, isRoot: true),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _replyTile(Comment c, AppSettings settings, {required bool allowPics}) {
    final user = c.user;
    final showAvatar = !settings.hideCommentAvatar;
    final isAuthor = widget.statusAuthor.isNotEmpty &&
        user != null &&
        user.name == widget.statusAuthor;

    final replyToName = c.replyTo?.user?.displayName.trim() ?? '';
    final plain = RichTextParser.toPlain(c.textHtml).trimLeft();
    final needsReplyPrefix = replyToName.isNotEmpty &&
        !plain.startsWith('回复@$replyToName') &&
        !plain.startsWith('回复 @$replyToName');
    final displayHtml =
        needsReplyPrefix ? '回复@$replyToName：${c.textHtml}' : c.textHtml;

    return InkWell(
      onTap: () => _selectReplyTarget(c),
      onLongPress: () => _showCommentActions(c),
      child: Container(
        color: ShareColors.cardBg,
        padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showAvatar) ...[
              GestureDetector(
                onTap: () => _openUser(user),
                child: _avatarWidget(user?.avatar, size: 30, radius: settings.avatarRadius),
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
                        child: GestureDetector(
                          onTap: () => _openUser(user),
                          child: Text(
                            user?.name ?? '匿名用户',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                              color: ShareColors.textPrimary,
                            ),
                          ),
                        ),
                      ),
                      if (isAuthor) ...[
                        const SizedBox(width: 6),
                        _tagPill('作者', ShareColors.accent),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  WeiboRichText(
                    html: displayHtml,
                    fontSize: 14,
                    color: ShareColors.textPrimary,
                    onTapSegment: (seg) => openRichSegment(context, seg, settings: settings),
                  ),
                  if (allowPics && c.pics.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _commentPicsStrip(c.pics, settings),
                  ],
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        formatWeiboTime(c.createdAt),
                        style: TextStyle(fontSize: 11.5, color: ShareColors.textHint),
                      ),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () => _selectReplyTarget(c),
                        child: Text(
                          '回复',
                          style: TextStyle(fontSize: 11.5, color: ShareColors.link),
                        ),
                      ),
                      if (c.likedByAuthor) ...[
                        const SizedBox(width: 8),
                        _tagPill('作者赞过', Colors.orange),
                      ],
                      const Spacer(),
                      _likeButton(c),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _commentPicsStrip(List<Pic> pics, AppSettings settings) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (int i = 0; i < pics.length; i++)
          GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => GalleryPage(pics: pics, initialIndex: i),
              ),
            ),
            onLongPress: () => ShareActions.showPicLongPressMenu(
              context,
              pics,
              i,
              deduplicateName: settings.samePhotoName,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: _applyImageFilter(
                Image.network(
                  pics[i].url,
                  width: 82,
                  height: 82,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    width: 82,
                    height: 82,
                    color: ShareColors.placeholder,
                    child: Icon(Icons.broken_image_outlined,
                        size: 20, color: ShareColors.textHint),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _likeButton(Comment c, {bool isRoot = false}) {
    final active = c.likedByMe;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _toggleLike(c, isRoot: isRoot),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              active ? Icons.thumb_up_rounded : Icons.thumb_up_outlined,
              size: 14,
              color: active ? ShareColors.accent : ShareColors.textHint,
            ),
            if (c.likeCount > 0) ...[
              const SizedBox(width: 4),
              Text(
                formatCount(c.likeCount),
                style: TextStyle(
                  fontSize: 11.5,
                  color: active ? ShareColors.accent : ShareColors.textHint,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildReplyBar() {
    final targetName = _replyTarget?.user?.name;
    final hint = (targetName != null && targetName.isNotEmpty)
        ? '回复 @$targetName'
        : '回复 @${_root.user?.name ?? '楼主'}';

    return Container(
      decoration: BoxDecoration(
        color: ShareColors.cardBg,
        border: Border(top: BorderSide(color: ShareColors.divider, width: 0.6)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_replyTarget != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                color: ShareColors.repostBg,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '正在回复 @${_replyTarget!.user?.name ?? '用户'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: ShareColors.textSecondary,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => setState(() => _replyTarget = null),
                      child: Icon(Icons.close_rounded,
                          size: 16, color: ShareColors.textHint),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 10, 6),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      Icons.sentiment_satisfied_alt_outlined,
                      color: ShareColors.textSecondary,
                      size: 22,
                    ),
                    tooltip: '插入表情',
                    onPressed: () => showEmojiPanel(context, _insertEmoji),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _submitReply(),
                      style: TextStyle(
                        fontSize: 14,
                        color: ShareColors.textPrimary,
                      ),
                      decoration: InputDecoration(
                        hintText: hint,
                        hintStyle: TextStyle(
                          fontSize: 13.5,
                          color: ShareColors.textHint,
                        ),
                        isDense: true,
                        filled: true,
                        fillColor: ShareColors.inputBg,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 9,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _input,
                    builder: (_, value, _) {
                      final canSend = value.text.trim().isNotEmpty && !_sending;
                      return FilledButton(
                        onPressed: canSend ? _submitReply : null,
                        style: FilledButton.styleFrom(
                          backgroundColor: ShareColors.accent,
                          disabledBackgroundColor: ShareColors.inputBg,
                          minimumSize: const Size(54, 34),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        child: _sending
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                '发送',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: canSend
                                      ? Colors.white
                                      : ShareColors.textHint,
                                ),
                              ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _applyImageFilter(Widget child) {
    final filter = ShareColors.activeImageFilter;
    return filter == null ? child : ColorFiltered(colorFilter: filter, child: child);
  }

  Widget _avatarWidget(String? url, {required double size, required double radius}) {
    final borderRadius = radius >= 99 ? size / 2 : radius;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: size,
        height: size,
        child: (url != null && url.isNotEmpty)
            ? _applyImageFilter(
                Image.network(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => ColoredBox(
                    color: ShareColors.placeholder,
                    child: Icon(Icons.person, size: size * 0.55, color: ShareColors.textHint),
                  ),
                ),
              )
            : ColoredBox(
                color: ShareColors.placeholder,
                child: Icon(Icons.person, size: size * 0.55, color: ShareColors.textHint),
              ),
      ),
    );
  }

  Widget _tagPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _emptyOrError(
    String message, {
    String? actionLabel,
    VoidCallback? onTap,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: ShareColors.textSecondary),
            ),
            if (actionLabel != null && onTap != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onTap, child: Text(actionLabel)),
            ],
          ],
        ),
      ),
    );
  }
}
