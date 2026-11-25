import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/settings.dart';
import '../app_theme.dart';
import '../compose/compose_page.dart';
import '../compose/drafts_page.dart';
import '../dm/dm_list_page.dart';
import '../favorites/favorites_page.dart';
import '../group/group_page.dart';
import '../login/login_page.dart';
import '../profile/social_manage_page.dart';
import '../profile/user_page.dart';
import '../search/search_page.dart';
import '../settings/accounts_page.dart';
import '../settings/history_page.dart';
import '../settings/keyword_page.dart';
import '../settings/settings_page.dart';
import '../stopic/stopic_page.dart';
import '../theme/theme_page.dart';

/// 当前登录账号的资料（封面、关注/粉丝/微博数）。游客为 `null`。
final meProfileProvider = FutureProvider.autoDispose<User?>((ref) async {
  final account = ref.watch(sessionProvider).account;
  if (account == null || account.isGuest || account.uid.isEmpty) return null;
  try {
    return await WeiboApi.instance.profile(account.uid);
  } catch (_) {
    return null;
  }
});

/// 侧栏抽屉 —— 对齐原版 `DrawerLayout` (`C2801hc` 菜单排序与显隐、`drawer_cover_type` 3 种封面)。
class ShareDrawer extends ConsumerWidget {
  final void Function(int index) onSelectTab;

  const ShareDrawer({super.key, required this.onSelectTab});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final settings = ref.watch(settingsProvider);
    final account = session.account;
    final profile = ref.watch(meProfileProvider).valueOrNull;
    final preset = settings.effectivePreset(MediaQuery.platformBrightnessOf(context));
    final isDark = preset.dark;

    final width = (MediaQuery.sizeOf(context).width * 0.78).clamp(240.0, 310.0);
    final orderedKeys = [
      ...settings.drawerMenuOrder,
      for (final k in AppSettings.defaultDrawerOrder)
        if (!settings.drawerMenuOrder.contains(k)) k,
    ].where((k) => !settings.drawerHiddenKeys.contains(k)).toList();

