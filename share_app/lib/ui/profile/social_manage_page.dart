import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/models.dart';
import '../../core/share_core.dart';
import '../app_theme.dart';
import 'user_page.dart';

/// 1:1 复刻 `EditProfileActivity`（编辑昵称 / 简介 / 性别 / 更换头像）。
class EditProfilePage extends StatefulWidget {
  final User user;

  const EditProfilePage({super.key, required this.user});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _bioCtrl;
  late String _gender;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.user.name);
    _bioCtrl = TextEditingController(text: widget.user.description);
    _gender = widget.user.gender == 'f' ? 'f' : 'm';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _bioCtrl.dispose();
    super.dispose();
  }

  Future<void> _changeAvatar() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return;
    setState(() => _saving = true);
    try {
      final bytes = await file.readAsBytes();
      await ShareCore.instance.uploadAvatar(bytes, file.name);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('头像已上传更新')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('头像上传失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ShareCore.instance.profileEdit({
        'screen_name': _nameCtrl.text.trim(),
        'description': _bioCtrl.text.trim(),
        'gender': _gender,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('个人资料已保存')));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑资料'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中…' : '保存',
                style: TextStyle(color: ShareColors.accent, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: Column(
              children: [
                CircleAvatar(
                  radius: 36,
                  backgroundColor: ShareColors.placeholder,
                  backgroundImage:
                      widget.user.avatar.isNotEmpty ? NetworkImage(widget.user.avatar) : null,
                ),
                TextButton(
                  onPressed: _saving ? null : _changeAvatar,
                  child: const Text('更换头像'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: '昵称',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: _gender,
            decoration: const InputDecoration(
              labelText: '性别',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'm', child: Text('男')),
              DropdownMenuItem(value: 'f', child: Text('女')),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _gender = v);
            },
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _bioCtrl,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '简介',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// 1:1 复刻 `MyFriendActivity`（好友 / 关注与粉丝关系管理 + 修改备注 / 移除粉丝 / 拉黑）。
class MyFriendPage extends StatefulWidget {
  final String uid;
  final bool showFollowers;

  const MyFriendPage({
    super.key,
    required this.uid,
    this.showFollowers = false,
  });

  @override
  State<MyFriendPage> createState() => _MyFriendPageState();
}

class _MyFriendPageState extends State<MyFriendPage> {
  final List<User> _users = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  int _cursor = -1;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<User> _parseUsers(Map<String, dynamic> res) {
    final out = <User>[];
    final seen = <String>{};
    final raw = (res['users'] as List?) ??
        (res['data'] is Map ? (res['data'] as Map)['users'] as List? : null) ??
        const [];
    for (final item in raw.whereType<Map<String, dynamic>>()) {
      final userMap = item['user'] is Map<String, dynamic>
          ? item['user'] as Map<String, dynamic>
          : item;
      final u = User.fromJson(userMap);
      if (u.id.isNotEmpty && seen.add(u.id)) out.add(u);
    }
    return out;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _page = 1;
      _cursor = -1;
    });
    try {
      final raw = await ShareCore.instance.friendsListDual(
        widget.uid,
        page: 1,
        cursor: -1,
        count: 50,
        followers: widget.showFollowers,
      );
      final res = decodeObject(raw);
      final parsed = _parseUsers(res);
      final nextCursorRaw = res['next_cursor'] ?? res['next_cursor_str'];
      final nextCursor = int.tryParse('${nextCursorRaw ?? 0}') ?? 0;
      if (!mounted) return;
      setState(() {
        _users
          ..clear()
          ..addAll(parsed);
        _page = 1;
        _cursor = nextCursor;
        _hasMore = nextCursor > 0 || (widget.showFollowers && parsed.length >= 20);
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

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    setState(() => _loadingMore = true);
    try {
      final nextPage = _page + 1;
      final raw = await ShareCore.instance.friendsListDual(
        widget.uid,
        page: nextPage,
        cursor: _cursor > 0 ? _cursor : -1,
        count: 50,
        followers: widget.showFollowers,
      );
      final res = decodeObject(raw);
      final parsed = _parseUsers(res);
      final nextCursorRaw = res['next_cursor'] ?? res['next_cursor_str'];
      final nextCursor = int.tryParse('${nextCursorRaw ?? 0}') ?? 0;
      final existingIds = _users.map((u) => u.id).toSet();
      final fresh = parsed.where((u) => !existingIds.contains(u.id)).toList();
      if (!mounted) return;
      setState(() {
        _users.addAll(fresh);
        _page = nextPage;
        _cursor = nextCursor;
        _hasMore = fresh.isNotEmpty &&
            (nextCursor > 0 || (widget.showFollowers && parsed.length >= 20));
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _hasMore = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _manageUser(User u) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(u.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: const Text('修改备注'),
              onTap: () => Navigator.pop(ctx, 'remark'),
            ),
            if (widget.showFollowers)
              ListTile(
                leading: const Icon(Icons.person_remove_outlined),
                title: const Text('移除该粉丝'),
                onTap: () => Navigator.pop(ctx, 'remove_follower'),
              ),
            ListTile(
              leading: const Icon(Icons.block),
              title: const Text('加入黑名单'),
              onTap: () => Navigator.pop(ctx, 'block'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    try {
      if (action == 'remark') {
        final ctrl = TextEditingController(text: u.remark ?? '');
        final next = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('修改备注'),
            content: TextField(controller: ctrl),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: const Text('确定'),
              ),
            ],
          ),
        );
        ctrl.dispose();
        if (next != null) {
          await ShareCore.instance.updateRemark(u.id, next);
          await _load();
        }
      } else if (action == 'remove_follower') {
        await ShareCore.instance.removeFollower(u.id);
        await _load();
      } else if (action == 'block') {
        await ShareCore.instance.blockUser(u.id, block: true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已将 ${u.displayName} 加入黑名单')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.showFollowers ? '粉丝列表' : '我的关注')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : (_error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 10),
                        OutlinedButton(onPressed: _load, child: const Text('重试')),
                      ],
                    ),
                  ),
                )
              : (_users.isEmpty
                  ? RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          SizedBox(height: MediaQuery.sizeOf(context).height * 0.3),
                          Center(
                            child: Text(
                              widget.showFollowers ? '暂无粉丝' : '暂无关注账号',
                              style: TextStyle(color: ShareColors.textHint),
                            ),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: _users.length + (_hasMore ? 1 : 0),
                        separatorBuilder: (_, _) =>
                            Divider(height: 0.5, color: ShareColors.divider),
                        itemBuilder: (_, i) {
                          if (i >= _users.length) {
                            if (!_loadingMore) {
                              WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
                            }
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: Center(
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            );
                          }
                          final u = _users[i];
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: ShareColors.placeholder,
                              backgroundImage:
                                  u.avatar.isNotEmpty ? NetworkImage(u.avatar) : null,
                            ),
                            title: Text(u.displayName),
                            subtitle: Text(
                              u.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.more_horiz),
                              onPressed: () => _manageUser(u),
                            ),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => UserPage(
                                  uid: u.id,
                                  initialName: u.name,
                                  initialAvatar: u.avatar,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ))),
    );
  }
}
