import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/keyword_filter.dart';
import '../../core/models.dart';
import '../../core/settings.dart';
import '../app_theme.dart';
import '../common/status_action_sheet.dart';
import '../detail/status_detail_page.dart';
import '../feed/status_card.dart';
import '../media/gallery_page.dart';
import '../profile/user_page.dart';

/// 我赞过的微博 —— 原版 `PersonalLikedStatusActivity`，
/// 数据来自 `/ajax/statuses/likelist?uid=&page=&with_total=true`。
class LikedPage extends ConsumerStatefulWidget {
  final String uid;
  final String? title;

  const LikedPage({super.key, required this.uid, this.title});

  @override
  ConsumerState<LikedPage> createState() => _LikedPageState();
}

class _LikedPageState extends ConsumerState<LikedPage> {
  final List<Status> _items = [];
  final ScrollController _controller = ScrollController();
  int _page = 1;
  bool _loading = false;
  bool _hasMore = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      if (_controller.position.pixels > _controller.position.maxScrollExtent - 400) {
        _loadMore();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadFirst());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<Status> get _visible =>
      applyStatusFilters(_items, ref.read(settingsProvider));

  Future<void> _loadFirst() async {
    setState(() {
      _loading = true;
      _error = null;
      _page = 1;
    });
    try {
      final page = await WeiboApi.instance.likedStatuses(widget.uid, page: 1);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _humanize(e);
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final page = await WeiboApi.instance.likedStatuses(widget.uid, page: _page + 1);
      if (!mounted) return;
      setState(() {
        _page += 1;
        _items.addAll(page.items);
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title ?? '赞过的微博')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.favorite_border, size: 42, color: ShareColors.textHint),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _loadFirst, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text('还没有赞过微博',
            style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
      );
    }

    final list = _visible;
    return RefreshIndicator(
      color: ShareColors.accent,
      onRefresh: _loadFirst,
      child: ListView.separated(
        controller: _controller,
        itemCount: list.length + 1,
        separatorBuilder: (_, _) => Divider(
          height: 8,
          thickness: 8,
          color: ShareColors.pageBg,
        ),
        itemBuilder: (context, index) {
          if (index == list.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text(
                  _hasMore ? '加载中…' : '没有更多了',
                  style: TextStyle(fontSize: 12, color: ShareColors.textHint),
                ),
              ),
            );
          }
          final status = list[index];
          return StatusCard(
            status: status,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => StatusDetailPage(status: status)),
            ),
            onAvatarTap: () {
              final user = status.user;
              if (user == null) return;
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => UserPage(
                  uid: user.id,
                  initialName: user.name,
                  initialAvatar: user.avatar,
                ),
              ));
            },
            // 点赞交给 StatusCard 内建实现：它做乐观更新 + 失败回滚提示，
            // 这里自己写一份只会出现「点了图标不动、失败也无提示」。
            onMore: () => showStatusActionSheet(
              context,
              ref,
              status,
              onDeleted: () => setState(() => _items.removeWhere((e) => e.id == status.id)),
            ),
            onDeleted: () => setState(() => _items.removeWhere((e) => e.id == status.id)),
            onImageTap: (i) {
              if (status.pics.isEmpty) return;
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => GalleryPage(pics: status.pics, initialIndex: i),
              ));
            },
          );
        },
      ),
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
