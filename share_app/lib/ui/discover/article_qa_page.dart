import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/settings.dart';
import '../../core/share_core.dart';
import '../app_theme.dart';
import '../detail/status_detail_page.dart';
import '../feed/status_card.dart';
import '../media/gallery_page.dart';
import '../media/video_page.dart';
import '../widgets/weibo_rich_text.dart';

/// 1:1 复刻 `HotStatusActivity`：依托 `/2/guest/login` + `/2/statuses/unread_hot_timeline`
/// 支持游客/登录态免阻断浏览各垂直频道热门微博。
class HotStatusPage extends ConsumerStatefulWidget {
  const HotStatusPage({super.key});

  @override
  ConsumerState<HotStatusPage> createState() => _HotStatusPageState();
}

class _HotStatusPageState extends ConsumerState<HotStatusPage> {
  static const _channels = <({String gid, String label})>[
    (gid: '102803', label: '热门'),
    (gid: '102803_ctg1_8999_-_ctg1_8999_home', label: '榜单'),
    (gid: '102803_ctg1_4388_-_ctg1_4388', label: '搞笑'),
    (gid: '102803_ctg1_2088_-_ctg1_2088', label: '科技'),
    (gid: '102803_ctg1_5088_-_ctg1_5088', label: '数码'),
    (gid: '102803_ctg1_4888_-_ctg1_4888', label: '游戏'),
    (gid: '102803_ctg1_4588_-_ctg1_4588', label: 'ACG'),
    (gid: '102803_ctg1_4288_-_ctg1_4288', label: '社会'),
  ];

  int _channelIndex = 0;
  List<Status> _items = const [];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final res = await ShareCore.instance.hotTimelineDual(
        groupId: _channels[_channelIndex].gid,
        count: ref.read(settingsProvider).feedPageSize,
      );
      final rawList = (res['statuses'] as List?) ?? const [];
      final parsed = rawList
          .whereType<Map<String, dynamic>>()
          .map(Status.fromJson)
          .where((s) => s.id.isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        _items = reset ? parsed : [..._items, ...parsed];
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (reset) _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('热门微博')),
      body: Column(
        children: [
          Container(
            height: 44,
            color: ShareColors.cardBg,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              itemCount: _channels.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final active = i == _channelIndex;
                return ChoiceChip(
                  label: Text(_channels[i].label, style: const TextStyle(fontSize: 12.5)),
                  selected: active,
                  onSelected: (_) {
                    if (i != _channelIndex) {
                      setState(() => _channelIndex = i);
                      _load(reset: true);
                    }
                  },
                );
              },
            ),
          ),
          Divider(height: 0.5, color: ShareColors.divider),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _load(reset: true),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      color: ShareColors.accent,
      onRefresh: () => _load(reset: true),
      child: ListView.separated(
        itemCount: _items.length + 1,
        separatorBuilder: (_, _) => Divider(height: 8, thickness: 8, color: ShareColors.pageBg),
        itemBuilder: (context, i) {
          if (i == _items.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: _loadingMore
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: () => _load(reset: false),
                        child: const Text('加载更多热门'),
                      ),
              ),
            );
          }
          final st = _items[i];
          return StatusCard(
            status: st,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => StatusDetailPage(status: st)),
            ),
            onImageTap: (idx) => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => GalleryPage(pics: st.pics, initialIndex: idx)),
            ),
            onVideoTap: () {
              final url = st.videoUrl ?? '';
              if (url.isNotEmpty || (st.videoObjectId ?? '').isNotEmpty) {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => VideoPage(
                      url: url,
                      objectId: st.videoObjectId,
                      cover: st.videoCover,
                      title: st.textRaw,
                    ),
                  ),
                );
              }
            },
          );
        },
      ),
    );
  }
}

/// 1:1 复刻 `ArticleActivity`（头条文章长文阅读器）。
class ArticlePage extends StatefulWidget {
  final String oid;
  final String? title;

  const ArticlePage({super.key, required this.oid, this.title});

  @override
  State<ArticlePage> createState() => _ArticlePageState();
}

