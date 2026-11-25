import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/settings.dart';
import '../app_theme.dart';
import '../settings/pref_page.dart';

/// 发布页里「真能落地」的两个开关。
///
/// 其余菜单项依赖微博服务端能力，故意不在这里建模 —— 建了字段却发不出去，
/// 等于给 UI 留一个永远为假的开关。
class ComposeOptions {
  /// 发送前把「昵称 + Share」烧进图片。
  final bool watermark;

  /// 发博来源尾巴显示控制（对应 `publish_source` 国际版客户端与尾巴参数）。
  final bool tail;

  const ComposeOptions({this.watermark = false, this.tail = false});

  ComposeOptions copyWith({bool? watermark, bool? tail}) => ComposeOptions(
        watermark: watermark ?? this.watermark,
        tail: tail ?? this.tail,
      );
}

/// 唤起「发送选项」底部面板，返回关闭时的最终状态。
Future<ComposeOptions?> showComposeOptionsSheet(
  BuildContext context, {
  required ComposeOptions initial,
}) {
  return showModalBottomSheet<ComposeOptions>(
    context: context,
    backgroundColor: ShareColors.cardBg,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
    ),
    builder: (_) => _ComposeOptionsSheet(initial: initial),
  );
}

/// 顺序严格对齐 `res/menu/n.xml`：
/// 选择账号 / 发送选项（分组标题）/ 定时发送 / 取消定时 / 图片水印 /
/// 微博尾巴 / 快转 / 点评 / 签到 / 投票。
class _ComposeOptionsSheet extends ConsumerStatefulWidget {
  final ComposeOptions initial;

  const _ComposeOptionsSheet({required this.initial});

  @override
  ConsumerState<_ComposeOptionsSheet> createState() => _ComposeOptionsSheetState();
}

class _ComposeOptionsSheetState extends ConsumerState<_ComposeOptionsSheet> {
  late ComposeOptions _options = widget.initial;

  /// 点了灰色项后的说明文字。
  ///
  /// 为什么不用 SnackBar：提示条会浮在屏幕底部，正好被这个底部面板盖住，
  /// 用户看到的就是"点了没反应"。改成面板内的一行说明，保证必被看见。
  String? _notice;

  void _say(String message) => setState(() => _notice = message);

