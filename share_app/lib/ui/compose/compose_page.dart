import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api.dart';
import '../../core/settings.dart';
import '../../core/drafts.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/share_core.dart';
import '../../src/rust/api/share_api.dart' show FollowerDto;
import '../app_theme.dart';
import '../settings/pref_page.dart';
import 'compose_options_sheet.dart';
import 'emoji_panel.dart';
import 'watermark.dart';

/// A picture chosen from the gallery, before it is uploaded.
class _PickedImage {
  final Uint8List? bytes;
  final String? networkUrl;
  final String name;
  final String mime;

  /// Weibo's `pid`, filled in once the upload succeeds or from existing status pic.
  String? pid;

  _PickedImage({
    this.bytes,
    this.networkUrl,
    required this.name,
    required this.mime,
    this.pid,
  });
}

class ComposePage extends ConsumerStatefulWidget {
  /// Content of the draft being edited, when opened from 草稿箱.
  final String? initialText;

  /// Draft id to update / delete on the way out.
  final String? draftId;

  /// Existing post to edit in full Share composer mode (`statuses/modify_weibo`).
  final Status? editStatus;

  const ComposePage({
    super.key,
    this.initialText,
    this.draftId,
    this.editStatus,
  });

  @override
  ConsumerState<ComposePage> createState() => _ComposePageState();
}

class _ComposePageState extends ConsumerState<ComposePage> {
  static const _maxImages = 9;

  late final TextEditingController _controller;
  final ImagePicker _picker = ImagePicker();
  final List<_PickedImage> _images = [];

  bool _sending = false;
  String? _draftId;
  String _progress = '';

  /// 公开范围（微博 `visible`）：0 公开 / 2 好友圈 / 1 仅自己可见。
  int _visible = 0;

  /// 发送选项里的本地开关（水印、尾巴）。默认都关，与原版一致。
  ComposeOptions _options = const ComposeOptions();

  // @ 联想
  Timer? _mentionDebounce;
  List<User> _mentionUsers = const [];
  String _mentionQuery = '';
  int _mentionStart = -1;

  bool get _isEditing => widget.editStatus != null;

  @override
  void initState() {
    super.initState();
    final edit = widget.editStatus;
    final initial = edit != null ? _initialEditText(edit.textRaw) : (widget.initialText ?? '');
    _controller = TextEditingController(text: initial);
    _draftId = widget.draftId;
    if (edit != null) {
      _visible = const {0, 1, 2}.contains(edit.visible) ? edit.visible : 0;
      for (final pic in edit.pics.take(_maxImages)) {
        final pid = pic.pid ?? Pic.extractPid(pic.large ?? pic.url);
        _images.add(_PickedImage(
          networkUrl: pic.url,
          name: pid ?? 'image.jpg',
          mime: 'image/jpeg',
          pid: pid,
        ));
      }
      _options = const ComposeOptions();
      if (edit.isLongText &&
          (edit.textRaw.contains('...全文') || edit.textRaw.endsWith('...'))) {
        unawaited(_loadEditLongText(edit, initial));
      }
    } else {
      _options = ComposeOptions(
        tail: ref.read(settingsProvider).publishTail.isNotEmpty,
      );
    }
    _controller.addListener(_onTextChanged);
  }

  static String _initialEditText(String raw) {
    return raw.replaceFirst(RegExp(r'\s*\.\.\.\s*全文$'), '').trimRight();
  }

