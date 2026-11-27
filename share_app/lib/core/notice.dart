import 'models.dart';

/// 通知中心 view models.
///
/// The original APK's `StatusNotifyActivity` had four independent feeds; each
/// maps to one weibo.com endpoint and one JSON array inside `data`:
///
/// | 通知分类      | endpoint                  | array              |
/// |--------------|---------------------------|--------------------|
/// | 微博提到我    | `/ajax/statuses/mentions` | `statuses[]`       |
/// | 评论提到我    | `/ajax/comments/mentions` | `comments[]`       |
/// | 我收到的评论  | `/ajax/message/cmt`       | `comments[]`       |
/// | 我收到的赞    | `/ajax/message/attitudes` | `attitudes[]`      |
enum NoticeKind {
  atWeibo('微博提到我', '/ajax/statuses/mentions'),
  comment('收到的评论', '/ajax/message/cmt'),
  like('收到的赞', '/ajax/message/attitudes'),
  atComment('评论提到我', '/ajax/comments/mentions');

  const NoticeKind(this.label, this.path);
  final String label;
  final String path;
}

class Notice {
  final String id;
  final NoticeKind kind;

  /// Both feeds use the classic `Sat Jun 22 18:07:52 +0800 2024` format.
  final String createdAt;

  /// Who @ed me / commented / liked.
  final User? from;

  /// Comment body (empty for likes).
  final String textHtml;

  /// The status the notice is about. For [NoticeKind.atWeibo] this *is* the
  /// `@`-ed status, so the list can reuse `StatusCard`.
  final Status? status;

  /// When someone replied to one of *my* comments, `reply_comment` carries it.
  final String? myComment;

  /// `heart` / `like` / ... for [NoticeKind.like].
  final String attitude;

  const Notice({
    required this.id,
    required this.kind,
    required this.createdAt,
    this.from,
    this.textHtml = '',
    this.status,
    this.myComment,
    this.attitude = 'heart',
  });
}

class NoticeFeed {
  final List<Notice> notices;

  /// Only populated for [NoticeKind.atWeibo].
  final List<Status> statuses;

  /// `data.total_number` — used for the tab badge.
  final int total;

  final bool hasMore;

  const NoticeFeed({
    this.notices = const [],
    this.statuses = const [],
    this.total = 0,
    this.hasMore = false,
  });

  bool get isEmpty => notices.isEmpty && statuses.isEmpty;

  static NoticeFeed parse(String raw, NoticeKind kind) {
    final json = decodeObject(raw);
    final rawData = json['data'];
    final hasMobileArray = switch (kind) {
      NoticeKind.atWeibo => json['statuses'] is List,
      NoticeKind.like => json['attitudes'] is List,
      NoticeKind.comment || NoticeKind.atComment => json['comments'] is List,
    };
    final Map<String, dynamic> data;
    if (rawData is Map<String, dynamic>) {
      data = rawData;
    } else if (hasMobileArray) {
      data = json;
    } else {
      // `/ajax/*` answers `{"ok":0,"message":"..."}` and mobile `/2/*` answers `{"error":...}`
      final message = json['message'] ?? json['msg'] ?? json['error'] ?? json['errmsg'] ?? '接口返回了意外的结构';
      throw FormatException('$message');
    }

    final total = jsonInt(data['total_number']);
    final nextCursor = jsonInt(data['next_cursor']);
    final maxId = data['max_id']?.toString() ?? '';
    final hasNextCursor = nextCursor > 0 || (maxId.isNotEmpty && maxId != '0');

    if (kind == NoticeKind.atWeibo) {
      final list = (data['statuses'] as List?) ?? const [];
      final statuses = list
          .map(jsonMap)
          .whereType<Map<String, dynamic>>()
          .map(Status.fromJson)
          .toList();
      return NoticeFeed(
        statuses: statuses,
        total: total,
        hasMore: statuses.isNotEmpty && (hasNextCursor || statuses.length >= 15),
      );
    }

    if (kind == NoticeKind.like) {
      final list = (data['attitudes'] as List?) ?? const [];
      final notices = <Notice>[];
      for (final rawItem in list) {
        final item = jsonMap(rawItem);
        if (item == null) continue;
        final userMap = jsonMap(item['user']);
        final statusMap = jsonMap(item['status']);
        notices.add(Notice(
          id: '${item['id'] ?? item['idstr'] ?? item['idStr'] ?? ''}',
          kind: kind,
          createdAt: jsonStr(item['created_at']),
          from: userMap != null ? User.fromJson(userMap) : null,
          status: statusMap != null ? Status.fromJson(statusMap) : null,
          attitude: (item['attitude'] ?? item['attitude_type'] ?? 'heart').toString(),
        ));
      }
      return NoticeFeed(
        notices: notices,
        total: total,
        hasMore: notices.isNotEmpty && (hasNextCursor || notices.length >= 15),
      );
    }

    final list = (data['comments'] as List?) ?? const [];
    final notices = <Notice>[];
    for (final rawItem in list) {
      final item = jsonMap(rawItem);
      if (item == null) continue;
      final reply = jsonMap(item['reply_comment']);
      final userMap = jsonMap(item['user']);
      final statusMap = jsonMap(item['status']);
      notices.add(Notice(
        id: '${item['id'] ?? item['idstr'] ?? ''}',
        kind: kind,
        createdAt: jsonStr(item['created_at']),
        from: userMap != null ? User.fromJson(userMap) : null,
        textHtml: jsonStr(item['text']),
        status: statusMap != null ? Status.fromJson(statusMap) : null,
        myComment: reply != null ? jsonNullableStr(reply['text']) : null,
      ));
    }
    return NoticeFeed(
      notices: notices,
      total: total,
      hasMore: notices.isNotEmpty && (hasNextCursor || notices.length >= 15),
    );
  }
}

