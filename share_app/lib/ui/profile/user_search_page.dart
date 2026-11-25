import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/user_search.dart';
import '../app_theme.dart';
import '../search/search_page.dart';
import 'user_page.dart';

/// 用户搜索 —— 原版 `UserSearchActivity`。
///
/// 走 `/ajax/side/search`，访客可用。除了模糊匹配的用户，服务端还会下发
/// 联想词（hotquery），这里把联想词做成「微博搜索」的快捷入口，避免浪费。
class UserSearchPage extends StatefulWidget {
  final String? initialKeyword;

  const UserSearchPage({super.key, this.initialKeyword});

  @override
  State<UserSearchPage> createState() => _UserSearchPageState();
}

class _UserSearchPageState extends State<UserSearchPage> {
  final TextEditingController _input = TextEditingController();
  UserSearchResult _result = UserSearchResult.empty;
  bool _loading = false;
  String? _error;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    final keyword = widget.initialKeyword?.trim() ?? '';
    if (keyword.isNotEmpty) {
      _input.text = keyword;
      _submit(keyword);
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _submit(String keyword) async {
    final query = keyword.trim();
    if (query.isEmpty) return;
    final id = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await WeiboApi.instance.searchUsers(query);
      if (!mounted || id != _requestId) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Container(
          height: 34,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            color: ShareColors.inputBg,
            borderRadius: BorderRadius.circular(17),
          ),
          child: TextField(
            controller: _input,
            autofocus: widget.initialKeyword == null,
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontSize: 14.5),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              prefixIcon: Icon(Icons.search, size: 18, color: ShareColors.textHint),
              prefixIconConstraints: const BoxConstraints(minWidth: 34),
              hintText: '搜索用户',
              hintStyle: TextStyle(fontSize: 14, color: ShareColors.placeholder),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
            ),
            onSubmitted: _submit,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => _submit(_input.text),
            child: Text('搜索', style: TextStyle(color: ShareColors.accent)),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(_error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
        ),
      );
    }

    final users = _result.mentionCandidates;
    final suggestions = _result.suggestions.take(8).toList();

    if (users.isEmpty && suggestions.isEmpty) {
      return Center(
        child: Text(
          _input.text.trim().isEmpty ? '输入昵称开始搜索' : '没有找到用户',
          style: TextStyle(fontSize: 13, color: ShareColors.textHint),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (users.isNotEmpty) ...[
          _caption('用户（${users.length}）'),
          Container(
            color: ShareColors.cardBg,
            child: Column(
              children: [
                for (var i = 0; i < users.length; i++) ...[
                  if (i > 0)
                    Divider(
                        height: 0.5,
                        thickness: 0.5,
                        color: ShareColors.divider,
                        indent: 68),
                  _userRow(users[i]),
                ],
              ],
            ),
          ),
        ],
        if (suggestions.isNotEmpty) ...[
          _caption('相关搜索'),
          Container(
            color: ShareColors.cardBg,
            child: Column(
              children: [
                for (final word in suggestions)
                  ListTile(
                    dense: true,
                    leading: Icon(Icons.search, size: 18, color: ShareColors.textHint),
                    title: Text(word, style: const TextStyle(fontSize: 14.5)),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => SearchPage(initialKeyword: word),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _caption(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(text, style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary)),
    );
  }

  Widget _userRow(User user) {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => UserPage(
            uid: user.id,
            initialName: user.name,
            initialAvatar: user.avatar,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: SizedBox(
                width: 44,
                height: 44,
                child: user.avatar.isEmpty
                    ? ColoredBox(color: ShareColors.placeholder)
                    : Image.network(
                        user.avatar,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            ColoredBox(color: ShareColors.placeholder),
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          user.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (user.verified) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.verified, size: 13, color: ShareColors.accent),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    user.description.isNotEmpty
                        ? user.description
                        : '粉丝 ${user.followers} · 微博 ${user.statuses}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: ShareColors.textSecondary),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 17, color: ShareColors.textHint),
          ],
        ),
      ),
    );
  }
}