  Future<void> _loadEditLongText(Status edit, String seededText) async {
    try {
      final fullHtml = await WeiboApi.instance.longText(edit.id);
      if (!mounted || fullHtml.isEmpty) return;
      final fullPlain = RichTextParser.toPlain(fullHtml).trim();
      if (fullPlain.isNotEmpty && _controller.text == seededText) {
        _controller.value = TextEditingValue(
          text: fullPlain,
          selection: TextSelection.collapsed(offset: fullPlain.length),
        );
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _mentionDebounce?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    setState(() {});
    _detectMention();
  }

  /// 找到光标前最近的一个 `@`，取出昵称片段去联想。
  ///
  /// 只认「`@` 前面不是字母/数字/@」的情况，避免把邮箱、连续 @ 误判成提及。
  void _detectMention() {
    final text = _controller.text;
    final selection = _controller.selection;
    final caret = selection.isValid ? selection.baseOffset : text.length;
    if (caret <= 0 || caret > text.length) return _clearMention();

    final at = text.lastIndexOf('@', caret - 1);
    if (at < 0 || caret - at > 24) return _clearMention();
    if (at > 0 && RegExp(r'[A-Za-z0-9_@]').hasMatch(text[at - 1])) return _clearMention();

    final query = text.substring(at + 1, caret);
    if (query.contains(RegExp(r'\s')) || query.contains('@')) return _clearMention();
    if (query.isEmpty) return _clearMention();

    _mentionStart = at;
    if (query == _mentionQuery) return;
    _mentionQuery = query;

    _mentionDebounce?.cancel();
    _mentionDebounce = Timer(const Duration(milliseconds: 220), () async {
      final uid = ref.read(sessionProvider).account?.uid ?? '';
      try {
        List<FollowerDto> cached = const [];
        try {
          cached = await ShareCore.instance.followersSearch(uid, query: query, limit: 6);
        } catch (_) {}
        final mappedCached = cached
            .map((f) => User(id: f.tid, name: f.name, avatar: f.avatar, verified: f.verified))
            .toList();
        if (mounted && _mentionQuery == query && mappedCached.isNotEmpty) {
          setState(() => _mentionUsers = mappedCached);
        }
        final result = await WeiboApi.instance.searchUsers(query);
        if (!mounted || _mentionQuery != query) return;
        final candidates = result.mentionCandidates.take(6).toList();
        if (candidates.isNotEmpty) {
          setState(() => _mentionUsers = candidates);
        }
      } catch (_) {
        if (!mounted) return;
      }
    });
  }

  void _clearMention() {
    if (_mentionUsers.isEmpty && _mentionQuery.isEmpty && _mentionStart < 0) return;
    _mentionDebounce?.cancel();
    if (!mounted) {
      _mentionUsers = const [];
      _mentionQuery = '';
      _mentionStart = -1;
      return;
    }
    setState(() {
      _mentionUsers = const [];
      _mentionQuery = '';
      _mentionStart = -1;
    });
  }

  /// 把 `@片段` 整体替换成 `@昵称 `。
  void _pickMention(String name) {
    final text = _controller.text;
    final selection = _controller.selection;
    final caret = selection.isValid ? selection.baseOffset : text.length;
    final start = _mentionStart < 0 ? caret : _mentionStart;
    final next = text.replaceRange(start, caret, '@$name ');
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + name.length + 2),
    );
    _clearMention();
  }

  Future<void> _pickImages() async {
    if (_images.length >= _maxImages) {
      _toast('最多只能选 $_maxImages 张图片');
      return;
    }
    try {
      // 图片上传的默认质量: 1 压缩 / 2 原图 / 3 自动
      final picked = await _picker.pickMultiImage(
        imageQuality: ref.read(settingsProvider).uploadCompression,
      );
      if (picked.isEmpty) return;
      final room = _maxImages - _images.length;
      for (final file in picked.take(room)) {
        final bytes = await file.readAsBytes();
        _images.add(_PickedImage(
          bytes: bytes,
          name: file.name.isEmpty ? 'image.jpg' : file.name,
          mime: _mimeOf(file.name),
        ));
      }
      if (picked.length > room) {
        _toast('最多只能选 $_maxImages 张，已忽略多余的 ${picked.length - room} 张');
      }
      if (mounted) setState(() {});
    } catch (e) {
      _toast('选择图片失败：$e');
    }
  }

  String _mimeOf(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    return 'image/jpeg';
  }

  /// 水印文字：昵称 + Share。未登录（理论上发不出去）时只留品牌名，不编假昵称。
  String get _watermarkText {
    final name = (ref.read(sessionProvider).account?.screenName ?? '').trim();
    return name.isEmpty ? 'Share' : '$name · Share';
  }

  /// 合成后一定是 PNG，扩展名跟着改，避免服务端按后缀校验格式失败。
  String _asPngName(String name) {
    final dot = name.lastIndexOf('.');
    return '${dot > 0 ? name.substring(0, dot) : name}.png';
  }

