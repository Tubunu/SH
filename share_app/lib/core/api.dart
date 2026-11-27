import 'dart:convert';

import '../src/rust/api/web_api.dart' as rust;
import 'dm.dart';
import 'emotions.dart';
import 'groups.dart';
import 'models.dart';
import 'notice.dart';
import 'share_core.dart';
import 'stopic.dart';
import 'user_search.dart';

/// Everything the UI needs from the Rust core, already parsed into view models.
class WeiboApi {
  WeiboApi._();

  static final WeiboApi instance = WeiboApi._();

  bool get _useDual => ShareCore.instance.isInitialized;

  // -------------------------------------------------------------------------
  // Bootstrap / session
  // -------------------------------------------------------------------------

  Future<void> init(String dataDir) => rust.initCore(dataDir: dataDir);

  Future<SessionAccount?> currentAccount() async {
    final dto = await rust.currentAccount();
    return dto == null ? null : SessionAccount.fromDto(dto);
  }

  Future<List<SessionAccount>> accounts() async {
    final webList = (await rust.accounts()).map(SessionAccount.fromDto).toList();
    if (!_useDual) return webList;
    try {
      final activeUid = ShareCore.instance.lastInit?.activeUid ?? '';
      final sqlList = await ShareCore.instance.accounts();
      final byUid = <String, SessionAccount>{
        for (final w in webList) w.uid: w,
      };
      for (final s in sqlList) {
        final existing = byUid[s.uid];
        byUid[s.uid] = SessionAccount(
          uid: s.uid,
          screenName: s.name.isNotEmpty
              ? s.name
              : (existing?.screenName.isNotEmpty == true ? existing!.screenName : s.uid),
          avatar: s.avatar.isNotEmpty ? s.avatar : (existing?.avatar ?? ''),
          isGuest: false,
          active: s.uid == activeUid || s.isActive || (existing?.active ?? false),
        );
      }
      return byUid.values.toList();
    } catch (_) {
      return webList;
    }
  }

  /// Creates an anonymous session so the app can show public content before login.
  Future<void> ensureGuestSession() async {
    if (await rust.isLoggedIn()) return;
    await rust.guestLogin();
  }

  Future<SessionAccount> loginWithCookie(String cookie) async {
    final dto = await rust.loginWithCookie(cookie: cookie);
    return SessionAccount.fromDto(dto);
  }

  Future<SessionAccount> syncAccountCookie({
    required String uid,
    required String screenName,
    required String avatar,
    required String cookie,
  }) async {
    final dto = await rust.syncAccountCookie(
      uid: uid,
      screenName: screenName,
      avatar: avatar,
      cookie: cookie,
    );
    return SessionAccount.fromDto(dto);
  }

  Future<void> logout() => rust.logout();

  Future<void> switchAccount(String uid) async {
    await rust.switchAccount(uid: uid);
  }

  Future<void> removeAccount(String uid) => rust.removeAccount(uid: uid);

  Future<bool> isLoggedIn() => rust.isLoggedIn();

  // -------------------------------------------------------------------------
  // Timelines
  // -------------------------------------------------------------------------

  Future<Paged<Status>> homeTimeline({
    String? maxId,
    int count = 20,
    int page = 1,
  }) async {
    if (_useDual) {
      final raw = await ShareCore.instance.friendsTimelineDualRaw(
        maxId: maxId,
        count: count,
        page: page,
      );
      return _parseTimeline(raw, sortChronologically: true);
    }
    final raw = await rust.homeTimeline(maxId: maxId, count: count);
    return _parseTimeline(raw, sortChronologically: true);
  }

  Future<Paged<Status>> cachedHome() async {
    final raw = await rust.cachedHomeTimeline();
    if (raw == null || raw.isEmpty) return const Paged(items: [], hasMore: false);
    return _parseTimeline(raw, hasMore: false, sortChronologically: true);
  }

  Future<Paged<Status>> hotTimeline({String? maxId, int count = 20}) async {
    if (_useDual) {
      final raw = await ShareCore.instance.hotTimelineDualRaw(
        maxId: maxId,
        count: count,
      );
      return _parseTimeline(raw);
    }
    final raw = await rust.hotTimeline(maxId: maxId, count: count);
    return _parseTimeline(raw);
  }

  /// 分组时间线 —— 全部关注 / 好友圈 / 自定义分组。
  Future<Paged<Status>> feedTimeline({
    required String gid,
    String? maxId,
    int count = 20,
    int page = 1,
  }) async {
    final isHot = gid == 'hot' || gid == '102803';
    if (_useDual) {
      if (isHot) {
        return hotTimeline(maxId: maxId, count: count);
      }
      final listId = (gid.isEmpty || gid == 'all' || gid == 'friends') ? null : gid;
      final raw = await ShareCore.instance.friendsTimelineDualRaw(
        listId: listId,
        maxId: maxId,
        count: count,
        page: page,
      );
      return _parseTimeline(raw, sortChronologically: true);
    }
    final raw = await rust.feedTimeline(gid: gid, maxId: maxId, count: count);
    return _parseTimeline(raw, sortChronologically: !isHot);
  }

