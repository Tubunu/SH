import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/settings.dart';
import '../common/share_actions.dart';

/// Full-screen image viewer: swipe horizontally, pinch to zoom, drag down to
/// dismiss — the same gesture set as the original `GalleryActivity`.
class GalleryPage extends ConsumerStatefulWidget {
  final List<Pic> pics;
  final int initialIndex;

  const GalleryPage({super.key, required this.pics, this.initialIndex = 0});

  @override
  ConsumerState<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends ConsumerState<GalleryPage> {
  final Set<int> _originalIndexes = {};

  String _urlForIndex(int index) {
    final pic = widget.pics[index];
    final base = pic.large ?? pic.url;
    return _originalIndexes.contains(index) ? ShareActions.originalUrl(base) : base;
  }

  String get _currentUrl => _urlForIndex(_index);
  late final PageController _controller;
  late int _index;
  double _dragOffset = 0;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _showImageMenu(int index) async {
    final pic = widget.pics[index];
    final baseUrl = pic.large ?? pic.url;
    final origUrl = ShareActions.originalUrl(baseUrl);
    final isShowingOrig = _originalIndexes.contains(index) || baseUrl == origUrl;
    final dedup = ref.read(settingsProvider).samePhotoName;
    await ShareActions.showPicLongPressMenu(
      context,
      widget.pics,
      index,
      deduplicateName: dedup,
      onViewOriginal: isShowingOrig
          ? null
          : () {
              setState(() => _originalIndexes.add(index));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('正在加载原图'), behavior: SnackBarBehavior.floating),
              );
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final allowDragBack = settings.flag('drag_photo_back');
    final allowClickBack = settings.flag('click_photo_back');
    final opacity = (1 - _dragOffset.abs() / 400).clamp(0.2, 1.0);

    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: opacity),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: allowDragBack
            ? (details) => setState(() => _dragOffset += details.delta.dy)
            : null,
        onVerticalDragEnd: allowDragBack
            ? (_) {
                if (_dragOffset.abs() > 120) {
                  Navigator.of(context).maybePop();
                } else {
                  setState(() => _dragOffset = 0);
                }
              }
            : null,
        child: Transform.translate(
          offset: Offset(0, _dragOffset),
          child: Stack(
            children: [
              PageView.builder(
                controller: _controller,
                itemCount: widget.pics.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, index) {
                  final imgUrl = _urlForIndex(index);
                  return GestureDetector(
                    onTap: allowClickBack ? () => Navigator.of(context).maybePop() : null,
                    onLongPress: () => _showImageMenu(index),
                    child: InteractiveViewer(
                      minScale: 1,
                      maxScale: 4,
                      child: Center(
                        child: Image.network(
                          imgUrl,
                          fit: BoxFit.contain,
                          loadingBuilder: (context, child, progress) {
                            if (progress == null) return child;
                            return const Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white70),
                              ),
                            );
                          },
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.broken_image_outlined,
                            color: Colors.white38,
                            size: 40,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              Positioned(
                top: MediaQuery.paddingOf(context).top + 8,
                left: 8,
                right: 8,
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${_index + 1}/${widget.pics.length}',
                        style: const TextStyle(color: Colors.white, fontSize: 12.5),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: '保存图片',
                      icon: const Icon(Icons.download_rounded, color: Colors.white),
                      onPressed: () {
                        if (widget.pics.length > 1) {
                          _showImageMenu(_index);
                          return;
                        }
                        ShareActions.saveImage(
                          context,
                          _currentUrl,
                          original: true,
                          deduplicateName: settings.samePhotoName,
                        );
                      },
                    ),
                    IconButton(
                      tooltip: '更多操作',
                      icon: const Icon(Icons.more_horiz_rounded, color: Colors.white),
                      onPressed: () => _showImageMenu(_index),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