  Future<void> _openOptions() async {
    if (_sending) return;
    FocusScope.of(context).unfocus();
    final result = await showComposeOptionsSheet(context, initial: _options);
    if (!mounted || result == null) return;
    setState(() {
      _options = result;
      // 已上传的 pid 绑定的是"上一次上传的那串字节 / 那个账号"，选项一改就不再成立，
      // 直接作废，下次发送重新上传，避免水印被跳过或拿旧账号的 pid 发布；
      // 但编辑原微博保留的线上图片不重置 pid。
      for (final image in _images) {
        if (image.bytes != null) {
          image.pid = null;
        }
      }
    });
  }

  Future<void> _pickVisible() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: ShareColors.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            for (final option in _visibilityOptions)
              ListTile(
                dense: true,
                leading: Icon(option.icon, size: 20, color: ShareColors.textSecondary),
                title: Text(option.label,
                    style: TextStyle(fontSize: 14.5, color: ShareColors.textPrimary)),
                trailing: option.value == _visible
                    ? Icon(Icons.check, size: 18, color: ShareColors.accent)
                    : null,
                onTap: () => Navigator.of(ctx).pop(option.value),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || picked == null) return;
    setState(() => _visible = picked);
  }

  /// 原版九宫格的拖拽重排：长按拿起 → 落到另一格就互换。
  ///
  /// 用交换而不是"插入"是有意的：用户看到的是"把这张挪到那个位置"，
  /// 交换的位移最小，撤销成本也最低；顺序即上传顺序，所以列表一改就生效。
  void _swapImages(int from, int to) {
    if (from == to || from < 0 || to < 0) return;
    if (from >= _images.length || to >= _images.length) return;
    setState(() {
      final moving = _images[from];
      _images[from] = _images[to];
      _images[to] = moving;
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if ((text.isEmpty && _images.isEmpty) || _sending) return;
    if (!ref.read(sessionProvider).isLoggedIn) {
      _toast('请先登录后再发布');
      return;
    }

    setState(() {
      _sending = true;
      final needUpload = _images.where((e) => e.pid == null && e.bytes != null).length;
      _progress = needUpload == 0 ? '' : '上传图片 0/$needUpload';
    });

    try {
      // Upload any newly added local picture that does not have a pid yet.
      final pids = <String>[];
      final toUploadCount = _images.where((e) => e.pid == null && e.bytes != null).length;
      var uploadedIdx = 0;
      for (var i = 0; i < _images.length; i++) {
        final image = _images[i];
        if (image.pid == null && image.bytes != null) {
          uploadedIdx++;
          if (mounted) {
            setState(() => _progress = '上传图片 $uploadedIdx/$toUploadCount');
          }

          var bytes = image.bytes!;
          var name = image.name;
          var mime = image.mime;
          if (_options.watermark) {
            if (mounted) {
              setState(() => _progress = '合成水印 $uploadedIdx/$toUploadCount');
            }
            final marked = await applyWatermark(bytes, text: _watermarkText);
            // 合成失败时 applyWatermark 原样返回同一个实例，此时按原始字节上传，
            // 不能把 jpeg 标成 png，微博侧会拒收。
            if (!identical(marked, bytes)) {
              bytes = marked;
              name = _asPngName(name);
              mime = sniffImageMime(marked) ?? 'image/png';
            }
          }

          image.pid = await WeiboApi.instance.uploadPicture(bytes, name, mime);
        }
        final pid = image.pid;
        if (pid != null && pid.isNotEmpty) {
          pids.add(pid);
        }
      }

      if (_isEditing) {
        if (mounted) setState(() => _progress = '保存中…');
        await ShareCore.instance.statusModify(
          widget.editStatus!.id,
          text,
          picIds: pids.isEmpty ? null : pids.join(','),
          visible: _visible,
        );
      } else {
        if (mounted) setState(() => _progress = '发布中…');
        final tail = _options.tail ? ref.read(settingsProvider).publishTail : '';
        await WeiboApi.instance.publish(
          text,
          visible: _visible,
          picIds: pids.join(','),
          tail: tail,
        );
        final draftId = _draftId;
        if (draftId != null && draftId.isNotEmpty) {
          await DraftStore.remove(draftId);
        }
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _progress = '';
      });
      _toast(_humanize(e));
    }
  }

  Future<void> _saveDraft() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      _toast('内容为空，无需存草稿');
      return;
    }
    if (_images.isNotEmpty) {
      // Drafts are text-only, exactly like the original local draft box.
      _toast('草稿只保存文字，图片需要重新选择');
    }
    _draftId = await DraftStore.save(id: _draftId, text: _controller.text);
    if (!mounted) return;
    _toast('已存入草稿箱');
  }

  /// Leaving with unsaved content silently keeps it, so nothing is ever lost.
  Future<void> _close() async {
    if (_sending) return;
    if (!_isEditing) {
      final text = _controller.text.trim();
      if (text.isNotEmpty) {
        _draftId = await DraftStore.save(id: _draftId, text: _controller.text);
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _openEmoji() async {
    FocusScope.of(context).unfocus();
    await showEmojiPanel(context, _insert);
  }

  void _insert(String token) {
    final selection = _controller.selection;
    final text = _controller.text;
    final start = selection.start < 0 ? text.length : selection.start;
    final end = selection.end < 0 ? text.length : selection.end;
    final next = text.replaceRange(start, end, token);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + token.length),
    );
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
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

  bool get _canSend => _controller.text.trim().isNotEmpty || _images.isNotEmpty;

  _VisibilityOption get _currentVisibility => _visibilityOptions.firstWhere(
        (option) => option.value == _visible,
        orElse: () => _visibilityOptions.first,
      );

  @override
  Widget build(BuildContext context) {
    final length = _controller.text.length;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: ShareColors.cardBg,
        appBar: AppBar(
          title: Text(_progress.isEmpty ? (_isEditing ? '编辑微博' : '发微博') : _progress),
          leading: TextButton(
            onPressed: _sending ? null : _close,
            child: Text('取消', style: TextStyle(color: ShareColors.textSecondary)),
          ),
          leadingWidth: 64,
          actions: [
            IconButton(
              onPressed: _sending ? null : _openOptions,
              icon: const Icon(Icons.more_horiz, size: 22),
              tooltip: _isEditing ? '图片选项' : '发送选项',
            ),
            if (!_isEditing)
              TextButton(
                onPressed: _sending ? null : _saveDraft,
                child: Text(
                  '存草稿',
                  style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              child: FilledButton(
                onPressed: (!_canSend || _sending) ? null : _send,
                style: FilledButton.styleFrom(
                  backgroundColor: ShareColors.accent,
                  minimumSize: const Size(64, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                child: _sending
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Text(_isEditing ? '保存' : '发送', style: const TextStyle(fontSize: 14)),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: TextField(
                  controller: _controller,
                  maxLines: null,
                  expands: true,
                  maxLength: 2000,
                  textAlignVertical: TextAlignVertical.top,
                  autofocus: !_isEditing && (widget.initialText ?? '').isEmpty && _images.isEmpty,
                  style: const TextStyle(fontSize: 16, height: 1.5),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    counterText: '',
                    hintText: _isEditing ? '编辑微博正文…' : '分享新鲜事…',
                    hintStyle: TextStyle(fontSize: 16, color: ShareColors.textHint),
                  ),
                ),
              ),
            ),
            if (_isEditing && widget.editStatus?.retweeted != null)
              _retweetPreview(widget.editStatus!.retweeted!),
            if (_images.isNotEmpty) _imageGrid(),
            if (_mentionUsers.isNotEmpty) _mentionStrip(),
            if (!_isEditing &&
                (_options.tail || ref.watch(settingsProvider).publishTail.isNotEmpty))
              _tailHint(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: ShareColors.divider, width: 0.5)),
              ),
              child: Row(
                children: [
                  _tool(Icons.image_outlined, '添加图片', onTap: _pickImages),
                  const SizedBox(width: 16),
                  _tool(Icons.emoji_emotions_outlined, '表情', onTap: _openEmoji),
                  const SizedBox(width: 16),
                  _tool(Icons.alternate_email, '插入 @', onTap: () => _insert('@')),
                  const SizedBox(width: 16),
                  _tool(Icons.tag, '插入 #话题#', onTap: () => _insert('##')),
                  const SizedBox(width: 16),
                  _tool(Icons.location_on_outlined, '附近地点', onTap: _pickPoi),
                  const SizedBox(width: 8),
                  // 右侧这组整体右对齐；窄屏（<360dp）时等比缩小，
                  // 而不是把「仅自己可见」截断或让整行溢出。
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _visibilityPill(),
                            const SizedBox(width: 8),
                            Text('$length/2000',
                                style: TextStyle(
                                    fontSize: 12, color: ShareColors.textHint)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SafeArea(top: false, child: SizedBox(height: 4)),
          ],
        ),
      ),
    );
  }

  /// 尾巴指示条：展示当前选择的客户端来源（支持点击直接切换）。
  Widget _tailHint() {
    final settings = ref.watch(settingsProvider);
    final label = AppSettings.formatPublishTailLabel(settings.publishTail);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: GestureDetector(
        onTap: () async {
          final next = await showPublishTailPicker(context, settings.publishTail);
          if (next != null && mounted) {
            ref.read(settingsProvider.notifier).setPref('publish_source', next);
            setState(() => _options = _options.copyWith(tail: next.isNotEmpty));
          }
        },
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Icon(Icons.link, size: 12, color: ShareColors.link),
            const SizedBox(width: 4),
            Text(
              '微博尾巴：$label（点击切换）',
              style: TextStyle(fontSize: 11.5, color: ShareColors.link),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mentionStrip() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 168),
      decoration: BoxDecoration(
        color: ShareColors.cardBg,
        border: Border(top: BorderSide(color: ShareColors.divider, width: 0.5)),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: _mentionUsers.length,
        separatorBuilder: (_, _) => Divider(
            height: 0.5, thickness: 0.5, color: ShareColors.divider, indent: 52),
        itemBuilder: (context, index) {
          final user = _mentionUsers[index];
          final name = user.name;
          final avatar = user.avatar;
          return ListTile(
            dense: true,
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 32,
                height: 32,
                child: avatar.isEmpty
                    ? ColoredBox(color: ShareColors.placeholder)
                    : Image.network(
                        avatar,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            ColoredBox(color: ShareColors.placeholder),
                      ),
              ),
            ),
            title: Text(name, style: const TextStyle(fontSize: 14.5)),
            trailing: Text('@$name',
                style: TextStyle(fontSize: 12, color: ShareColors.textHint)),
            onTap: () => _pickMention(name),
          );
        },
      ),
    );
  }

  Future<void> _pickPoi() async {
    final qCtrl = TextEditingController();
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        List<dynamic> pois = const [];
        var loading = false;
        return StatefulBuilder(
          builder: (ctx, setLocal) => DraggableScrollableSheet(
            initialChildSize: 0.65,
            expand: false,
            builder: (_, sc) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    controller: qCtrl,
                    decoration: InputDecoration(
                      hintText: '搜索地点 POI…',
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.search),
                        onPressed: () async {
                          setLocal(() => loading = true);
                          try {
                            final res = await ShareCore.instance.nearbyPois(
                              39.9042,
                              116.4074,
                              q: qCtrl.text.trim(),
                            );
                            setLocal(() {
                              pois = (res['pois'] as List?) ?? const [];
                              loading = false;
                            });
                          } catch (_) {
                            setLocal(() => loading = false);
                          }
                        },
                      ),
                    ),
                  ),
                ),
                if (loading) const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: pois.isEmpty
                      ? const Center(child: Text('输入城市或地标点击搜索选择位置'))
                      : ListView.builder(
                          controller: sc,
                          itemCount: pois.length,
                          itemBuilder: (_, i) {
                            final p = pois[i] as Map? ?? const {};
                            final title = '${p['title'] ?? p['poi_street'] ?? ''}';
                            return ListTile(
                              leading: const Icon(Icons.place_outlined),
                              title: Text(title),
                              subtitle: Text('${p['poi_street'] ?? p['address'] ?? ''}'),
                              onTap: () => Navigator.pop(ctx, title),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
    qCtrl.dispose();
    if (picked != null && picked.isNotEmpty) {
      _insert(' 📍$picked ');
    }
  }

  /// 图片九宫格：一行 3 格，长按拖动可换位。
  ///
  /// 用 `Wrap` 而不是 `GridView`：格数最多 9 个，Wrap 的高度随内容走，
  /// 不会在正文区里抢一个固定可滚动区域，键盘弹起时也不会出现嵌套滚动。
  Widget _imageGrid() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 一行 3 格、格间距 6dp；封顶 108dp，免得平板上单张图铺满半屏。
          final cell = math.min((constraints.maxWidth - 12) / 3, 108.0);
          return Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < _images.length; i++) _gridTile(i, cell),
              if (_images.length < _maxImages) _addTile(cell),
            ],
          );
        },
      ),
    );
  }

  Widget _retweetPreview(Status rt) {
    final author = rt.user?.name.isNotEmpty == true ? '@${rt.user!.name}' : '原微博';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: ShareColors.inputBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ShareColors.divider, width: 0.5),
      ),
      child: Text(
        '$author: ${rt.textRaw}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary, height: 1.4),
      ),
    );
  }

  Widget _thumb(_PickedImage img, double cell) {
    final fallback = Container(
      width: cell,
      height: cell,
      color: ShareColors.placeholder,
      child: Icon(Icons.broken_image, color: ShareColors.textHint),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: img.bytes != null
          ? Image.memory(
              img.bytes!,
              width: cell,
              height: cell,
              fit: BoxFit.cover,
              cacheWidth: 300,
              errorBuilder: (_, _, _) => fallback,
            )
          : Image.network(
              img.networkUrl ?? '',
              width: cell,
              height: cell,
              fit: BoxFit.cover,
              cacheWidth: 300,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }

  Widget _gridTile(int index, double cell) {
    final image = _images[index];
    return DragTarget<int>(
      onWillAcceptWithDetails: (details) => details.data != index,
      onAcceptWithDetails: (details) => _swapImages(details.data, index),
      builder: (context, candidates, _) {
        final highlight = candidates.isNotEmpty;
        return LongPressDraggable<int>(
          data: index,
          // 发送中锁住拖动，避免把上传顺序改在半路上。
          maxSimultaneousDrags: _sending ? 0 : 1,
          feedback: Material(
            color: Colors.transparent,
            child: Transform.scale(
              // 轻微放大 + 阴影：明确"这张被拿起来了"，同时不遮住落点。
              scale: 1.06,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.28),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: _thumb(image, cell),
              ),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.25, child: _thumb(image, cell)),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                // 用 foregroundDecoration 画高亮边框：不改尺寸，拖动时格子不会抖。
                foregroundDecoration: highlight
                    ? BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: ShareColors.accent, width: 1.5),
                      )
                    : null,
                child: _thumb(image, cell),
              ),
              Positioned(
                top: -6,
                right: -6,
                child: GestureDetector(
                  onTap: _sending
                      ? null
                      : () => setState(() => _images.removeAt(index)),
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close, size: 13, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _addTile(double cell) {
    return InkWell(
      onTap: _pickImages,
      child: Container(
        width: cell,
        height: cell,
        decoration: BoxDecoration(
          color: ShareColors.inputBg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(Icons.add, size: 26, color: ShareColors.textHint),
      ),
    );
  }

  /// 底部工具栏右侧的可见范围胶囊：图标 + 文案 + 下拉箭头。
  Widget _visibilityPill() {
    final current = _currentVisibility;
    return InkWell(
      onTap: _sending ? null : _pickVisible,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 3, 2, 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ShareColors.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(current.icon, size: 13, color: ShareColors.textSecondary),
            const SizedBox(width: 4),
            Text(
              current.label,
              style: TextStyle(fontSize: 11.5, color: ShareColors.textSecondary),
            ),
            Icon(Icons.arrow_drop_down, size: 16, color: ShareColors.textHint),
          ],
        ),
      ),
    );
  }

  Widget _tool(IconData icon, String tooltip, {VoidCallback? onTap}) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap ?? () => _toast(tooltip),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(
            icon,
            size: 22,
            color: onTap == null ? ShareColors.textHint : ShareColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// 一条可见范围选项。
///
/// `value` 就是微博 `visible` 参数的真实取值，不做二次映射，
/// 避免哪天服务端语义变了还得在两处对表。
class _VisibilityOption {
  final int value;
  final String label;
  final IconData icon;

  const _VisibilityOption(this.value, this.label, this.icon);
}

/// 顺序照原版：公开 / 好友圈 / 仅自己可见。
const List<_VisibilityOption> _visibilityOptions = [
  _VisibilityOption(0, '公开', Icons.public),
  _VisibilityOption(2, '好友圈', Icons.group_outlined),
  _VisibilityOption(1, '仅自己可见', Icons.lock_outline),
];