  /// 我赞过的微博。
  Future<Paged<Status>> likedStatuses(String uid, {int page = 1}) async {
    final raw = _useDual
        ? await ShareCore.instance.likedStatusesDual(uid, page: page)
        : await rust.likedStatuses(uid: uid, page: page);
    final json = decodeObject(raw);
    final data = json['data'];
    final list = (data is Map ? data['list'] : null) as List? ??
        (json['statuses'] as List?) ??
        (json['cards'] as List?) ??
        const [];
    final items = _extractStatusesFromList(list);
    final total = (data is Map ? jsonNullableInt(data['total']) : null) ??
        jsonNullableInt(json['total_number']) ??
        0;
    return Paged(
      items: items,
      maxId: '${page + 1}',
      hasMore: items.length >= 10 && (total == 0 || page * 10 < total),
    );
  }

  /// 删除自己的微博。
  Future<void> deleteStatus(String id) =>
      _useDual ? ShareCore.instance.deleteStatusDual(id) : rust.deleteStatus(id: id);

  /// 谁赞了这条微博（详情页「赞」Tab）。
  Future<List<User>> statusLikers(String id, {int page = 1, int count = 20}) async {
    final raw = _useDual
        ? await ShareCore.instance.likersDual(id, page: page, count: count)
        : await rust.statusLikers(id: id, page: page, count: count);
    return extractLikersFromPayload(decodeObject(raw));
  }

  static List<User> extractLikersFromPayload(Map<String, dynamic> json) {
    final data = json['data'];
    final candidates = <dynamic>[
      data,
      if (data is Map) data['data'],
      if (data is Map) data['users'],
      if (data is Map) data['list'],
      json['users'],
      json['attitudes'],
    ];
    List<dynamic>? list;
    for (final c in candidates) {
      if (c is List && c.isNotEmpty) {
        list = c;
        break;
      }
    }
    if (list == null) return const [];
    final users = <User>[];
    for (final e in list) {
      if (e is Map<String, dynamic>) {
        final nested = e['user'];
        users.add(User.fromJson(nested is Map<String, dynamic> ? nested : e));
      }
    }
    return users;
  }

  /// 主页内搜索某人的微博 —— `/ajax/profile/searchblog?uid=&page=&q=`。
  Future<Paged<Status>> searchProfile(String uid, String q, {int page = 1}) async {
    final raw = await rust.searchProfile(uid: uid, q: q, page: page);
    final json = decodeObject(raw);
    final data = json['data'];
    final list = (data is Map ? (data['list'] ?? data['statuses']) : data) as List? ?? const [];
    final items = <Status>[];
    for (final e in list) {
      if (e is Map<String, dynamic>) {
        final mblog = e['mblog'];
        items.add(Status.fromJson(mblog is Map<String, dynamic> ? mblog : e));
      }
    }
    final sinceId = data is Map ? data['since_id']?.toString() : null;
    return Paged(
      items: items,
      maxId: '$page',
      hasMore: items.length >= 10 && sinceId != null && sinceId != '0',
    );
  }

  /// 新增粉丝 —— `data.new_follows` 是用户数组。
  Future<List<User>> newFollowers(
    String uid, {
    int page = 1,
    int count = 20,
    int newFollowerCount = 0,
  }) async {
    final raw = await rust.newFollowers(
      uid: uid,
      page: page,
      count: count,
      newFollowerCount: newFollowerCount,
    );
    final json = decodeObject(raw);
    final data = json['data'];
    final list = data is Map
        ? (data['new_follows'] ?? data['followers'] ?? data['users'])
        : data;
    if (list is! List) return const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map((e) {
          final nested = e['user'];
          return User.fromJson(nested is Map<String, dynamic> ? nested : e);
        })
        .toList();
  }

  /// 编辑历史。
  Future<List<Status>> editHistory(String mid, {int page = 1}) async {
    final raw = await rust.editHistory(mid: mid, page: page);
    final json = decodeObject(raw);
    final list = (json['statuses'] as List?) ?? const [];
    return list.whereType<Map<String, dynamic>>().map(Status.fromJson).toList();
  }

  /// 机器翻译，返回译文纯文本。
  Future<({String text, String source})> translate(String idstr,
      {String locale = 'zh'}) async {
    final raw = _useDual
        ? await ShareCore.instance.translateStatusDual(idstr, locale: locale)
        : await rust.translateStatus(idstr: idstr, locale: locale);
    final json = decodeObject(raw);
    final ok = jsonInt(json['ok'], 1);
    if (ok <= 0 && json['data'] == null) {
      throw FormatException('${json['msg'] ?? '翻译失败'}');
    }
    final data = json['data'];
    final text = data is String
        ? data
        : (data is Map ? '${data['trans'] ?? data['text'] ?? data['translation'] ?? ''}' : '${json['trans'] ?? ''}');
    if (text.trim().isEmpty) {
      throw FormatException('${json['msg'] ?? '暂无可用翻译'}');
    }
    return (
      text: text,
      source: '${(data is Map ? data['source'] : null) ?? json['source'] ?? ''}',
    );
  }

  static bool _isPromotedJson(Map<String, dynamic> target) {
    if (target['is_ad'] == true) return true;
    if (target['promotion'] is Map) return true;
    if (target['mblogtype'] == 1) return true;
    return false;
  }

