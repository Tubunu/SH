import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/settings.dart';
import '../app_theme.dart';
import '../common/segment_actions.dart';
import '../common/share_actions.dart';
import '../common/status_action_sheet.dart';
import '../detail/status_detail_page.dart';
import '../media/gallery_page.dart';
import 'card_shot.dart';
import '../widgets/pic_grid.dart';
import '../widgets/weibo_rich_text.dart';

/// Feed card — reproduces the Share/Weibo status row structure:
/// avatar + identity block, body text, media grid, retweet box, action bar.
///
/// 有状态是必要的：点赞 / 收藏按钮必须在**本地**立刻变样，否则服务端成功了
/// 图标却不动，用户会以为没点上。调用方不需要自己维护这两个状态；如果调用方
/// 传了 `onLike` / `onMore`，就仍然以调用方为准（feed 列表要同步整条 item）。
class StatusCard extends ConsumerStatefulWidget {
  final Status status;
  final VoidCallback? onTap;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onLike;
  final VoidCallback? onComment;
  final VoidCallback? onRepost;
  final VoidCallback? onMore;
  final void Function(int index)? onImageTap;
  final VoidCallback? onVideoTap;
  final VoidCallback? onRetweetTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDeleted;
  final bool showActions;
  final bool showFollowButton;
  final bool showRetweet;
  final bool fullText;

  const StatusCard({
    super.key,
    required this.status,
    this.onTap,
    this.onAvatarTap,
    this.onLike,
    this.onComment,
    this.onRepost,
    this.onMore,
    this.onImageTap,
    this.onVideoTap,
    this.onRetweetTap,
    this.onLongPress,
    this.onDeleted,
    this.showActions = true,
    this.showFollowButton = false,
    this.showRetweet = true,
    this.fullText = false,
  });

  @override
  ConsumerState<StatusCard> createState() => _StatusCardState();
}

class _StatusCardState extends ConsumerState<StatusCard> {
  final GlobalKey _shotKey = GlobalKey();
  bool? _liked;
  int? _attitudes;
  bool? _favorited;
  bool _liking = false;
  String? _translatedText;
  String? _translationSource;
  bool _translating = false;

  @override
  void initState() {
    super.initState();
    registerStatusCardShotKey(widget.status.id, _shotKey);
  }

  @override
  void dispose() {
    unregisterStatusCardShotKey(widget.status.id, _shotKey);
    super.dispose();
  }

  // 转发/评论等回调仍由外部决定，这里只为少改函数体做一次转发。
  Status get status => widget.status;
  VoidCallback? get onTap => widget.onTap;
  // 头像同理：没接就自己跳主页。
  VoidCallback get onAvatarTap =>
      widget.onAvatarTap ?? () => openUserProfile(context, status.user);
  void Function(int index)? get onImageTap => widget.onImageTap;
  VoidCallback? get onVideoTap => widget.onVideoTap;
  VoidCallback? get onDeleted => widget.onDeleted;
  bool get showActions => widget.showActions;
  bool get showFollowButton => widget.showFollowButton;

  // 点赞 / 更多：调用方没接就落回内置实现，避免出现点了没反应的死按钮。
  VoidCallback? get onLike => widget.onLike ?? _internalLike;
  VoidCallback? get onComment => widget.onComment;
  VoidCallback? get onRepost => widget.onRepost;
  VoidCallback? get onMore =>
      widget.onMore ??
      () => showStatusActionSheet(
            context,
            ref,
            status,
            onDeleted: widget.onDeleted,
            onChanged: widget.onDeleted,
          );
  VoidCallback? get onLongPress => widget.onLongPress;

  bool get _isLiked => _liked ?? status.liked;
  int get _attitudeCount => _attitudes ?? status.attitudes;
  bool get _isFavorited => _favorited ?? status.favorited;

  @override
  void didUpdateWidget(covariant StatusCard old) {
    super.didUpdateWidget(old);
    if (widget.status.id != old.status.id) {
      unregisterStatusCardShotKey(old.status.id, _shotKey);
      registerStatusCardShotKey(widget.status.id, _shotKey);
      _liked = null;
      _attitudes = null;
      _favorited = null;
    } else {
      // 外部刷新回来了，以外部为准。
      if (widget.status.liked != old.status.liked) {
        _liked = null;
        _attitudes = null;
      }
      if (widget.status.favorited != old.status.favorited) {
        _favorited = null;
      }
    }
  }