class _ArticlePageState extends State<ArticlePage> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ShareCore.instance.articleShow(widget.oid);
      if (!mounted) return;
      setState(() {
        _data = res;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = '${_data?['title'] ?? widget.title ?? '头条文章'}';
    final content = '${_data?['content'] ?? _data?['summary'] ?? ''}';
    final author = '${_data?['userinfo']?['screen_name'] ?? _data?['author'] ?? ''}';
    final cover = '${_data?['cover_image']?['url'] ?? _data?['cover'] ?? ''}';

    return Scaffold(
      appBar: AppBar(title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : (_error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!),
                      const SizedBox(height: 12),
                      OutlinedButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, height: 1.35),
                    ),
                    if (author.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text('作者：$author',
                          style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
                    ],
                    if (cover.startsWith('http')) ...[
                      const SizedBox(height: 14),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(cover, fit: BoxFit.cover),
                      ),
                    ],
                    const SizedBox(height: 16),
                    WeiboRichText(
                      html: content.isEmpty ? '暂无正文内容' : content,
                      fontSize: 16,
                      height: 1.65,
                      color: ShareColors.textPrimary,
                      linkColor: ShareColors.link,
                    ),
                  ],
                )),
    );
  }
}

/// 1:1 复刻 `QAActivity`（微博问答详情与围观）。
class QaPage extends StatefulWidget {
  final String oid;
  final String? title;

  const QaPage({super.key, required this.oid, this.title});

  @override
  State<QaPage> createState() => _QaPageState();
}

class _QaPageState extends State<QaPage> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ShareCore.instance.qaShow(widget.oid);
      if (!mounted) return;
      setState(() {
        _data = res;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _watch() async {
    try {
      await ShareCore.instance.qaWatch(widget.oid);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final question = '${_data?['title'] ?? _data?['question'] ?? widget.title ?? '微博问答'}';
    final answer = '${_data?['answer_content'] ?? _data?['content'] ?? ''}';
    final answerer = '${_data?['answer_user']?['screen_name'] ?? ''}';

    return Scaffold(
      appBar: AppBar(title: const Text('微博问答')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : (_error != null
              ? Center(child: Text(_error!))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      question,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, height: 1.4),
                    ),
                    const SizedBox(height: 12),
                    if (answerer.isNotEmpty)
                      Text('答主：$answerer',
                          style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
                    const Divider(height: 24),
                    if (answer.isNotEmpty)
                      WeiboRichText(
                        html: answer,
                        fontSize: 15.5,
                        height: 1.6,
                        color: ShareColors.textPrimary,
                        linkColor: ShareColors.link,
                      )
                    else
                      Column(
                        children: [
                          Text('点击围观查看完整回答内容',
                              style: TextStyle(color: ShareColors.textSecondary)),
                          const SizedBox(height: 12),
                          FilledButton(onPressed: _watch, child: const Text('免费围观 / 刷新')),
                        ],
                      ),
                  ],
                )),
    );
  }
}

/// 1:1 复刻通用 `CardListActivity`（超话社区分栏 / 新鲜事 / 搜索专题卡片流）。
class CardListPage extends StatefulWidget {
  final String containerid;
  final String title;

  const CardListPage({
    super.key,
    required this.containerid,
    required this.title,
  });

  @override
  State<CardListPage> createState() => _CardListPageState();
}

class _CardListPageState extends State<CardListPage> {
  List<dynamic> _cards = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ShareCore.instance.cardlist(widget.containerid, page: 1);
      if (!mounted) return;
      setState(() {
        _cards = (res['cards'] as List?) ?? const [];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final flatStatuses = <Status>[];
    final cardTiles = <Map<String, dynamic>>[];

    for (final c in _cards) {
      if (c is! Map<String, dynamic>) continue;
      if (c['mblog'] is Map<String, dynamic>) {
        flatStatuses.add(Status.fromJson(c['mblog'] as Map<String, dynamic>));
      } else if (c['card_group'] is List) {
        for (final sub in (c['card_group'] as List)) {
          if (sub is Map<String, dynamic>) {
            if (sub['mblog'] is Map<String, dynamic>) {
              flatStatuses.add(Status.fromJson(sub['mblog'] as Map<String, dynamic>));
            } else {
              cardTiles.add(sub);
            }
          }
        }
      } else {
        cardTiles.add(c);
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : (_error != null
              ? Center(child: Text(_error!))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    children: [
                      for (final tile in cardTiles)
                        if ('${tile['title_sub'] ?? tile['desc'] ?? tile['title'] ?? ''}'
                            .isNotEmpty)
                          ListTile(
                            title: Text('${tile['title_sub'] ?? tile['title'] ?? tile['desc']}'),
                            subtitle: tile['desc1'] != null ? Text('${tile['desc1']}') : null,
                          ),
                      for (final st in flatStatuses)
                        StatusCard(
                          status: st,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => StatusDetailPage(status: st)),
                          ),
                        ),
                    ],
                  ),
                )),
    );
  }
}