  List<Status> _extractStatusesFromList(List<dynamic> list, {bool dropAds = false}) {
    final nonAds = <Status>[];
    final all = <Status>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      final cardGroup = e['card_group'];
      if (cardGroup is List) {
        final nestedItems = _extractStatusesFromList(cardGroup, dropAds: dropAds);
        nonAds.addAll(nestedItems);
        all.addAll(nestedItems);
        continue;
      }
      final nested = e['mblog'] ?? e['status'];
      final target = nested is Map<String, dynamic> ? nested : e;
      final looksLikeStatus = nested is Map<String, dynamic> ||
          target['created_at'] != null ||
          target['user'] is Map ||
          target['reposts_count'] != null;
      if (!looksLikeStatus) continue;
      final s = Status.fromJson(target);
      if (s.id.isEmpty) continue;
      all.add(s);
      if (!dropAds || !_isPromotedJson(target)) {
        nonAds.add(s);
      }
    }
    return nonAds.isNotEmpty ? nonAds : all;
  }

  static void sortStatusesChronologically(List<Status> items) {
    items.sort((a, b) {
      final aId = BigInt.tryParse(a.id.trim()) ?? BigInt.zero;
      final bId = BigInt.tryParse(b.id.trim()) ?? BigInt.zero;
      return bId.compareTo(aId);
    });
  }

  Paged<Status> _parseTimeline(
    String raw, {
    bool hasMore = true,
    bool sortChronologically = false,
  }) {
    final json = decodeObject(raw);
    final data = json['data'];
    final list = (json['statuses'] as List?) ??
        (data is Map ? (data['list'] as List?) : null) ??
        (json['cards'] as List?) ??
        const [];
    final items = _extractStatusesFromList(list, dropAds: sortChronologically);
    if (sortChronologically && items.length > 1) {
      sortStatusesChronologically(items);
    }

    var next = (json['max_id_str'] ?? json['max_id'] ?? json['next_cursor'])?.toString();
    if ((next == null || next.isEmpty || next == '0') && data is Map) {
      next = data['since_id']?.toString();
    }
    if ((next == null || next.isEmpty || next == '0') &&
        json['hasmore'] == true &&
        items.isNotEmpty) {
      next = items.last.id;
    }
    final cleanNext = (next == null || next.isEmpty || next == '0') ? null : next;
    final cardPage = (json['cardlistInfo'] is Map)
        ? json['cardlistInfo']['since_id']?.toString()
        : null;
    final resolvedNext = cleanNext ??
        ((cardPage != null && cardPage.isNotEmpty && cardPage != '0')
            ? cardPage
            : (hasMore && items.length >= 15 ? items.last.id : null));
    return Paged(
      items: items,
      maxId: resolvedNext,
      hasMore: hasMore && items.isNotEmpty && resolvedNext != null && resolvedNext != '0',
    );
  }

  // -------------------------------------------------------------------------
  // Detail
  // -------------------------------------------------------------------------

  Future<Status> status(String id) async {
    final raw = _useDual
        ? await ShareCore.instance.statusShowDual(id)
        : await rust.statusShow(id: id);
    final parsed = Status.fromJson(decodeObject(raw));
    return expandStatusLongText(parsed);
  }

  /// Ensures long statuses (and their quoted retweeted status if long) carry full untruncated text.
  Future<Status> expandStatusLongText(Status status) async {
    var result = status;
    if (result.id.isNotEmpty && _needsLongTextExpand(result)) {
      try {
        final full = await longText(result.id);
        if (full.isNotEmpty && full.length >= result.textRaw.length) {
          result = result.copyWith(
            textHtml: full,
            textRaw: RichTextParser.toPlain(full),
            isLongText: false,
          );
        }
      } catch (_) {}
    }
    final rt = result.retweeted;
    if (rt != null && rt.id.isNotEmpty && _needsLongTextExpand(rt)) {
      try {
        final rtFull = await longText(rt.id);
        if (rtFull.isNotEmpty && rtFull.length >= rt.textRaw.length) {
          result = result.copyWith(
            retweeted: rt.copyWith(
              textHtml: rtFull,
              textRaw: RichTextParser.toPlain(rtFull),
              isLongText: false,
            ),
          );
        }
      } catch (_) {}
    }
    return result;
  }

  static bool _needsLongTextExpand(Status status) {
    if (status.isLongText) return true;
    final raw = status.textRaw.trimRight();
    return raw.endsWith('全文') || status.textHtml.contains('全文</a>');
  }

  Future<String> longText(String id) =>
      _useDual ? ShareCore.instance.statusLongtextDual(id) : rust.statusLongText(id: id);

  Future<Paged<Comment>> comments({
    required String statusId,
    required String authorUid,
    int flow = 0,
    String? maxId,
    int count = 20,
    int page = 1,
  }) async {
    final raw = _useDual
        ? await ShareCore.instance.commentsDual(
            statusId,
            authorUid: authorUid,
            flow: flow,
            maxId: maxId,
            page: page,
            count: count,
          )
        : await rust.comments(
            statusId: statusId,
            uid: authorUid,
            flow: flow,
            maxId: maxId,
            count: count,
          );
    final json = decodeObject(raw);
    final items = extractCommentsFromPayload(json, flow: flow);
    final rawNext = json['max_id_str'] ?? json['max_id'] ?? json['next_cursor'];
    final next = rawNext?.toString();
    final hasValidCursor = next != null && next.isNotEmpty && next != '0';
    return Paged(
      items: items,
      maxId: hasValidCursor ? next : null,
      hasMore: hasValidCursor && items.isNotEmpty,
    );
  }

  /// Parses comments from any mobile (`/2/comments/build_comments` `root_comments`
  /// / `datas`, `/2/comments/show` `comments`) or web (`/ajax/statuses/buildComments`
  /// `data`) response without letting an empty sibling array block non-empty ones.
  static List<Comment> extractCommentsFromPayload(
    Map<String, dynamic> json, {
    int flow = 0,
  }) {
    final items = <Comment>[];
    for (final key in const ['root_comments', 'data', 'comments']) {
      final list = json[key];
      if (list is List && list.isNotEmpty) {
        for (final rawItem in list) {
          final e = jsonMap(rawItem);
          if (e == null) continue;
          if (e['text'] != null || e['user'] != null || e['id'] != null) {
            items.add(Comment.fromJson(e));
          }
        }
        if (items.isNotEmpty) return items;
      }
    }
    if (json['datas'] is List) {
      for (final rawEntry in (json['datas'] as List)) {
        final e = jsonMap(rawEntry);
        if (e == null) continue;
        final target = jsonMap(e['data']) ?? e;
        if (target['text'] != null || target['user'] != null || target['id'] != null) {
          items.add(Comment.fromJson(target));
        }
      }
      if (items.isNotEmpty) return items;
    }
    if (flow == 0 && json['hot_comments'] is List) {
      for (final rawItem in (json['hot_comments'] as List)) {
        final e = jsonMap(rawItem);
        if (e != null) {
          items.add(Comment.fromJson(e));
        }
      }
    }
    return items;
  }

  /// Forwarding list of a status.
  Future<({List<Status> items, String tip})> repostList(
    String statusId, {
    int page = 1,
  }) async {
    final raw = _useDual
        ? await ShareCore.instance.repostListDual(statusId, page: page)
        : await rust.reposts(statusId: statusId, page: page);
    final json = decodeObject(raw);
    return extractRepostsFromPayload(json);
  }

  ({List<Status> items, String tip}) extractRepostsFromPayload(
    Map<String, dynamic> json,
  ) {
    final data = json['data'];
    final candidates = <dynamic>[
      json['reposts'],
      json['hot_reposts'],
      data,
      if (data is Map) data['list'],
      if (data is Map) data['reposts'],
      if (data is Map) data['data'],
      json['datas'],
    ];
    List<dynamic> picked = const [];
    for (final c in candidates) {
      if (c is List && c.isNotEmpty) {
        picked = c;
        break;
      }
    }
    final items = _extractStatusesFromList(picked);
    final tip = '${json['empty_tip'] ?? json['hot_desc'] ?? ''}';
    return (items: items, tip: tip == 'null' ? '' : tip);
  }

  Future<List<Comment>> replies(
    String commentId, {
    String? maxId,
    int flow = 0,
    int count = 20,
  }) async {
    final paged = await repliesPaged(
      commentId,
      maxId: maxId,
      flow: flow,
      count: count,
    );
    return paged.items;
  }

  /// Paginated floor/child replies (跟评 / 楼中楼) supporting both mobile
  /// `/2/comments/build_comments?fetch_level=1` and web `ajax/statuses/buildComments`.
  Future<Paged<Comment>> repliesPaged(
    String commentId, {
    String? maxId,
    int flow = 0,
    int count = 20,
  }) async {
    final raw = _useDual
        ? await ShareCore.instance.commentRepliesDual(
            commentId,
            maxId: maxId,
            flow: flow,
            count: count,
          )
        : await rust.commentReplies(commentId: commentId, maxId: maxId);
    final json = decodeObject(raw);
    var items = extractCommentsFromPayload(json, flow: flow);
    if (items.isEmpty) {
      final rootObj = json['rootComment'] ?? json['root_comment'];
      if (rootObj is Map) {
        final rootParsed = Comment.fromJson(Map<String, dynamic>.from(rootObj));
        items = rootParsed.replies;
      }
    }
    final rawNext = json['max_id_str'] ?? json['max_id'] ?? json['next_cursor'];
    final next = rawNext?.toString();
    final hasValidCursor = next != null && next.isNotEmpty && next != '0';
    return Paged(
      items: items,
      maxId: hasValidCursor ? next : null,
      hasMore: hasValidCursor && items.isNotEmpty,
    );
  }

  // -------------------------------------------------------------------------
  // Interactions
  // -------------------------------------------------------------------------

  Future<void> like(String statusId, bool undo) => _useDual
      ? ShareCore.instance.likeDual(statusId, undo: undo)
      : rust.like(statusId: statusId, undo: undo);

  Future<void> favorite(String statusId, bool undo) => _useDual
      ? ShareCore.instance.favoriteDual(statusId, undo: undo)
      : rust.favorite(statusId: statusId, undo: undo);

  Future<void> repost(String statusId, String text, {bool alsoComment = false}) =>
      _useDual
          ? ShareCore.instance.repostDual(statusId, text, alsoComment: alsoComment)
          : rust.repost(statusId: statusId, text: text, alsoComment: alsoComment);

  Future<void> comment(String statusId, String text) => _useDual
      ? ShareCore.instance.commentCreateDual(statusId, text)
      : rust.createComment(statusId: statusId, text: text);

  Future<void> commentReply(String statusId, String commentId, String text) async {
    if (_useDual) {
      await ShareCore.instance.commentReplyDual(statusId, commentId, text);
      return;
    }
    await rust.createComment(statusId: statusId, text: text);
  }

  Future<void> likeComment(String commentId, {bool undo = false}) async {
    if (_useDual) {
      await ShareCore.instance.commentLikeDual(commentId, undo: undo);
      return;
    }
    await rust.like(statusId: commentId, undo: undo);
  }

  Future<void> publish(
    String text, {
    int visible = 0,
    String picIds = '',
    String tail = '',
  }) =>
      _useDual
          ? ShareCore.instance.publishDual(
              text,
              visible: visible,
              picIds: picIds,
              tail: tail,
            )
          : rust.publish(text: text, visible: visible, picIds: picIds);

  // -------------------------------------------------------------------------
  // Discovery
  // -------------------------------------------------------------------------

  Future<List<HotSearchItem>> hotSearch() async {
    final categories = await hotSearchCategories();
    if (categories.isNotEmpty && categories.first.items.isNotEmpty) {
      return categories.first.items;
    }
    return const [];
  }

  /// Fetches Hot Search categories matching Share's `HotSearchActivity`:
  /// Tab 0 `实时热搜`, dynamic mobile `channel_list` bands if available, plus
  /// curated topic categories derived from Sina's live `hot_band`.
  Future<List<HotSearchCategory>> hotSearchCategories() async {
    if (!_useDual) {
      final raw = await rust.hotSearch();
      final json = decodeObject(raw);
      final items = _parseWebHotList(json['data']?['realtime'] as List?);
      return [HotSearchCategory(id: 'realtimehot', title: '实时热搜', items: items)];
    }
    final raw = await ShareCore.instance.hotSearchBandsDual();
    return parseHotSearchCategoriesPayload(decodeObject(raw));
  }

  Future<List<HotSearchItem>> hotSearchCategoryItems(HotSearchCategory cat) async {
    if (cat.items.isNotEmpty) return cat.items;
    final cid = cat.containerid?.trim() ?? '';
    if (cid.isEmpty || !_useDual) return const [];
    final raw = await ShareCore.instance.cardlist(cid, page: 1);
    return _parseMobileHotCards(raw);
  }

  static List<HotSearchCategory> parseHotSearchCategoriesPayload(
    Map<String, dynamic> payload,
  ) {
    final mobile = payload['mobile'];
    final band = payload['band'];
    final realtime = payload['realtime'];

    final bandList = (band is Map && band['data'] is Map)
        ? (band['data']['band_list'] as List?)
        : null;
    final realtimeList = (realtime is Map && realtime['data'] is Map)
        ? (realtime['data']['realtime'] as List?)
        : null;

    var primaryItems = _parseWebHotList(bandList);
    if (primaryItems.isEmpty) {
      primaryItems = _parseWebHotList(realtimeList);
    }
    if (primaryItems.isEmpty && mobile is Map<String, dynamic>) {
      primaryItems = _parseMobileHotCards(mobile);
    }

    final categories = <HotSearchCategory>[
      HotSearchCategory(id: 'realtimehot', title: '实时热搜', items: primaryItems),
    ];

    final seenTitles = <String>{'实时热搜'};
    if (mobile is Map<String, dynamic>) {
      final info = mobile['cardlistInfo'];
      final channels = info is Map ? info['channel_list'] : null;
      if (channels is List) {
        for (final ch in channels) {
          if (ch is! Map) continue;
          final name = '${ch['name'] ?? ch['title'] ?? ''}'.trim();
          final cid = '${ch['containerid'] ?? ''}'.trim();
          if (name.isEmpty || cid.isEmpty || !seenTitles.add(name)) continue;
          categories.add(HotSearchCategory(
            id: cid,
            title: name,
            containerid: cid,
            items: const [],
          ));
        }
      }
    }

    if (primaryItems.isNotEmpty) {
      final buckets = <String, List<HotSearchItem>>{
        '要闻社会': [],
        '文娱': [],
        '财经': [],
        '科技数码': [],
        '体育电竞': [],
        '生活': [],
      };
      for (final item in primaryItems) {
        final bucket = _classifyHotCategory(item.category);
        if (bucket != null) {
          final list = buckets[bucket]!;
          list.add(HotSearchItem(
            rank: list.length + 1,
            word: item.word,
            hot: item.hot,
            label: item.label,
            category: item.category,
          ));
        }
      }
      for (final entry in buckets.entries) {
        if (entry.value.isEmpty || !seenTitles.add(entry.key)) continue;
        categories.add(HotSearchCategory(
          id: 'band_${entry.key}',
          title: entry.key,
          items: entry.value,
        ));
      }
    }
    return categories;
  }

  static String? _classifyHotCategory(String rawCategory) {
    final c = rawCategory.trim();
    if (c.isEmpty) return null;
    if (c.contains('财经') || c.contains('股市') || c.contains('金融')) return '财经';
    if (c.contains('文娱') ||
        c.contains('艺人') ||
        c.contains('剧集') ||
        c.contains('综艺') ||
        c.contains('电影') ||
        c.contains('音乐') ||
        c.contains('明星') ||
        c.contains('动漫') ||
        c.contains('演出')) {
      return '文娱';
    }
    if (c.contains('电竞') || c.contains('游戏') || c.contains('体育') || c.contains('赛事')) {
      return '体育电竞';
    }
    if (c.contains('科技') || c.contains('互联网') || c.contains('数码') || c.contains('AI') || c.contains('手机')) {
      return '科技数码';
    }
    if (c.contains('时政') || c.contains('新闻') || c.contains('国际') || c.contains('社会') || c.contains('民生') || c.contains('法律') || c.contains('军事')) {
      return '要闻社会';
    }
    return '生活';
  }

  static List<HotSearchItem> _parseWebHotList(List<dynamic>? list) {
    if (list == null || list.isEmpty) return const [];
    final items = <HotSearchItem>[];
    for (final e in list) {
      if (e is! Map) continue;
      final word = '${e['word'] ?? e['note'] ?? ''}'.trim();
      if (word.isEmpty) continue;
      final rawLabel = '${e['label_name'] ?? e['icon_desc'] ?? ''}'.trim();
      items.add(HotSearchItem(
        rank: items.length + 1,
        word: word,
        hot: jsonInt(e['num']),
        label: rawLabel,
        category: '${e['category'] ?? e['flag_desc'] ?? ''}'.trim(),
      ));
    }
    return items;
  }

  static List<HotSearchItem> _parseMobileHotCards(Map<String, dynamic> json) {
    final cards = json['cards'] as List? ?? const [];
    final items = <HotSearchItem>[];
    void visit(List<dynamic> list) {
      for (final c in list) {
        if (c is! Map) continue;
        final cg = c['card_group'];
        if (cg is List) {
          visit(cg);
          continue;
        }
        final word = '${c['desc'] ?? c['title_sub'] ?? ''}'.trim();
        if (word.isEmpty || word.contains('查看完整热搜') || word.contains('更多热搜')) continue;
        final extr = '${c['desc_extr'] ?? ''}'.replaceAll(RegExp(r'[^\d]'), '');
        final icon = '${c['icon'] ?? ''}';
        var label = '';
        if (icon.contains('hot_')) label = '热';
        if (icon.contains('new_')) label = '新';
        if (icon.contains('boil_')) label = '沸';
        if (icon.contains('boom_')) label = '爆';
        items.add(HotSearchItem(
          rank: items.length + 1,
          word: word,
          hot: int.tryParse(extr) ?? 0,
          label: label,
        ));
      }
    }
    visit(cards);
    return items;
  }

  Future<Paged<Status>> search(String keyword, {int page = 1}) async {
    final raw = _useDual
        ? await ShareCore.instance.searchStatusesDual(keyword, page: page)
        : await rust.search(keyword: keyword, page: page);
    final json = decodeObject(raw);
    final list = (json['statuses'] as List?) ?? (json['cards'] as List?) ?? const [];
    final items = _extractStatusesFromList(list);
    return Paged(items: items, maxId: '$page', hasMore: items.isNotEmpty);
  }

  /// Categorized search matching `SearchActivity`: `all`, `realtime`, `user`, `pic`, `video`.
  Future<({List<Status> statuses, List<User> users, bool hasMore})> searchTyped(
    String keyword, {
    String type = 'all',
    int page = 1,
  }) async {
    if (type == 'user') {
      if (_useDual) {
        final raw = await ShareCore.instance.searchTypedDual(
          keyword,
          searchType: 'user',
          page: page,
        );
        final json = decodeObject(raw);
        final rawUsers = (json['users'] as List?) ??
            (json['data'] is Map ? (json['data']['users'] as List?) : null) ??
            const [];
        final users = rawUsers
            .whereType<Map>()
            .map((e) => User.fromJson(Map<String, dynamic>.from(e)))
            .where((u) => u.id.isNotEmpty || u.name.isNotEmpty)
            .toList();
        if (users.isNotEmpty) {
          return (statuses: const <Status>[], users: users, hasMore: users.length >= 10);
        }
      }
      final fallback = await searchUsers(keyword);
      return (
        statuses: const <Status>[],
        users: fallback.users,
        hasMore: false,
      );
    }

    final reqType = type == 'pic' ? 'all' : type;
    final raw = _useDual
        ? await ShareCore.instance.searchTypedDual(
            keyword,
            searchType: reqType,
            page: page,
          )
        : await rust.search(keyword: keyword, page: page);
    final json = decodeObject(raw);
    final list = (json['statuses'] as List?) ?? (json['cards'] as List?) ?? const [];
    var items = _extractStatusesFromList(list);
    if (type == 'pic') {
      items = items
          .where((s) => s.pics.isNotEmpty || (s.retweeted?.pics.isNotEmpty ?? false))
          .toList();
    } else if (type == 'video') {
      final onlyVideo = items
          .where((s) => s.isVideo || (s.retweeted?.isVideo ?? false))
          .toList();
      if (onlyVideo.isNotEmpty) items = onlyVideo;
    }
    return (
      statuses: items,
      users: const <User>[],
      hasMore: list.isNotEmpty,
    );
  }

  /// Nickname -> uid, for tapping an `@名字` inside rich text.
  Future<String?> userIdByName(String name) async {
    if (_useDual) {
      try {
        final mob = await ShareCore.instance.mobileGet('profile', {'screen_name': name});
        final user = User.fromProfilePayload(mob);
        if (user != null && user.id.isNotEmpty) return user.id;
      } catch (_) {}
    }
    final raw = await rust.resolveNickname(name: name);
    final json = decodeObject(raw);
    final user = json['data']?['user'];
    if (user is List && user.isNotEmpty) {
      final first = user.first;
      if (first is Map) {
        final uid = first['uid'] ?? first['id'];
        if (uid != null) return '$uid';
      }
    }
    return null;
  }

  Future<User?> profile(String uid) async {
    final raw = _useDual
        ? await ShareCore.instance.userProfileDual(uid)
        : await rust.userProfile(uid: uid);
    return User.fromProfilePayload(decodeObject(raw));
  }

  Future<Paged<Status>> userStatuses(
    String uid, {
    int page = 1,
    int feature = 0,
    String? maxId,
  }) async {
    final raw = _useDual
        ? await ShareCore.instance.userTimelineDual(
            uid,
            maxId: maxId,
            page: page,
            feature: feature,
          )
        : await rust.userStatuses(uid: uid, page: page, feature: feature);
    final json = decodeObject(raw);
    final data = json['data'];
    final list = (data is Map ? data['list'] : null) as List? ??
        (json['statuses'] as List?) ??
        (json['cards'] as List?) ??
        const [];
    final items = _extractStatusesFromList(list);
    final nextCursor = (json['max_id_str'] ?? json['max_id'] ?? json['next_cursor'])?.toString() ??
        (data is Map ? data['since_id']?.toString() : null);
    final hasNext = items.isNotEmpty &&
        ((nextCursor != null && nextCursor.isNotEmpty && nextCursor != '0') ||
            items.length >= 15);
    return Paged(
      items: items,
      maxId: (nextCursor != null && nextCursor.isNotEmpty && nextCursor != '0')
          ? nextCursor
          : (items.isNotEmpty ? items.last.id : '$page'),
      hasMore: hasNext,
    );
  }

  Future<void> follow(String uid, bool undo) =>
      _useDual ? ShareCore.instance.followDual(uid, undo: undo) : rust.follow(uid: uid, undo: undo);

  // -------------------------------------------------------------------------
  // 收藏 / 图片上传
  // -------------------------------------------------------------------------

  Future<Paged<Status>> favorites({int page = 1}) async {
    final raw = _useDual
        ? await ShareCore.instance.favoritesDual(page: page)
        : await rust.favorites(page: page);
    final json = decodeObject(raw);
    final list = (json['data'] as List?) ?? (json['favorites'] as List?) ?? const [];
    final items = _extractStatusesFromList(list);
    final count = jsonNullableInt(json['count']) ??
        jsonNullableInt(json['total_number']) ??
        items.length;
    return Paged(
      items: items,
      maxId: '$page',
      hasMore: items.isNotEmpty && count > 0,
    );
  }

  /// Uploads one picture and returns the `pid` for `publish(picIds:)`.
  Future<String> uploadPicture(List<int> bytes, String filename, String mime) async {
    if (_useDual) {
      try {
        final res = await ShareCore.instance.mobileUploadPic(
          bytes,
          filename: filename,
          mime: mime,
        );
        final pid = '${res['pic_id'] ?? res['pid'] ?? ''}';
        if (pid.isNotEmpty) return pid;
      } catch (_) {}
    }
    return rust.uploadPicture(bytes: bytes, filename: filename, mime: mime);
  }

  // -------------------------------------------------------------------------
  // 分组 / 表情 / 用户搜索
  // -------------------------------------------------------------------------

  Future<GroupSet> groups() async {
    final raw = _useDual ? await ShareCore.instance.groupsDual() : await rust.groups();
    return GroupSet.parse(raw);
  }

  static const _emoticonFlatKvKey = 'share_emoticons_flat_v1';
  EmoticonSet? _emoticonCache;
  Future<void>? _warmingEmotions;

  /// Loads cached online emoticons immediately and fetches `/ajax/statuses/config`
  /// in the background so modern emojis (`[淡淡的]` etc.) render right away.
  Future<void> warmEmotions() async {
    if (!EmoticonRegistry.instance.isEmpty) return;
    _warmingEmotions ??= _doWarmEmotions();
    return _warmingEmotions;
  }

  Future<void> _doWarmEmotions() async {
    try {
      if (_useDual) {
        final cached = await ShareCore.instance.kvGet(_emoticonFlatKvKey);
        if (cached != null && cached.isNotEmpty) {
          EmoticonRegistry.instance.loadFlatJson(cached);
        }
      }
      if (EmoticonRegistry.instance.isEmpty) {
        await emotions();
      }
    } catch (_) {
      // Best effort: never block startup when offline or rate-limited.
    } finally {
      _warmingEmotions = null;
    }
  }

  /// 表情配置（约 750KB，进程内只取一次，同时写入 EmoticonRegistry 与本地 KV 缓存）。
  Future<EmoticonSet> emotions({bool refresh = false}) async {
    final cached = _emoticonCache;
    if (cached != null && !refresh) {
      EmoticonRegistry.instance.registerSet(cached);
      return cached;
    }
    final set = EmoticonSet.parse(await rust.emotions());
    if (!set.isEmpty) {
      _emoticonCache = set;
      EmoticonRegistry.instance.registerSet(set);
      if (_useDual) {
        ShareCore.instance
            .kvSet(_emoticonFlatKvKey, EmoticonRegistry.instance.exportFlatJson())
            .catchError((_) {});
      }
    }
    return set;
  }

  /// 用户 / 话题联想。
  Future<UserSearchResult> searchUsers(String keyword) async {
    final query = keyword.trim();
    if (query.isEmpty) return UserSearchResult.empty;
    return UserSearchResult.parse(await rust.searchUsers(keyword: query));
  }

  // -------------------------------------------------------------------------
  // 超话
  // -------------------------------------------------------------------------

  Future<List<StopicCate>> stopicCates() async {
    final raw = await rust.stopicCates();
    return StopicCate.parseList(raw);
  }

  Future<({List<Stopic> items, int pages})> stopicList({
    int sortId = 0,
    String keyword = '',
    int page = 1,
  }) async {
    final raw = await rust.stopicList(sortId: sortId, keyword: keyword, page: page);
    return Stopic.parse(raw);
  }

  // -------------------------------------------------------------------------
  // Message centre (通知中心)
  // -------------------------------------------------------------------------

  Future<NoticeFeed> notices(NoticeKind kind, {int page = 1}) async {
    final raw = _useDual
        ? await ShareCore.instance.noticesDual(kind.name, page: page)
        : switch (kind) {
            NoticeKind.atWeibo => await rust.atWeibo(page: page),
            NoticeKind.comment => await rust.receivedComments(page: page),
            NoticeKind.like => await rust.receivedLikes(page: page),
            NoticeKind.atComment => await rust.atComments(page: page),
          };
    return NoticeFeed.parse(raw, kind);
  }

  Future<UnreadHint> unreadHint() async {
    final raw = _useDual ? await ShareCore.instance.unreadCountDual() : await rust.unreadHint();
    return UnreadHint.parse(raw);
  }

  // -------------------------------------------------------------------------
  // 私信 (WebIM / 移动端双协议)
  // -------------------------------------------------------------------------

  Future<List<DmConversation>> dmConversations({int count = 20}) async {
    final raw = _useDual
        ? await ShareCore.instance.dmConversationsDual(count: count)
        : await rust.dmConversations(count: count);
    return DmConversation.parseList(raw);
  }

  Future<DmHistory> dmHistory(
    String uid, {
    String? maxId,
    int count = 20,
    bool isGroup = false,
    required String myUid,
  }) async {
    final raw = _useDual
        ? await ShareCore.instance.dmHistoryDual(
            uid,
            maxId: maxId,
            count: count,
            isGroup: isGroup,
          )
        : await rust.dmHistory(uid: uid, maxId: maxId, count: count);
    return DmHistory.parse(raw, myUid: myUid, count: count);
  }

  /// Sends a message and returns the server's own copy of it.
  Future<DmMessage> dmSend(
    String uid,
    String text, {
    bool isGroup = false,
    required String myUid,
  }) async {
    final raw = _useDual
        ? await ShareCore.instance.dmSendDual(uid, text, isGroup: isGroup)
        : await rust.dmSend(uid: uid, text: text);
    final json = decodeObject(raw);
    if (json['error'] is String && (json['error'] as String).isNotEmpty) {
      throw FormatException('${json['error']}');
    }
    if (json['result'] == false) {
      final msg = json['error_msg'] ?? json['errmsg'] ?? json['msg'] ?? '发送失败';
      throw FormatException('$msg');
    }
    return DmMessage.fromJson(json, myUid: myUid);
  }

  /// Cookie header currently held by the native session (used to seed WebView).
  Future<String> activeCookie() async {
    if (_useDual) {
      final dualCookie = await ShareCore.instance.getActiveWebCookie();
      if (dualCookie != null && dualCookie.isNotEmpty) return dualCookie;
    }
    return rust.activeCookie();
  }
}

