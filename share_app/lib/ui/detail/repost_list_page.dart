import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/settings.dart';
import '../app_theme.dart';
import '../common/share_actions.dart';
import '../feed/status_card.dart';
import '../media/gallery_page.dart';
import '../profile/user_page.dart';
import 'status_detail_page.dart';

/// 转发列表独立页 —— `RepostListActivity`.
/// 详情页里已经切到「转发」Tab，这一页只作为菜单里的「查看转发列表」保留。
class RepostListPage extends ConsumerWidget {
  final Status status;

  const RepostListPage({super.key, required this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text('转发 ${formatCount(status.reposts)}')),
      body: RepostTabList(statusId: status.id),
    );
  }
}

/// 转发列表内容 —— 详情页「转发」Tab 与上面的独立页共用一份分页逻辑。
///
/// [headSlivers] 是详情页共用头部（正文卡片 + 吸顶 Tab 栏）。
class RepostTabList extends ConsumerStatefulWidget {
  final String statusId;
  final List<Widget> headSlivers;

  const RepostTabList({
    super.key,
    required this.statusId,
    this.headSlivers = const [],
  });

  @override
  ConsumerState<RepostTabList> createState() => _RepostTabListState();
}

class _RepostTabListState extends ConsumerState<RepostTabList> {
  final List<Status> _items = [];
  final ScrollController _scroll = ScrollController();

  /// 服务端原话（游客会拿到「前方拥堵，请登录后使用」之类），非空就顶在列表最前面。
  String _tip = '';
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void didUpdateWidget(covariant RepostTabList old) {
    super.didUpdateWidget(old);
    if (widget.statusId != old.statusId) {
      _load(reset: true);
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) {
      _load();
    }
  }

  Future<void> _load({bool reset = false}) async {
    // 上一页失败后先停下，等用户点「重试」，否则滚动会反复打同一个失败请求。
    if (!reset && (_loading || _loadingMore || !_hasMore || _error != null)) return;
    if (reset) {
      setState(() {
        _loading = true;
        _loadingMore = false;
        _error = null;
        _hasMore = true;
        _page = 1;
        _items.clear();
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final result = await WeiboApi.instance.repostList(widget.statusId, page: _page);
      if (!mounted) return;
      setState(() {
        _items.addAll(result.items);
        _tip = result.tip;
        // repostList 只给 items + tip，没有游标，按「这页是否装满」判断。
        _hasMore = result.items.length >= 10;
        _page += 1;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = _humanize(e);
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

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      controller: _scroll,
      slivers: [...widget.headSlivers, ..._contentSlivers()],
    );
  }

  List<Widget> _contentSlivers() {
    if (_loading) {
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
    if (_error != null && _items.isEmpty) {
      return [
        if (_tip.isNotEmpty) _tipSliver(),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            child: Column(
              children: [
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => _load(reset: true),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ];
    }
    if (_items.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 28),
            child: Center(
              child: Text(
                _tip.isNotEmpty ? _tip : '还没有人转发',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
              ),
            ),
          ),
        ),
      ];
    }

    final cardStyle = ref.watch(settingsProvider).cardStyle;
    return [
      if (_tip.isNotEmpty) _tipSliver(),
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            if (index.isOdd) {
              if (cardStyle) return const SizedBox.shrink();
              return Divider(height: 1, thickness: 0.5, color: ShareColors.divider);
            }
            final item = _items[index ~/ 2];
            return StatusCard(
              status: item,
              showActions: false,
              showRetweet: false,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => StatusDetailPage(status: item)),
              ),
              onAvatarTap: () {
                final u = item.user;
                if (u == null || u.id.isEmpty) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => UserPage(
                      uid: u.id,
                      initialName: u.name,
                      initialAvatar: u.avatar,
                    ),
                  ),
                );
              },
              onImageTap: (i) => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => GalleryPage(pics: item.pics, initialIndex: i),
                ),
              ),
              onVideoTap: () => ShareActions.openStatusVideo(context, item),
            );
          },
          childCount: _items.length * 2 - 1,
        ),
      ),
      SliverToBoxAdapter(child: _footer()),
    ];
  }

  Widget _tipSliver() {
    return SliverToBoxAdapter(
      child: Container(
        width: double.infinity,
        color: ShareColors.cardBg,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Text(
          _tip,
          style: TextStyle(fontSize: 12, color: ShareColors.textSecondary),
        ),
      ),
    );
  }

  Widget _footer() {
    if (_error != null) {
      // 已有内容时翻页失败只占页脚，不清空已经看到的转发。
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          children: [
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: ShareColors.textSecondary),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => _load(reset: true),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Center(
        child: _loadingMore
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 1.8),
              )
            : Text(
                _hasMore ? '' : '没有更多了',
                style: TextStyle(fontSize: 12, color: ShareColors.textHint),
              ),
      ),
    );
  }
}
