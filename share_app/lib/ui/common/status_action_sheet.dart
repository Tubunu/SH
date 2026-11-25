import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/settings.dart';
import '../../core/session.dart';
import '../app_theme.dart';
import '../compose/compose_page.dart';
import '../detail/edit_history_page.dart';
import '../detail/status_detail_page.dart';
import '../media/gallery_page.dart';
import 'in_app_web_page.dart';
import 'long_image_page.dart';
import 'share_actions.dart';
import 'text_boom_dialog.dart';
import '../../core/share_core.dart';

/// 微博卡片「更多」菜单 —— 逐条对齐原版 `res/menu/v.xml`。
///
/// 原版把「评论管理 / 编辑历史 / 编辑微博 / 置顶 / 分享范围 / 抽奖 / 删除」全部
/// 声明为 `android:visible="false"`，只有作者本人打开时才置为可见；
/// 「分享 / 在浏览器中打开 / 收藏 / 复制 / 屏蔽 / 投诉 / 生成长图 / 新鲜事投稿」
/// 对所有人可见。这里按同一规则生成条目。
Future<void> showStatusActionSheet(
  BuildContext context,
  WidgetRef ref,
  Status status, {
  VoidCallback? onChanged,
  VoidCallback? onDeleted,
}) async {
  final account = ref.read(sessionProvider).account;
  final myUid = account?.uid ?? '';
  final isMine = myUid.isNotEmpty && status.user?.id == myUid;

  var favorited = status.favorited;

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: ShareColors.cardBg,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) {
        Widget row(IconData icon, String label, VoidCallback onTap, {Color? color}) {
          return InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 48,
              child: Row(
                children: [
                  const SizedBox(width: 20),
                  Icon(icon, size: 19, color: color ?? ShareColors.textSecondary),
                  const SizedBox(width: 16),
                  Text(
                    label,
                    style: TextStyle(fontSize: 15, color: color ?? ShareColors.textPrimary),
                  ),
                ],
              ),
            ),
          );
        }

        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.72),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 6),
                  row(Icons.ios_share_rounded, '分享', () {
                    Navigator.pop(ctx);
                    ShareActions.shareStatus(context, status);
                  }),
                  row(Icons.open_in_browser_rounded, '在浏览器中打开', () {
                    Navigator.pop(ctx);
                    _openWeb(context, ShareActions.statusLink(status), '微博');
                  }),
                  row(
                    favorited ? Icons.star_rounded : Icons.star_border_rounded,
                    favorited ? '取消收藏' : '收藏',
                    () async {
                      Navigator.pop(ctx);
                      try {
                        await WeiboApi.instance.favorite(status.id, favorited);
                        if (context.mounted) {
                          _toast(context, favorited ? '已取消收藏' : '已收藏');
                        }
                        onChanged?.call();
                      } catch (e) {
                        if (context.mounted) _toast(context, _humanize(e));
                      }
                    },
                  ),
                  row(Icons.link_rounded, '复制', () {
                    Navigator.pop(ctx);
                    ShareActions.copyText(
                      context,
                      '${status.textRaw}\n${ShareActions.statusLink(status)}',
                      toast: '已复制',
                    );
                  }),
                  if (ref.read(settingsProvider).textBoom)
                    row(Icons.auto_awesome_mosaic_outlined, '文本大爆炸（分词）', () {
                      Navigator.pop(ctx);
                      TextBoomDialog.show(context, status.textRaw);
                    }),
                  row(Icons.visibility_off_outlined, '屏蔽', () {
                    Navigator.pop(ctx);
                    _showBlockSheet(context, ref, status);
                  }),
                  row(Icons.report_gmailerrorred_rounded, '投诉', () {
                    Navigator.pop(ctx);
                    _openWeb(
                      context,
                      'https://m.weibo.cn/detail/${status.mblogid}',
                      '投诉',
                    );
                    _toast(context, '已打开原博页面，可在右上角菜单投诉');
                  }),
                  row(Icons.image_outlined, '生成长图', () {
                    Navigator.pop(ctx);
                    _shareLongImage(context, status);
                  }),
                  if (status.pics.length == 1)
                    row(Icons.download_rounded, '保存原图到手机', () {
                      Navigator.pop(ctx);
                      ShareActions.saveImage(
                        context,
                        status.pics.first.large ?? status.pics.first.url,
                        original: true,
                        deduplicateName: ref.read(settingsProvider).samePhotoName,
                      );
                    }),
                  if (status.pics.length > 1) ...[
                    row(Icons.photo_library_outlined, '浏览并保存单张原图', () {
                      Navigator.pop(ctx);
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => GalleryPage(pics: status.pics),
                        ),
                      );
                    }),
                    row(
                      Icons.collections_bookmark_outlined,
                      '保存所有原图到手机 (${status.pics.length}张)',
                      () {
                        Navigator.pop(ctx);
                        ShareActions.saveImages(
                          context,
                          status.pics.map((p) => p.large ?? p.url).toList(),
                          original: true,
                          deduplicateName: ref.read(settingsProvider).samePhotoName,
                        );
                      },
                    ),
                  ],
                  if (status.retweeted != null)
                    row(Icons.repeat_rounded, '查看原微博', () {
                      Navigator.pop(ctx);
                      final original = status.retweeted!;
                      if (original.id.isNotEmpty || original.mblogid.isNotEmpty) {
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => StatusDetailPage(status: original),
                        ));
                      } else {
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => InAppWebPage(
                            url: ShareActions.statusLink(original),
                            title: '原微博',
                          ),
                        ));
                      }
                    }),
                  if (isMine) ...[
                    Divider(height: 8, thickness: 0.5, color: ShareColors.divider),
                    row(Icons.edit_outlined, '编辑微博', () async {
                      Navigator.pop(ctx);
                      final edited = await showTextInputDialog(
                        context,
                        title: '编辑微博',
                        initial: status.textRaw,
                        maxLines: 6,
                      );
                      if (edited == null || edited.trim().isEmpty) return;
                      try {
                        await ShareCore.instance.statusModify(status.id, edited.trim());
                        if (context.mounted) _toast(context, '已保存修改');
                        onChanged?.call();
                      } catch (_) {
                        if (context.mounted) {
                          _toast(context, '移动编辑受限时已为您填入发布页重发');
                          Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => ComposePage(initialText: edited),
                          ));
                        }
                      }
                    }),
                    row(Icons.vertical_align_top, '设为个人主页置顶', () async {
                      Navigator.pop(ctx);
                      try {
                        await ShareCore.instance.statusSetTop(status.id, isTop: true);
                        if (context.mounted) _toast(context, '已置顶');
                        onChanged?.call();
                      } catch (e) {
                        if (context.mounted) _toast(context, _humanize(e));
                      }
                    }),
                    row(Icons.lock_outline, '修改可见范围', () async {
                      Navigator.pop(ctx);
                      final picked = await showDialog<int>(
                        context: context,
                        builder: (dctx) => SimpleDialog(
                          title: const Text('可见范围'),
                          children: [
                            SimpleDialogOption(
                              onPressed: () => Navigator.pop(dctx, 0),
                              child: const Text('公开'),
                            ),
                            SimpleDialogOption(
                              onPressed: () => Navigator.pop(dctx, 2),
                              child: const Text('好友圈'),
                            ),
                            SimpleDialogOption(
                              onPressed: () => Navigator.pop(dctx, 1),
                              child: const Text('仅自己可见'),
                            ),
                          ],
                        ),
                      );
                      if (picked == null) return;
                      try {
                        await ShareCore.instance.statusModifyVisible(status.id, picked);
                        if (context.mounted) _toast(context, '已更新可见范围');
                        onChanged?.call();
                      } catch (e) {
                        if (context.mounted) _toast(context, _humanize(e));
                      }
                    }),
                    row(Icons.history_rounded, '编辑历史', () {
                      Navigator.pop(ctx);
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => EditHistoryPage(status: status),
                      ));
                    }),
                    row(
                      Icons.delete_outline_rounded,
                      '删除',
                      () async {
                        Navigator.pop(ctx);
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (dctx) => AlertDialog(
                            title: const Text('确定删除微博么？'),
                            content: Text(
                              status.textRaw,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(dctx, false),
                                child: const Text('取消'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(dctx, true),
                                child: Text('删除',
                                    style: TextStyle(color: ShareColors.accent)),
                              ),
                            ],
                          ),
                        );
                        if (ok != true) return;
                        try {
                          await WeiboApi.instance.deleteStatus(status.id);
                          if (context.mounted) _toast(context, '删除成功');
                          onDeleted?.call();
                          onChanged?.call();
                        } catch (e) {
                          if (context.mounted) _toast(context, _humanize(e));
                        }
                      },
                      color: const Color(0xFFE64340),
                    ),
                  ],
                  Divider(height: 8, thickness: 0.5, color: ShareColors.divider),
                  InkWell(
                    onTap: () => Navigator.pop(ctx),
                    child: SizedBox(
                      height: 50,
                      child: Center(
                        child: Text('取消',
                            style: TextStyle(fontSize: 15, color: ShareColors.textSecondary)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// 屏蔽二级弹窗：博主 / 关键词 / 来源，与原版 `menu/v.xml` → 屏蔽 的三项一致。
Future<void> _showBlockSheet(BuildContext context, WidgetRef ref, Status status) async {
  final name = status.user?.displayName ?? '';
  final uid = status.user?.id ?? '';
  final source = status.cleanSource;
  final picked = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: ShareColors.cardBg,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('屏蔽',
                  style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
            ),
          ),
          if (uid.isNotEmpty)
            ListTile(
              dense: true,
              leading: const Icon(Icons.person_off_outlined, size: 20),
              title: Text('屏蔽此博主（$name）', style: const TextStyle(fontSize: 15)),
              onTap: () => Navigator.pop(ctx, 'user'),
            ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.tag, size: 20),
            title: const Text('屏蔽此关键词…', style: TextStyle(fontSize: 15)),
            onTap: () => Navigator.pop(ctx, 'keyword'),
          ),
          if (source.isNotEmpty)
            ListTile(
              dense: true,
              leading: const Icon(Icons.devices_other, size: 20),
              title: Text('屏蔽此来源（$source）', style: const TextStyle(fontSize: 15)),
              onTap: () => Navigator.pop(ctx, 'source'),
            ),
          const SizedBox(height: 10),
        ],
      ),
    ),
  );
  if (!context.mounted || picked == null) return;

  final notifier = ref.read(settingsProvider.notifier);
  final myUid = ref.read(sessionProvider).account?.uid ?? '';
  switch (picked) {
    case 'user':
      final list = [
        ...(ref.read(settingsProvider).prefs['muted_uids'] as List? ?? const [])
      ].map((e) => '$e').toList();
      if (!list.contains(uid)) list.add(uid);
      notifier.setPref('muted_uids', list);
      await ShareCore.instance
          .blacklistUpsert(uid: myUid, key: uid, info: name, ruleType: 0)
          .catchError((_) => 0);
      if (context.mounted) _toast(context, '已屏蔽 $name');
    case 'source':
      final list = [
        ...(ref.read(settingsProvider).prefs['muted_sources'] as List? ?? const [])
      ].map((e) => '$e').toList();
      if (!list.contains(source)) list.add(source);
      notifier.setPref('muted_sources', list);
      await ShareCore.instance
          .blacklistUpsert(uid: myUid, key: source, ruleType: 2)
          .catchError((_) => 0);
      if (context.mounted) _toast(context, '已屏蔽来源：$source');
    case 'keyword':
      final input = await showTextInputDialog(
        context,
        title: '屏蔽关键词',
        hint: '正文含该词的微博将不再显示',
      );
      if (input == null || input.isEmpty) return;
      final list = [...ref.read(settingsProvider).hiddenKeywords];
      if (!list.contains(input)) list.add(input);
      notifier.setPref('block_keywords', list);
      await ShareCore.instance
          .blacklistUpsert(uid: myUid, key: input, ruleType: 1)
          .catchError((_) => 0);
      if (!context.mounted) return;
      _toast(context, '已屏蔽关键词：$input');
  }
}

