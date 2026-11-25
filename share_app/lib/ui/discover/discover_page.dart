import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/settings.dart';
import '../app_theme.dart';
import '../login/qr_scan_page.dart';
import '../profile/user_search_page.dart';
import '../search/search_page.dart';
import '../stopic/stopic_page.dart';
import 'article_qa_page.dart';

class DiscoverPage extends ConsumerStatefulWidget {
  const DiscoverPage({super.key});

  @override
  ConsumerState<DiscoverPage> createState() => _DiscoverPageState();}

class _DiscoverPageState extends ConsumerState<DiscoverPage> {
  List<HotSearchCategory> _categories = [];
  int _catIndex = 0;
  bool _loadingCat = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (ref.read(settingsProvider).hideHotSearch) {
      setState(() {
        _loading = false;
        _error = null;
        _categories = const [];
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cats = await WeiboApi.instance.hotSearchCategories();
      if (!mounted) return;
      setState(() {
        _categories = cats;
        if (_catIndex >= cats.length) _catIndex = 0;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _selectCategory(int index) async {
    if (index < 0 || index >= _categories.length || index == _catIndex) return;
    setState(() {
      _catIndex = index;
      _loadingCat = false;
    });
    final cat = _categories[index];
    if (cat.items.isEmpty && (cat.containerid ?? '').isNotEmpty) {
      setState(() => _loadingCat = true);
      try {
        final items = await WeiboApi.instance.hotSearchCategoryItems(cat);
        if (!mounted) return;
        setState(() {
          _categories[index] = cat.copyWith(items: items);
          _loadingCat = false;
        });
      } catch (_) {
        if (mounted) setState(() => _loadingCat = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('发现')),
      body: RefreshIndicator(
        color: ShareColors.accent,
        onRefresh: _load,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null) {
      return ListView(
        children: [
          SizedBox(height: 120),
          Center(
            child: Column(
              children: [
                Text(_error!,
                    style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
                SizedBox(height: 12),
                OutlinedButton(onPressed: _load, child: Text('重试')),
              ],
            ),
          ),
        ],
      );
    }

    final activeItems = _categories.isEmpty
        ? const <HotSearchItem>[]
        : _categories[_catIndex.clamp(0, _categories.length - 1)].items;

    return ListView.separated(
      itemCount: activeItems.isEmpty ? 3 : activeItems.length + 2,
      separatorBuilder: (_, _) =>
          Divider(height: 0.5, thickness: 0.5, color: ShareColors.divider),
      itemBuilder: (context, index) {
        if (index == 0) return _entries();
        if (index == 1) {
          if (_categories.isEmpty) return const SizedBox.shrink();
          return Container(
            height: 40,
            color: ShareColors.cardBg,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _categories.length,
              separatorBuilder: (_, _) => const SizedBox(width: 4),
              itemBuilder: (context, i) {
                final cat = _categories[i];
                final selected = i == _catIndex;
                return InkWell(
                  onTap: () => _selectCategory(i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: selected ? ShareColors.accent : Colors.transparent,
                          width: 2,
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
          );
        }
        if (activeItems.isEmpty && index == 2) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: _loadingCat
                  ? const CircularProgressIndicator(strokeWidth: 2)
                  : Text('该分类暂无热搜',
                      style: TextStyle(fontSize: 13, color: ShareColors.textHint)),
            ),
          );
        }
        final item = activeItems[index - 2];
        return InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => SearchPage(initialKeyword: item.word)),
          ),
          child: Container(
          color: ShareColors.cardBg,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  '${item.rank}',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: _rankColor(item.rank),
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  item.word,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, color: ShareColors.textPrimary),
                ),
              ),
              if (item.label.isNotEmpty && item.label != ' ')
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: _labelColor(item.label).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    item.label,
                    style: TextStyle(fontSize: 10, color: _labelColor(item.label)),
                  ),
                ),
              Text(
                item.hot > 0 ? formatCount(item.hot) : '',
                style: TextStyle(fontSize: 12, color: ShareColors.textHint),
              ),
            ],
          ),
        ),
        );
      },
    );
  }

  Widget _entries() {
    return Container(
      color: ShareColors.cardBg,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const HotStatusPage()),
                  ),
                  child: _entry(Icons.local_fire_department_outlined, '热门微博'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const StopicPage()),
                  ),
                  child: _entry(Icons.tag, '超话'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SearchPage()),
                  ),
                  child: _entry(Icons.search, '微博搜索'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const UserSearchPage()),
                  ),
                  child: _entry(Icons.person_search_outlined, '找人'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const CardListPage(
                        containerid: '102803_ctg1_8999_-_ctg1_8999_home',
                        title: '热门榜单',
                      ),
                    ),
                  ),
                  child: _entry(Icons.trending_up, '榜单'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const QrScanPage()),
                  ),
                  child: _entry(Icons.qr_code_scanner, '扫一扫'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _entry(IconData icon, String label) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: ShareColors.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 17, color: ShareColors.accent),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(fontSize: 14, color: ShareColors.textPrimary)),
        ],
      ),
    );
  }

  Color _rankColor(int rank) {
    if (rank == 1) return Color(0xFFE64545);
    if (rank == 2) return Color(0xFFF2711C);
    if (rank == 3) return Color(0xFFF5A623);
    return ShareColors.textSecondary;
  }

  Color _labelColor(String label) {
    switch (label) {
      case '爆':
        return Color(0xFFE64545);
      case '热':
        return Color(0xFFF2711C);
      case '新':
        return Color(0xFF3BA55C);
      case '沸':
        return Color(0xFFE64545);
      default:
        return ShareColors.textSecondary;
    }
  }
}
