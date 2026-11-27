import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/settings.dart';
import '../app_theme.dart';

/// 混排九宫格中的视频格子信息。
class PicGridVideo {
  final String? coverUrl;
  final int durationSeconds;
  final VoidCallback? onTap;

  const PicGridVideo({
    this.coverUrl,
    this.durationSeconds = 0,
    this.onTap,
  });
}

class _GridEntry {
  final Pic? pic;
  final int? picIndex;
  final PicGridVideo? video;

  const _GridEntry.pic(this.pic, this.picIndex) : video = null;
  const _GridEntry.video(this.video)
      : pic = null,
        picIndex = null;
}

/// Weibo image (and mixed image + video) grid.
///
/// Mirrors Share/Weibo `GridGalleryView` rules:
/// * 1 image  -> single, max width 72%, aspect ratio clamped to 0.6 .. 1.9
/// * 2 items  -> 2 columns (2x1), ~72% width
/// * 4 items  -> 2 x 2 square grid, ~72% width
/// * 3 / 5..9 -> 3 columns full-width square grid (including mixed video tile)
///
/// Honours 无图模式: a tappable placeholder is shown until the reader asks for
/// the images.
class PicGrid extends ConsumerStatefulWidget {
  final List<Pic> pics;
  final PicGridVideo? video;
  final int? videoIndex;
  final void Function(int index)? onTap;
  final void Function(int index)? onLongPress;
  final double maxWidth;

  const PicGrid({
    super.key,
    required this.pics,
    this.video,
    this.videoIndex,
    this.onTap,
    this.onLongPress,
    this.maxWidth = 300,
  });

  @override
  ConsumerState<PicGrid> createState() => _PicGridState();
}

class _PicGridState extends ConsumerState<PicGrid> {
  bool _revealed = false;

