import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/settings.dart';
import '../app_theme.dart';

/// Weibo image grid.
///
/// Mirrors the original `GridGalleryView` rules:
/// * 1 image  -> single, max width 70%, aspect ratio clamped to 3:4 .. 4:3
/// * 2 images -> two squares side by side
/// * 4 images -> 2 x 2
/// * 3 / 5..9 -> 3 columns of squares
///
/// Honours 无图模式: a tappable placeholder is shown until the reader asks for
/// the images.
class PicGrid extends ConsumerStatefulWidget {
  final List<Pic> pics;
  final void Function(int index)? onTap;
  final void Function(int index)? onLongPress;
  final double maxWidth;

  const PicGrid({
    super.key,
    required this.pics,
    this.onTap,
    this.onLongPress,
    this.maxWidth = 300,
  });

  @override
  ConsumerState<PicGrid> createState() => _PicGridState();
}

class _PicGridState extends ConsumerState<PicGrid> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final pics = widget.pics;
    if (pics.isEmpty) return const SizedBox.shrink();

    final loadImages = ref.watch(settingsProvider).loadImageOnMobile;
    if (!loadImages && !_revealed) {
      return GestureDetector(
        onTap: () => setState(() => _revealed = true),
        child: Container(
          width: widget.maxWidth,
          height: pics.length == 1 ? 120 : 96,
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
                '${pics.length} 张图片 · 点击加载',
                style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    if (pics.length == 1) {
      final pic = pics.first;
      final ratio = pic.aspectRatio.clamp(0.6, 1.9);
      final badge = _badgeLabel(pic);
      return GestureDetector(
        onTap: () => widget.onTap?.call(0),
        onLongPress: widget.onLongPress == null ? null : () => widget.onLongPress!(0),
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
      );
    }

    final displayCount = math.min(pics.length, 9);
    final overflowCount = pics.length - 9;
    final columns = displayCount == 2 || displayCount == 4 ? 2 : 3;
    const spacing = 4.0;
    final totalWidth = widget.maxWidth;
    final itemSize = (totalWidth - spacing * (columns - 1)) / columns;
    final rows = (displayCount / columns).ceil();

    return SizedBox(
      width: totalWidth,
      child: Column(
        children: List.generate(rows, (row) {
          return Padding(
            padding: EdgeInsets.only(bottom: row == rows - 1 ? 0 : spacing),
            child: Row(
              children: List.generate(columns, (col) {
                final index = row * columns + col;
                if (index >= displayCount) {
                  return SizedBox(width: itemSize, height: itemSize);
                }
                final pic = pics[index];
                final badge = _badgeLabel(pic);
                final showOverflow = overflowCount > 0 && index == 8;
                return Padding(
                  padding: EdgeInsets.only(right: col == columns - 1 ? 0 : spacing),
                  child: GestureDetector(
                    onTap: () => widget.onTap?.call(index),
                    onLongPress:
                        widget.onLongPress == null ? null : () => widget.onLongPress!(index),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        width: itemSize,
                        height: itemSize,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _image(pic.url, fit: BoxFit.cover, width: 360),
                            if (badge != null && !showOverflow) _badgeOverlay(badge),
                            if (showOverflow)
                              Container(
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
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          );
        }),
      ),
    );
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
