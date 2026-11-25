import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'share_core.dart';
import '../src/rust/api/share_api.dart' show DraftDto;

/// A locally stored draft backed by Rust SQLite `STATUS_DRAFTS` + SharedPreferences mirror.
class Draft {
  final String id;
  final String text;
  final int updatedAt;

  const Draft({required this.id, required this.text, required this.updatedAt});

  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'updatedAt': updatedAt};

  factory Draft.fromJson(Map<String, dynamic> json) => Draft(
        id: '${json['id'] ?? ''}',
        text: (json['text'] ?? '') as String,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

class DraftStore {
  static const _key = 'drafts_v1';
  static const _max = 50;

  static Future<List<Draft>> load({String uid = ''}) async {
    try {
      final rows = await ShareCore.instance.draftList(uid);
      if (rows.isNotEmpty) {
        return rows
            .where((r) => r.content.trim().isNotEmpty)
            .map((r) => Draft(
                  id: 'sql_${r.id}',
                  text: r.content,
                  updatedAt: r.date,
                ))
            .toList();
      }
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final drafts = decoded
          .whereType<Map<String, dynamic>>()
          .map(Draft.fromJson)
          .where((d) => d.text.trim().isNotEmpty)
          .toList();
      drafts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return drafts;
    } catch (_) {
      return const [];
    }
  }

  static Future<String> save({
    String? id,
    required String text,
    String uid = '',
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return id ?? '';

    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      final sqlId = (id != null && id.startsWith('sql_'))
          ? int.tryParse(id.substring(4)) ?? 0
          : 0;
      final savedId = await ShareCore.instance.draftSave(
        DraftDto(
          id: sqlId,
          uid: uid,
          content: text,
          date: now,
          urlsJson: '',
          targetStatusId: '',
          targetStatusJson: '',
          targetCommentId: '',
          targetCommentUserName: '',
          targetCommentContent: '',
          assignGroupIdStr: '',
          assignGroupType: 0,
          address: '',
          publishTiming: 0,
          isCommentOrigin: false,
          status: 0,
          isMention: false,
          state: 0,
          typeCode: 0,
          parentType: 0,
          extraJson: '',
        ),
      );
      if (savedId > 0) return 'sql_$savedId';
    } catch (_) {}

    final drafts = await load(uid: uid);
    final targetId = (id != null && id.isNotEmpty)
        ? id
        : 'd${DateTime.now().microsecondsSinceEpoch}';

    final index = drafts.indexWhere((d) => d.id == targetId);
    final draft = Draft(id: targetId, text: text, updatedAt: now);
    if (index >= 0) {
      drafts[index] = draft;
    } else {
      drafts.insert(0, draft);
    }

    final trimmedList = drafts.length > _max ? drafts.sublist(0, _max) : drafts;
    await _persist(trimmedList);
    return targetId;
  }

  static Future<void> remove(String id, {String uid = ''}) async {
    if (id.startsWith('sql_')) {
      final parsed = int.tryParse(id.substring(4));
      if (parsed != null) {
        await ShareCore.instance.draftDelete(parsed).catchError((_) => false);
      }
    }
    final drafts = await load(uid: uid);
    drafts.removeWhere((d) => d.id == id);
    await _persist(drafts);
  }

  static Future<void> clear({String uid = ''}) async {
    await ShareCore.instance.draftClear(uid).catchError((_) => 0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static Future<void> _persist(List<Draft> drafts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(drafts.map((d) => d.toJson()).toList()),
    );
  }
}