  void _set(ComposeOptions next) => setState(() => _options = next);

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(sessionProvider).account;
    final name = (account?.screenName ?? '').isEmpty ? '未登录' : account!.screenName;
    final maxHeight = MediaQuery.of(context).size.height * 0.78;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _grabber(),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  _accountRow(name),
                  _sectionTitle('发送选项'),
                  _disabledRow('定时发送',
                      '定时发送需要服务端定时任务接口（statuses/schedule/upload），本版本未实现'),
                  _disabledRow('取消定时',
                      '取消定时同样依赖服务端定时任务接口（statuses/schedule/upload），本版本未实现'),
                  _switchRow(
                    title: '图片水印',
                    subtitle: _options.watermark
                        ? '发送前会把「昵称 + Share」烧进图片右下角'
                        : '打开后发送前给每张图叠加「昵称 + Share」',
                    value: _options.watermark,
                    onChanged: (v) => _set(_options.copyWith(watermark: v)),
                  ),
                  _tailRow(),
                  _disabledRow('快转', '快转是微博会员专属的服务端能力，本版本未接入'),
                  _disabledRow('点评', '点评需要微博的服务端"点评"接口，本版本未接入'),
                  _disabledRow('签到', '签到依赖超话 / 话题签到接口（stopic/curl），本版本未接入'),
                  _disabledRow('投票', '投票需要服务端投票配置接口（vote/config），本版本未接入'),
                ],
              ),
            ),
            if (_notice != null) _noticeBar(_notice!),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _grabber() => Center(
        child: Container(
          margin: const EdgeInsets.only(top: 8, bottom: 4),
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: ShareColors.divider,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Text(
          text,
          style: TextStyle(fontSize: 12, color: ShareColors.textSecondary),
        ),
      );

  /// 选择账号是原版少数不依赖发帖接口的菜单项，`accounts()` / `switchAccount()`
  /// 都已经实现，所以这里做真的，不置灰。
  Widget _accountRow(String name) {
    return InkWell(
      onTap: _openAccountSheet,
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Text('选择账号', style: TextStyle(fontSize: 15, color: ShareColors.textPrimary)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: ShareColors.textHint),
          ],
        ),
      ),
    );
  }

  Widget _tailRow() {
    final settings = ref.watch(settingsProvider);
    final tailLabel = AppSettings.formatPublishTailLabel(settings.publishTail);
    return InkWell(
      onTap: () async {
        final next = await showPublishTailPicker(context, settings.publishTail);
        if (next != null && mounted) {
          ref.read(settingsProvider.notifier).setPref('publish_source', next);
          _set(_options.copyWith(tail: next.isNotEmpty));
          _say('微博尾巴已设置为：${AppSettings.formatPublishTailLabel(next)}');
        }
      },
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Text('微博尾巴', style: TextStyle(fontSize: 15, color: ShareColors.textPrimary)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                tailLabel,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: ShareColors.textHint),
          ],
        ),
      ),
    );
  }

  Widget _disabledRow(String title, String reason) {
    return InkWell(
      onTap: () => _say('$title：$reason'),
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(fontSize: 15, color: ShareColors.textHint),
              ),
            ),
            Text('未接入', style: TextStyle(fontSize: 11, color: ShareColors.textHint)),
          ],
        ),
      ),
    );
  }

  Widget _switchRow({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(fontSize: 15, color: ShareColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, height: 1.3, color: ShareColors.textSecondary),
                  ),
                ],
              ),
            ),
            // 开关交给整行处理：Switch 自己再吃一次点击会和 InkWell 抢手势，
            // 极端情况下"点一下切两次"等于没反应，这里直接屏蔽它自己的命中测试。
            IgnorePointer(child: Switch(value: value, onChanged: onChanged)),
          ],
        ),
      ),
    );
  }

  Widget _noticeBar(String text) {
    return Container(
      width: double.infinity,
      color: ShareColors.inputBg,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 15, color: ShareColors.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, height: 1.35, color: ShareColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: ShareColors.divider, width: 0.5)),
      ),
      child: Text(
        '灰色项为原版依赖微博服务端能力的功能，尚未接入',
        style: TextStyle(fontSize: 11, color: ShareColors.textHint),
      ),
    );
  }

  Future<void> _openAccountSheet() async {
    List<SessionAccount> accounts;
    try {
      accounts = await WeiboApi.instance.accounts();
    } catch (e) {
      if (!mounted) return;
      _say('读取账号列表失败：$e');
      return;
    }
    if (!mounted) return;

    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: ShareColors.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) {
        final currentUid = ref.read(sessionProvider).account?.uid ?? '';
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('选择发布账号',
                      style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
                ),
              ),
              for (final account in accounts)
                ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: ShareColors.placeholder,
                    backgroundImage:
                        account.avatar.isEmpty ? null : NetworkImage(account.avatar),
                    child: account.avatar.isEmpty
                        ? Icon(Icons.person, size: 16, color: ShareColors.textHint)
                        : null,
                  ),
                  title: Text(account.screenName,
                      style: TextStyle(fontSize: 14.5, color: ShareColors.textPrimary)),
                  trailing: account.uid == currentUid
                      ? Icon(Icons.check, size: 18, color: ShareColors.accent)
                      : null,
                  onTap: () => Navigator.of(ctx).pop(account.uid),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (picked == null || !mounted) return;
    if (picked == (ref.read(sessionProvider).account?.uid ?? '')) return;

    try {
      // 切号会改变全局会话，所以只在这一刻做，并且立刻重新读一遍当前账号。
      await ref.read(sessionProvider.notifier).switchTo(picked);
      if (!mounted) return;
      setState(() => _notice = '已切换发布账号，将使用新账号发布');
    } catch (e) {
      if (!mounted) return;
      _say('切换账号失败：$e');
    }
  }
}
