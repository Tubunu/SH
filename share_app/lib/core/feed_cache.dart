import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'share_core.dart';

class CachedTimelineSnapshot {
  final String groupKey;
  final List<Status> items;
  final String? maxId;
  final int page;
  final bool hasMore;
  final bool usingGuestFeed;
  final double scrollOffset;
  final String anchorStatusId;
  final int savedAtMs;

  const CachedTimelineSnapshot({
    required this.groupKey,
    required this.items,
    this.maxId,
    this.page = 1,
    this.hasMore = true,
    this.usingGuestFeed = false,
    this.scrollOffset = 0,
    this.anchorStatusId = '',
    this.savedAtMs = 0,
  });

  Map<String, dynamic> toJson() => {
        'groupKey': groupKey,
        'items': items.take(120).map((s) => s.toJson()).toList(),
        if (maxId != null) 'maxId': maxId,
        'page': page,
        'hasMore': hasMore,
        'usingGuestFeed': usingGuestFeed,
        'scrollOffset': scrollOffset,
        'anchorStatusId': anchorStatusId,
        'savedAtMs': savedAtMs,
      };

  static CachedTimelineSnapshot? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final rawItems = decoded['items'];
      final items = <Status>[];
      if (rawItems is List) {
        for (final entry in rawItems) {
          if (entry is Map<String, dynamic>) {
            final status = Status.fromJson(entry);
            if (status.id.isNotEmpty) items.add(status);
          } else if (entry is Map) {
            final status = Status.fromJson(Map<String, dynamic>.from(entry));
            if (status.id.isNotEmpty) items.add(status);
          }
        }
      }
      return CachedTimelineSnapshot(
        groupKey: '${decoded['groupKey'] ?? 'all'}',
        items: items,
        maxId: decoded['maxId']?.toString(),
        page: jsonInt(decoded['page'], 1),
        hasMore: jsonBool(decoded['hasMore'], true),
        usingGuestFeed: jsonBool(decoded['usingGuestFeed']),
        scrollOffset: jsonDouble(decoded['scrollOffset']),
        anchorStatusId: '${decoded['anchorStatusId'] ?? ''}',
        savedAtMs: jsonInt(decoded['savedAtMs']),
      );
    } catch (_) {
      return null;
    }
  }
}

class CachedGroupSelection {
  final String groupKey;
  final String title;
  final bool isHotChannel;

  const CachedGroupSelection({
    required this.groupKey,
    this.title = '',
    this.isHotChannel = false,
  });

  Map<String, dynamic> toJson() => {
        'groupKey': groupKey,
        'title': title,
        'isHotChannel': isHotChannel,
      };

  static CachedGroupSelection? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final key = '${map['groupKey'] ?? ''}'.trim();
      if (key.isEmpty) return null;
      return CachedGroupSelection(
        groupKey: key,
        title: '${map['title'] ?? ''}',
        isHotChannel: map['isHotChannel'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Persists feed items and exact scroll offset per account and group so killing
/// the app and reopening resumes seamlessly where the user stopped reading
/// (Share's `start_refresh_status == false` behavior).
class FeedCacheStore {
  FeedCacheStore._();

  static final FeedCacheStore instance = FeedCacheStore._();

  static const _kvPrefix = 'share_feed_cache_v2_';
  static const _groupSelPrefix = 'share_feed_group_v2_';

  String _scopeUid(String uid) => uid.trim().isEmpty ? 'guest' : uid.trim();

  String _snapshotKey(String uid, String groupKey) =>
      '$_kvPrefix${_scopeUid(uid)}_${groupKey.isEmpty ? 'all' : groupKey}';

  String _groupKey(String uid) => '$_groupSelPrefix${_scopeUid(uid)}';

  Future<String?> _readRaw(String key) async {
    if (ShareCore.instance.isInitialized) {
      try {
        final v = await ShareCore.instance.kvGet(key);
        if (v != null && v.isNotEmpty) return v;
      } catch (_) {}
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeRaw(String key, String value) async {
    if (ShareCore.instance.isInitialized) {
      try {
        await ShareCore.instance.kvSet(key, value);
      } catch (_) {}
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (_) {}
  }

  Future<CachedTimelineSnapshot?> loadSnapshot(
    String uid, {
    String groupKey = 'all',
  }) async {
    final raw = await _readRaw(_snapshotKey(uid, groupKey));
    return CachedTimelineSnapshot.tryParse(raw);
  }

  Future<void> saveSnapshot(
    String uid,
    CachedTimelineSnapshot snapshot,
  ) async {
    if (snapshot.items.isEmpty) return;
    final payload = CachedTimelineSnapshot(
      groupKey: snapshot.groupKey,
      items: snapshot.items,
      maxId: snapshot.maxId,
      page: snapshot.page,
      hasMore: snapshot.hasMore,
      usingGuestFeed: snapshot.usingGuestFeed,
      scrollOffset: snapshot.scrollOffset < 0 ? 0 : snapshot.scrollOffset,
      anchorStatusId: snapshot.anchorStatusId,
      savedAtMs: snapshot.savedAtMs > 0
          ? snapshot.savedAtMs
          : DateTime.now().millisecondsSinceEpoch,
    );
    await _writeRaw(
      _snapshotKey(uid, snapshot.groupKey),
      jsonEncode(payload.toJson()),
    );
  }

  Future<CachedGroupSelection?> loadLastGroup(String uid) async {
    final raw = await _readRaw(_groupKey(uid));
    return CachedGroupSelection.tryParse(raw);
  }

  Future<void> saveLastGroup(String uid, CachedGroupSelection selection) async {
    await _writeRaw(_groupKey(uid), jsonEncode(selection.toJson()));
  }
}