/// 打开 1:1 复刻的 Share「生成长图」预览编辑页（自动展开长微博全文、支持评论与二维码）。
Future<void> _shareLongImage(BuildContext context, Status status) async {
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => LongImagePage(status: status)),
  );
}

void _openWeb(BuildContext context, String url, String title) {
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => InAppWebPage(url: url, title: title)),
  );
}

void _toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
  );
}

/// 单行 / 多行文本输入弹窗。
///
/// 用 State 持有 controller，而不是在 `builder` 里 new 一个 —— 后者每次重建
/// 都会重置输入框，而且永远不会被 dispose。
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  String hint = '',
  String initial = '',
  int? maxLines,
  bool multiline = false,
  String confirmText = '确定',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextInputDialog(
      title: title,
      hint: hint,
      initial: initial,
      maxLines: maxLines,
      multiline: multiline,
      confirmText: confirmText,
    ),
  );
}

class _TextInputDialog extends StatefulWidget {
  final String title;
  final String hint;
  final String initial;
  final int? maxLines;
  final bool multiline;
  final String confirmText;

  const _TextInputDialog({
    required this.title,
    required this.hint,
    this.initial = '',
    this.maxLines,
    required this.multiline,
    required this.confirmText,
  });

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveMax = widget.maxLines ?? (widget.multiline ? 4 : 1);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: effectiveMax,
        minLines: 1,
        decoration: InputDecoration(hintText: widget.hint),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(widget.confirmText),
        ),
      ],
    );
  }
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
