import 'models.dart';

/// 私信 view models.
///
/// Transport is the official WebIM API on `api.weibo.com`. Verified against the
/// shipped `pcweibochat` bundle: it authenticates with cookies only
/// (`withCredentials: true`, no `access_token` anywhere in the code), so the
/// same `SUB`/`SUBP` session captured by the login WebView is enough.
///
/// Response shapes come from that bundle too:
///   conversation.json     -> `conversations[]` with `user` + `last_message`
///   recent_messages.json  -> `direct_messages[]` with `sender_id` / `text`
///   new.json              -> the created message
/// Every parser below therefore accepts the canonical key first and falls back
/// to the flat variants, but **never** fabricates an empty list out of a failed
/// parse — that would silently turn an auth error into "你还没有私信".
class DmConversation {
  final String uid;
  final String name;
  final String avatar;
  final String preview;
  final int timeMs;
  final int unread;
  final String conversationId;

  const DmConversation({
    required this.uid,
    required this.name,
    required this.avatar,
    this.preview = '',
    this.timeMs = 0,
    this.unread = 0,
    this.conversationId = '',
  });

  static List<DmConversation> parseList(String raw) {
    final json = decodeObject(raw);
    if (json['error'] is String && (json['error'] as String).isNotEmpty) {
      throw FormatException('${json['error']}');
    }
    if (json['errmsg'] is String &&
        (json['errmsg'] as String).isNotEmpty &&
        json['conversations'] == null &&
        json['user_list'] == null) {
      throw FormatException('${json['errmsg']}');
    }
    final list = _firstList(
      json,
      const ['conversations', 'user_list', 'direct_messages', 'list', 'data'],
    );
    if (list == null) {
      throw FormatException('私信列表返回了意外的结构：${_preview(raw)}');
    }
    final out = <DmConversation>[];
    for (final item in list.whereType<Map<String, dynamic>>()) {
      final user = item['user'] is Map<String, dynamic>
          ? item['user'] as Map<String, dynamic>
          : item;
      final last = item['last_message'] is Map<String, dynamic>
          ? item['last_message'] as Map<String, dynamic>
          : (item['direct_message'] is Map<String, dynamic>
              ? item['direct_message'] as Map<String, dynamic>
              : item);
      final uid = _str(user, const ['id', 'idstr', 'uid']);
      if (uid.isEmpty) continue;
      final timeMs = _timeMs(last, const ['created_at', 'updated_at', 'time']);
      out.add(DmConversation(
        uid: uid,
        name: _str(user, const ['screen_name', 'name', 'nick', 'remark']),
        avatar: _str(user, const ['avatar_hd', 'avatar_large', 'profile_image_url', 'avatar']),
        preview: _str(last, const ['text', 'content', 'last_message']),
        timeMs: timeMs > 0 ? timeMs : _timeMs(item, const ['created_at', 'updated_at', 'time']),
        unread: _int(item, const ['unread_count', 'unread', 'new_message_count']),
        conversationId: _str(item, const ['id', 'idstr', 'conversation_id']),
      ));
    }
    // Newest conversation first — the server usually already orders them.
    out.sort((a, b) => b.timeMs.compareTo(a.timeMs));
    return out;
  }
}

class DmMessage {
  final String id;
  final String text;
  final int timeMs;
  final String senderId;
  final String senderName;
  final bool fromMe;

  const DmMessage({
    required this.id,
    required this.text,
    required this.timeMs,
    this.senderId = '',
    this.senderName = '',
    this.fromMe = false,
  });

  static DmMessage fromJson(Map<String, dynamic> json, {required String myUid}) {
    final senderMap = json['sender'] is Map<String, dynamic>
        ? json['sender'] as Map<String, dynamic>
        : null;
    final sender = _str(json, const ['sender_id', 'uid', 'from_uid']).isNotEmpty
        ? _str(json, const ['sender_id', 'uid', 'from_uid'])
        : (senderMap != null ? _str(senderMap, const ['idstr', 'id', 'uid']) : '');
    final senderName = _str(json, const ['sender_screen_name', 'screen_name']).isNotEmpty
        ? _str(json, const ['sender_screen_name', 'screen_name'])
        : (senderMap != null ? _str(senderMap, const ['screen_name', 'name']) : '');
    return DmMessage(
      id: _str(json, const ['id', 'idstr', 'mid']),
      text: _str(json, const ['text', 'content']),
      timeMs: _timeMs(json, const ['created_at', 'time']),
      senderId: sender,
      senderName: senderName,
      fromMe: myUid.isNotEmpty && sender == myUid,
    );
  }
}

class DmHistory {
  final List<DmMessage> items;
  final bool hasMore;

  const DmHistory({this.items = const [], this.hasMore = false});

  static DmHistory parse(String raw, {required String myUid, int count = 0}) {
    final json = decodeObject(raw);
    if (json['error'] is String && (json['error'] as String).isNotEmpty) {
      throw FormatException('${json['error']}');
    }
    if (json['errmsg'] is String &&
        (json['errmsg'] as String).isNotEmpty &&
        json['direct_messages'] == null &&
        json['messages'] == null) {
      throw FormatException('${json['errmsg']}');
    }
    final list = _firstList(json, const ['direct_messages', 'messages', 'list', 'data']);
    if (list == null) {
      throw FormatException('私信记录返回了意外的结构：${_preview(raw)}');
    }
    final items = <DmMessage>[];
    for (final item in list.whereType<Map<String, dynamic>>()) {
      items.add(DmMessage.fromJson(item, myUid: myUid));
    }
    // WebIM returns newest first; the chat view wants oldest first.
    items.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return DmHistory(
      items: items,
      hasMore: count <= 0 || items.length >= count,
    );
  }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

List<dynamic>? _firstList(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is List) return value;
    if (value is Map<String, dynamic>) {
      final nested = _firstList(value, const ['list', 'data']);
      if (nested != null) return nested;
    }
  }
  return null;
}

String _str(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is String && value.isNotEmpty) return value;
    if (value is num) return '$value';
  }
  return '';
}

int _timeMs(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is num) {
      final n = value.toInt();
      if (n > 0) return n < 100000000000 ? n * 1000 : n;
    }
    if (value is String && value.isNotEmpty) {
      final parsedInt = int.tryParse(value);
      if (parsedInt != null && parsedInt > 0) {
        return parsedInt < 100000000000 ? parsedInt * 1000 : parsedInt;
      }
      final parsedWeibo = parseWeiboTimeMs(value);
      if (parsedWeibo > 0) return parsedWeibo;
    }
  }
  return 0;
}

int _int(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed;
    }
  }
  return 0;
}

String _preview(String raw) {
  final cut = raw.length > 160 ? raw.substring(0, 160) : raw;
  return cut.replaceAll('\n', ' ');
}

/// WebIM timestamps are epoch **milliseconds** (the official client feeds them
/// straight into `new Date(...)`).
String formatDmTime(int ms) {
  if (ms <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(time.year, time.month, time.day);
  final dayDiff = today.difference(that).inDays;

  String two(int v) => v.toString().padLeft(2, '0');
  if (dayDiff == 0) return '${two(time.hour)}:${two(time.minute)}';
  if (dayDiff == 1) return '昨天';
  if (time.year == now.year) return '${two(time.month)}-${two(time.day)}';
  return '${time.year}-${two(time.month)}-${two(time.day)}';
}

/// `HH:mm` used as the timestamp inside a chat bubble row.
String formatDmClock(int ms) {
  if (ms <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}';
}
