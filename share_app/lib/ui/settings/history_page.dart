import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/share_core.dart';
import '../../src/rust/api/share_api.dart' show StatusHistoryDto, UserHistoryDto;
import '../app_theme.dart';
import '../detail/status_detail_page.dart';
import '../profile/user_page.dart';

/// 1:1 复刻浏览历史 (`STATUS_HISTORY`) 与经常访问 (`USER_HISTORY`) 管理页。
class HistoryPage extends ConsumerStatefulWidget {
  final int initialTab;

  const HistoryPage({super.key, this.initialTab = 0});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  List<StatusHistoryDto> _statuses = const [];
  List<UserHistoryDto> _users = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 1),
    );
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  String get _uid => ref.read(sessionProvider).account?.uid ?? '';

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        ShareCore.instance.historyListStatuses(_uid, limit: 80),
        ShareCore.instance.historyListUsers(_uid, limit: 50),
      ]);
      if (!mounted) return;
      setState(() {
        _statuses = results[0] as List<StatusHistoryDto>;
        _users = results[1] as List<UserHistoryDto>;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _clearCurrentTab() async {
    if (_tabs.index == 0) {
      await ShareCore.instance.historyClearStatuses(_uid);
    } else {
      await ShareCore.instance.historyClearUsers(_uid);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('浏览记录与常访'),
        actions: [
          TextButton(
            onPressed: _clearCurrentTab,
            child: Text('清空当前', style: TextStyle(color: ShareColors.toolbarFg)),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: ShareColors.accent,
          unselectedLabelColor: ShareColors.textSecondary,
          indicatorColor: ShareColors.accent,
          tabs: const [
            Tab(text: '微博浏览历史'),
            Tab(text: '经常访问主页'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : TabBarView(
              controller: _tabs,
              children: [
                _buildStatusList(),
                _buildUserList(),
              ],
            ),
    );
  }

  Widget _buildStatusList() {
    if (_statuses.isEmpty) {
      return Center(
        child: Text('暂无微博浏览历史', style: TextStyle(color: ShareColors.textHint)),
      );
    }
    return ListView.separated(
      itemCount: _statuses.length,
      separatorBuilder: (_, _) => Divider(height: 0.5, color: ShareColors.divider),
      itemBuilder: (context, i) {
        final item = _statuses[i];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: ShareColors.placeholder,
            backgroundImage: item.avatar.isNotEmpty ? NetworkImage(item.avatar) : null,
            child: item.avatar.isEmpty ? const Icon(Icons.person_outline, size: 18) : null,
          ),
          title: Text(
            item.username.isNotEmpty ? item.username : '微博 #${item.statusId}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            item.totalText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary),
          ),
          onTap: () {
            try {
              final decoded = jsonDecode(item.statusJson);
              if (decoded is Map<String, dynamic>) {
                final st = Status.fromJson(decoded);
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => StatusDetailPage(status: st)),
                );
              }
            } catch (_) {}
          },
        );
      },
    );
  }

  Widget _buildUserList() {
    if (_users.isEmpty) {
      return Center(
        child: Text('暂无常访用户记录', style: TextStyle(color: ShareColors.textHint)),
      );
    }
    return ListView.separated(
      itemCount: _users.length,
      separatorBuilder: (_, _) => Divider(height: 0.5, color: ShareColors.divider),
      itemBuilder: (context, i) {
        final u = _users[i];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: ShareColors.placeholder,
            backgroundImage: u.targetUserAvatar.isNotEmpty
                ? NetworkImage(u.targetUserAvatar)
                : null,
            child: u.targetUserAvatar.isEmpty
                ? const Icon(Icons.person_outline, size: 18)
                : null,
          ),
          title: Text(u.targetUserName),
          trailing: Text(
            '访问 ${u.visitCount} 次',
            style: TextStyle(fontSize: 12, color: ShareColors.textHint),
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => UserPage(
                uid: u.targetUid,
                initialName: u.targetUserName,
                initialAvatar: u.targetUserAvatar,
              ),
            ),
          ),
        );
      },
    );
  }
}
