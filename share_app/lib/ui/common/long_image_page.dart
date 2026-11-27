import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../app_theme.dart';
import 'share_actions.dart';
import '../widgets/qr_code_box.dart';
import '../widgets/weibo_rich_text.dart';

/// 1:1 复刻原版 Share「生成长图」预览与导出页面（`C6263ooOoooO` / `C6261ooOooo0O`）。
///
/// 支持：
/// * 自动拉取长微博全文（含被转发原博），绝不在长图里截断文字
/// * 垂直堆叠高清原图（可开关隐藏/显示配图）
/// * 可选附加热门评论列表（`0 / 3 / 5 / 10` 条，「以下为部分评论」）
/// * 可选背景斜向水印、夜间深色长图、底部 Share 二维码
class LongImagePage extends StatefulWidget {
  final Status status;
  final List<Comment> initialComments;

  const LongImagePage({
    super.key,
    required this.status,
    this.initialComments = const [],
  });

  @override
  State<LongImagePage> createState() => _LongImagePageState();
}

class _LongImagePageState extends State<LongImagePage> {
  final GlobalKey _posterKey = GlobalKey();
  late Status _status;
  List<Comment> _comments = const [];
  bool _loadingDetails = true;
  bool _exporting = false;

  int _commentLimit = 3; // 0, 3, 5, 10
  bool _showImages = true;
  bool _showQrFooter = true;
  bool _showWatermark = false;
  bool _darkCanvas = false;

  @override
  void initState() {
    super.initState();
    _status = widget.status;
    _comments = widget.initialComments;
    _darkCanvas = ShareColors.isDark;
    _prepareData();
  }

  Future<void> _prepareData() async {
    Status expanded = _status;
    try {
      expanded = await WeiboApi.instance.expandStatusLongText(_status);
    } catch (_) {}

    List<Comment> loadedComments = _comments;
    if (loadedComments.isEmpty && _status.comments > 0) {
      try {
        final page = await WeiboApi.instance.comments(
          statusId: _status.id,
          authorUid: _status.user?.id ?? '',
          flow: 0,
          count: 15,
        );
        loadedComments = page.items;
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _status = expanded;
      _comments = loadedComments;
      _loadingDetails = false;
    });
  }

  List<String> _posterImageUrls() {
    if (!_showImages) return const [];
    final urls = <String>[];
    for (final p in _status.pics) {
      final u = p.large ?? p.url;
      if (u.isNotEmpty) urls.add(u);
    }
    final rt = _status.retweeted;
    if (rt != null) {
      for (final p in rt.pics) {
        final u = p.large ?? p.url;
        if (u.isNotEmpty) urls.add(u);
      }
    }
    return urls;
  }

  Future<void> _precachePosterImages() async {
    final urls = <String>[
      if (_status.user?.avatar.isNotEmpty == true) _status.user!.avatar,
      if (_status.retweeted?.user?.avatar.isNotEmpty == true)
        _status.retweeted!.user!.avatar,
      ..._posterImageUrls(),
    ];
    for (final c in _visibleComments) {
      if (c.user?.avatar.isNotEmpty == true) urls.add(c.user!.avatar);
    }
    await Future.wait(
      urls.toSet().map((url) async {
        try {
          if (!mounted) return;
          await precacheImage(NetworkImage(url), context)
              .timeout(const Duration(seconds: 6));
        } catch (_) {}
      }),
    );
  }

  List<Comment> get _visibleComments => _commentLimit <= 0
      ? const []
      : _comments.take(_commentLimit).toList(growable: false);