  List<_GridEntry> _buildEntries() {
    final pics = widget.pics;
    final entries = <_GridEntry>[
      for (var i = 0; i < pics.length; i++) _GridEntry.pic(pics[i], i),
    ];
    final video = widget.video;
    if (video != null) {
      final insertAt = (widget.videoIndex ?? pics.length).clamp(0, entries.length);
      entries.insert(insertAt, _GridEntry.video(video));
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final pics = widget.pics;
    final video = widget.video;
    if (pics.isEmpty && video == null) return const SizedBox.shrink();

    final loadImages = ref.watch(settingsProvider).loadImageOnMobile;
    if (!loadImages && !_revealed) {
      final label = video != null && pics.isNotEmpty
          ? '${pics.length} 张图片 · 1 个视频 · 点击加载'
          : (pics.isNotEmpty ? '${pics.length} 张图片 · 点击加载' : '1 个视频 · 点击加载');
      return GestureDetector(
        onTap: () => setState(() => _revealed = true),
        child: Container(
          width: widget.maxWidth,
          height: (pics.length + (video != null ? 1 : 0)) == 1 ? 120 : 96,
          decoration: BoxDecoration(
            color: ShareColors.repostBg,
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.image_outlined, size: 18, color: ShareColors.textSecondary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    final entries = _buildEntries();
    return LayoutBuilder(
      builder: (context, constraints) {
        final effectiveMaxWidth = constraints.hasBoundedWidth
            ? math.min(widget.maxWidth, constraints.maxWidth)
            : widget.maxWidth;
        if (effectiveMaxWidth <= 0) return const SizedBox.shrink();

        if (entries.length == 1 && entries.first.pic != null) {
          final pic = entries.first.pic!;
          final ratio = pic.aspectRatio.clamp(0.6, 1.9);
          final badge = _badgeLabel(pic);
          final singleWidth =
              (effectiveMaxWidth * 0.72).clamp(120.0, effectiveMaxWidth).toDouble();
          return Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: singleWidth,
              child: GestureDetector(
                onTap: () => widget.onTap?.call(0),
                onLongPress: widget.onLongPress == null
                    ? null
                    : () => widget.onLongPress!(0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: AspectRatio(
                    aspectRatio: ratio,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _image(pic.url, fit: BoxFit.cover, width: 720),
                        if (badge != null) _badgeOverlay(badge),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        final displayCount = math.min(entries.length, 9);
        final overflowCount = entries.length - 9;
        final isTwoColumn = displayCount == 2 || displayCount == 4;
        final columns = isTwoColumn ? 2 : 3;
        const spacing = 4.5;
        final double totalWidth = isTwoColumn
            ? (effectiveMaxWidth * 0.72)
                .clamp(math.min(effectiveMaxWidth, 160.0), effectiveMaxWidth)
                .toDouble()
            : effectiveMaxWidth;
        final itemSize =
            ((totalWidth - spacing * (columns - 1)) / columns).floorToDouble();
        final gridWidth = itemSize * columns + spacing * (columns - 1);
        final rows = (displayCount / columns).ceil();

        return Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: gridWidth,
            child: Column(
              children: List.generate(rows, (row) {
                return Padding(
                  padding: EdgeInsets.only(bottom: row == rows - 1 ? 0 : spacing),
                  child: Row(
                    children: List.generate(columns, (col) {
                      final cellIndex = row * columns + col;
                      if (cellIndex >= displayCount) {
                        return SizedBox(width: itemSize, height: itemSize);
                      }
                      final entry = entries[cellIndex];
                      final showOverflow = overflowCount > 0 && cellIndex == 8;
                      return Padding(
                        padding:
                            EdgeInsets.only(right: col == columns - 1 ? 0 : spacing),
                        child: entry.video != null
                            ? _buildVideoCell(
                                entry.video!,
                                size: itemSize,
                                overflowCount: showOverflow ? overflowCount : 0,
                              )
                            : _buildPicCell(
                                entry.pic!,
                                picIndex: entry.picIndex!,
                                size: itemSize,
                                overflowCount: showOverflow ? overflowCount : 0,
                              ),
                      );
                    }),
                  ),
                );
              }),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPicCell(
    Pic pic, {
    required int picIndex,
    required double size,
    required int overflowCount,
  }) {
    final badge = _badgeLabel(pic);
    final showOverflow = overflowCount > 0;
    return GestureDetector(
      onTap: () => widget.onTap?.call(picIndex),
      onLongPress: widget.onLongPress == null
          ? null
          : () => widget.onLongPress!(picIndex),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _image(pic.url, fit: BoxFit.cover, width: 360),
              if (badge != null && !showOverflow) _badgeOverlay(badge),
              if (showOverflow) _overflowScrim(overflowCount),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoCell(
    PicGridVideo video, {
    required double size,
    required int overflowCount,
  }) {
    final showOverflow = overflowCount > 0;
    final cover = video.coverUrl;
    return GestureDetector(
      onTap: video.onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (cover != null && cover.isNotEmpty)
                _image(cover, fit: BoxFit.cover, width: 360)
              else
                const ColoredBox(color: Color(0xFF1E1E22)),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.center,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0x66000000)],
                  ),
                ),
              ),
              if (!showOverflow)
                Center(
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
              if (!showOverflow && video.durationSeconds > 0)
                _badgeOverlay(_formatDuration(video.durationSeconds)),
              if (showOverflow) _overflowScrim(overflowCount),
            ],
          ),
        ),
      ),
    );
  }

  Widget _overflowScrim(int overflowCount) {
    return Container(
      color: Colors.black54,
      alignment: Alignment.center,
      child: Text(
        '+$overflowCount',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  static String _formatDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  static String? _badgeLabel(Pic pic) {
    if (pic.isGif) return 'GIF';
    if (pic.isLongImage) return '长图';
    return null;
  }

  Widget _badgeOverlay(String label) {
    return Positioned(
      right: 4,
      bottom: 4,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 9.5,
            fontWeight: FontWeight.w600,
            height: 1.15,
          ),
        ),
      ),
    );
  }

  /// Weibo serves the same asset at several sizes; the API hands us the
  /// `orj960` variant, which is far too heavy for a 3-column grid.
  static String _thumb(String url, {int width = 360}) {
    return url
        .replaceFirst('/orj1080/', '/wap$width/')
        .replaceFirst('/orj960/', '/wap$width/')
        .replaceFirst('/large/', '/wap$width/')
        .replaceFirst('/bmiddle/', '/wap$width/');
  }

  Widget _image(String url, {BoxFit fit = BoxFit.cover, int width = 360}) {
    final filter = ShareColors.activeImageFilter;
    final img = Image.network(
      _thumb(url, width: width),
      cacheWidth: width,
      fit: fit,
      gaplessPlayback: true,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return ColoredBox(
          color: ShareColors.placeholder,
          child: Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                value: progress.expectedTotalBytes != null
                    ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
                    : null,
              ),
            ),
          ),
        );
      },
      errorBuilder: (_, _, _) => ColoredBox(
        color: ShareColors.placeholder,
        child: Icon(Icons.broken_image_outlined, color: ShareColors.textHint, size: 24),
      ),
    );
    if (filter == null) return img;
    return ColorFiltered(colorFilter: filter, child: img);
  }
}
