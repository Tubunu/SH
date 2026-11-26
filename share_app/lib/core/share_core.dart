import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../src/rust/api/share_api.dart' as rust;

/// Unified Flutter <-> Rust Dual-Protocol + SQLite + Platform MethodChannel facade.
///
/// Wraps every function exposed by `rust/src/api/share_api.rs` and bridges
/// Android/iOS native cookie stores (`com.hengye.share/cookies`) and dynamic
/// launcher icons (`com.hengye.share/platform`).
class ShareCore {
  ShareCore._();

  static final ShareCore instance = ShareCore._();

  static const _cookieChannel = MethodChannel('com.hengye.share/cookies');
  static const _platformChannel = MethodChannel('com.hengye.share/platform');

  bool _initialized = false;
  String? _dataDir;
  rust.CoreInitResult? _initResult;

  bool get isInitialized => _initialized;
  rust.CoreInitResult? get lastInit => _initResult;

  /// Initializes Rust SQLite persistence (`share_app.db`), migrates any legacy
  /// `session.json`, and bootstraps guest `aid`/`gsid` if needed.
  Future<rust.CoreInitResult> init({
    String? customDataDir,
    bool forceRefresh = false,
  }) async {
    if (_initialized &&
        _initResult != null &&
        customDataDir == null &&
        !forceRefresh) {
      return _initResult!;
    }
    final dir = customDataDir ??
        _dataDir ??
        (await getApplicationSupportDirectory()).path;
    _dataDir = dir;
    final res = await rust.initShareCore(dataDir: dir);
    _initResult = res;
    _initialized = true;
    return res;
  }

  /// Ensures CoreEngine is initialized before executing any SQL/mobile call.
  Future<void> ensureInit() async {
    if (!_initialized) {
      await init();
    }
  }

  // --------------------------------------------------------------------------
  // Native Android / iOS Platform MethodChannels
  // --------------------------------------------------------------------------

  /// Extracts full cookies (including `HttpOnly` `SUB` / `SUBP`) from
  /// `android.webkit.CookieManager` on Android or `WKHTTPCookieStore` on iOS.
  Future<String?> getNativeWebCookies({
    String url = 'https://weibo.com',
    bool allDomains = true,
  }) async {
    try {
      final raw = await _cookieChannel.invokeMethod<String>(
        'getCookies',
        {'url': url, 'allDomains': allDomains},
      );
      if (raw == null || raw.trim().isEmpty) return null;
      return raw.trim();
    } catch (_) {
      return null;
    }
  }