  Future<Uint8List?> _capturePosterBytes() async {
    setState(() => _exporting = true);
    try {
      await _precachePosterImages();
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final boundary =
          _posterKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 2.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _saveToGallery() async {
    if (_exporting) return;
    final bytes = await _capturePosterBytes();
    if (bytes == null) {
      if (mounted) _toast('长图渲染失败，请等待图片加载完成后重试');
      return;
    }
    final granted = await Gal.hasAccess() || await Gal.requestAccess();
    if (!granted) {
      if (mounted) _toast('没有相册权限，无法保存长图');
      return;
    }
    try {
      await Gal.putImageBytes(
        bytes,
        album: 'Share',
        name: 'share_long_${_status.id}_${DateTime.now().millisecondsSinceEpoch}',
      );
      if (mounted) _toast('长图已保存到相册 (Share)');
    } on GalException catch (e) {
      if (mounted) _toast('保存失败：${e.type.message}');
    }
  }

  Future<void> _shareLongImage() async {
    if (_exporting) return;
    final bytes = await _capturePosterBytes();
    if (bytes == null) {
      if (mounted) _toast('长图渲染失败，请重试');
      return;
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/share_long_${_status.id}.png');
    await file.writeAsBytes(bytes);
    if (!mounted) return;
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: 'image/png')],
      text: ShareActions.statusShareText(_status),
    ));
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = _darkCanvas ? const Color(0xFF1A1C20) : const Color(0xFFFFFFFF);
    final repostBg = _darkCanvas ? const Color(0xFF25282E) : const Color(0xFFF5F6F8);
    final textPrimary = _darkCanvas ? const Color(0xFFE7E9EC) : const Color(0xFF1F2229);
    final textSecondary = _darkCanvas ? const Color(0xFF98A0AB) : const Color(0xFF7D828D);
    final dividerColor = _darkCanvas ? const Color(0xFF2C3038) : const Color(0xFFEBECEF);

