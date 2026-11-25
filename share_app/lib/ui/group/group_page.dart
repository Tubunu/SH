import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/groups.dart';
import '../../core/share_core.dart';
import '../app_theme.dart';

/// 分组管理 —— 原版 `GroupManageActivity`。
///
/// 分组结构对游客也开放（`/ajax/feed/allGroups`），所以这里能如实列出
/// 默认分组 / 我的分组 / 订阅分组 / 我的频道；只有分组**时间线**要登录，
/// 点开时会说明，而不是给一个空列表。
class GroupPage extends StatefulWidget {
  const GroupPage({super.key});

  @override
  State<GroupPage> createState() => _GroupPageState();
}

class _GroupPageState extends State<GroupPage> {
  GroupSet? _set;
  String? _error;
  bool _loading = false;

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
      final set = await WeiboApi.instance.groups();
      if (!mounted) return;
      setState(() {
        _set = set;
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

  @override
  Widget build(BuildContext context) {
    final set = _set;
    return Scaffold(
      appBar: AppBar(
        title: const Text('分组管理'),
        actions: [
          IconButton(
            tooltip: '新建分组',
            icon: const Icon(Icons.create_new_folder_outlined, size: 20),
            onPressed: _createGroup,
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: RefreshIndicator(
        color: ShareColors.accent,
        onRefresh: _load,
        child: _buildBody(set),
      ),
    );
  }

  Widget _buildBody(GroupSet? set) {
    if (_loading && set == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null && set == null) {
      return ListView(
        children: [
          const SizedBox(height: 140),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: OutlinedButton(onPressed: _load, child: const Text('重试')),
          ),
        ],
      );
    }
    if (set == null || set.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 140),
          Center(
            child: Text('没有可取的分组',
                style: TextStyle(fontSize: 13, color: ShareColors.textHint)),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        for (final category in set.categories)
          if (category.groups.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
              child: Text('${category.title}（${category.groups.length}）',
                  style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary)),
            ),
            Container(
              color: ShareColors.cardBg,
              child: Column(
                children: [
                  for (var i = 0; i < category.groups.length; i++) ...[
                    if (i > 0)
                      Divider(
                          height: 0.5,
                          thickness: 0.5,
                          color: ShareColors.divider,
                          indent: 16),
                    _row(category.groups[i]),
                  ],
                ],
              ),
            ),
          ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
          child: Text(
            '分组结构与分组顺序来自微博服务端；新建、重命名、调整顺序属于账号设置，'
            '需要登录后在网页版「分组管理」里改，这里只做展示与快捷切换。',
            style: TextStyle(fontSize: 11.5, height: 1.6, color: ShareColors.textHint),
          ),
        ),
      ],
    );
  }

  Widget _row(WeiboGroup group) {
    return InkWell(
      onTap: () => _pick(group),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Icon(
              group.isHotChannel
                  ? Icons.local_fire_department_outlined
                  : Icons.folder_outlined,
              size: 18,
              color: group.isHotChannel ? ShareColors.accent : ShareColors.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(group.title, style: const TextStyle(fontSize: 15)),
            ),
            if (group.isHotChannel)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: ShareColors.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('可直接切换',
                    style: TextStyle(fontSize: 10.5, color: ShareColors.accent)),
              )
            else if (group.count > 0)
              Text('${group.count}',
                  style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary)),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 17, color: ShareColors.textHint),
          ],
        ),
      ),
    );
  }

  Future<void> _createGroup() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建分组'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入分组名称'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty) return;
    try {
      await ShareCore.instance.groupCrud('create', {'name': name});
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('创建失败：$e')));
      }
    }
  }

  Future<void> _pick(WeiboGroup group) async {
    if (group.isHotChannel) {
      Navigator.of(context).pop(group);
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: ShareColors.cardBg,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(group.title, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名分组'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Color(0xFFE64545)),
              title: const Text('删除该分组', style: TextStyle(color: Color(0xFFE64545))),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    try {
      if (action == 'rename') {
        final ctrl = TextEditingController(text: group.title);
        final next = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('重命名分组'),
            content: TextField(controller: ctrl),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: const Text('保存'),
              ),
            ],
          ),
        );
        ctrl.dispose();
        if (next != null && next.isNotEmpty) {
          await ShareCore.instance.groupCrud('update', {'list_id': group.gid, 'name': next});
          await _load();
        }
      } else if (action == 'delete') {
        await ShareCore.instance.groupCrud('destroy', {'list_id': group.gid});
        await _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }
}