  Future<bool> clearNativeWebCookies() async {
    try {
      return await _cookieChannel.invokeMethod<bool>('clearCookies') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Switches the app launcher icon (`Launcher`..`Launcher5`).
  Future<bool> setLauncherIcon(int index1Based) async {
    final alias = index1Based <= 1 ? 'Launcher' : 'Launcher$index1Based';
    try {
      return await _platformChannel.invokeMethod<bool>(
            'setLauncherIcon',
            {'alias': alias},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  // --------------------------------------------------------------------------
  // Auth & Multi-Account SQLite Storage
  // --------------------------------------------------------------------------

  Future<Map<String, dynamic>> guestLogin() async {
    await ensureInit();
    final raw = await rust.guestLoginMobile();
    return _decodeMap(raw);
  }

  Future<Map<String, dynamic>> loginPassword({
    required String username,
    required String password,
    String? cptId,
    String? cptCode,
    String? alt,
  }) async {
    await ensureInit();
    final raw = await rust.loginPasswordMobile(
      username: username,
      password: password,
      cptId: cptId,
      cptCode: cptCode,
      alt: alt,
    );
    return _decodeMap(raw);
  }

  Future<Map<String, dynamic>> loginCaptchaGet({String? cptId}) async {
    await ensureInit();
    return _decodeMap(await rust.loginCaptchaGet(cptId: cptId));
  }

  Future<Map<String, dynamic>> loginSafetySendSms({
    required String phone,
    required String area,
    required String retcode,
  }) async {
    await ensureInit();
    return _decodeMap(
      await rust.loginSafetySendSms(phone: phone, area: area, retcode: retcode),
    );
  }

  Future<Map<String, dynamic>> loginSmsSend({
    required String phone,
    String area = '0086',
  }) async {
    await ensureInit();
    return _decodeMap(await rust.loginSmsSend(phone: phone, area: area));
  }

  Future<Map<String, dynamic>> loginSmsVerify({
    required String phone,
    required String area,
    required String number,
    required String code,
    required bool isSmsLogin,
    String? username,
    String? password,
    String? retcode,
  }) async {
    await ensureInit();
    return _decodeMap(
      await rust.loginSmsVerify(
        phone: phone,
        area: area,
        number: number,
        code: code,
        isSmsLogin: isSmsLogin,
        username: username,
        password: password,
        retcode: retcode,
      ),
    );
  }

  Future<Map<String, dynamic>> qrConfirm({
    required String qrUrl,
    String? customCookie,
  }) async {
    await ensureInit();
    return _decodeMap(
      await rust.qrConfirmLogin(qrUrl: qrUrl, customCookie: customCookie),
    );
  }

  Future<rust.AccountSummary> importCookie(
    String cookie, {
    String? uidHint,
    String? nameHint,
  }) async {
    await ensureInit();
    return rust.importCookieAccount(
      cookie: cookie,
      uidHint: uidHint,
      nameHint: nameHint,
    );
  }

  Future<List<rust.AccountSummary>> accounts() async {
    await ensureInit();
    return rust.listAccountsSql();
  }

  Future<rust.AccountSummary> switchAccount(String uid) async {
    await ensureInit();
    return rust.switchAccountSql(uid: uid);
  }

  Future<bool> deleteAccount(String uid) async {
    await ensureInit();
    return rust.deleteAccountSql(uid: uid);
  }

  Future<String?> logoutCurrent() async {
    await ensureInit();
    return rust.logoutCurrentSql();
  }

  // --------------------------------------------------------------------------
  // Dual-Protocol Endpoints & Generic Signed /2/* API
  // --------------------------------------------------------------------------

  Future<Map<String, dynamic>> mobileGet(
    String path, [
    Map<String, dynamic> params = const {},
  ]) async {
    await ensureInit();
    final raw = await rust.mobileGet(path: path, paramsJson: jsonEncode(params));
    return _decodeMap(raw);
  }

  Future<Map<String, dynamic>> mobilePost(
    String path, {
    Map<String, dynamic> query = const {},
    Map<String, dynamic> form = const {},
  }) async {
    await ensureInit();
    final raw = await rust.mobilePost(
      path: path,
      queryJson: jsonEncode(query),
      formJson: jsonEncode(form),
    );
    return _decodeMap(raw);
  }

  Future<Map<String, dynamic>> mobileUploadPic(
    List<int> bytes, {
    required String filename,
    String mime = 'image/jpeg',
  }) async {
    await ensureInit();
    final raw = await rust.mobileUploadPic(
      bytes: bytes,
      filename: filename,
      mime: mime,
    );
    return _decodeMap(raw);
  }

  Future<Map<String, dynamic>> hotTimelineDual({
    String groupId = '102803',
    String? maxId,
    int count = 20,
    bool needJump = false,
  }) async {
    await ensureInit();
    return _decodeMap(
      await rust.hotTimelineDual(
        groupId: groupId,
        maxId: maxId,
        count: count,
        needJump: needJump,
      ),
    );
  }

  Future<Map<String, dynamic>> friendsTimelineDual({
    String? listId,
    String? sinceId,
    String? maxId,
    int count = 25,
    int page = 1,
  }) async {
    await ensureInit();
    return _decodeMap(
      await rust.friendsTimelineDual(
        listId: listId,
        sinceId: sinceId,
        maxId: maxId,
        count: count,
        page: page,
      ),
    );
  }

  Future<Map<String, dynamic>> topicCheckin(String requestUrl) async {
    await ensureInit();
    return _decodeMap(await rust.topicCheckin(requestUrl: requestUrl));
  }

  Future<Map<String, dynamic>> cardlist(
    String containerid, {
    int page = 1,
    String? sinceId,
  }) async {
    await ensureInit();
    return _decodeMap(
      await rust.cardlistGet(containerid: containerid, page: page, sinceId: sinceId),
    );
  }

  Future<Map<String, dynamic>> pageGet(String containerid, {int page = 1}) async {
    await ensureInit();
    return _decodeMap(await rust.pageGet(containerid: containerid, page: page));
  }

  Future<Map<String, dynamic>> articleShow(String oid) async {
    await ensureInit();
    return _decodeMap(await rust.articleShow(oid: oid));
  }

  Future<Map<String, dynamic>> qaShow(String oid) async {
    await ensureInit();
    return _decodeMap(await rust.qaShow(oid: oid));
  }

  Future<Map<String, dynamic>> qaWatch(String oid) async {
    await ensureInit();
    return _decodeMap(await rust.qaWatch(oid: oid));
  }

  Future<Map<String, dynamic>> videoPlayback(String objectIds) async {
    await ensureInit();
    return _decodeMap(await rust.videoPlayback(objectIds: objectIds));
  }

  Future<Map<String, dynamic>> shortUrlExpand(String urlShort) async {
    await ensureInit();
    return _decodeMap(await rust.shortUrlExpand(urlShort: urlShort));
  }

  Future<Map<String, dynamic>> profileEdit(Map<String, dynamic> fields) async {
    await ensureInit();
    return _decodeMap(await rust.profileEdit(fieldsJson: jsonEncode(fields)));
  }

  Future<Map<String, dynamic>> uploadAvatar(List<int> bytes, String filename) async {
    await ensureInit();
    return _decodeMap(await rust.uploadAvatar(bytes: bytes, filename: filename));
  }

  Future<Map<String, dynamic>> friendsList(
    String uid, {
    int page = 1,
    int count = 50,
    int trimStatus = 1,
  }) async {
    await ensureInit();
    return _decodeMap(
      await rust.friendsList(
        uid: uid,
        page: page,
        count: count,
        trimStatus: trimStatus,
      ),
    );
  }

  Future<Map<String, dynamic>> removeFollower(String uid) async {
    await ensureInit();
    return _decodeMap(await rust.removeFollower(uid: uid));
  }

  Future<Map<String, dynamic>> updateRemark(String uid, String remark) async {
    await ensureInit();
    return _decodeMap(await rust.updateRemark(uid: uid, remark: remark));
  }

  Future<Map<String, dynamic>> groupCrud(
    String op, [
    Map<String, dynamic> params = const {},
  ]) async {
    await ensureInit();
    return _decodeMap(await rust.groupCrud(op: op, paramsJson: jsonEncode(params)));
  }

  Future<Map<String, dynamic>> groupOrder(List<String> listIds) async {
    await ensureInit();
    return _decodeMap(await rust.groupOrder(listIdsCsv: listIds.join(',')));
  }

  Future<Map<String, dynamic>> groupMembersEdit({
    required bool add,
    required String listId,
    required List<String> uids,
  }) async {
    await ensureInit();
    return _decodeMap(
      await rust.groupMembersEdit(
        add: add,
        listId: listId,
        uidsCsv: uids.join(','),
      ),
    );
  }

  Future<Map<String, dynamic>> blockUser(String uid, {required bool block}) async {
    await ensureInit();
    return _decodeMap(await rust.blockUser(block: block, uid: uid));
  }

  Future<Map<String, dynamic>> filterStatus(String statusId, {int filterType = 1}) async {
    await ensureInit();
    return _decodeMap(
      await rust.filterStatus(statusId: statusId, filterType: filterType),
    );
  }

  Future<Map<String, dynamic>> statusSetTop(String statusId, {required bool isTop}) async {
    await ensureInit();
    return _decodeMap(await rust.statusSetTop(isTop: isTop, statusId: statusId));
  }

  Future<Map<String, dynamic>> statusModifyVisible(String statusId, int visible) async {
    await ensureInit();
    return _decodeMap(
      await rust.statusModifyVisible(statusId: statusId, visible: visible),
    );
  }

  Future<Map<String, dynamic>> statusModify(
    String statusId,
    String content, {
    String? picIds,
  }) async {
    await ensureInit();
    return _decodeMap(
      await rust.statusModify(statusId: statusId, content: content, picId: picIds),
    );
  }

  Future<Map<String, dynamic>> commentDelete(
    String cid, {
    bool blockAndDelete = false,
  }) async {
    await ensureInit();
    return _decodeMap(
      await rust.commentDelete(cid: cid, blockAndDelete: blockAndDelete),
    );
  }

  Future<Map<String, dynamic>> commentApproval(
    String op,
    Map<String, dynamic> params,
  ) async {
    await ensureInit();
    return _decodeMap(
      await rust.commentApproval(op: op, paramsJson: jsonEncode(params)),
    );
  }

  Future<Map<String, dynamic>> nearbyPois(
    double lat,
    double lon, {
    String? q,
    int page = 1,
  }) async {
    await ensureInit();
    return _decodeMap(
      await rust.nearbyPois(lat: lat, lon: lon, q: q, page: page),
    );
  }

  Future<Map<String, dynamic>> publisherList() async {
    await ensureInit();
    return _decodeMap(await rust.publisherList());
  }

  // --------------------------------------------------------------------------
  // SQLite 9-Table DAO Ops (Drafts, History, Blacklist, Followers, Groups, KV)
  // --------------------------------------------------------------------------

  Future<int> draftSave(rust.DraftDto draft) async {
    await ensureInit();
    return (await rust.draftSave(draft: draft)).toInt();
  }

  Future<List<rust.DraftDto>> draftList(String uid) async {
    await ensureInit();
    return rust.draftList(uid: uid);
  }

  Future<bool> draftUpdateStatus(int id, int status) async {
    await ensureInit();
    return rust.draftUpdateStatus(id: id, status: status);
  }

  Future<bool> draftDelete(int id) async {
    await ensureInit();
    return rust.draftDelete(id: id);
  }

  Future<int> draftClear(String uid) async {
    await ensureInit();
    return (await rust.draftClear(uid: uid)).toInt();
  }

  Future<void> historyRecordStatus({
    required String uid,
    required String statusId,
    required String username,
    String avatar = '',
    required String totalText,
    required String statusJson,
  }) async {
    await ensureInit();
    await rust.historyRecordStatus(
      uid: uid,
      statusId: statusId,
      username: username,
      avatar: avatar,
      totalText: totalText,
      statusJson: statusJson,
    );
  }

  Future<List<rust.StatusHistoryDto>> historyListStatuses(
    String uid, {
    int limit = 50,
    int offset = 0,
  }) async {
    await ensureInit();
    return rust.historyListStatuses(uid: uid, limit: limit, offset: offset);
  }

  Future<int> historyClearStatuses(String uid) async {
    await ensureInit();
    return (await rust.historyClearStatuses(uid: uid)).toInt();
  }

  Future<void> historyRecordUser({
    required String uid,
    required String targetUid,
    required String targetUserName,
    String targetUserAvatar = '',
    String userJson = '',
  }) async {
    await ensureInit();
    await rust.historyRecordUser(
      uid: uid,
      targetUid: targetUid,
      targetUserName: targetUserName,
      targetUserAvatar: targetUserAvatar,
      userJson: userJson,
    );
  }

  Future<List<rust.UserHistoryDto>> historyListUsers(
    String uid, {
    int limit = 30,
  }) async {
    await ensureInit();
    return rust.historyListUsers(uid: uid, limit: limit);
  }

  Future<int> historyClearUsers(String uid) async {
    await ensureInit();
    return (await rust.historyClearUsers(uid: uid)).toInt();
  }

  Future<List<rust.BlacklistRuleDto>> blacklistList(
    String uid, {
    int? ruleType,
  }) async {
    await ensureInit();
    return rust.blacklistList(uid: uid, ruleType: ruleType);
  }

  Future<int> blacklistUpsert({
    required String uid,
    required String key,
    String info = '',
    required int ruleType,
    int state = 1,
    int blackType = 1,
  }) async {
    await ensureInit();
    return (await rust.blacklistUpsert(
      uid: uid,
      key: key,
      info: info,
      ruleType: ruleType,
      state: state,
      blackType: blackType,
    ))
        .toInt();
  }

  Future<bool> blacklistToggle(int id, int state) async {
    await ensureInit();
    return rust.blacklistToggle(id: id, state: state);
  }

  Future<bool> blacklistDelete(int id) async {
    await ensureInit();
    return rust.blacklistDelete(id: id);
  }

  Future<String> blacklistExportBackup(String uid) async {
    await ensureInit();
    return rust.blacklistExportBackup(uid: uid);
  }

  Future<int> blacklistImportBackup(String uid, String backupJson) async {
    await ensureInit();
    return (await rust.blacklistImportBackup(uid: uid, backupJson: backupJson))
        .toInt();
  }

  Future<int> followersReplaceBatch(String uid, String usersJson) async {
    await ensureInit();
    return (await rust.followersReplaceBatch(uid: uid, usersJson: usersJson))
        .toInt();
  }

  Future<List<rust.FollowerDto>> followersSearch(
    String uid, {
    String query = '',
    int limit = 50,
  }) async {
    await ensureInit();
    return rust.followersSearch(uid: uid, query: query, limit: limit);
  }

  Future<int> groupsCacheReplace(String uid, String groupsJson) async {
    await ensureInit();
    return (await rust.groupsCacheReplace(uid: uid, groupsJson: groupsJson))
        .toInt();
  }

  Future<List<rust.CachedGroupDto>> groupsCacheList(
    String uid, {
    bool onlyVisible = false,
  }) async {
    await ensureInit();
    return rust.groupsCacheList(uid: uid, onlyVisible: onlyVisible);
  }

  Future<String?> kvGet(String key) async {
    await ensureInit();
    return rust.shareJsonGet(key: key);
  }

  Future<void> kvSet(String key, String value) async {
    await ensureInit();
    await rust.shareJsonSet(key: key, value: value);
  }

  // --------------------------------------------------------------------------
  // Unified Dual-Protocol Helpers (Mobile /2/* + Web /ajax/* fallback)
  // --------------------------------------------------------------------------

  Future<String> hotTimelineDualRaw({
    String groupId = '102803',
    String? maxId,
    int count = 20,
    bool needJump = false,
  }) async {
    await ensureInit();
    return rust.hotTimelineDual(
      groupId: groupId,
      maxId: maxId,
      count: count,
      needJump: needJump,
    );
  }

  Future<String> friendsTimelineDualRaw({
    String? listId,
    String? sinceId,
    String? maxId,
    int count = 25,
    int page = 1,
  }) async {
    await ensureInit();
    return rust.friendsTimelineDual(
      listId: listId,
      sinceId: sinceId,
      maxId: maxId,
      count: count,
      page: page,
    );
  }

  Future<String?> getActiveWebCookie() async {
    await ensureInit();
    return rust.getActiveWebCookieDual();
  }

  Future<String> userProfileDual(String uid) async {
    await ensureInit();
    return rust.userProfileDual(uid: uid);
  }

  Future<String> userTimelineDual(
    String uid, {
    String? maxId,
    int count = 20,
    int page = 1,
    int feature = 0,
  }) async {
    await ensureInit();
    return rust.userTimelineDual(
      uid: uid,
      maxId: maxId,
      count: count,
      page: page,
      feature: feature,
    );
  }

  Future<String> friendsListDual(
    String uid, {
    int page = 1,
    int cursor = -1,
    int count = 50,
    bool followers = false,
  }) async {
    await ensureInit();
    return rust.friendsListDual(
      uid: uid,
      page: page,
      cursor: cursor,
      count: count,
      followers: followers,
    );
  }

  Future<String> unreadCountDual() async {
    await ensureInit();
    return rust.unreadCountDual();
  }

  Future<String> noticesDual(
    String kind, {
    String? maxId,
    int page = 1,
    int count = 20,
  }) async {
    await ensureInit();
    return rust.noticesDual(
      kind: kind,
      maxId: maxId,
      page: page,
      count: count,
    );
  }

  Future<String> dmConversationsDual({int count = 20, String? cursor}) async {
    await ensureInit();
    return rust.dmConversationsDual(count: count, cursor: cursor);
  }

  Future<String> dmHistoryDual(
    String uid, {
    String? maxId,
    int count = 20,
    bool isGroup = false,
  }) async {
    await ensureInit();
    return rust.dmHistoryDual(
      uid: uid,
      maxId: maxId,
      count: count,
      isGroup: isGroup,
    );
  }

  Future<String> dmSendDual(
    String uid,
    String text, {
    bool isGroup = false,
  }) async {
    await ensureInit();
    return rust.dmSendDual(uid: uid, text: text, isGroup: isGroup);
  }

  Future<String> statusShowDual(String id) async {
    await ensureInit();
    return rust.statusShowDual(id: id);
  }

  Future<String> statusLongtextDual(String id) async {
    await ensureInit();
    return rust.statusLongtextDual(id: id);
  }

  Future<String> commentsDual(
    String statusId, {
    String authorUid = '',
    int flow = 0,
    String? maxId,
    int page = 1,
    int count = 20,
  }) async {
    await ensureInit();
    return rust.commentsDual(
      statusId: statusId,
      authorUid: authorUid,
      flow: flow,
      maxId: maxId,
      page: page,
      count: count,
    );
  }

  Future<String> commentRepliesDual(
    String commentId, {
    String? maxId,
    int flow = 0,
    int count = 20,
  }) async {
    await ensureInit();
    return rust.commentRepliesDual(
      commentId: commentId,
      maxId: maxId,
      flow: flow,
      count: count,
    );
  }

  Future<String> repostListDual(String statusId, {int page = 1}) async {
    await ensureInit();
    return rust.repostListDual(statusId: statusId, page: page);
  }

  Future<String> likersDual(
    String statusId, {
    int page = 1,
    int count = 20,
  }) async {
    await ensureInit();
    return rust.likersDual(statusId: statusId, page: page, count: count);
  }

  Future<void> likeDual(String statusId, {bool undo = false}) async {
    await ensureInit();
    return rust.likeDual(statusId: statusId, undo: undo);
  }

  Future<void> favoriteDual(String statusId, {bool undo = false}) async {
    await ensureInit();
    return rust.favoriteDual(statusId: statusId, undo: undo);
  }

  Future<String> favoritesDual({int page = 1, int count = 20}) async {
    await ensureInit();
    return rust.favoritesDual(page: page, count: count);
  }

  Future<String> likedStatusesDual(String uid, {int page = 1}) async {
    await ensureInit();
    return rust.likedStatusesDual(uid: uid, page: page);
  }

  Future<String> commentCreateDual(String statusId, String text) async {
    await ensureInit();
    return rust.commentCreateDual(statusId: statusId, text: text);
  }

  Future<String> commentReplyDual(String statusId, String cid, String text) async {
    await ensureInit();
    return rust.commentReplyDual(statusId: statusId, cid: cid, text: text);
  }

  Future<void> commentLikeDual(String cid, {bool undo = false}) async {
    await ensureInit();
    return rust.commentLikeDual(cid: cid, undo: undo);
  }

  Future<String> translateStatusDual(String idstr, {String locale = 'zh'}) async {
    await ensureInit();
    return rust.translateStatusDual(idstr: idstr, locale: locale);
  }

  Future<String> hotSearchBandsDual() async {
    await ensureInit();
    return rust.hotSearchBandsDual();
  }

  Future<String> repostDual(
    String statusId,
    String text, {
    bool alsoComment = false,
  }) async {
    await ensureInit();
    return rust.repostDual(
      statusId: statusId,
      text: text,
      alsoComment: alsoComment,
    );
  }

  Future<String> publishDual(
    String text, {
    int visible = 0,
    String picIds = '',
    String? tail,
  }) async {
    await ensureInit();
    final trimmedTail = tail?.trim();
    return rust.publishDual(
      text: text,
      visible: visible,
      picIds: picIds,
      tail: (trimmedTail == null || trimmedTail.isEmpty) ? null : trimmedTail,
    );
  }

  Future<void> followDual(String uid, {bool undo = false}) async {
    await ensureInit();
    return rust.followDual(uid: uid, undo: undo);
  }

  Future<void> deleteStatusDual(String statusId) async {
    await ensureInit();
    return rust.deleteStatusDual(statusId: statusId);
  }

  Future<String> groupsDual() async {
    await ensureInit();
    return rust.groupsDual();
  }

  Future<String> searchStatusesDual(
    String keyword, {
    int page = 1,
    int count = 20,
  }) async {
    await ensureInit();
    return rust.searchStatusesDual(keyword: keyword, page: page, count: count);
  }

  Future<String> searchTypedDual(
    String keyword, {
    String searchType = 'all',
    int page = 1,
    int count = 20,
  }) async {
    await ensureInit();
    return rust.searchTypedDual(
      keyword: keyword,
      searchType: searchType,
      page: page,
      count: count,
    );
  }

  Uint8List wesyncEncode(int cmd, int seq, List<int> payload) =>
      rust.wesyncEncodeFrame(cmd: cmd, seq: seq, payload: payload);

  Map<String, dynamic> wesyncDecode(List<int> bytes) =>
      _decodeMap(rust.wesyncDecodeFrameJson(bytes: bytes));

  Map<String, dynamic> _decodeMap(String raw) {
    final val = jsonDecode(raw);
    if (val is Map<String, dynamic>) return val;
    return {'data': val};
  }
}