  /// 内部兜底：调用方没接 onLike 时，卡片自己完成点赞并翻转图标。
  Future<void> _internalLike() async {
    if (_liking) return;
    final wasLiked = _isLiked;
    final before = _attitudeCount;
    setState(() {
      _liking = true;
      _liked = !wasLiked;
      _attitudes = before + (wasLiked ? -1 : 1);
    });
    try {
      await WeiboApi.instance.like(status.id, wasLiked);
    } catch (e) {
      if (!mounted) return;
      if (ref.read(settingsProvider).flag('show_like_status_error')) {
        setState(() {
          _liked = wasLiked;
          _attitudes = before;
        });
        _toast(context, _humanize(e));
      }
    } finally {
      if (mounted) setState(() => _liking = false);
    }
  }

  /// 内部兜底：收藏。原版这里点了图标要立刻变实心。
  Future<void> _internalFavorite() async {
    final wasFavorited = _isFavorited;
    setState(() => _favorited = !wasFavorited);
    try {
      await WeiboApi.instance.favorite(status.id, wasFavorited);
      if (mounted) _toast(context, wasFavorited ? '已取消收藏' : '已收藏');
    } catch (e) {
      if (!mounted) return;
      setState(() => _favorited = wasFavorited);
      _toast(context, _humanize(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final screenWidth = MediaQuery.sizeOf(context).width;
    const left = 16.0;
    final bodyIndent =
        (settings.leftIndent && !settings.hideStatusAvatar) ? 48.0 : 0.0;
    final cardInset = settings.cardStyle ? 16.0 : 0.0;
    final contentWidth = screenWidth - left * 2 - bodyIndent - cardInset;

    final card = settings.cardStyle;
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(left, 13, left, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(context, settings),
          Padding(
            padding: EdgeInsets.only(top: 10, left: bodyIndent),
            child: _body(context, contentWidth, settings),
          ),
          const SizedBox(height: 8),
          if (showActions) _actionBar(context, settings),
        ],
      ),
    );

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress ??
          () => showStatusActionSheet(
                context,
                ref,
                status,
                onDeleted: onDeleted,
                onChanged: onDeleted,
              ),
      child: RepaintBoundary(
        key: _shotKey,
        child: Container(
          margin: card ? const EdgeInsets.fromLTRB(8, 8, 8, 0) : EdgeInsets.zero,
          decoration: card
              ? BoxDecoration(
                  color: ShareColors.cardBg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: ShareColors.divider.withValues(
                      alpha: settings.cardBackground ? 0.9 : 0.65,
                    ),
                    width: 0.5,
                  ),
                  boxShadow: ShareColors.isDark || ShareColors.isTransparent
                      ? null
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.024),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                )
              : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(card ? 6 : 0),
            child: Column(
              children: [
                if (card) content else ColoredBox(color: ShareColors.cardBg, child: content),
                if (settings.cardDivider || !card) const _CardDivider(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Header: 38dp avatar + 10dp spacing + medium display name / calm "来自" metadata.
  Widget _header(BuildContext context, AppSettings settings) {
    final user = status.user;
    final meta = <String>[
      formatWeiboTime(status.createdAt),
      if (settings.showSource && status.cleanSource.isNotEmpty) '来自 ${status.cleanSource}',
      if (status.region.isNotEmpty) status.region,
    ].join('  ');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (!settings.hideStatusAvatar) ...[
          GestureDetector(
            onTap: onAvatarTap,
            child: _Avatar(
              url: user?.avatar ?? '',
              size: 38,
              radius: settings.avatarRadius,
              ring: settings.cardBackground,
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
                      (settings.nameWithRemark &&
                              user?.remark != null &&
                              user!.remark!.isNotEmpty &&
                              user.remark != user.name)
                          ? '${user.remark} (${user.name})'
                          : (user?.displayName ?? '微博用户'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: settings.nameBold ? FontWeight.w500 : FontWeight.w400,
                        color: settings.nameAccent ? ShareColors.accent : ShareColors.textPrimary,
                        height: 1.25,
                      ),
                    ),
                  ),
                  if (settings.nameIcon &&
                      settings.showVerified &&
                      (user?.verified ?? false)) ...[
                    const SizedBox(width: 4),
                    _verifiedBadge(user!.verifiedType),
                  ],
                ],
              ),
              const SizedBox(height: 3),
              Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: ShareColors.textSecondary, height: 1.2),
              ),
            ],
          ),
        ),
        if (showFollowButton && !(user?.following ?? true))
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 1),
            child: GestureDetector(
              onTap: () async {
                final uid = user?.id ?? '';
                if (uid.isEmpty) return;
                try {
                  await WeiboApi.instance.follow(uid, false);
                  if (context.mounted) _toast(context, '已关注');
                } catch (e) {
                  if (context.mounted) _toast(context, _humanize(e));
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: ShareColors.accent,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Text(
                  '关注',
                  style: TextStyle(fontSize: 11.5, color: Colors.white),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _verifiedBadge(int type) {
    // 0 -> personal (orange), 220 -> gold, others -> blue organisation
    final color = switch (type) {
      0 => const Color(0xFFFF8200),
      220 => const Color(0xFFF5B50A),
      _ => const Color(0xFF4A90D9),
    };
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(7)),
      child: const Icon(Icons.check, size: 9, color: Colors.white),
    );
  }

  Future<void> _toggleTranslate(AppSettings settings) async {
    if (_translatedText != null) {
      setState(() {
        _translatedText = null;
        _translationSource = null;
      });
      return;
    }
    if (_translating) return;
    setState(() => _translating = true);
    try {
      final res = await WeiboApi.instance.translate(
        status.mblogid.isNotEmpty ? status.mblogid : status.id,
        locale: settings.translationLocale,
      );
      if (!mounted) return;
      setState(() {
        _translatedText = res.text;
        _translationSource = res.source;
        _translating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _translating = false);
      _toast(context, _humanize(e));
    }
  }

  Widget _body(BuildContext context, double contentWidth, AppSettings settings) {
    final gridWidth = contentWidth.clamp(120.0, 330.0);
    final fs = settings.fontSize;
    final showExpandHint = !widget.fullText && status.isLongText;
    final effectiveRetweeted = status.resolvedRetweeted;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        WeiboRichText(
          html: status.textHtml,
          fontSize: fs,
          height: settings.lineSpacing,
          maxLines: widget.fullText ? null : (status.isLongText ? 9 : null),
          color: ShareColors.textPrimary,
          linkColor: ShareColors.link,
          onTapSegment: (segment) => openRichSegment(
            context,
            segment,
            settings: settings,
          ),
        ),
        if (showExpandHint)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '全文',
              style: TextStyle(fontSize: fs - 1, color: ShareColors.accent),
            ),
          ),
        if (settings.statusTranslation || _translatedText != null) ...[
          const SizedBox(height: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _toggleTranslate(settings),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                _translating
                    ? '正在翻译…'
                    : (_translatedText != null ? '收起译文' : '查看翻译'),
                style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary),
              ),
            ),
          ),
          if (_translatedText != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: ShareColors.repostBg,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _translatedText!,
                    style: TextStyle(
                      fontSize: (fs - 0.5).clamp(12, 22).toDouble(),
                      height: settings.lineSpacing,
                      color: ShareColors.textPrimary,
                    ),
                  ),
                  if (_translationSource != null && _translationSource!.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      '译自 $_translationSource',
                      style: TextStyle(fontSize: 11, color: ShareColors.textHint),
                    ),
                  ],
                ],
              ),
            ),
        ],
        if (effectiveRetweeted == null && status.hasVideoMedia) ...[
          const SizedBox(height: 10),
          GestureDetector(onTap: onVideoTap, child: _videoCover(gridWidth)),
        ] else if (status.pics.isNotEmpty) ...[
          const SizedBox(height: 10),
          PicGrid(
            pics: status.pics,
            maxWidth: gridWidth,
            onTap: onImageTap,
            onLongPress: (i) => ShareActions.showPicLongPressMenu(
              context,
              status.pics,
              i,
              deduplicateName: settings.samePhotoName,
              onViewOriginal: onImageTap == null ? null : () => onImageTap!(i),
            ),
          ),
        ],
        if (widget.showRetweet && effectiveRetweeted != null) ...[
          const SizedBox(height: 8),
          _retweetBox(context, effectiveRetweeted, gridWidth, fs, settings),
        ],
        if (settings.hotCommentPreview &&
            !widget.fullText &&
            status.hotComment != null) ...[
          const SizedBox(height: 8),
          _hotCommentPreviewBox(context, status.hotComment!, fs, settings),
        ],
      ],
    );
  }

  Widget _hotCommentPreviewBox(
    BuildContext context,
    Comment hot,
    double fs,
    AppSettings settings,
  ) {
    final author = hot.user?.displayName.trim() ?? '';
    final previewHtml = author.isNotEmpty ? '@$author：${hot.textHtml}' : hot.textHtml;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
        decoration: BoxDecoration(
          color: ShareColors.repostBg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: ShareColors.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    '热评',
                    style: TextStyle(
                      fontSize: 9.5,
                      color: ShareColors.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                if (hot.likeCount > 0) ...[
                  Icon(
                    Icons.thumb_up_alt_outlined,
                    size: 11.5,
                    color: ShareColors.textHint,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    formatCount(hot.likeCount),
                    style: TextStyle(fontSize: 11, color: ShareColors.textHint),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            WeiboRichText(
              html: previewHtml,
              fontSize: (fs - 1.5).clamp(12.0, 18.0),
              maxLines: 2,
              color: ShareColors.textSecondary,
              onTapSegment: (segment) => openRichSegment(
                context,
                segment,
                settings: settings,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _videoCover(double width, {String? coverOverride, int durationOverride = -1}) {
    final coverUrl = coverOverride ?? status.videoCover;
    final dur = durationOverride >= 0 ? durationOverride : status.videoDuration;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: (coverUrl != null && coverUrl.isNotEmpty)
                ? Image.network(
                    coverUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => ColoredBox(color: ShareColors.placeholder),
                  )
                : const ColoredBox(color: Color(0xFF1E1E22)),
          ),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 30),
          ),
          if (dur > 0)
            Positioned(
              right: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  _duration(dur),
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _duration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _openRetweetDetail(BuildContext context, Status original) {
    if (original.id.isEmpty && original.mblogid.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => StatusDetailPage(status: original)),
    );
  }

  void _openRetweetVideo(BuildContext context, Status original) {
    ShareActions.openStatusVideo(context, original);
  }

  Widget _retweetBox(
    BuildContext context,
    Status original,
    double width,
    double fs,
    AppSettings settings,
  ) {
    final prefix = (original.user?.displayName.isNotEmpty ?? false)
        ? '@${original.user!.displayName} '
        : '';
    final canOpen = original.id.isNotEmpty || original.mblogid.isNotEmpty;
    final tapHandler = widget.onRetweetTap ??
        (canOpen ? () => _openRetweetDetail(context, original) : null);

    return Material(
      color: ShareColors.repostBg,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: tapHandler,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              WeiboRichText(
                html: '$prefix${original.textHtml}',
                fontSize: (fs - 1).clamp(12, 22).toDouble(),
                height: settings.lineSpacing,
                maxLines: widget.fullText ? null : 6,
                color: ShareColors.textPrimary,
                linkColor: ShareColors.link,
                onTapSegment: (segment) => openRichSegment(
                  context,
                  segment,
                  settings: settings,
                ),
              ),
              if (original.pics.isNotEmpty) ...[
                const SizedBox(height: 8),
                PicGrid(
                  pics: original.pics,
                  maxWidth: width * 0.62,
                  onTap: (index) => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => GalleryPage(pics: original.pics, initialIndex: index),
                    ),
                  ),
                  onLongPress: (index) => ShareActions.showPicLongPressMenu(
                    context,
                    original.pics,
                    index,
                    deduplicateName: settings.samePhotoName,
                    onViewOriginal: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => GalleryPage(pics: original.pics, initialIndex: index),
                      ),
                    ),
                  ),
                ),
              ],
              if (original.hasVideoMedia) ...[
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: original.hasPlayableVideo
                      ? () => _openRetweetVideo(context, original)
                      : onVideoTap,
                  child: _videoCover(
                    width,
                    coverOverride: original.videoCover ?? '',
                    durationOverride: original.videoDuration,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 卡片底栏 —— 轻量化 17dp 图标 + 0.5dp 顶部细线，无数字时隐藏 '0'。
  Widget _actionBar(BuildContext context, AppSettings settings) {
    if (!settings.showOptions) return const SizedBox(height: 8);
    Widget slot(int flex, Widget child) =>
        Expanded(flex: flex, child: Center(child: child));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Divider(
          height: 0.5,
          thickness: 0.5,
          color: ShareColors.divider.withValues(alpha: 0.7),
        ),
        SizedBox(
          height: 38,
          child: Row(
            children: [
              slot(
                2,
                _action(
                  Icons.repeat_rounded,
                  status.reposts > 0 ? formatCount(status.reposts) : '',
                  onRepost,
                  onLongPress: () => _quickRepost(context),
                ),
              ),
              slot(
                2,
                _action(
                  Icons.chat_bubble_outline_rounded,
                  status.comments > 0 ? formatCount(status.comments) : '',
                  onComment,
                  onLongPress: () => _quickComment(context),
                  iconSize: 16,
                ),
              ),
              slot(
                2,
                _action(
                  _isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  _attitudeCount > 0 ? formatCount(_attitudeCount) : '',
                  // `like_status_long_click` 打开后，长按才是点赞（防误触）。
                  settings.likeLongPress ? null : onLike,
                  onLongPress: settings.likeLongPress ? onLike : null,
                  highlighted: _isLiked,
                ),
              ),
              if (settings.showCollect)
                slot(
                  1,
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _internalFavorite,
                    child: Icon(
                      _isFavorited ? Icons.star_rounded : Icons.star_border_rounded,
                      size: 18,
                      color: _isFavorited ? ShareColors.accent : ShareColors.textSecondary,
                    ),
                  ),
                ),
              slot(
                1,
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onMore,
                  child: Icon(Icons.more_horiz_rounded, size: 18, color: ShareColors.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 快转（`direct_repost`）：不进发布器，直接以「转发微博」发出。
  Future<void> _quickRepost(BuildContext context) async {
    try {
      await WeiboApi.instance.repost(status.id, '转发微博');
      if (context.mounted) _toast(context, '已快转');
    } catch (e) {
      if (context.mounted) _toast(context, _humanize(e));
    }
  }

  /// 长按评论 = 原地快速评论。
  Future<void> _quickComment(BuildContext context) async {
    final text = await showTextInputDialog(
      context,
      title: '评论',
      hint: '说点什么…',
      multiline: true,
      confirmText: '发送',
    );
    if (text == null || text.isEmpty) return;
    try {
      await WeiboApi.instance.comment(status.id, text);
      if (context.mounted) _toast(context, '评论成功');
    } catch (e) {
      if (context.mounted) _toast(context, _humanize(e));
    }
  }

  Widget _action(
    IconData icon,
    String label,
    VoidCallback? onTap, {
    VoidCallback? onLongPress,
    bool highlighted = false,
    double iconSize = 17,
  }) {
    final color = highlighted ? ShareColors.accent : ShareColors.textSecondary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: iconSize, color: color),
            if (label.isNotEmpty) ...[
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w400,
                  color: color,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

void _toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
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

class _Avatar extends StatelessWidget {
  final String url;
  final double size;
  final double radius;
  final bool ring;

  const _Avatar({required this.url, this.size = 42, this.radius = 100, this.ring = false});

  @override
  Widget build(BuildContext context) {
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        width: size,
        height: size,
        color: ShareColors.placeholder,
        child: url.isEmpty
            ? const Icon(Icons.person, color: Colors.white, size: 22)
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Icon(Icons.person, color: ShareColors.textHint, size: 22),
              ),
      ),
    );

    // 显示头像框: a hairline ring around the avatar, as the original draws it.
    if (!ring) return image;
    return Container(
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius + 2),
        border: Border.all(color: ShareColors.divider, width: 0.8),
      ),
      child: image,
    );
  }
}

/// 卡片底部 1dp 分割线（原版 `kp.xml` 末尾的 View，高 `@dimen/gm`）。
class _CardDivider extends StatelessWidget {
  const _CardDivider();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 1,
      child: ColoredBox(color: ShareColors.divider),
    );
  }
}
