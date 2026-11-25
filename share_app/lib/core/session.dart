import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/share_api.dart' show CoreInitResult;
import 'api.dart';
import 'share_core.dart';

class SessionState {
  final SessionAccount? account;
  final bool loading;
  final String? error;

  const SessionState({this.account, this.loading = false, this.error});

  bool get isLoggedIn => account != null && !account!.isGuest;

  SessionState copyWith({
    SessionAccount? account,
    bool? loading,
    String? error,
    bool clearError = false,
    bool clearAccount = false,
  }) {
    return SessionState(
      account: clearAccount ? null : (account ?? this.account),
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class SessionNotifier extends StateNotifier<SessionState> {
  SessionNotifier() : super(const SessionState(loading: true));

  Future<void> bootstrap() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      CoreInitResult? coreInit;
      try {
        coreInit = await ShareCore.instance.init(
          forceRefresh: ShareCore.instance.isInitialized,
        );
      } catch (_) {}
      final webAccount = await _safeCurrentAccount();
      var account = webAccount;

      if (coreInit != null && coreInit.hasAuthenticatedUser && coreInit.activeUid.isNotEmpty) {
        String resolvedName = coreInit.activeName;
        String resolvedAvatar = coreInit.activeAvatar;
        if (resolvedName.isEmpty) {
          try {
            final sqlAccounts = await ShareCore.instance.accounts();
            final active = sqlAccounts.where((a) => a.uid == coreInit!.activeUid).firstOrNull ??
                sqlAccounts.firstOrNull;
            if (active != null) {
              if (active.name.isNotEmpty) resolvedName = active.name;
              if (resolvedAvatar.isEmpty) resolvedAvatar = active.avatar;
            }
          } catch (_) {}
        }
        if (resolvedName.isEmpty) resolvedName = coreInit.activeUid;

        if (account == null || account.uid != coreInit.activeUid || account.isGuest) {
          account = SessionAccount(
            uid: coreInit.activeUid,
            screenName: resolvedName,
            avatar: resolvedAvatar,
            isGuest: false,
            active: true,
          );
        }

        // Sync SQLite mobile account + cleaned cookie back into WebClient so Web fallback
        // and InAppWebPage share the same active account without wiping existing SUB cookies.
        if (coreInit.activeCookie.isNotEmpty ||
            webAccount == null ||
            webAccount.uid != coreInit.activeUid ||
            webAccount.isGuest) {
          try {
            final synced = await WeiboApi.instance.syncAccountCookie(
              uid: coreInit.activeUid,
              screenName: resolvedName,
              avatar: resolvedAvatar,
              cookie: coreInit.activeCookie,
            );
            account = synced;
          } catch (_) {}
        }
      } else if (account != null && account.isGuest) {
        await WeiboApi.instance.ensureGuestSession().catchError((_) {});
      }

      state = SessionState(account: account, loading: false);
    } catch (e) {
      state = SessionState(loading: false, error: _humanize(e));
    }
  }

  Future<SessionAccount?> _safeCurrentAccount() async {
    try {
      return await WeiboApi.instance.currentAccount();
    } catch (_) {
      return null;
    }
  }

  /// Authenticates with Weibo username/password via official mobile RSA `/2/account/login`.
  ///
  /// Returns raw result map: `status == 'ok'` means logged in cleanly;
  /// `status == 'challenge'` means caller must open Safety Verify / SMS / Captcha UI.
  Future<Map<String, dynamic>> loginWithPassword({
    required String username,
    required String password,
    String? cptId,
    String? cptCode,
    String? alt,
  }) async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final res = await ShareCore.instance.loginPassword(
        username: username,
        password: password,
        cptId: cptId,
        cptCode: cptCode,
        alt: alt,
      );
      if (res['status'] == 'ok') {
        await _syncAfterMobileAuth(res);
      } else {
        state = state.copyWith(
          loading: false,
          error: res['errmsg']?.toString(),
        );
      }
      return res;
    } catch (e) {
      final msg = _humanize(e);
      state = state.copyWith(loading: false, error: msg);
      return {'status': 'error', 'errmsg': msg};
    }
  }

  /// Completes SMS login or risk-control secondary SMS check via `/2/account/login`.
  Future<bool> completeSmsLogin({
    required String phone,
    required String area,
    required String number,
    required String code,
    required bool isSmsLogin,
    String? username,
    String? password,
    String? retcode,
  }) async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final res = await ShareCore.instance.loginSmsVerify(
        phone: phone,
        area: area,
        number: number,
        code: code,
        isSmsLogin: isSmsLogin,
        username: username,
        password: password,
        retcode: retcode,
      );
      if (res['status'] == 'ok') {
        await _syncAfterMobileAuth(res);
        return true;
      }
      state = state.copyWith(
        loading: false,
        error: res['errmsg']?.toString() ?? '验证失败',
      );
      return false;
    } catch (e) {
      state = state.copyWith(loading: false, error: _humanize(e));
      return false;
    }
  }

  Future<void> _syncAfterMobileAuth(Map<String, dynamic> res) async {
    final acc = res['account'] as Map<String, dynamic>? ?? const {};
    final raw = res['raw'] as Map<String, dynamic>? ?? const {};
    final uid = '${acc['uid'] ?? raw['uid'] ?? ''}';
    final name = '${acc['name'] ?? raw['user']?['screen_name'] ?? uid}';
    final avatar = '${acc['avatar'] ?? raw['user']?['avatar_hd'] ?? ''}';

    // Always synchronize mobile account & sanitized Cookie into WebClient/session.json.
    final flatCookie = _extractCookieHeader(raw['cookie']) ??
        (await ShareCore.instance.getActiveWebCookie().catchError((_) => null)) ??
        '';
    SessionAccount syncedAccount = SessionAccount(
      uid: uid,
      screenName: name.isEmpty ? uid : name,
      avatar: avatar,
      isGuest: false,
      active: true,
    );
    if (uid.isNotEmpty) {
      try {
        syncedAccount = await WeiboApi.instance.syncAccountCookie(
          uid: uid,
          screenName: syncedAccount.screenName,
          avatar: avatar,
          cookie: flatCookie,
        );
      } catch (_) {}
    }

    state = SessionState(
      account: syncedAccount,
      loading: false,
    );
  }

  Future<bool> loginWithCookie(String cookie) async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final account = await WeiboApi.instance.loginWithCookie(cookie);
      try {
        await ShareCore.instance.importCookie(
          cookie,
          uidHint: account.uid,
          nameHint: account.screenName,
        );
      } catch (_) {}
      state = SessionState(account: account, loading: false);
      return true;
    } catch (e) {
      try {
        final sqlAccount = await ShareCore.instance.importCookie(cookie);
        state = SessionState(
          account: SessionAccount(
            uid: sqlAccount.uid,
            screenName: sqlAccount.name.isEmpty ? sqlAccount.uid : sqlAccount.name,
            avatar: sqlAccount.avatar,
            isGuest: false,
            active: true,
          ),
          loading: false,
        );
        return true;
      } catch (_) {
        state = state.copyWith(loading: false, error: _humanize(e));
        return false;
      }
    }
  }

  Future<void> continueAsGuest() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      await ShareCore.instance.guestLogin().catchError((_) => <String, dynamic>{});
      await WeiboApi.instance.ensureGuestSession().catchError((_) {});
      final account = SessionAccount(
        uid: '',
        screenName: '访客',
        avatar: '',
        isGuest: true,
        active: true,
      );
      state = SessionState(account: account, loading: false);
    } catch (e) {
      state = state.copyWith(loading: false, error: _humanize(e));
    }
  }

  Future<void> switchTo(String uid) async {
    try {
      await ShareCore.instance.switchAccount(uid);
    } catch (_) {}
    await WeiboApi.instance.switchAccount(uid).catchError((_) {});
    await bootstrap();
  }

  Future<bool> remove(String uid) async {
    try {
      await ShareCore.instance.deleteAccount(uid).catchError((_) => false);
      await WeiboApi.instance.removeAccount(uid).catchError((_) {});
      await bootstrap();
      return true;
    } catch (e) {
      state = state.copyWith(error: _humanize(e));
      return false;
    }
  }

  Future<void> logout() async {
    await ShareCore.instance.logoutCurrent().catchError((_) => null);
    await WeiboApi.instance.logout().catchError((_) {});
    state = const SessionState();
  }

  static const _cookieAttrNames = {
    'expires',
    'max-age',
    'domain',
    'path',
    'samesite',
    'priority',
    'httponly',
    'secure',
  };

  void _collectCleanCookies(String raw, Map<String, String> out) {
    final cleaned = raw.replaceAll(RegExp(r'^Cookie:\s*', caseSensitive: false), '');
    for (final line in cleaned.split('\n')) {
      for (final seg in line.split(';')) {
        final t = seg.trim();
        final eq = t.indexOf('=');
        if (eq <= 0) continue;
        final k = t.substring(0, eq).trim();
        final v = t.substring(eq + 1).trim();
        if (k.isEmpty || v.isEmpty || _cookieAttrNames.contains(k.toLowerCase())) {
          continue;
        }
        out[k] = v;
      }
    }
  }

  String? _extractCookieHeader(dynamic cookieObj) {
    final jar = <String, String>{};
    if (cookieObj is String && cookieObj.isNotEmpty) {
      _collectCleanCookies(cookieObj, jar);
    } else if (cookieObj is Map) {
      final inner = cookieObj['cookie'] is Map ? cookieObj['cookie'] as Map : cookieObj;
      final keys = inner.keys.map((k) => '$k').toList()
        ..sort((a, b) => _cookieDomainPriority(a).compareTo(_cookieDomainPriority(b)));
      for (final key in keys) {
        final val = inner[key];
        if (val is String && val.isNotEmpty) {
          _collectCleanCookies(val, jar);
        }
      }
    }
    if (jar.isEmpty) return null;
    return jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  int _cookieDomainPriority(String domain) => switch (domain) {
        '.weibo.com' || 'weibo.com' => 3,
        '.weibo.cn' || 'weibo.cn' => 2,
        '.sina.com.cn' => 1,
        _ => 0,
      };

  String _humanize(Object error) {
    final text = error.toString();
    final marker = text.indexOf('AnyhowException(');
    if (marker >= 0) {
      return text
          .substring(marker + 'AnyhowException('.length)
          .replaceAll(RegExp(r'\)+$'), '')
          .trim();
    }
    return text;
  }
}

final sessionProvider = StateNotifierProvider<SessionNotifier, SessionState>((ref) {
  return SessionNotifier();
});
