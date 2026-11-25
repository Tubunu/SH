import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../app_theme.dart';
import '../login/login_page.dart';

/// 账号管理 — mirrors the original app's multi-account switcher. The native
/// layer keeps every account's cookie jar on disk, so switching is instant and
/// does not require signing in again.
class AccountsPage extends ConsumerStatefulWidget {
  const AccountsPage({super.key});

  @override
  ConsumerState<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends ConsumerState<AccountsPage> {
  List<SessionAccount> _accounts = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final accounts = await WeiboApi.instance.accounts();
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _switch(SessionAccount account) async {
    if (account.active) return;
    await ref.read(sessionProvider.notifier).switchTo(account.uid);
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已切换到 ${account.screenName}')),
    );
  }

  Future<void> _remove(SessionAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除账号'),
        content: Text('确定移除 ${account.screenName.isEmpty ? account.uid : account.screenName} 吗？'
            '本地保存的登录信息会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除', style: TextStyle(color: Color(0xFFE64545))),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(sessionProvider.notifier).remove(account.uid);
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('账号管理')),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }

    return ListView(
      children: [
        const SizedBox(height: 8),
        Container(
          color: ShareColors.cardBg,
          child: Column(
            children: [
              for (var i = 0; i < _accounts.length; i++) ...[
                if (i > 0)
                  Container(
                    height: 0.6,
                    color: ShareColors.divider,
                    margin: const EdgeInsets.only(left: 66),
                  ),
                _accountTile(_accounts[i]),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton.icon(
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LoginPage()),
              );
              if (mounted) await _load();
            },
            style: FilledButton.styleFrom(
              backgroundColor: ShareColors.accent,
              minimumSize: const Size.fromHeight(44),
            ),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加账号'),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton(
            onPressed: _logout,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
              foregroundColor: const Color(0xFFD64541),
              side: BorderSide(color: ShareColors.divider),
            ),
            child: const Text('退出登录'),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            '每个账号的登录信息分别保存在本机，切换账号不需要重新登录。'
            '退出登录后会回到访客模式。',
            style: TextStyle(fontSize: 12, color: ShareColors.textHint, height: 1.5),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后将回到访客模式，确定继续吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('退出')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(sessionProvider.notifier).logout();
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  Widget _accountTile(SessionAccount account) {
    return InkWell(
      onTap: () => _switch(account),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(21),
              child: SizedBox(
                width: 42,
                height: 42,
                child: account.avatar.isNotEmpty
                    ? Image.network(
                        account.avatar,
                        fit: BoxFit.cover,
                        cacheWidth: 130,
                        errorBuilder: (_, _, _) => ColoredBox(
                          color: ShareColors.placeholder,
                          child: Icon(Icons.person, color: ShareColors.textHint),
                        ),
                      )
                    : ColoredBox(
                        color: ShareColors.placeholder,
                        child: Icon(Icons.person, color: ShareColors.textHint),
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
                          account.screenName.isEmpty ? account.uid : account.screenName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: ShareColors.textPrimary,
                          ),
                        ),
                      ),
                      if (account.isGuest) ...[
                        const SizedBox(width: 5),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: ShareColors.inputBg,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text('访客',
                              style: TextStyle(fontSize: 9, color: ShareColors.textSecondary)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    account.uid.isEmpty ? '未绑定 UID' : 'UID ${account.uid}',
                    style: TextStyle(fontSize: 11.5, color: ShareColors.textHint),
                  ),
                ],
              ),
            ),
            if (account.active)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(Icons.check_circle, size: 18, color: ShareColors.accent),
              )
            else
              IconButton(
                onPressed: () => _remove(account),
                icon: Icon(Icons.delete_outline, size: 19, color: ShareColors.textHint),
                tooltip: '移除',
              ),
          ],
        ),
      ),
    );
  }
}
