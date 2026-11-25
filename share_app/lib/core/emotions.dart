import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 微博表情 —— `/ajax/statuses/config` 的 `data.emoticon.ZH_CN`。
///
/// 2026-11 实测：10 个分类、348 个表情。每个表情是「短语 + PNG 地址」，
/// 发出去时正文里写 `[塔露拉]`，时间线渲染时由富文本层换成图片。
class Emoticon {
  final String phrase;
  final String url;

  const Emoticon({required this.phrase, required this.url});

  /// `[微笑]` -> `微笑`（用于搜索/无障碍标签）。
  String get name => phrase.replaceAll('[', '').replaceAll(']', '');
}

class EmoticonCategory {
  final String title;
  final List<Emoticon> items;

  const EmoticonCategory({required this.title, required this.items});
}

class EmoticonSet {
  final List<EmoticonCategory> categories;

  const EmoticonSet(this.categories);

  static const empty = EmoticonSet([]);

  bool get isEmpty => categories.isEmpty;

  int get total => categories.fold(0, (sum, c) => sum + c.items.length);

  static EmoticonSet parse(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return empty;

    final data = decoded['data'];
    if (data is! Map) return empty;

    final emoticon = data['emoticon'];
    if (emoticon is! Map) return empty;

    // 服务端目前只下发 ZH_CN，但保留其它语言的兜底。
    final lang = emoticon['ZH_CN'] ?? emoticon.values.firstWhere(
          (v) => v is Map,
          orElse: () => null,
        );
    if (lang is! Map) return empty;

    return EmoticonSet([
      for (final entry in lang.entries)
        EmoticonCategory(
          title: '${entry.key}',
          items: [
            for (final item in (entry.value is List ? entry.value as List : const []))
              if (item is Map && item['phrase'] != null && item['url'] != null)
                Emoticon(
                  phrase: '${item['phrase']}',
                  url: '${item['url']}',
                ),
          ],
        ),
    ].where((c) => c.items.isNotEmpty).toList());
  }
}

/// Runtime cache of Sina online emoticon phrases (`[淡淡的]`, `[塔露拉]`, etc.)
/// so [RichTextParser] can render modern Weibo emojis cleanly even when they
/// aren't in the legacy Share APK offline PNG bundle.
class EmoticonRegistry {
  EmoticonRegistry._();

  static final EmoticonRegistry instance = EmoticonRegistry._();

  final Map<String, String> _urls = <String, String>{};
  final ValueNotifier<int> version = ValueNotifier<int>(0);

  bool get isEmpty => _urls.isEmpty;
  int get length => _urls.length;

  static String _normalizeUrl(String url) {
    final u = url.trim();
    if (u.startsWith('//')) return 'https:$u';
    return u;
  }

  void registerPairs(Map<String, String> pairs) {
    var added = false;
    pairs.forEach((k, v) {
      final key = k.trim();
      final val = _normalizeUrl(v);
      if (key.isEmpty || val.isEmpty) return;
      if (_urls[key] != val) {
        _urls[key] = val;
        added = true;
      }
      if (!key.startsWith('[')) {
        final bracketed = '[$key]';
        if (_urls[bracketed] != val) {
          _urls[bracketed] = val;
          added = true;
        }
      }
    });
    if (added) version.value++;
  }

  void registerSet(EmoticonSet set) {
    var added = false;
    for (final cat in set.categories) {
      for (final item in cat.items) {
        final phrase = item.phrase.trim();
        final url = _normalizeUrl(item.url);
        if (phrase.isEmpty || url.isEmpty) continue;
        if (_urls[phrase] != url) {
          _urls[phrase] = url;
          added = true;
        }
      }
    }
    if (added) version.value++;
  }

  void loadFlatJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final pairs = <String, String>{};
        decoded.forEach((k, v) {
          if (k is String && v is String && v.isNotEmpty) {
            pairs[k] = v;
          }
        });
        registerPairs(pairs);
      }
    } catch (_) {}
  }

  String exportFlatJson() => jsonEncode(_urls);

  String? urlFor(String phrase) {
    final direct = _urls[phrase];
    if (direct != null) return direct;
    if (!phrase.startsWith('[')) return _urls['[$phrase]'];
    return null;
  }
}