/// Unread badges for the message hub.
///
/// weibo.com only exposes a coarse payload: `data.apps[]` entries (one per
/// message category) plus two DM counters. We read whatever counts are present
/// and simply hide the badge when the server sends nothing — no invented
/// numbers.
class UnreadHint {
  final Map<String, int> counts;
  final int dmUsers;
  final int dmGroups;

  const UnreadHint({
    this.counts = const {},
    this.dmUsers = 0,
    this.dmGroups = 0,
  });

  int get dm => dmUsers + dmGroups;

  /// 底栏「消息」红点用的总数：各通知分类之和 + 私信未读。
  ///
  /// 服务端没给的分类不计入，所以未登录 / 接口没回数据时这里就是 0，
  /// 红点也就能干净地不显示。
  int get total {
    var sum = 0;
    for (final value in counts.values) {
      if (value > 0) sum += value;
    }
    return sum + dm;
  }

  int countFor(NoticeKind kind) {
    for (final key in _keysFor(kind)) {
      final value = counts[key];
      if (value != null && value > 0) return value;
    }
    return 0;
  }

  static const Map<NoticeKind, List<String>> _aliases = {
    NoticeKind.atWeibo: ['at_weibo', 'atweibo', 'at', 'mention'],
    NoticeKind.comment: ['cmt', 'comment', 'comments'],
    NoticeKind.like: ['attitude', 'attitudes', 'like', 'likes'],
    NoticeKind.atComment: ['at_comment', 'atcomment', 'comment_mention'],
  };

  static List<String> _keysFor(NoticeKind kind) => _aliases[kind] ?? const [];

  static UnreadHint parse(String raw) {
    final json = decodeObject(raw);
    final counts = <String, int>{};

    final data = json['data'];
    if (data is Map<String, dynamic>) {
      final apps = data['apps'];
      if (apps is List) {
        for (final app in apps.whereType<Map<String, dynamic>>()) {
          final name = _firstString(app, const ['app_name', 'name', 'id', 'app_id']);
          final value = _firstInt(app, const ['unread', 'count', 'num', 'unread_count', 'badge']);
          if (name != null && value != null && value > 0) {
            counts[name.toLowerCase()] = value;
          }
        }
      }
      return UnreadHint(
        counts: counts,
        dmUsers: jsonInt(data['page_friends_to_me']),
        dmGroups: jsonInt(data['page_group_to_me']),
      );
    }

    // Mobile `/2/remind/unread_count` top-level payload:
    // { cmt, mention_status, mention_cmt, attitude, dm, dm_single, group, msgbox, follower }
    void putIfPos(String key, List<String> srcKeys) {
      final v = _firstInt(json, srcKeys);
      if (v != null && v > 0) counts[key] = v;
    }

    putIfPos('at_weibo', const ['mention_status']);
    putIfPos('cmt', const ['cmt']);
    putIfPos('attitude', const ['attitude']);
    putIfPos('at_comment', const ['mention_cmt']);

    final dmUsers = _firstInt(json, const ['dm', 'dm_single', 'page_friends_to_me']) ?? 0;
    final dmGroups = _firstInt(json, const ['page_group_to_me', 'msgbox']) ?? 0;
    return UnreadHint(
      counts: counts,
      dmUsers: dmUsers,
      dmGroups: dmGroups == dmUsers ? 0 : dmGroups,
    );
  }

  static String? _firstString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is String && value.isNotEmpty) return value;
      if (value is num) return '$value';
    }
    return null;
  }

  static int? _firstInt(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is num) return value.toInt();
      if (value is String) {
        final parsed = int.tryParse(value);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }
}
