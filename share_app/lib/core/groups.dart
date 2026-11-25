import 'dart:convert';

/// 微博分组 —— `/ajax/feed/allGroups`。
///
/// 游客也能拿到完整结构：默认分组（全部关注 / 最新微博 / 互相关注 / 原创 /
/// 视频 / V+微博 / 群微博）、我的分组（悄悄关注）、订阅分组、我的频道。
/// 只有分组**时间线**需要登录。
class WeiboGroup {
  final String gid;
  final String title;
  final String navigationTitle;
  final int count;

  /// `1` 全部关注 / `20` 最新微博 / `9` 互相关注 / `10` 群微博 / `5` 悄悄关注 /
  /// `8888` 频道。
  final String type;

  /// 分组自带的时间线路径（如 `statuses/friends/timeline`）。
  final String apiPath;

  /// 频道容器 id（热门频道 = `102803`）。
  final String containerId;
  final bool system;

  const WeiboGroup({
    required this.gid,
    required this.title,
    this.navigationTitle = '',
    this.count = 0,
    this.type = '',
    this.apiPath = '',
    this.containerId = '',
    this.system = false,
  });

  /// 热门频道不需要登录，可以直接换成首页的热门时间线。
  bool get isHotChannel => containerId == '102803' || type == '8888';

  /// 需要登录才能看内容的分组（几乎所有非频道分组）。
  bool get needsLogin => !isHotChannel;

  String get label => navigationTitle.isNotEmpty ? navigationTitle : title;

  static List<WeiboGroup> parseList(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((json) => WeiboGroup(
              gid: '${json['gid'] ?? json['idstr'] ?? json['id'] ?? ''}',
              title: '${json['title'] ?? json['name'] ?? ''}',
              navigationTitle: '${json['navigation_title'] ?? ''}',
              count: (json['count'] ?? json['member_count'] as num?)?.toInt() ?? 0,
              type: '${json['type'] ?? ''}',
              apiPath: '${json['apipath'] ?? ''}',
              containerId: '${json['containerid'] ?? ''}',
              system: '${json['sysgroup'] ?? ''}' == '2',
            ))
        .where((g) => g.gid.isNotEmpty || g.containerId.isNotEmpty)
        .toList();
  }
}

class GroupCategory {
  final String title;
  final List<WeiboGroup> groups;

  const GroupCategory({required this.title, required this.groups});
}

class GroupSet {
  final List<GroupCategory> categories;

  const GroupSet(this.categories);

  bool get isEmpty => categories.every((c) => c.groups.isEmpty);

  List<WeiboGroup> get all => categories.expand((c) => c.groups).toList();

  /// 首页「关注」分组（默认分组里的全部关注）。
  WeiboGroup? get followGroup {
    for (final group in all) {
      if (group.type == '1') return group;
    }
    return null;
  }

  WeiboGroup? get hotChannel {
    for (final group in all) {
      if (group.isHotChannel) return group;
    }
    return null;
  }

  static GroupSet parse(String raw) {
    final decoded = _decode(raw);
    final list = decoded['groups'];
    if (list is List) {
      return GroupSet([
        for (final category in list.whereType<Map>())
          GroupCategory(
            title: '${category['title'] ?? '分组'}',
            groups: WeiboGroup.parseList(category['group']),
          ),
      ]);
    }
    // Mobile `/2/groups` returns `lists: [{ idstr, id, name, member_count }]`.
    final mobileLists = decoded['lists'];
    if (mobileLists is List) {
      return GroupSet([
        GroupCategory(
          title: '我的分组',
          groups: WeiboGroup.parseList(mobileLists),
        ),
      ]);
    }
    final message = decoded['message'] ?? decoded['error'] ?? decoded['errmsg'];
    throw FormatException(message is String && message.isNotEmpty ? message : '分组数据为空');
  }

  static Map<String, dynamic> _decode(String raw) {
    final value = jsonDecode(raw);
    return value is Map<String, dynamic> ? value : <String, dynamic>{};
  }
}
