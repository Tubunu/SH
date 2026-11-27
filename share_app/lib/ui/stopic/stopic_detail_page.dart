import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/share_core.dart';
import '../../core/stopic.dart';
import '../app_theme.dart';
import '../common/share_actions.dart';
import '../detail/status_detail_page.dart';
import '../feed/status_card.dart';
import '../media/gallery_page.dart';

/// 超话详情.
///
/// The native 超话 feed (`/ajax/profile/topicContent`) is login-gated, so the
/// timeline below is a real status search for `#超话名#` — same posts, same
/// account session, no invented content.
class StopicDetailPage extends ConsumerStatefulWidget {
  final Stopic stopic;

  const StopicDetailPage({super.key, required this.stopic});

  @override
  ConsumerState<StopicDetailPage> createState() => _StopicDetailPageState();
}

class _StopicDetailPageState extends ConsumerState<StopicDetailPage> {
  final ScrollController _scroll = ScrollController();

  List<Status> _items = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _expanded = false;
  bool _checkedIn = false;
  bool _checkingIn = false;
  int _page = 1;
  String? _error;

  Future<void> _doCheckin() async {
    if (_checkingIn) return;
    setState(() => _checkingIn = true);
    try {
      final url =
          'https://m.weibo.cn/api/container/button?request_url=http%3A%2F%2Fi.huati.weibo.com%2Fmobile%2Fsuper%2Factive_fcheckin%3Fcardid%3Dbottom_one_checkin%26container_id%3D${Uri.encodeComponent(widget.stopic.pageId)}&pageid=${Uri.encodeComponent(widget.stopic.pageId)}';
      await ShareCore.instance.topicCheckin(url);
      if (!mounted) return;
      setState(() {
        _checkedIn = true;
        _checkingIn = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('「${widget.stopic.title}」超话签到成功！')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _checkingIn = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('签到提示：${_humanize(e)}')),
      );
    }
  }

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
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 340) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await WeiboApi.instance.search(widget.stopic.hashtag, page: 1);
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _page = 1;
        _hasMore = page.items.isNotEmpty;
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
      final page = await WeiboApi.instance.search(widget.stopic.hashtag, page: _page + 1);
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...page.items];
        _page += 1;
        _hasMore = page.items.isNotEmpty;
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
      appBar: AppBar(
        title: Text(widget.stopic.title),
        actions: [
          TextButton.icon(
            onPressed: _checkingIn ? null : _doCheckin,
            icon: Icon(
              _checkedIn ? Icons.check_circle : Icons.event_available_outlined,
              size: 18,
              color: ShareColors.toolbarFg,
            ),
            label: Text(
              _checkedIn ? '已签到' : (_checkingIn ? '签到中' : '签到'),
              style: TextStyle(color: ShareColors.toolbarFg),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: ShareColors.accent,
        onRefresh: _load,
        child: ListView.builder(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: 1 + _rows.length,
          itemBuilder: (context, index) {
            if (index == 0) return _header();
            return _rows[index - 1];
          },
        ),
      ),
    );
  }

  List<Widget> get _rows {
    final rows = <Widget>[];
    rows.add(Container(height: 0.6, color: ShareColors.divider));
    rows.add(Container(
      color: ShareColors.cardBg,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        children: [
          Container(width: 3, height: 14, color: ShareColors.accent),
          const SizedBox(width: 6),
          Text('超话微博',
              style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: ShareColors.textPrimary)),
        ],
      ),
    ));

    if (_loading) {
      rows.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 50),
        child: Center(
          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      ));
      return rows;
    }

    if (_error != null) {
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(28, 40, 28, 40),
        child: Column(
          children: [
            Icon(Icons.cloud_off, size: 34, color: ShareColors.textHint),
            const SizedBox(height: 10),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: ShareColors.textSecondary, height: 1.5),
            ),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      ));
      return rows;
    }

    if (_items.isEmpty) {
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 46),
        child: Center(
          child: Text('这个话题还没有相关微博',
              style: TextStyle(fontSize: 13, color: ShareColors.textHint)),
        ),
      ));
      return rows;
    }

    for (final status in _items) {
      rows.add(StatusCard(
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
        onVideoTap: () => ShareActions.openStatusVideo(context, status),
      ));
      rows.add(Container(height: 0.6, color: ShareColors.divider));
    }

    rows.add(Padding(
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
    ));
    return rows;
  }

  Widget _header() {
    final stopic = widget.stopic;
    return Container(
      color: ShareColors.cardBg,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 62,
                  height: 62,
                  child: stopic.image.isNotEmpty
                      ? Image.network(
                          stopic.image,
                          fit: BoxFit.cover,
                          cacheWidth: 200,
                          errorBuilder: (_, _, _) => _cover(),
                        )
                      : _cover(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '#${stopic.title}#',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: ShareColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (stopic.fans.isNotEmpty)
                      Text(
                        stopic.fans,
                        style: TextStyle(fontSize: 12, color: ShareColors.textHint),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (stopic.description.isNotEmpty) ...[
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Text(
                stopic.description.replaceAll(RegExp(r'\n{2,}'), '\n').trim(),
                maxLines: _expanded ? null : 2,
                overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: ShareColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 4),
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Text(
                _expanded ? '收起' : '展开',
                style: TextStyle(fontSize: 12, color: ShareColors.link),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _cover() {
    return Container(
      color: ShareColors.accent.withValues(alpha: 0.12),
      child: Icon(Icons.tag, size: 24, color: ShareColors.accent),
    );
  }
}