    return Scaffold(
      backgroundColor: _darkCanvas ? const Color(0xFF111215) : const Color(0xFFECEEF2),
      appBar: AppBar(
        title: const Text('生成长图'),
        actions: [
          IconButton(
            tooltip: '保存长图',
            onPressed: _exporting ? null : _saveToGallery,
            icon: const Icon(Icons.download_rounded),
          ),
          IconButton(
            tooltip: '分享长图',
            onPressed: _exporting ? null : _shareLongImage,
            icon: const Icon(Icons.ios_share_rounded),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              if (_loadingDetails) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: InteractiveViewer(
                  minScale: 0.6,
                  maxScale: 2.5,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                    child: Center(
                      child: SizedBox(
                        width: 380,
                        child: Container(
                          decoration: BoxDecoration(
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.12),
                                blurRadius: 16,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: RepaintBoundary(
                            key: _posterKey,
                            child: _PosterCanvas(
                              status: _status,
                              comments: _visibleComments,
                              showImages: _showImages,
                              showQrFooter: _showQrFooter,
                              showWatermark: _showWatermark,
                              bgColor: bgColor,
                              repostBg: repostBg,
                              textPrimary: textPrimary,
                              textSecondary: textSecondary,
                              dividerColor: dividerColor,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              _controlBar(),
            ],
          ),
          if (_exporting)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.35),
                child: const Center(
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 12),
                          Text('正在生成高清长图…'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _controlBar() {
    return Material(
      color: ShareColors.cardBg,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _choiceChip(
                      '评论: ${_commentLimit == 0 ? '无' : '$_commentLimit条'}',
                      selected: _commentLimit > 0,
                      onTap: _cycleCommentLimit,
                    ),
                    const SizedBox(width: 8),
                    _choiceChip(
                      '配图',
                      selected: _showImages,
                      onTap: () => setState(() => _showImages = !_showImages),
                    ),
                    const SizedBox(width: 8),
                    _choiceChip(
                      '二维码',
                      selected: _showQrFooter,
                      onTap: () => setState(() => _showQrFooter = !_showQrFooter),
                    ),
                    const SizedBox(width: 8),
                    _choiceChip(
                      '水印',
                      selected: _showWatermark,
                      onTap: () => setState(() => _showWatermark = !_showWatermark),
                    ),
                    const SizedBox(width: 8),
                    _choiceChip(
                      '深色背景',
                      selected: _darkCanvas,
                      onTap: () => setState(() => _darkCanvas = !_darkCanvas),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _exporting ? null : _shareLongImage,
                      icon: const Icon(Icons.ios_share_rounded, size: 18),
                      label: const Text('分享长图'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: _exporting ? null : _saveToGallery,
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: const Text('保存到相册'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _cycleCommentLimit() {
    setState(() {
      _commentLimit = switch (_commentLimit) {
        0 => 3,
        3 => 5,
        5 => 10,
        _ => 0,
      };
    });
  }

  Widget _choiceChip(
    String label, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? ShareColors.accent.withValues(alpha: 0.14)
              : ShareColors.inputBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? ShareColors.accent : ShareColors.divider,
            width: 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
            color: selected ? ShareColors.accent : ShareColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _PosterCanvas extends StatelessWidget {
  final Status status;
  final List<Comment> comments;
  final bool showImages;
  final bool showQrFooter;
  final bool showWatermark;
  final Color bgColor;
  final Color repostBg;
  final Color textPrimary;
  final Color textSecondary;
  final Color dividerColor;

  const _PosterCanvas({
    required this.status,
    required this.comments,
    required this.showImages,
    required this.showQrFooter,
    required this.showWatermark,
    required this.bgColor,
    required this.repostBg,
    required this.textPrimary,
    required this.textSecondary,
    required this.dividerColor,
  });

  @override
  Widget build(BuildContext context) {
    final user = status.user;
    final metaParts = <String>[
      formatWeiboTime(status.createdAt),
      if (status.cleanSource.isNotEmpty) '来自 ${status.cleanSource}',
      if (status.region.isNotEmpty) status.region,
    ];
    final effectiveRetweeted = status.resolvedRetweeted;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Author header
        Row(
          children: [
            ClipOval(
              child: SizedBox(
                width: 44,
                height: 44,
                child: (user?.avatar.isNotEmpty == true)
                    ? Image.network(user!.avatar, fit: BoxFit.cover)
                    : ColoredBox(color: dividerColor),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          user?.displayName ?? '微博用户',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: textPrimary,
                          ),
                        ),
                      ),
                      if (user?.verified == true) ...[
                        const SizedBox(width: 5),
                        Icon(
                          Icons.verified,
                          size: 15,
                          color: user!.verifiedType == 0
                              ? const Color(0xFFFF8200)
                              : const Color(0xFF4A90D9),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    (user?.verifiedReason.isNotEmpty == true)
                        ? user!.verifiedReason
                        : metaParts.join('  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: textSecondary),
                  ),
                  if (user?.verifiedReason.isNotEmpty == true) ...[
                    const SizedBox(height: 2),
                    Text(
                      metaParts.join('  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: textSecondary),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Divider(height: 1, thickness: 0.7, color: dividerColor),
        const SizedBox(height: 14),

        // Full untruncated body
        WeiboRichText(
          html: status.textHtml,
          fontSize: 16,
          height: 1.55,
          color: textPrimary,
          linkColor: ShareColors.link,
        ),

        // Original images stacked vertically
        if (showImages && status.pics.isNotEmpty) ...[
          const SizedBox(height: 14),
          _stackedImages(status.pics),
        ] else if (effectiveRetweeted == null &&
            status.isVideo &&
            status.videoCover != null &&
            status.videoCover!.isNotEmpty) ...[
          const SizedBox(height: 14),
          _videoPosterCover(status.videoCover!),
        ],

        // Quoted retweet box (also untruncated)
        if (effectiveRetweeted != null) ...[
          const SizedBox(height: 14),
          _retweetSection(effectiveRetweeted),
        ],

        const SizedBox(height: 16),
        Text(
          '转发 ${formatCount(status.reposts)}   评论 ${formatCount(status.comments)}   赞 ${formatCount(status.attitudes)}',
          style: TextStyle(fontSize: 12, color: textSecondary),
        ),

        // Optional selected comments ("以下为部分评论")
        if (comments.isNotEmpty) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: Divider(height: 1, color: dividerColor)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  '以下为部分评论',
                  style: TextStyle(fontSize: 11.5, color: textSecondary),
                ),
              ),
              Expanded(child: Divider(height: 1, color: dividerColor)),
            ],
          ),
          const SizedBox(height: 10),
          for (final c in comments) _commentRow(c),
        ],

        // QR Code & Share footer
        if (showQrFooter) ...[
          const SizedBox(height: 16),
          Divider(height: 1, thickness: 0.7, color: dividerColor),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: ShareColors.accent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'Share',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: ShareColors.accent,
                            ),
                          ),
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            '@${user?.displayName ?? '微博'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '长按或扫码查看原微博正文',
                      style: TextStyle(fontSize: 11.5, color: textSecondary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      ShareActions.statusLink(status),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              QrCodeBox(data: ShareActions.statusLink(status), size: 66),
            ],
          ),
        ],
      ],
    );

    return ColoredBox(
      color: bgColor,
      child: Stack(
        children: [
          if (showWatermark)
            Positioned.fill(
              child: CustomPaint(
                painter: _WatermarkPainter(
                  '@${user?.displayName ?? 'Share'} · Share',
                  textSecondary.withValues(alpha: 0.08),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
            child: body,
          ),
        ],
      ),
    );
  }

  Widget _stackedImages(List<Pic> pics) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < pics.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.network(
              pics[i].large ?? pics[i].url,
              fit: BoxFit.fitWidth,
              errorBuilder: (_, _, _) => Container(
                height: 120,
                color: dividerColor,
                alignment: Alignment.center,
                child: Icon(Icons.broken_image_outlined, color: textSecondary),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _retweetSection(Status original) {
    final prefix = (original.user?.displayName.isNotEmpty ?? false)
        ? '@${original.user!.displayName} '
        : '';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: repostBg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          WeiboRichText(
            html: '$prefix${original.textHtml}',
            fontSize: 14.5,
            height: 1.5,
            color: textPrimary,
            linkColor: ShareColors.link,
          ),
          if (showImages && original.pics.isNotEmpty) ...[
            const SizedBox(height: 10),
            _stackedImages(original.pics),
          ] else if (original.isVideo &&
              original.videoCover != null &&
              original.videoCover!.isNotEmpty) ...[
            const SizedBox(height: 10),
            _videoPosterCover(original.videoCover!),
          ],
        ],
      ),
    );
  }

  Widget _videoPosterCover(String coverUrl) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Image.network(coverUrl, fit: BoxFit.cover),
          ),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.play_arrow_rounded,
              color: Colors.white,
              size: 26,
            ),
          ),
        ],
      ),
    );
  }

  Widget _commentRow(Comment c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipOval(
            child: SizedBox(
              width: 26,
              height: 26,
              child: (c.user?.avatar.isNotEmpty == true)
                  ? Image.network(c.user!.avatar, fit: BoxFit.cover)
                  : ColoredBox(color: dividerColor),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        c.user?.displayName ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      formatWeiboTime(c.createdAt),
                      style: TextStyle(fontSize: 10.5, color: textSecondary),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                WeiboRichText(
                  html: c.textHtml,
                  fontSize: 13.5,
                  height: 1.4,
                  color: textPrimary,
                  linkColor: ShareColors.link,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WatermarkPainter extends CustomPainter {
  final String text;
  final Color color;

  _WatermarkPainter(this.text, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w500),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    const stepX = 165.0;
    const stepY = 120.0;
    for (double y = -size.width; y < size.height + size.width; y += stepY) {
      for (double x = -100; x < size.width + 120; x += stepX) {
        canvas.save();
        canvas.translate(x, y);
        canvas.rotate(-math.pi / 8);
        painter.paint(canvas, Offset.zero);
        canvas.restore();
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WatermarkPainter old) =>
      old.text != text || old.color != color;
}
