import 'models.dart';
import 'settings.dart';

/// 关键词屏蔽 (original key `black_content`).
///
/// The APK drops statuses whose body matches a stored keyword before they reach
/// the adapter. This build does the same at the point where a page of data is
/// accepted, so the filter covers 时间线 / 搜索 / 评论 alike.
String _plainText(String html) => html.replaceAll(RegExp(r'<[^>]*>'), ' ');

bool matchesKeyword(String text, List<String> loweredKeywords) {
  if (loweredKeywords.isEmpty) return false;
  final lowered = text.toLowerCase();
  return loweredKeywords.any(lowered.contains);
}

/// 卡片菜单「屏蔽」写入的三张名单：
///  * `block_keywords` 关键词
///  * `muted_uids`     博主
///  * `muted_sources`  来源小尾巴
List<String> mutedUids(AppSettings settings) => _stringList(settings, 'muted_uids');
List<String> mutedSources(AppSettings settings) => _stringList(settings, 'muted_sources');

List<String> _stringList(AppSettings settings, String key) {
  final v = settings.prefs[key];
  if (v is List<String>) return v;
  if (v is List) return v.whereType<String>().toList();
  return const [];
}

/// 关键词 + 博主 + 来源 三段过滤，时间线统一走这里。
List<Status> applyStatusFilters(List<Status> source, AppSettings settings) {
  final keywords = settings.hiddenKeywords.map((w) => w.toLowerCase()).toList();
  final uids = mutedUids(settings).toSet();
  final sources = mutedSources(settings).toSet();
  if (keywords.isEmpty && uids.isEmpty && sources.isEmpty) return source;

  final lowered = keywords;
  bool drop(Status status) {
    final uid = status.user?.id ?? '';
    if (uids.contains(uid)) return true;
    if (sources.isNotEmpty && sources.contains(status.source)) return true;
    if (matchesKeyword(_plainText(status.textHtml), lowered)) return true;
    final original = status.retweeted;
    if (original != null) {
      if (uids.contains(original.user?.id ?? '')) return true;
      if (matchesKeyword(_plainText(original.textHtml), lowered)) return true;
    }
    return false;
  }

  return source.where((s) => !drop(s)).toList();
}

/// Keeps 微博 whose body *and* retweeted body avoid every keyword.
List<Status> hideStatusesByKeyword(List<Status> source, List<String> keywords) {
  if (keywords.isEmpty) return source;
  final lowered = keywords.map((w) => w.toLowerCase()).toList();
  return source.where((status) {
    if (matchesKeyword(_plainText(status.textHtml), lowered)) return false;
    final original = status.retweeted;
    if (original != null && matchesKeyword(_plainText(original.textHtml), lowered)) {
      return false;
    }
    return true;
  }).toList();
}

List<Comment> hideCommentsByKeyword(List<Comment> source, List<String> keywords) {
  if (keywords.isEmpty) return source;
  final lowered = keywords.map((w) => w.toLowerCase()).toList();
  return source
      .where((comment) => !matchesKeyword(_plainText(comment.textHtml), lowered))
      .toList();
}
