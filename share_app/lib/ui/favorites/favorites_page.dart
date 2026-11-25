import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../app_theme.dart';
import '../detail/status_detail_page.dart';
import '../feed/status_card.dart';
import '../media/gallery_page.dart';
import '../media/video_page.dart';

/// 我的收藏 — `/ajax/favorites/all_fav`.
class FavoritesPage extends ConsumerStatefulWidget {
  const FavoritesPage({super.key});

  @override
  ConsumerState<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends ConsumerState<FavoritesPage> {
  final ScrollController _scroll = ScrollController();

  List<Status> _items = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
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

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await WeiboApi.instance.favorites();
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _hasMore = page.hasMore;
        _page = 1;
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
    if (_loadingMore || !_hasMore || _loading || _error != null) return;
    setState(() => _loadingMore = true);
    try {
      final page = await WeiboApi.instance.favorites(page: _page + 1);
      if (!mounted) return;
      if (page.items.isEmpty) {
        setState(() {
          _hasMore = false;
          _loadingMore = false;
        });
        return;
      }
      setState(() {
        _items = [..._items, ...page.items];
        _page += 1;
        _hasMore = page.hasMore;
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
    return Scaffold(
      appBar: AppBar(title: const Text('我的收藏')),
      body: RefreshIndicator(
        color: ShareColors.accent,
        onRefresh: _load,
        child: _body(),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null) {
      final loggedIn = ref.watch(sessionProvider).isLoggedIn;
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 100),
          Icon(loggedIn ? Icons.cloud_off : Icons.lock_outline,
              size: 44, color: ShareColors.textHint),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              loggedIn ? _error! : '收藏需要登录后查看',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: ShareColors.textSecondary, height: 1.5),
            ),
          ),
          if (loggedIn) Center(child: TextButton(onPressed: _load, child: const Text('重试'))),
        ],
      );
    }
    if (_items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 110),
          Icon(Icons.star_border, size: 44, color: ShareColors.textHint),
          const SizedBox(height: 12),
          Text(
            '还没有收藏的微博',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
          ),
        ],
      );
    }

    return ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _items.length + 1,
      itemBuilder: (context, index) {
        if (index == _items.length) {
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
        final status = _items[index];
        return Container(
          decoration: BoxDecoration(
            color: ShareColors.cardBg,
            border: Border(bottom: BorderSide(color: ShareColors.divider, width: 0.6)),
          ),
          child: StatusCard(
            status: status,
            onTap: () => _openDetail(status),
            onComment: () => _openDetail(status),
            onRepost: () => _openDetail(status),
            onImageTap: (i) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => GalleryPage(pics: status.pics, initialIndex: i),
                ),
              );
            },
            onVideoTap: () {
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
            },
          ),
        );
      },
    );
  }
}