    return Drawer(
      width: width,
      backgroundColor: ShareColors.cardBg,
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        right: false,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            _header(context, ref, account, profile, settings),
            _accountRow(context, ref, session, account),
            Divider(height: 0.5, thickness: 0.5, color: ShareColors.divider),
            for (final key in orderedKeys) _buildMenuItem(context, ref, key),
            Divider(height: 12, thickness: 6, color: ShareColors.pageBg),
            _nightSwitch(context, ref, settings, isDark),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuItem(BuildContext context, WidgetRef ref, String key) {
    switch (key) {
      case 'home':
        return _item(Icons.home_outlined, '首页', () {
          Navigator.pop(context);
          onSelectTab(0);
        });
      case 'hot':
        return _item(Icons.local_fire_department_outlined, '热门', () {
          Navigator.pop(context);
          onSelectTab(1);
        });
      case 'friends':
        return _item(Icons.people_outline, '我的关注', () {
          final session = ref.read(sessionProvider);
          final uid = session.account?.uid ?? '';
          Navigator.pop(context);
          if (!session.isLoggedIn || uid.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('请先登录后查看关注列表')),
            );
            return;
          }
          _push(context, MyFriendPage(uid: uid, showFollowers: false));
        });
      case 'topic':
        return _item(Icons.forum_outlined, '超话', () {
          Navigator.pop(context);
          _push(context, const StopicPage());
        });
      case 'search':
        return _item(Icons.search, '搜索', () {
          Navigator.pop(context);
          _push(context, const SearchPage());
        });
      case 'favorites':
        return _item(Icons.star_border, '收藏', () {
          Navigator.pop(context);
          _push(context, const FavoritesPage());
        });
      case 'drafts':
        return _item(Icons.drafts_outlined, '草稿箱', () {
          Navigator.pop(context);
          _push(context, const DraftsPage());
        });
      case 'message':
        return _item(Icons.mark_email_unread_outlined, '消息', () {
          Navigator.pop(context);
          onSelectTab(2);
        });
      case 'dm':
        return _item(Icons.chat_bubble_outline, '私信', () {
          Navigator.pop(context);
          _push(context, const DmListPage());
        });
      case 'groups':
        return _item(Icons.folder_outlined, '分组管理', () {
          Navigator.pop(context);
          _push(context, const GroupPage());
        });
      case 'blacklist':
        return _item(Icons.block_outlined, '黑名单与屏蔽', () {
          Navigator.pop(context);
          _push(context, const KeywordPage(initialTab: 0));
        });
      case 'history':
        return _item(Icons.history, '浏览记录', () {
          Navigator.pop(context);
          _push(context, const HistoryPage());
        });
      case 'theme':
        return _item(Icons.palette_outlined, '主题', () {
          Navigator.pop(context);
          _push(context, const ThemePage());
        });
      case 'settings':
      default:
        return _item(Icons.settings_outlined, '设置', () {
          Navigator.pop(context);
          _push(context, const SettingsPage());
        });
    }
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  Widget _header(
    BuildContext context,
    WidgetRef ref,
    SessionAccount? account,
    User? profile,
    AppSettings settings,
  ) {
    final coverType = settings.drawerCoverType;
    final coverUrl = coverType == 3 ? (profile?.cover ?? '') : '';
    final localImg = coverType == 2 ? settings.customTheme.backgroundImagePath : null;
    final hasLocalCover = localImg != null && File(localImg).existsSync();

    final name = profile?.displayName.isNotEmpty == true
        ? profile!.displayName
        : (account?.screenName.isNotEmpty == true ? account!.screenName : '未登录');
    final avatar = profile?.avatar.isNotEmpty == true
        ? profile!.avatar
        : (account?.avatar ?? '');

    return SizedBox(
      height: 196,
      child: Stack(
        children: [
          Positioned.fill(
            child: hasLocalCover
                ? Image.file(File(localImg), fit: BoxFit.cover)
                : (coverUrl.isNotEmpty
                    ? Image.network(
                        coverUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _coverGradient(),
                      )
                    : _coverGradient()),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.05),
                    Colors.black.withValues(alpha: 0.35),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 14,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    GestureDetector(
                      onTap: () {
                        if (profile == null) {
                          Navigator.pop(context);
                          _push(context, const LoginPage());
                          return;
                        }
                        Navigator.pop(context);
                        _push(
                          context,
                          UserPage(
                            uid: profile.id,
                            initialName: profile.name,
                            initialAvatar: profile.avatar,
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.all(1.5),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.2),
                        ),
                        child: ClipOval(
                          child: SizedBox(
                            width: 54,
                            height: 54,
                            child: avatar.isEmpty
                                ? const ColoredBox(
                                    color: Colors.white24,
                                    child: Icon(Icons.person, color: Colors.white70),
                                  )
                                : Image.network(
                                    avatar,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => const ColoredBox(
                                      color: Colors.white24,
                                      child: Icon(Icons.person, color: Colors.white70),
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                    shadows: [Shadow(color: Colors.black26, blurRadius: 3)],
                                  ),
                                ),
                              ),
                              if (profile?.verified ?? false) ...[
                                const SizedBox(width: 4),
                                Icon(Icons.verified, size: 14, color: Colors.amber.shade300),
                              ],
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            profile?.description.isNotEmpty == true
                                ? profile!.description
                                : (account?.isGuest ?? true ? '访客模式 · 点击头像登录' : ''),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _stat('关注', profile?.friends ?? 0),
                    _stat('粉丝', profile?.followers ?? 0),
                    _stat('微博', profile?.statuses ?? 0),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _coverGradient() {
    final base = ShareColors.themeColor;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            base,
            Color.lerp(base, ShareColors.accent, 0.38) ?? base,
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, int value) {
    return Expanded(
      child: Row(
        children: [
          Text(
            formatCount(value),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12)),
        ],
      ),
    );
  }

  Widget _accountRow(
    BuildContext context,
    WidgetRef ref,
    SessionState session,
    SessionAccount? account,
  ) {
    return InkWell(
      onTap: () => _showAccountSheet(context, ref),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Icon(Icons.switch_account_outlined, size: 18, color: ShareColors.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                account == null
                    ? '未登录'
                    : (account.isGuest ? '访客账号（点击切换/登录）' : '当前账号 · ${account.screenName}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
              ),
            ),
            Icon(Icons.keyboard_arrow_down, size: 18, color: ShareColors.textHint),
          ],
        ),
      ),
    );
  }

  Future<void> _showAccountSheet(BuildContext context, WidgetRef ref) async {
    final accounts = await WeiboApi.instance.accounts();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: ShareColors.cardBg,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(
                children: [
                  Text('切换账号',
                      style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
                  const Spacer(),
                  Text('${accounts.length} 个',
                      style: TextStyle(fontSize: 11.5, color: ShareColors.textHint)),
                ],
              ),
            ),
            for (final a in accounts)
              ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 16,
                  backgroundColor: ShareColors.placeholder,
                  backgroundImage: a.avatar.isEmpty ? null : NetworkImage(a.avatar),
                ),
                title: Text(a.screenName, style: const TextStyle(fontSize: 15)),
                subtitle: Text(a.isGuest ? '访客' : a.uid, style: const TextStyle(fontSize: 11)),
                trailing: a.active ? Icon(Icons.check, size: 18, color: ShareColors.accent) : null,
                onTap: () async {
                  Navigator.pop(ctx);
                  await ref.read(sessionProvider.notifier).switchTo(a.uid);
                },
              ),
            ListTile(
              dense: true,
              leading: Icon(Icons.add, size: 20, color: ShareColors.accent),
              title: Text('添加 / 管理账号', style: TextStyle(fontSize: 15, color: ShareColors.accent)),
              onTap: () {
                Navigator.pop(ctx);
                _push(context, const AccountsPage());
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _item(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 46,
        child: Row(
          children: [
            const SizedBox(width: 18),
            Icon(icon, size: 20, color: ShareColors.textSecondary),
            const SizedBox(width: 14),
            Text(label, style: TextStyle(fontSize: 15, color: ShareColors.textPrimary)),
          ],
        ),
      ),
    );
  }

  Widget _nightSwitch(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    bool isDark,
  ) {
    return InkWell(
      onTap: () => ref.read(settingsProvider.notifier).toggleThemeDark(!isDark),
      child: SizedBox(
        height: 46,
        child: Row(
          children: [
            const SizedBox(width: 18),
            Icon(
              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              size: 20,
              color: ShareColors.textSecondary,
            ),
            const SizedBox(width: 14),
            Text(
              isDark ? '日间模式' : '夜间模式',
              style: TextStyle(fontSize: 15, color: ShareColors.textPrimary),
            ),
            const Spacer(),
            Switch(
              value: isDark,
              activeThumbColor: ShareColors.accent,
              onChanged: (v) => ref.read(settingsProvider.notifier).toggleThemeDark(v),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

void openComposer(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ComposePage()));
}
