import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/settings.dart';
import '../../core/dm.dart';
import '../../core/session.dart';
import '../app_theme.dart';
import '../common/in_app_web_page.dart';

/// 私信 / 群聊对话 — the original `DirectMessageChatActivity`.
///
/// 1-on-1 DMs and joined group chats route through dual transport (mobile API
/// + WebIM groupchat). Any server refusal is shown verbatim instead of empty.
class DmChatPage extends ConsumerStatefulWidget {
  final String uid;
  final String peerName;
  final String peerAvatar;
  final bool isGroup;

  const DmChatPage({
    super.key,
    required this.uid,
    required this.peerName,
    required this.peerAvatar,
    this.isGroup = false,
  });

  @override
  ConsumerState<DmChatPage> createState() => _DmChatPageState();
}

class _DmChatPageState extends ConsumerState<DmChatPage> {
  final List<DmMessage> _messages = [];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();

  bool _loading = true;
  bool _sending = false;
  bool _hasMore = false;
  bool _loadingMore = false;
  String? _error;

  String get _myUid => ref.read(sessionProvider).account?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final history = await WeiboApi.instance.dmHistory(
        widget.uid,
        myUid: _myUid,
        isGroup: widget.isGroup,
      );
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(history.items);
        _hasMore = history.hasMore;
        _loading = false;
      });
      _jumpToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _humanize(e);
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _messages.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final oldest = _messages.first.id;
      final history = await WeiboApi.instance.dmHistory(
        widget.uid,
        myUid: _myUid,
        maxId: oldest,
        isGroup: widget.isGroup,
      );
      if (!mounted) return;
      final known = _messages.map((m) => m.id).toSet();
      final fresh = history.items.where((m) => !known.contains(m.id)).toList();
      setState(() {
        _messages.insertAll(0, fresh);
        _hasMore = history.hasMore && fresh.isNotEmpty;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _hasMore = false;
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;

    final optimistic = DmMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      text: text,
      timeMs: DateTime.now().millisecondsSinceEpoch,
      senderId: _myUid,
      fromMe: true,
    );

    setState(() {
      _sending = true;
      _messages.add(optimistic);
      _input.clear();
    });
    _jumpToBottom();

    try {
      final sent = await WeiboApi.instance.dmSend(
        widget.uid,
        text,
        myUid: _myUid,
        isGroup: widget.isGroup,
      );
      if (!mounted) return;
      setState(() {
        final index = _messages.indexWhere((m) => m.id == optimistic.id);
        if (index >= 0) {
          // The server copy may omit fields our optimistic one filled in.
          _messages[index] = DmMessage(
            id: sent.id.isEmpty ? optimistic.id : sent.id,
            text: sent.text.isEmpty ? text : sent.text,
            timeMs: sent.timeMs == 0 ? optimistic.timeMs : sent.timeMs,
            senderId: sent.senderId,
            senderName: sent.senderName,
            senderAvatar: sent.senderAvatar,
            fromMe: true,
          );
        }
        _sending = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.removeWhere((m) => m.id == optimistic.id);
        _sending = false;
        _input.text = text;
      });
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(SnackBar(content: Text('发送失败：${_humanize(e)}')));
    }
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ShareColors.pageBg,
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: 28,
                height: 28,
                child: widget.peerAvatar.isNotEmpty
                    ? Image.network(
                        widget.peerAvatar,
                        fit: BoxFit.cover,
                        cacheWidth: 90,
                    errorBuilder: (_, _, _) => ColoredBox(
                          color: ShareColors.placeholder,
                          child: Icon(
                            widget.isGroup ? Icons.group : Icons.person,
                            size: 15,
                            color: ShareColors.textHint,
                          ),
                        ),
                      )
                    : ColoredBox(
                        color: ShareColors.placeholder,
                        child: Icon(
                          widget.isGroup ? Icons.group : Icons.person,
                          size: 15,
                          color: ShareColors.textHint,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 8),
            if (widget.isGroup) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: ShareColors.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  '群',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: ShareColors.accent,
                  ),
                ),
              ),
            ],
            Flexible(
              child: Text(
                widget.peerName.isEmpty
                    ? (widget.isGroup ? '群聊' : '私信')
                    : widget.peerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: '刷新消息',
            onPressed: _load,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _body()),
          _inputBar(),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null) {
      return RefreshIndicator(
        color: ShareColors.accent,
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 80),
            Icon(Icons.cloud_off, size: 42, color: ShareColors.textHint),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: ShareColors.textSecondary, height: 1.5),
              ),
            ),
            const SizedBox(height: 12),
            Center(child: TextButton(onPressed: _load, child: const Text('重试'))),
            Center(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const InAppWebPage(
                      url: 'https://api.weibo.com/chat',
                      title: '私信',
                    ),
                  ),
                ),
                child: const Text('在网页版私信中打开'),
              ),
            ),
          ],
        ),
      );
    }

    if (_messages.isEmpty) {
      return RefreshIndicator(
        color: ShareColors.accent,
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 100),
            Icon(
              widget.isGroup ? Icons.forum_outlined : Icons.chat_bubble_outline,
              size: 42,
              color: ShareColors.textHint,
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                widget.isGroup
                    ? '暂无群聊消息，下拉可刷新。\n若该群消息未同步，可在网页版私信查看。'
                    : '暂无消息，下拉可刷新。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: ShareColors.textSecondary, height: 1.5),
              ),
            ),
            const SizedBox(height: 12),
            Center(child: TextButton(onPressed: _load, child: const Text('刷新'))),
          ],
        ),
      );
    }

    return RefreshIndicator(
      color: ShareColors.accent,
      onRefresh: _load,
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        itemCount: _messages.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (_hasMore && index == 0) {
            return Center(
              child: TextButton(
                onPressed: _loadingMore ? null : _loadMore,
                child: Text(
                  _loadingMore ? '加载中…' : '查看更早的消息',
                  style: TextStyle(fontSize: 12, color: ShareColors.textSecondary),
                ),
              ),
            );
          }
          final message = _messages[index - (_hasMore ? 1 : 0)];
          return _bubble(message);
        },
      ),
    );
  }

  Widget _bubble(DmMessage message) {
    final mine = message.fromMe;
    final avatarUrl = widget.isGroup ? message.senderAvatar : widget.peerAvatar;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 32,
                height: 32,
                child: avatarUrl.isNotEmpty
                    ? Image.network(
                        avatarUrl,
                        fit: BoxFit.cover,
                        cacheWidth: 100,
                        errorBuilder: (_, _, _) => ColoredBox(
                          color: ShareColors.placeholder,
                          child: Icon(Icons.person, size: 16, color: ShareColors.textHint),
                        ),
                      )
                    : ColoredBox(
                        color: ShareColors.placeholder,
                        child: Icon(Icons.person, size: 16, color: ShareColors.textHint),
                      ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (widget.isGroup && !mine && message.senderName.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 2, bottom: 3),
                    child: Text(
                      message.senderName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: ShareColors.textSecondary,
                      ),
                    ),
                  ),
                ],
                Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.sizeOf(context).width * 0.68,
                  ),
                  padding: const EdgeInsets.fromLTRB(11, 8, 11, 8),
                  decoration: BoxDecoration(
                    color: mine ? ShareColors.accent : ShareColors.cardBg,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(6),
                      topRight: const Radius.circular(6),
                      bottomLeft: Radius.circular(mine ? 6 : 2),
                      bottomRight: Radius.circular(mine ? 2 : 6),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        message.text,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.35,
                          color: mine ? Colors.white : ShareColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        formatDmClock(message.timeMs),
                        style: TextStyle(
                          fontSize: 10,
                          color: mine ? Colors.white70 : ShareColors.textHint,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (mine) const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _inputBar() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: ShareColors.cardBg,
          border: Border(top: BorderSide(color: ShareColors.divider, width: 0.6)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: ShareColors.inputBg,
                  borderRadius: BorderRadius.circular(18),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: ref.read(settingsProvider).dmEnterToSend
                      ? TextInputAction.send
                      : TextInputAction.newline,
                  onSubmitted:
                      ref.read(settingsProvider).dmEnterToSend ? (_) => _send() : null,
                  style: TextStyle(fontSize: 15, color: ShareColors.textPrimary),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    hintText: '发消息…',
                    hintStyle: TextStyle(fontSize: 15, color: ShareColors.textHint),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _sending ? null : _send,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _sending ? ShareColors.placeholder : ShareColors.accent,
                  shape: BoxShape.circle,
                ),
                child: _sending
                    ? Padding(
                        padding: const EdgeInsets.all(10),
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: ShareColors.textHint,
                        ),
                      )
                    : const Icon(Icons.send, size: 17, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
