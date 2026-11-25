import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../app_theme.dart';
import '../common/status_action_sheet.dart';
import '../detail/status_detail_page.dart';
import '../feed/status_card.dart';
import '../media/gallery_page.dart';
import 'user_page.dart';

/// 搜索历史只在进程内存里活着。
///
/// 原版会写进 `search_history` 偏好，但那个值是全局的：换账号登录后旧账号搜过的
/// 词还留着。这里既然没有持久化需求，放在库级变量里刚好「本次会话内保留、
/// 退出即忘」，重开页面还能看到刚才搜过的词。
final List<String> _sessionHistory = <String>[];

/// 主页内搜索 —— 原版 `PersonalStatusSearchActivity`。
///
/// 走 `/ajax/profile/searchblog?uid=&page=&q=`，返回的是按页给的微博列表，
/// 所以翻页用 `page` 递增，到底与否看 `Paged.hasMore`。
class ProfileSearchPage extends ConsumerStatefulWidget {
  final String uid;
  final String ownerName;

  const ProfileSearchPage({
    super.key,
    required this.uid,
    required this.ownerName,
  });

  @override
  ConsumerState<ProfileSearchPage> createState() => _ProfileSearchPageState();
}

class _ProfileSearchPageState extends ConsumerState<ProfileSearchPage> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  List<Status> _items = const [];
  int _page = 1;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String _query = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 360) {
        _loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  void _remember(String q) {
    _sessionHistory
      ..remove(q)
      ..insert(0, q);
    // 只留最近 10 条，再多一条也用不上，还会把引导区挤满。
    if (_sessionHistory.length > 10) {
      _sessionHistory.removeRange(10, _sessionHistory.length);
    }
  }

  /// 首次搜索 / 重新搜索 / 下拉刷新都走这里。
  Future<void> _search(String raw) async {
    final q = raw.trim();
    if (q.isEmpty) return;
    if (_input.text != q) _input.text = q;
    _remember(q);
    setState(() {
      _query = q;
      _items = const [];
      _page = 1;
      _hasMore = true;
      _loading = true;
      _error = null;
    });
    try {
      final page = await WeiboApi.instance.searchProfile(widget.uid, q, page: 1);
      // 用户可能已经改词重搜，旧请求的结果必须丢掉，否则列表会串。
      if (!mounted || _query != q) return;
      setState(() {
        _items = page.items;
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || _query != q) return;
      setState(() {
        _error = _humanize(e);
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _query.isEmpty) return;
    final q = _query;
    setState(() => _loadingMore = true);
    try {
      final page = await WeiboApi.instance.searchProfile(widget.uid, q, page: _page + 1);
      if (!mounted || _query != q) return;
      setState(() {
        _page += 1;
        _items = [..._items, ...page.items];
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (_) {
      // 翻页失败不改 hasMore，用户再滑一次会重试；首屏失败才显示错误页。
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Container(
          height: 34,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            color: ShareColors.inputBg,
            borderRadius: BorderRadius.circular(17),
          ),
          child: TextField(
            controller: _input,
            autofocus: true,
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontSize: 14.5),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              prefixIcon: Icon(Icons.search, size: 18, color: ShareColors.textHint),
              prefixIconConstraints: const BoxConstraints(minWidth: 34),
              hintText: '搜索 ${widget.ownerName} 的微博',
              hintStyle: TextStyle(fontSize: 14, color: ShareColors.placeholder),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
            ),
            onSubmitted: _search,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => _search(_input.text),
            child: Text('搜索', style: TextStyle(color: ShareColors.accent)),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_query.isEmpty) return _intro();

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
              Icon(Icons.error_outline, size: 40, color: ShareColors.textHint),
              const SizedBox(height: 12),
              // 服务端原话（比如「登录状态已失效，请重新登录」）比任何自造文案都有用。
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.5, color: ShareColors.textSecondary),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => _search(_query),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (_items.isEmpty) {
      return Center(
        child: Text(
          '没有找到相关微博',
          style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
        ),
      );
    }

    return RefreshIndicator(
      color: ShareColors.accent,
      onRefresh: () => _search(_query),
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        // StatusCard 自带 1dp 分隔线，这里不再额外插间距，避免出现双层线。
        itemCount: _items.length + 1,
        itemBuilder: (context, index) {
          if (index == _items.length) return _footer();
          return _card(_items[index]);
        },
      ),
    );
  }

  Widget _card(Status status) {
    return StatusCard(
      status: status,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => StatusDetailPage(status: status)),
      ),
      onComment: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => StatusDetailPage(status: status)),
      ),
      onRepost: () => Navigator.of(context).push(
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
      // 点赞交给 StatusCard 内建实现（乐观更新 + 失败提示）。
      onMore: () => showStatusActionSheet(
        context,
        ref,
        status,
        onDeleted: () => setState(
          () => _items = _items.where((e) => e.id != status.id).toList(),
        ),
      ),
      onDeleted: () => setState(
        () => _items = _items.where((e) => e.id != status.id).toList(),
      ),
      onImageTap: (i) {
        if (status.pics.isEmpty) return;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => GalleryPage(pics: status.pics, initialIndex: i),
        ));
      },
    );
  }

  Widget _footer() {
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

  /// 还没搜时的引导区：说明搜的是谁 + 本次会话的搜索历史。
  Widget _intro() {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 28, 16, 0),
          child: Column(
            children: [
              Icon(Icons.search, size: 40, color: ShareColors.textHint),
              const SizedBox(height: 12),
              Text(
                '输入关键词，搜索「${widget.ownerName}」发过的微博',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
              ),
            ],
          ),
        ),
        if (_sessionHistory.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Row(
              children: [
                Text('搜索历史',
                    style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary)),
                const Spacer(),
                GestureDetector(
                  onTap: () => setState(_sessionHistory.clear),
                  child: Icon(Icons.delete_outline, size: 17, color: ShareColors.textHint),
                ),
              ],
            ),
          ),
          Container(
            color: ShareColors.cardBg,
            child: Column(
              children: [
                for (var i = 0; i < _sessionHistory.length; i++) ...[
                  if (i > 0)
                    Divider(
                        height: 0.8,
                        thickness: 0.8,
                        color: ShareColors.divider,
                        indent: 44),
                  InkWell(
                    onTap: () => _search(_sessionHistory[i]),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: Row(
                        children: [
                          Icon(Icons.history, size: 18, color: ShareColors.textHint),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _sessionHistory[i],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
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
}
