import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api.dart';
import '../../core/emotions.dart';
import '../../core/offline_emoticons.dart';
import '../app_theme.dart';

/// Opens the offline-first 4-tab EmojiPanel modal bottom sheet.
Future<void> showEmojiPanel(BuildContext context, ValueChanged<String> onPick) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: ShareColors.cardBg,
    isScrollControlled: true,
    builder: (_) => EmojiPanel(onPick: onPick),
  );
}

/// Offline-first 4-tab Emoticon Picker matching Share v3.9.6:
/// 1) 经典微博表情 (174 primary offline assets)
/// 2) Emoji (396 Unicode codepoints from arrays.xml `array/ai`)
/// 3) 颜文字 (Kaomoji presets)
/// 4) 在线扩展 (loaded lazily on demand via `WeiboApi.instance.emotions()`)
class EmojiPanel extends StatefulWidget {
  final ValueChanged<String> onPick;

  const EmojiPanel({super.key, required this.onPick});

  @override
  State<EmojiPanel> createState() => _EmojiPanelState();
}

class _EmojiPanelState extends State<EmojiPanel> {
  static const _recentKey = 'prefs_recent_emoticons';

  int _tab = 0; // 0=Offline, 1=Unicode Emoji, 2=Kaomoji, 3=Online
  List<String> _recent = const [];
  EmoticonSet? _onlineSet;
  bool _loadingOnline = false;
  String? _onlineError;
  int _onlineCategory = 0;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_recentKey);
    if (mounted && list != null) {
      setState(() => _recent = list);
    }
  }

  Future<void> _pickPhrase(String phrase) async {
    widget.onPick(phrase);
    final updated = [phrase, ..._recent.where((e) => e != phrase)].take(16).toList();
    setState(() => _recent = updated);
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_recentKey, updated);
  }

  Future<void> _loadOnline() async {
    if (_onlineSet != null || _loadingOnline) return;
    setState(() {
      _loadingOnline = true;
      _onlineError = null;
    });
    try {
      final set = await WeiboApi.instance.emotions();
      if (!mounted) return;
      setState(() {
        _onlineSet = set;
        _loadingOnline = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _onlineError = '$e';
        _loadingOnline = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 332,
      color: ShareColors.cardBg,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
            child: Row(
              children: [
                _tabChip(0, '默认 (${kSharePrimaryEmoticonCodes.length})'),
                const SizedBox(width: 6),
                _tabChip(1, 'Emoji (${kShareUnicodeEmojis.length})'),
                const SizedBox(width: 6),
                _tabChip(2, '颜文字'),
                const SizedBox(width: 6),
                _tabChip(3, '在线', onTap: () {
                  setState(() => _tab = 3);
                  _loadOnline();
                }),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.close, size: 18, color: ShareColors.textHint),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
          ),
          Divider(height: 0.5, color: ShareColors.divider),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _tabChip(int idx, String label, {VoidCallback? onTap}) {
    final active = _tab == idx;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap ?? () => setState(() => _tab = idx),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? ShareColors.accent.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: active ? ShareColors.accent : ShareColors.textSecondary,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_tab) {
      case 0:
        return _buildOfflineGrid();
      case 1:
        return GridView.builder(
          padding: const EdgeInsets.all(10),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 8,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
          ),
          itemCount: kShareUnicodeEmojis.length,
          itemBuilder: (context, i) {
            final emoji = kShareUnicodeEmojis[i];
            return InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _pickPhrase(emoji),
              child: Center(
                child: Text(emoji, style: const TextStyle(fontSize: 22)),
              ),
            );
          },
        );
      case 2:
        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: kShareKaomojiList.length,
          separatorBuilder: (_, _) => const SizedBox(height: 6),
          itemBuilder: (context, i) {
            final item = kShareKaomojiList[i];
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _pickPhrase(item),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: ShareColors.repostBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  item,
                  style: TextStyle(fontSize: 15, color: ShareColors.textPrimary),
                ),
              ),
            );
          },
        );
      default:
        return _buildOnlineBody();
    }
  }

  Widget _buildOfflineGrid() {
    final codes = <String>[
      ..._recent.where((c) => kShareEmoticonAssets.containsKey(c)),
      ...kSharePrimaryEmoticonCodes,
    ];
    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: codes.length,
      itemBuilder: (context, i) {
        final code = codes[i];
        final asset = kShareEmoticonAssets[code];
        return Tooltip(
          message: code,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _pickPhrase(code),
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: asset != null
                  ? Image.asset(
                      asset,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    )
                  : Center(
                      child: Text(
                        code,
                        style: const TextStyle(fontSize: 11),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildOnlineBody() {
    if (_loadingOnline) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_onlineError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_onlineError!, style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary)),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _loadOnline, child: const Text('重试')),
          ],
        ),
      );
    }
    final set = _onlineSet;
    if (set == null || set.isEmpty) {
      return Center(
        child: Text('暂无在线扩展表情', style: TextStyle(color: ShareColors.textHint)),
      );
    }
    final cats = set.categories;
    final current = cats[_onlineCategory.clamp(0, cats.length - 1)];
    return Column(
      children: [
        SizedBox(
          height: 32,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            itemCount: cats.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final active = i == _onlineCategory;
              return ActionChip(
                label: Text(
                  cats[i].title,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: active ? ShareColors.accent : ShareColors.textSecondary,
                  ),
                ),
                onPressed: () => setState(() => _onlineCategory = i),
              );
            },
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(10),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: current.items.length,
            itemBuilder: (context, i) {
              final em = current.items[i];
              final asset = kShareEmoticonAssets[em.phrase];
              return Tooltip(
                message: em.phrase,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _pickPhrase(em.phrase),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: asset != null
                        ? Image.asset(asset, fit: BoxFit.contain)
                        : Image.network(em.url, fit: BoxFit.contain),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
