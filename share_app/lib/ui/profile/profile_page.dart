import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../app_theme.dart';
import '../compose/drafts_page.dart';
import '../group/group_page.dart';
import '../favorites/favorites_page.dart';
import '../settings/about_page.dart';
import '../settings/accounts_page.dart';
import '../settings/settings_page.dart';
import 'liked_page.dart';
import 'new_followers_page.dart';
import 'social_manage_page.dart';
import 'user_page.dart';
import '../settings/history_page.dart';
import '../settings/keyword_page.dart';
import '../theme/theme_page.dart';

class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  User? _user;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider);
    final uid = session.account?.uid ?? '';
    if (!session.isLoggedIn || uid.isEmpty) {
      if (mounted) {
        setState(() {
          _user = null;
          _loading = false;
        });
      }
      return;
    }
    setState(() => _loading = true);
    try {
      final user = await WeiboApi.instance.profile(uid);
      if (!mounted) return;
      setState(() {
        _user = user;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _requireLoginSnack() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('请先登录后查看')),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SessionState>(sessionProvider, (previous, next) {
      final prevUid = previous?.account?.uid ?? '';
      final nextUid = next.account?.uid ?? '';
      if (prevUid != nextUid || (previous?.isLoggedIn ?? false) != next.isLoggedIn) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _load());
      }
    });

    final session = ref.watch(sessionProvider);
    final account = session.account;
    final loggedIn = session.isLoggedIn;

    return Scaffold(
      appBar: AppBar(
        title: Text('我'),
        actions: [
          IconButton(onPressed: _load, icon: Icon(Icons.refresh, size: 22)),
        ],
      ),
      body: RefreshIndicator(
        color: ShareColors.accent,
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
          _header(account, loggedIn, onTap: () => _openSelf(account)),
          SizedBox(height: 10),
          _group([
            _row(Icons.article_outlined, '我的微博', '${_user?.statuses ?? 0}',
                onTap: () => _openSelf(account)),
            _row(Icons.people_outline, '关注', '${_user?.friends ?? 0}',
                onTap: () {
                  final uid = account?.uid ?? '';
                  if (!loggedIn || uid.isEmpty) return _requireLoginSnack();
                  _open(MyFriendPage(uid: uid, showFollowers: false));
                }),
            _row(Icons.group_outlined, '粉丝', '${_user?.followers ?? 0}',
                onTap: () {
                  final uid = account?.uid ?? '';
                  if (!loggedIn || uid.isEmpty) return _requireLoginSnack();
                  _open(MyFriendPage(uid: uid, showFollowers: true));
                }),
            _row(Icons.edit_outlined, '编辑资料', '',
                onTap: () async {
                  if (!loggedIn) return _requireLoginSnack();
                  if (_user == null) {
                    await _load();
                    if (!context.mounted || _user == null) return;
                  }
                  final changed = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(builder: (_) => EditProfilePage(user: _user!)),
                  );
                  if (changed == true) _load();
                }),
            _row(Icons.history, '浏览记录与常访', '',
                onTap: () => _open(const HistoryPage())),
            _row(Icons.block_outlined, '黑名单与过滤', '',
                onTap: () => _open(const KeywordPage(initialTab: 0))),
            // 原版 `MyFollowersActivity` 挂在「粉丝」这一组的下面。
            _row(Icons.person_add_alt_1_outlined, '新增粉丝', '',
                onTap: () => _openNewFollowers(account)),
          ]),
          SizedBox(height: 10),
          _group([
            _row(Icons.favorite_border, '赞过的微博', '',
                onTap: () {
                  final uid = account?.uid ?? '';
                  if (!loggedIn || uid.isEmpty) return _requireLoginSnack();
                  _open(LikedPage(uid: uid));
                }),
            _row(Icons.star_border, '我的收藏', '',
                onTap: () => _open(const FavoritesPage())),
            _row(Icons.drafts_outlined, '草稿箱', '',
                onTap: () => _open(const DraftsPage())),
            _row(Icons.folder_outlined, '分组管理', '',
                onTap: () => _open(const GroupPage())),
          ]),
          SizedBox(height: 10),
          _group([
            _row(Icons.palette_outlined, '主题外观', '', onTap: () => _open(const ThemePage())),
            _row(Icons.switch_account_outlined, '账号管理', '',
                onTap: () => _open(const AccountsPage())),
            _row(Icons.settings_outlined, '设置', '', onTap: () => _open(const SettingsPage())),
            _row(Icons.info_outline, '关于 Share', 'v3.9.6 · 1.5',
                onTap: () => _open(const AboutPage())),
          ]),
          SizedBox(height: 20),
          if (loggedIn)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: OutlinedButton(
                onPressed: () async {
                  await ref.read(sessionProvider.notifier).logout();
                },
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                  foregroundColor: Color(0xFFE64545),
                ),
                child: Text('退出登录'),
              ),
            ),
          SizedBox(height: 30),
        ],
        ),
      ),
    );
  }

  void _openSelf(SessionAccount? account) {
    if (account == null || account.uid.isEmpty) return;
    _open(UserPage(
      uid: account.uid,
      initialName: account.screenName,
      initialAvatar: account.avatar,
    ));
  }

  /// 「新增粉丝」只有登录态才有意义：接口要带 uid 才会返回别人对你的关注动作，
  /// 未登录时先给出明确提示，而不是打开一个必然报错的空页。
  void _openNewFollowers(SessionAccount? account) {
    final uid = account?.uid ?? '';
    if (!ref.read(sessionProvider).isLoggedIn || uid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('新增粉丝需要登录后查看')),
      );
      return;
    }
    _open(NewFollowersPage(uid: uid));
  }

  Widget _header(SessionAccount? account, bool loggedIn, {VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      child: Container(
      color: ShareColors.cardBg,
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(32),
            child: Container(
              width: 64,
              height: 64,
              color: Color(0xFFEFEFEF),
              child: (account?.avatar.isNotEmpty ?? false)
                  ? Image.network(account!.avatar, fit: BoxFit.cover)
                  : Icon(Icons.person, size: 32, color: Color(0xFFBDBDBD)),
            ),
          ),
          SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        loggedIn
                            ? (_user?.name ?? account?.screenName ?? '')
                            : '未登录',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: ShareColors.textPrimary,
                        ),
                      ),
                    ),
                    if (_user?.verified ?? false) ...[
                      SizedBox(width: 5),
                      Icon(Icons.verified, size: 15, color: Color(0xFFFF8200)),
                    ],
                  ],
                ),
                SizedBox(height: 6),
                Text(
                  loggedIn
                      ? (_user?.description.isNotEmpty == true
                          ? _user!.description
                          : 'UID ${account?.uid ?? ''}')
                      : '登录后可同步你的微博、私信与收藏',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary),
                ),
              ],
            ),
          ),
          if (_loading)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            ),
        ],
      ),
    ),
    );
  }

  Widget _group(List<Widget> children) {
    return Material(color: ShareColors.cardBg, child: Column(children: children));
  }

  void _open(Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  Widget _row(IconData icon, String title, String trailing, {VoidCallback? onTap}) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 20, color: ShareColors.textSecondary),
      title: Text(title, style: TextStyle(fontSize: 15)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailing.isNotEmpty)
            Text(trailing,
                style: TextStyle(fontSize: 12.5, color: ShareColors.textHint)),
          SizedBox(width: 4),
          Icon(Icons.chevron_right, size: 18, color: ShareColors.textHint),
        ],
      ),
      onTap: onTap,
    );
  }
}