class SessionAccount {
  final String uid;
  final String screenName;
  final String avatar;
  final bool isGuest;
  final bool active;

  const SessionAccount({
    required this.uid,
    required this.screenName,
    required this.avatar,
    this.isGuest = false,
    this.active = false,
  });

  factory SessionAccount.fromDto(rust.AccountDto dto) => SessionAccount(
        uid: dto.uid,
        screenName: dto.screenName,
        avatar: dto.avatar,
        isGuest: dto.isGuest,
        active: dto.active,
      );
}

class HotSearchCategory {
  final String id;
  final String title;
  final String? containerid;
  final List<HotSearchItem> items;

  const HotSearchCategory({
    required this.id,
    required this.title,
    this.containerid,
    this.items = const [],
  });

  HotSearchCategory copyWith({List<HotSearchItem>? items}) => HotSearchCategory(
        id: id,
        title: title,
        containerid: containerid,
        items: items ?? this.items,
      );
}

class HotSearchItem {
  final int rank;
  final String word;
  final int hot;
  final String label;
  final String category;

  const HotSearchItem({
    required this.rank,
    required this.word,
    required this.hot,
    this.label = '',
    this.category = '',
  });
}

/// Debug helper: pretty-prints a raw payload when the shape surprises us.
String prettyJson(String raw) {
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
  } catch (_) {
    return raw;
  }
}
