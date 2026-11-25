import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/stopic.dart';
import '../app_theme.dart';
import 'stopic_detail_page.dart';

/// 超话广场 — categories from `/ajax/stopic/cates`, topics from
/// `/ajax/stopic/list`. Everything here works for visitors too.
class StopicPage extends ConsumerStatefulWidget {
  const StopicPage({super.key});

  @override
  ConsumerState<StopicPage> createState() => _StopicPageState();
}

class _StopicPageState extends ConsumerState<StopicPage>
    with SingleTickerProviderStateMixin {
  TabController? _tabs;
  List<StopicCate> _cates = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCates();
  }

  @override
  void dispose() {
    _tabs?.dispose();
    super.dispose();
  }

  Future<void> _loadCates() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cates = await WeiboApi.instance.stopicCates();
      if (!mounted) return;
      setState(() {
        _cates = cates;
        _tabs?.dispose();
        _tabs = TabController(length: cates.length, vsync: this);
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
    final tabs = _tabs;
    return Scaffold(
      appBar: AppBar(
        title: const Text('超话'),
        bottom: (_loading || tabs == null)
            ? null
            : TabBar(
                controller: tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelColor: ShareColors.accent,
                unselectedLabelColor: ShareColors.textSecondary,
                indicatorColor: ShareColors.accent,
                indicatorSize: TabBarIndicatorSize.label,
                labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                unselectedLabelStyle: const TextStyle(fontSize: 14),
                tabs: [for (final cate in _cates) Tab(text: cate.name)],
              ),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 42, color: ShareColors.textHint),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
              ),
            ),
            TextButton(onPressed: _loadCates, child: const Text('重试')),
          ],
        ),
      );
    }
    final tabs = _tabs;
    if (tabs == null || _cates.isEmpty) {
      return Center(
        child: Text('暂无超话分类',
            style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
      );
    }

    return TabBarView(
      controller: tabs,
      children: [
        for (final cate in _cates) _StopicList(cate: cate),
      ],
    );
  }
}

class _StopicList extends ConsumerStatefulWidget {
  final StopicCate cate;

  const _StopicList({required this.cate});

  @override
  ConsumerState<_StopicList> createState() => _StopicListState();
}

class _StopicListState extends ConsumerState<_StopicList>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _search = TextEditingController();

  List<Stopic> _items = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  int _pages = 0;
  String _keyword = '';
  String? _error;

  @override
  bool get wantKeepAlive => true;

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
    _search.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 320) {
      _loadMore();
    }
  }

  bool get _isRecent => widget.cate.id == 123333;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await WeiboApi.instance.stopicList(
        sortId: _keyword.isEmpty ? widget.cate.id : 0,
        keyword: _keyword,
      );
      if (!mounted) return;
      setState(() {
        _items = result.items;
        _pages = result.pages;
        _page = 1;
        _hasMore = result.pages == 0 || result.pages > 1;
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
      final result = await WeiboApi.instance.stopicList(
        sortId: _keyword.isEmpty ? widget.cate.id : 0,
        keyword: _keyword,
        page: _page + 1,
      );
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...result.items];
        _page += 1;
        _hasMore = result.items.isNotEmpty && (_pages == 0 || _page < _pages);
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

  void _open(Stopic stopic) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => StopicDetailPage(stopic: stopic)),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          child: Container(
            height: 34,
            decoration: BoxDecoration(
              color: ShareColors.inputBg,
              borderRadius: BorderRadius.circular(17),
            ),
            child: Row(
              children: [
                const SizedBox(width: 10),
                Icon(Icons.search, size: 16, color: ShareColors.textHint),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _search,
                    textInputAction: TextInputAction.search,
                    style: TextStyle(fontSize: 13.5, color: ShareColors.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: '搜索超话',
                      hintStyle: TextStyle(fontSize: 13.5, color: ShareColors.textHint),
                    ),
                    onSubmitted: (value) {
                      setState(() => _keyword = value.trim());
                      _load();
                    },
                  ),
                ),
                if (_keyword.isNotEmpty)
                  GestureDetector(
                    onTap: () {
                      _search.clear();
                      setState(() => _keyword = '');
                      _load();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.close, size: 15, color: ShareColors.textHint),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(child: _content()),
      ],
    );
  }

  Widget _content() {
    if (_loading) {
      return const Center(
        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 70),
          Icon(Icons.cloud_off, size: 38, color: ShareColors.textHint),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
            ),
          ),
          Center(child: TextButton(onPressed: _load, child: const Text('重试'))),
        ],
      );
    }
    if (_items.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 90),
          Icon(Icons.tag, size: 40, color: ShareColors.textHint),
          const SizedBox(height: 10),
          Text(
            _isRecent && _keyword.isEmpty
                ? '还没有最近使用的超话\n在下面搜索一个试试'
                : '没有找到相关超话',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: ShareColors.textSecondary, height: 1.6),
          ),
        ],
      );
    }

    return ListView.separated(
      controller: _scroll,
      itemCount: _items.length + 1,
      separatorBuilder: (_, _) => Container(
        height: 0.6,
        color: ShareColors.divider,
        margin: const EdgeInsets.only(left: 74),
      ),
      itemBuilder: (context, index) {
        if (index == _items.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
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
        return _tile(_items[index]);
      },
    );
  }

  Widget _tile(Stopic stopic) {
    return InkWell(
      onTap: () => _open(stopic),
      child: Container(
        color: ShareColors.cardBg,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 48,
                height: 48,
                child: stopic.image.isNotEmpty
                    ? Image.network(
                        stopic.image,
                        fit: BoxFit.cover,
                        cacheWidth: 150,
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
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          stopic.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: ShareColors.textPrimary,
                          ),
                        ),
                      ),
                      if (stopic.fans.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          stopic.fans,
                          style: TextStyle(fontSize: 11, color: ShareColors.textHint),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    stopic.description.replaceAll(RegExp(r'\s+'), ' ').trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary, height: 1.35),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cover() {
    return Container(
      color: ShareColors.accent.withValues(alpha: 0.12),
      child: Icon(Icons.tag, size: 20, color: ShareColors.accent),
    );
  }
}
