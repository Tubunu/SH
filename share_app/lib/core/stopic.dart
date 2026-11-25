import 'models.dart';

/// 超话 view models.
///
/// Endpoints (from the `weibo-pro-next` SPA bundle):
///   `/ajax/stopic/cates`  -> `{data: [{id, name}]}`
///   `/ajax/stopic/list`   -> `{data: [{title, image, page_id, description}], count}`
///
/// The per-topic feed is login-gated (`/ajax/profile/topicContent` answers
/// `data: {}` for visitors), so [StopicDetailPage] shows status-search results
/// for `#话题#` instead of faking a native feed.
class StopicCate {
  final int id;
  final String name;

  const StopicCate({required this.id, required this.name});

  static List<StopicCate> parseList(String raw) {
    final json = decodeObject(raw);
    final data = json['data'];
    if (data is! List) return const [];
    return data
        .whereType<Map<String, dynamic>>()
        .map((e) => StopicCate(
              id: (e['id'] as num?)?.toInt() ?? 0,
              name: (e['name'] ?? '') as String,
            ))
        .where((c) => c.name.isNotEmpty)
        .toList();
  }
}

class Stopic {
  final String pageId;
  final String title;
  final String image;
  final String description;

  /// Weibo prefixes the description with `123.4万粉丝 `; split it out so the UI
  /// can show a real number instead of a run-on paragraph.
  final String fans;

  const Stopic({
    required this.pageId,
    required this.title,
    this.image = '',
    this.description = '',
    this.fans = '',
  });

  /// The hashtag used for the status-search feed.
  String get hashtag => '#$title#';

  /// `count` in the payload is the number of **pages**, not the number of
  /// items (`page >= count` stops paging in the official SPA).
  static ({List<Stopic> items, int pages}) parse(String raw) {
    final json = decodeObject(raw);
    if (json['errno'] is num && (json['errno'] as num).toInt() != 0) {
      final msg = json['errmsg'] ?? json['msg'] ?? '超话接口返回错误';
      throw FormatException('$msg');
    }
    final data = json['data'];
    if (data is! List) return (items: <Stopic>[], pages: 0);
    final pages = (json['count'] as num?)?.toInt() ?? 0;

    final items = <Stopic>[];
    for (final e in data.whereType<Map<String, dynamic>>()) {
      final title = (e['title'] ?? '') as String;
      if (title.isEmpty) continue;
      final desc = (e['description'] ?? '') as String;
      final (fans, body) = _splitFans(desc);
      items.add(Stopic(
        pageId: (e['page_id'] ?? e['id'] ?? '') as String,
        title: title,
        image: (e['image'] ?? '') as String,
        description: body,
        fans: fans,
      ));
    }
    return (items: items, pages: pages);
  }

  static (String, String) _splitFans(String desc) {
    final match = RegExp(r'^([0-9.]+\s*[万亿]?粉丝)\s*').firstMatch(desc);
    if (match == null) return ('', desc);
    return (match.group(1)!.replaceAll(' ', ''), desc.substring(match.end));
  }
}
