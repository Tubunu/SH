import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api.dart';
import '../../core/keyword_filter.dart';
import '../../core/models.dart';
import '../../core/settings.dart';
import '../app_theme.dart';
import '../detail/status_detail_page.dart';
import '../feed/status_card.dart';
import '../profile/user_page.dart';

/// 搜索 —— `SearchActivity` + `HotSearchActivity`:
/// displays search history chips + categorized Hot Search tabs (`实时热搜`, 文娱, 要闻,
/// 财经, 科技数码, etc.) before typing a query, and categorized result tabs
/// (`综合`, `实时`, `用户`, `图片`, `视频`) after submitting.
class SearchPage extends ConsumerStatefulWidget {
  /// When opened from a tapped `#topic#` this pre-fills and runs the search.
  final String? initialKeyword;

  const SearchPage({super.key, this.initialKeyword});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  static const _viewedPrefKey = 'share_hot_search_viewed_v1';
  static const _historyPrefKey = 'share_search_history_v1';
  static const List<(String type, String label)> _resultTabs = [
    ('all', '综合'),
    ('realtime', '实时'),
    ('user', '用户'),
    ('pic', '图片'),
    ('video', '视频'),
  ];

  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  List<Status> _results = [];
  List<User> _userResults = [];
  List<String> _searchHistory = [];
  List<HotSearchCategory> _categories = [];
  int _catIndex = 0;
  int _tabIndex = 0;
  bool _loadingCategoryItems = false;
  Set<String> _viewedWords = {};
  final Set<String> _followingOverrides = <String>{};
  final Set<String> _unfollowedOverrides = <String>{};
  bool _loading = false;
  bool _loadingHot = true;
  bool _hasMore = true;
  String? _error;
  String _query = '';
  int _page = 1;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadViewedHistory();
    _loadSearchHistory();
    final keyword = widget.initialKeyword?.trim() ?? '';
    if (keyword.isNotEmpty) {
      _input.text = keyword;
      _submit(keyword);
    } else {
      _loadHot();
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _loadViewedHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_viewedPrefKey) ?? const [];
      if (mounted && list.isNotEmpty) {
        setState(() => _viewedWords = list.toSet());
      }
    } catch (_) {}
  }

  Future<void> _recordHotSearchView(String word) async {
    if (!ref.read(settingsProvider).hotSearchTag) return;
    final clean = word.trim();
    if (clean.isEmpty) return;
    setState(() => _viewedWords = {..._viewedWords, clean});
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _viewedWords.toList();
      if (list.length > 60) list.removeRange(0, list.length - 60);
      await prefs.setStringList(_viewedPrefKey, list);
    } catch (_) {}
  }

  Future<void> _loadSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_historyPrefKey) ?? const [];
      if (mounted && list.isNotEmpty) {
        setState(() => _searchHistory = List<String>.from(list));
      }
    } catch (_) {}
  }

  Future<void> _recordSearchHistory(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return;
    final next = [
      clean,
      ..._searchHistory.where((e) => e != clean),
    ];
    if (next.length > 15) next.removeRange(15, next.length);
    setState(() => _searchHistory = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_historyPrefKey, next);
    } catch (_) {}
  }

  Future<void> _removeSearchHistory(String query) async {
    final next = _searchHistory.where((e) => e != query).toList();
    setState(() => _searchHistory = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_historyPrefKey, next);
    } catch (_) {}
  }

  Future<void> _clearSearchHistory() async {
    setState(() => _searchHistory = []);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_historyPrefKey);
    } catch (_) {}
  }

  Future<void> _loadHot() async {
    setState(() => _loadingHot = true);
    try {
      final cats = await WeiboApi.instance.hotSearchCategories();
      if (!mounted) return;
      setState(() {
        _categories = cats;
        if (_catIndex >= cats.length) _catIndex = 0;
        _loadingHot = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingHot = false);
    }
  }

  Future<void> _selectCategory(int index) async {
    if (index < 0 || index >= _categories.length || index == _catIndex) return;
    setState(() {
      _catIndex = index;
      _loadingCategoryItems = false;
    });
    final cat = _categories[index];
    if (cat.items.isEmpty && (cat.containerid ?? '').isNotEmpty) {
      setState(() => _loadingCategoryItems = true);
      try {
        final items = await WeiboApi.instance.hotSearchCategoryItems(cat);
        if (!mounted) return;
        setState(() {
          _categories[index] = cat.copyWith(items: items);
          _loadingCategoryItems = false;
        });
      } catch (_) {
        if (mounted) setState(() => _loadingCategoryItems = false);
      }
    }
  }

  Future<void> _submit(String value, {int? tabIndex}) async {
    final query = value.trim();
    if (query.isEmpty) return;
    final nextTab = (tabIndex ?? _tabIndex).clamp(0, _resultTabs.length - 1);
    final type = _resultTabs[nextTab].$1;
    _recordSearchHistory(query);
    setState(() {
      _query = query;
      _tabIndex = nextTab;
      _loading = true;
      _error = null;
      _results = [];
      _userResults = [];
      _page = 1;
      _hasMore = true;
    });
    try {
      final res = await WeiboApi.instance.searchTyped(query, type: type, page: 1);
      if (!mounted) return;
      final hidden = ref.read(settingsProvider).hiddenKeywords;
      setState(() {
        _results = hideStatusesByKeyword(res.statuses, hidden);
        _userResults = res.users;
        _hasMore = res.hasMore;
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
    if (_loading || !_hasMore || _query.isEmpty) return;
    final type = _resultTabs[_tabIndex].$1;
    setState(() => _loading = true);
    try {
      final res =
          await WeiboApi.instance.searchTyped(_query, type: type, page: _page + 1);
      if (!mounted) return;
      if (type == 'user') {
        final seen = _userResults.map((u) => u.id).toSet();
        final added = res.users.where((u) => !seen.contains(u.id)).toList();
        setState(() {
          _page += 1;
          _userResults = [..._userResults, ...added];
          _hasMore = res.hasMore && added.isNotEmpty;
          _loading = false;
        });
      } else {
        final hidden = ref.read(settingsProvider).hiddenKeywords;
        final filtered = hideStatusesByKeyword(res.statuses, hidden);
        final seen = _results.map((s) => s.id).toSet();
        final added = filtered.where((s) => !seen.contains(s.id)).toList();
        setState(() {
          _page += 1;
          _results = [..._results, ...added];
          _hasMore = res.hasMore && added.isNotEmpty;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
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
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Container(
          height: 34,
          decoration: BoxDecoration(
            color: ShareColors.inputBg,
            borderRadius: BorderRadius.circular(17),
          ),
          child: TextField(
            controller: _input,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onSubmitted: _submit,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              prefixIcon: Icon(Icons.search, size: 18, color: ShareColors.textHint),
              hintText: '搜索微博',
              hintStyle: TextStyle(fontSize: 14, color: ShareColors.textHint),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              if (_query.isNotEmpty) {
                _input.clear();
                setState(() {
                  _query = '';
                  _tabIndex = 0;
                  _results = [];
                  _userResults = [];
                  _error = null;
                });
                if (_categories.isEmpty && !_loadingHot) _loadHot();
              } else {
                Navigator.of(context).maybePop();
              }
            },
            child: Text(
              _query.isEmpty ? '取消' : '清除',
              style: TextStyle(color: ShareColors.textSecondary, fontSize: 14),
            ),
          ),
        ],
      ),
      body: _query.isEmpty ? _hotBody() : _resultBody(),
    );
  }

  Widget _hotBody() {
    final settings = ref.watch(settingsProvider);
    final historySection = _searchHistory.isEmpty
        ? null
        : Container(
            width: double.infinity,
            color: ShareColors.cardBg,
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '最近搜索',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: ShareColors.textSecondary,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: _clearSearchHistory,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        child: Text(
                          '清空',
                          style: TextStyle(fontSize: 12, color: ShareColors.textHint),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: _searchHistory.map((term) {
                    return InputChip(
                      label: Text(
                        term,
                        style: TextStyle(fontSize: 12.5, color: ShareColors.textPrimary),
                      ),
                      backgroundColor: ShareColors.inputBg,
                      side: BorderSide.none,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      deleteIcon: Icon(Icons.close, size: 14, color: ShareColors.textHint),
                      onDeleted: () => _removeSearchHistory(term),
                      onPressed: () {
                        _input.text = term;
                        _submit(term);
                      },
                    );
                  }).toList(),
                ),
              ],
            ),
          );

    if (settings.hideHotSearch) {
      return Column(
        children: [
          if (historySection != null) ...[
            historySection,
            Divider(height: 8, thickness: 8, color: ShareColors.pageBg),
          ],
          Expanded(
            child: Center(
              child: Text(
                '已在布局设置中隐藏热门搜索',
                style: TextStyle(fontSize: 13, color: ShareColors.textHint),
              ),
            ),
          ),
        ],
      );
    }
    if (_loadingHot) {
      return Column(
        children: [
          if (historySection != null) ...[
            historySection,
            Divider(height: 8, thickness: 8, color: ShareColors.pageBg),
          ],
          const Expanded(
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        ],
      );
    }
    if (_categories.isEmpty) {
      return Column(
        children: [
          if (historySection != null) ...[
            historySection,
            Divider(height: 8, thickness: 8, color: ShareColors.pageBg),
          ],
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('暂无热搜', style: TextStyle(fontSize: 13, color: ShareColors.textHint)),
                  const SizedBox(height: 10),
                  OutlinedButton(onPressed: _loadHot, child: const Text('刷新')),
                ],
              ),
            ),
          ),
        ],
      );
    }
    final activeCategory = _categories[_catIndex.clamp(0, _categories.length - 1)];
    final items = activeCategory.items;

    return Column(
      children: [
        if (historySection != null) ...[
          historySection,
          Divider(height: 8, thickness: 8, color: ShareColors.pageBg),
        ],
        Container(
          height: 42,
          decoration: BoxDecoration(
            color: ShareColors.cardBg,
            border: Border(bottom: BorderSide(color: ShareColors.divider, width: 0.7)),
          ),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: _categories.length,
            separatorBuilder: (_, _) => const SizedBox(width: 4),
            itemBuilder: (context, index) {
              final cat = _categories[index];
              final selected = index == _catIndex;
              return InkWell(
                onTap: () => _selectCategory(index),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: selected ? ShareColors.accent : Colors.transparent,
                        width: 2.2,
                      ),
                    ),
                  ),
                  child: Text(
                    cat.title,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected ? ShareColors.accent : ShareColors.textSecondary,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: _loadingCategoryItems
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : RefreshIndicator(
                  color: ShareColors.accent,
                  onRefresh: _loadHot,
                  child: items.isEmpty
                      ? ListView(
                          children: [
                            const SizedBox(height: 120),
                            Center(
                              child: Text('该分类暂无热搜',
                                  style: TextStyle(fontSize: 13, color: ShareColors.textHint)),
                            ),
                          ],
                        )
                      : ListView.separated(
                          itemCount: items.length,
                          separatorBuilder: (_, _) =>
                              Divider(height: 0.7, thickness: 0.5, color: ShareColors.divider),
                          itemBuilder: (context, index) {
                            final item = items[index];
                            final viewed =
                                settings.hotSearchTag && _viewedWords.contains(item.word);
                            return ListTile(
                              dense: true,
                              tileColor: ShareColors.cardBg,
                              onTap: () {
                                _recordHotSearchView(item.word);
                                _input.text = item.word;
                                _submit(item.word);
                              },
                              leading: SizedBox(
                                width: 24,
                                child: Text(
                                  '${item.rank}',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: _rankColor(item.rank),
                                  ),
                                ),
                              ),
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      item.word,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 14.5,
                                        color: viewed
                                            ? ShareColors.textSecondary
                                            : ShareColors.textPrimary,
                                      ),
                                    ),
                                  ),
                                  if (item.label.trim().isNotEmpty)
                                    Container(
                                      margin: const EdgeInsets.only(left: 6),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 4, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: _labelColor(item.label).withValues(alpha: 0.14),
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                      child: Text(
                                        item.label,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w500,
                                          color: _labelColor(item.label),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              trailing: item.hot > 0
                                  ? Text(formatCount(item.hot),
                                      style: TextStyle(
                                          fontSize: 11.5, color: ShareColors.textHint))
                                  : null,
                            );
                          },
                        ),
                ),
        ),
      ],
    );
  }

  Color _rankColor(int rank) {
    if (rank == 1) return const Color(0xFFE64545);
    if (rank == 2) return const Color(0xFFF2711C);
    if (rank == 3) return const Color(0xFFF5A623);
    return ShareColors.textSecondary;
  }

  Color _labelColor(String label) {
    switch (label.trim()) {
      case '爆':
      case '沸':
        return const Color(0xFFE64545);
      case '热':
        return const Color(0xFFF2711C);
      case '新':
        return const Color(0xFF3BA55C);
      default:
        return ShareColors.textSecondary;
    }
  }

  Widget _resultBody() {
    final activeType = _resultTabs[_tabIndex].$1;

    return Column(
      children: [
        Container(
          height: 42,
          decoration: BoxDecoration(
            color: ShareColors.cardBg,
            border: Border(bottom: BorderSide(color: ShareColors.divider, width: 0.7)),
          ),
          child: Row(
            children: List.generate(_resultTabs.length, (i) {
              final selected = i == _tabIndex;
              return Expanded(
                child: InkWell(
                  onTap: () {
                    if (i != _tabIndex) _submit(_query, tabIndex: i);
                  },
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: selected ? ShareColors.accent : Colors.transparent,
                          width: 2.2,
                        ),
                      ),
                    ),
                    child: Text(
                      _resultTabs[i].$2,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        color: selected ? ShareColors.accent : ShareColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        Expanded(child: _buildResultContent(activeType)),
      ],
    );
  }

  Widget _buildResultContent(String activeType) {
    final isUserTab = activeType == 'user';
    final isEmpty = isUserTab ? _userResults.isEmpty : _results.isEmpty;

    if (_loading && isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null && isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: () => _submit(_query, tabIndex: _tabIndex),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (isEmpty && (!isUserTab && _userResults.isEmpty || isUserTab)) {
      return Center(
        child: Text(
          isUserTab ? '没有找到相关用户' : '没有找到相关微博',
          style: TextStyle(fontSize: 13, color: ShareColors.textHint),
        ),
      );
    }

    if (isUserTab) {
      return ListView.separated(
        controller: _scroll,
        itemCount: _userResults.length + 1,
        separatorBuilder: (_, _) =>
            Divider(height: 0.6, thickness: 0.6, color: ShareColors.divider),
        itemBuilder: (context, index) {
          if (index == _userResults.length) {
            return _pagingFooter();
          }
          return _userSearchTile(_userResults[index]);
        },
      );
    }

    final hasRelatedUsers = activeType == 'all' && _userResults.isNotEmpty;
    final offset = hasRelatedUsers ? 1 : 0;

    return ListView.separated(
      controller: _scroll,
      itemCount: _results.length + offset + 1,
      separatorBuilder: (_, _) =>
          Divider(height: 8, thickness: 8, color: ShareColors.pageBg),
      itemBuilder: (context, index) {
        if (hasRelatedUsers && index == 0) {
          return _relatedUsersBanner();
        }
        final statusIndex = index - offset;
        if (statusIndex == _results.length) {
          return _pagingFooter();
        }
        final status = _results[statusIndex];
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
        );
      },
    );
  }

  Widget _pagingFooter() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: _loading
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

  Widget _relatedUsersBanner() {
    return Container(
      color: ShareColors.cardBg,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '相关用户',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: ShareColors.textSecondary,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => _submit(_query, tabIndex: 2),
                child: Text(
                  '查看更多 >',
                  style: TextStyle(fontSize: 12, color: ShareColors.link),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 76,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _userResults.length.clamp(0, 6),
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, idx) {
                final u = _userResults[idx];
                return GestureDetector(
                  onTap: () => _openUserPage(u),
                  child: SizedBox(
                    width: 62,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ClipOval(
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: u.avatar.isNotEmpty
                                ? Image.network(
                                    u.avatar,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => ColoredBox(
                                      color: ShareColors.placeholder,
                                      child: Icon(Icons.person,
                                          size: 20, color: ShareColors.textHint),
                                    ),
                                  )
                                : ColoredBox(
                                    color: ShareColors.placeholder,
                                    child: Icon(Icons.person,
                                        size: 20, color: ShareColors.textHint),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          u.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: ShareColors.textPrimary),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  bool _isFollowingUser(User u) {
    if (_followingOverrides.contains(u.id)) return true;
    if (_unfollowedOverrides.contains(u.id)) return false;
    return u.following;
  }

  Future<void> _toggleFollowUser(User u) async {
    final currentlyFollowing = _isFollowingUser(u);
    setState(() {
      if (currentlyFollowing) {
        _followingOverrides.remove(u.id);
        _unfollowedOverrides.add(u.id);
      } else {
        _unfollowedOverrides.remove(u.id);
        _followingOverrides.add(u.id);
      }
    });
    try {
      await WeiboApi.instance.follow(u.id, currentlyFollowing);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (currentlyFollowing) {
          _unfollowedOverrides.remove(u.id);
          _followingOverrides.add(u.id);
        } else {
          _followingOverrides.remove(u.id);
          _unfollowedOverrides.add(u.id);
        }
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(_humanize(e))));
    }
  }

  void _openUserPage(User u) {
    if (u.id.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UserPage(
          uid: u.id,
          initialName: u.displayName,
          initialAvatar: u.avatar,
        ),
      ),
    );
  }

  Widget _userSearchTile(User u) {
    final following = _isFollowingUser(u);
    final bio = u.verifiedReason.isNotEmpty ? u.verifiedReason : u.description;
    return InkWell(
      onTap: () => _openUserPage(u),
      child: Container(
        color: ShareColors.cardBg,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            ClipOval(
              child: SizedBox(
                width: 46,
                height: 46,
                child: u.avatar.isNotEmpty
                    ? Image.network(
                        u.avatar,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => ColoredBox(
                          color: ShareColors.placeholder,
                          child: Icon(Icons.person, size: 22, color: ShareColors.textHint),
                        ),
                      )
                    : ColoredBox(
                        color: ShareColors.placeholder,
                        child: Icon(Icons.person, size: 22, color: ShareColors.textHint),
                      ),
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
                          u.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: ShareColors.textPrimary,
                          ),
                        ),
                      ),
                      if (u.verified) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.verified,
                          size: 15,
                          color: u.verifiedType == 2 || u.verifiedType == 3
                              ? const Color(0xFF4285F4)
                              : const Color(0xFFF5A623),
                        ),
                      ],
                    ],
                  ),
                  if (bio.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      bio,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary),
                    ),
                  ],
                  const SizedBox(height: 3),
                  Text(
                    '粉丝 ${formatCount(u.followers)}   关注 ${formatCount(u.friends)}',
                    style: TextStyle(fontSize: 11.5, color: ShareColors.textHint),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton(
              onPressed: () => _toggleFollowUser(u),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(66, 30),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                side: BorderSide(
                  color: following ? ShareColors.divider : ShareColors.accent,
                ),
                foregroundColor: following ? ShareColors.textSecondary : ShareColors.accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              ),
              child: Text(
                following ? '已关注' : '+ 关注',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
