import 'dart:convert';

import 'models.dart';

/// 用户 / 话题联想结果 —— `/ajax/side/search?q=`。
///
/// 实测返回：`user`（精确匹配 1 条）、`users`（完整用户对象）、
/// `hotquery`（约 49 条联想词）、`query_relates`、`real_hot`、`history`。
/// 访客身份就能用，因此「用户搜索」和发布页的 `@` 联想都不需要登录。
class UserSearchResult {
  /// 精确命中（服务端只给 1 条）。
  final User? exact;

  /// 模糊匹配的候选用户。
  final List<User> users;

  /// 联想词（热搜/话题），用于 `#` 联想和搜索建议。
  final List<String> suggestions;

  const UserSearchResult({
    this.exact,
    this.users = const [],
    this.suggestions = const [],
  });

  static const empty = UserSearchResult();

  bool get isEmpty => users.isEmpty && exact == null && suggestions.isEmpty;

  /// @ 联想用：精确命中优先，其次候选列表，按 uid 去重。
  List<User> get mentionCandidates {
    final seen = <String>{};
    final list = <User>[];
    for (final user in [?exact, ...users]) {
      if (seen.add(user.id)) list.add(user);
    }
    return list;
  }

  static UserSearchResult parse(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return empty;

    final data = decoded['data'];
    if (data is! Map) return empty;

    final users = <User>[];
    for (final item in (data['users'] is List ? data['users'] as List : const [])) {
      if (item is Map<String, dynamic>) {
        users.add(User.fromJson(item));
      } else if (item is Map) {
        users.add(User.fromJson(Map<String, dynamic>.from(item)));
      }
    }

    User? exact;
    final single = data['user'];
    if (single is List && single.isNotEmpty) {
      final first = single.first;
      exact = first is Map<String, dynamic>
          ? User.fromJson(first)
          : (first is Map ? User.fromJson(Map<String, dynamic>.from(first)) : null);
    }

    final suggestions = <String>[];
    for (final item in (data['hotquery'] is List ? data['hotquery'] as List : const [])) {
      if (item is Map) {
        final word = '${item['suggestion'] ?? ''}';
        if (word.isNotEmpty) suggestions.add(word);
      }
    }

    return UserSearchResult(exact: exact, users: users, suggestions: suggestions);
  }
}
