/// 深链接解析 —— 原版在 `AndroidManifest` 里声明了 `sinaweibo` / `http` /
/// `https` 三套 scheme，这里把外部链接翻译成应用内的页面。
///
/// 支持：
///  * `sinaweibo://detail?mblogid=xxx&uid=xxx`
///  * `sinaweibo://userinfo?uid=xxx` / `sinaweibo://profile?uid=xxx`
///  * `https://weibo.com/<uid>/<mblogid>`
///  * `https://weibo.com/u/<uid>`、`https://weibo.com/<uid>`
///  * `https://weibo.com/n/<昵称>`
///  * `https://m.weibo.cn/detail/<id>`、`https://m.weibo.cn/u/<uid>`
///  * `https://m.weibo.cn/search?containerid=...&q=%23话题%23`
enum DeepLinkKind { status, user, userName, search }

class DeepLinkTarget {
  final DeepLinkKind kind;

  /// 微博 `mblogid`（详情）或数字 uid（用户）。
  final String value;

  /// 搜索词 / 昵称，按 [kind] 解释。
  final String keyword;

  const DeepLinkTarget({required this.kind, this.value = '', this.keyword = ''});

  static DeepLinkTarget? parse(Uri uri, [int depth = 0]) {
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();

    if (scheme == 'sinaweibo') {
      final type = (segments.isNotEmpty ? segments.first : host).toLowerCase();

      // 官方客户端的「在浏览器中打开」包装：sinaweibo://browser?url=<真实链接>。
      if (type == 'browser' && depth < 3) {
        final nested = uri.queryParameters['url'] ?? uri.queryParameters['target'];
        if (nested != null && nested.isNotEmpty) {
          return parse(Uri.parse(nested), depth + 1);
        }
      }

      if (type.startsWith('search')) {
        final q = uri.queryParameters['q'] ?? '';
        if (q.isNotEmpty) return DeepLinkTarget(kind: DeepLinkKind.search, keyword: q);
      }

      final mblogid = uri.queryParameters['mblogid'] ??
          uri.queryParameters['mblog_id'] ??
          uri.queryParameters['id'] ??
          '';
      final uid = uri.queryParameters['uid'] ?? '';
      if (type.contains('detail') && mblogid.isNotEmpty) {
        return DeepLinkTarget(kind: DeepLinkKind.status, value: mblogid);
      }
      if (type.contains('user') || type.contains('profile')) {
        if (uid.isNotEmpty) return DeepLinkTarget(kind: DeepLinkKind.user, value: uid);
      }
      if (mblogid.isNotEmpty) return DeepLinkTarget(kind: DeepLinkKind.status, value: mblogid);
      if (uid.isNotEmpty) return DeepLinkTarget(kind: DeepLinkKind.user, value: uid);
      return null;
    }

    if (scheme != 'http' && scheme != 'https') return null;
    if (!host.endsWith('weibo.com') && !host.endsWith('weibo.cn')) return null;

    // m.weibo.cn
    if (host.startsWith('m.') || host.startsWith('mobi.')) {
      if (segments.length >= 2 && segments[0] == 'detail') {
        return DeepLinkTarget(kind: DeepLinkKind.status, value: segments[1]);
      }
      if (segments.length >= 2 && (segments[0] == 'u' || segments[0] == 'profile')) {
        return DeepLinkTarget(kind: DeepLinkKind.user, value: segments[1]);
      }
      if (segments.isNotEmpty && segments[0] == 'search') {
        final q = uri.queryParameters['q'] ?? '';
        if (q.isNotEmpty) return DeepLinkTarget(kind: DeepLinkKind.search, keyword: q);
      }
      if (segments.length >= 2 && segments[0] == 'status') {
        return DeepLinkTarget(kind: DeepLinkKind.status, value: segments[1]);
      }
      return null;
    }

    // weibo.com
    if (segments.isEmpty) return null;
    if (segments[0] == 'n' && segments.length >= 2) {
      return DeepLinkTarget(kind: DeepLinkKind.userName, keyword: segments[1]);
    }
    if (segments[0] == 'u' && segments.length >= 2) {
      return DeepLinkTarget(kind: DeepLinkKind.user, value: segments[1]);
    }
    if (segments.length == 1 && _isNumeric(segments[0])) {
      return DeepLinkTarget(kind: DeepLinkKind.user, value: segments[0]);
    }
    if (segments.length >= 2 && _isNumeric(segments[0])) {
      // /<uid>/<mblogid>
      return DeepLinkTarget(kind: DeepLinkKind.status, value: segments[1]);
    }
    if (segments[0] == 'detail' && segments.length >= 2) {
      return DeepLinkTarget(kind: DeepLinkKind.status, value: segments[1]);
    }
    if (segments[0] == 'status' && segments.length >= 2) {
      return DeepLinkTarget(kind: DeepLinkKind.status, value: segments[1]);
    }
    return null;
  }

  static bool _isNumeric(String s) => s.isNotEmpty && int.tryParse(s) != null;

  @override
  String toString() => 'DeepLinkTarget($kind, $value$keyword)';
}
