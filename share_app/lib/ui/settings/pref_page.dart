import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/models.dart';
import '../../core/settings.dart';
import '../../core/settings_spec.dart';
import '../../core/share_core.dart';
import '../app_theme.dart';
import '../common/in_app_web_page.dart';
import '../feed/status_card.dart';
import 'about_page.dart';
import 'history_page.dart';
import 'keyword_page.dart';
import 'settings_util.dart';

class PrefBridge {
  final bool Function(AppSettings) read;
  final void Function(SettingsNotifier, bool) write;

  const PrefBridge({required this.read, required this.write});
}

/// Renders any [PrefPage] declared in `settings_spec.dart`, including the real-time
/// sample `StatusCard` preview pinned on top of `微博样式` (`card` / `xml/q.xml`).
class PrefPageView extends ConsumerWidget {
  final PrefPage page;
  final List<PrefGroup> extra;
  final Map<String, PrefBridge> bridges;

  const PrefPageView({
    super.key,
    required this.page,
    this.extra = const [],
    this.bridges = const {},
  });

  static final _previewStatus = Status(
    id: '0',
    mblogid: 'preview',
    createdAt: '刚刚',
    textHtml: '这是一条微博卡片样式预览[微笑] #Share# 字号、行距、头像形状与卡片分割线都会在此实时生效。',
    textRaw: '这是一条微博卡片样式预览[微笑] #Share# 字号、行距、头像形状与卡片分割线都会在此实时生效。',
    source: '<a href="">Share 客户端</a>',
    user: const User(
      id: '1000',
      name: 'Share 小助手',
      remark: '备注名',
      avatar: '',
      verified: true,
      verifiedType: 0,
    ),
    reposts: 12,
    comments: 34,
    attitudes: 56,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    final groups = [...page.groups, ...extra];
    final items = groups.expand((g) => g.items).where((i) => i.kind != PrefKind.nav);

    return Scaffold(
      appBar: AppBar(title: Text(page.title)),
      body: Column(
        children: [
          if (page.key == 'card')
            Container(
              decoration: BoxDecoration(
                color: ShareColors.pageBg,
                border: Border(bottom: BorderSide(color: ShareColors.divider, width: 1)),
              ),
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: AbsorbPointer(
                child: StatusCard(status: _previewStatus),
              ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 28),
              children: [
                if (page.blurb != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                    child: Text(
                      page.blurb!,
                      style: TextStyle(fontSize: 12.5, height: 1.5, color: ShareColors.textSecondary),
                    ),
                  ),
                for (final group in groups) ...[
                  if (group.title != null) _caption(group.title!),
                  if (group.title == null) const SizedBox(height: 12),
                  Material(
                    color: ShareColors.cardBg,
                    child: Column(
                      children: [
                        for (final item in group.items)
                          _Row(
                            item: item,
                            settings: settings,
                            notifier: notifier,
                            bridge: bridges[item.key],
                          ),
                      ],
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Text(
                    '共 ${items.length} 项配置（严格对应原版 Share 3.9.6 PreferenceScreen 键值）。',
                    style: TextStyle(fontSize: 11.5, height: 1.6, color: ShareColors.textHint),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _caption(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Text(title, style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary)),
    );
  }
}

class _Row extends StatelessWidget {
  final PrefItem item;
  final AppSettings settings;
  final SettingsNotifier notifier;
  final PrefBridge? bridge;

  const _Row({
    required this.item,
    required this.settings,
    required this.notifier,
    this.bridge,
  });

  @override
  Widget build(BuildContext context) {
    switch (item.kind) {
      case PrefKind.toggle:
        return SwitchListTile.adaptive(
          dense: true,
          value: bridge?.read(settings) ?? settings.flag(item.key),
          activeThumbColor: ShareColors.accent,
          title: Text(item.title, style: const TextStyle(fontSize: 15)),
          subtitle: item.note == null
              ? null
              : Text(item.note!,
                  style: TextStyle(fontSize: 11.5, height: 1.4, color: ShareColors.textSecondary)),
          onChanged: (v) {
            final bridged = bridge;
            if (bridged != null) {
              bridged.write(notifier, v);
            } else {
              notifier.setPref(item.key, v);
            }
          },
        );
      case PrefKind.choice:
      case PrefKind.slider:
        final current = settings.choiceOf(item.key);
        final label = _labelOf(current);
        return ListTile(
          dense: true,
          title: Text(item.title, style: const TextStyle(fontSize: 15)),
          subtitle: item.note == null
              ? null
              : Text(item.note!,
                  style: TextStyle(fontSize: 11.5, height: 1.4, color: ShareColors.textSecondary)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary)),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: ShareColors.textHint),
            ],
          ),
          onTap: () => _pick(context),
        );
      case PrefKind.multi:
        final picked = settings.multiOf(item.key);
        return ListTile(
          dense: true,
          title: Text(item.title, style: const TextStyle(fontSize: 15)),
          subtitle: Text(
            picked.isEmpty
                ? '未选择'
                : item.options
                    .where((o) => picked.contains(o.value))
                    .map((o) => o.label)
                    .join('、'),
            style: TextStyle(fontSize: 11.5, height: 1.4, color: ShareColors.textSecondary),
          ),
          trailing: Icon(Icons.chevron_right, size: 18, color: ShareColors.textHint),
          onTap: () => _pickMulti(context),
        );
      case PrefKind.nav:
        final navSummary = item.key == 'publish_source'
            ? AppSettings.formatPublishTailLabel(settings.publishTail)
            : null;
        return ListTile(
          dense: true,
          title: Text(item.title, style: const TextStyle(fontSize: 15)),
          subtitle: item.note == null
              ? null
              : Text(item.note!,
                  style: TextStyle(fontSize: 11.5, height: 1.4, color: ShareColors.textSecondary)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (navSummary != null) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    navSummary,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary),
                  ),
                ),
                const SizedBox(width: 4),
              ],
              Icon(Icons.chevron_right, size: 18, color: ShareColors.textHint),
            ],
          ),
          onTap: () => openRoute(context, item, settings: settings, notifier: notifier),
        );
    }
  }

  String _labelOf(int value) {
    if (item.kind == PrefKind.slider) return '$value%';
    for (final o in item.options) {
      if (o.value == value) return o.label;
    }
    return '$value';
  }

  void _pick(BuildContext context) {
    if (item.kind == PrefKind.slider) {
      notifier.setPref(item.key, settings.choiceOf(item.key));
      _showSlider(context);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(item.title, style: const TextStyle(fontSize: 16)),
        children: [
          for (final o in item.options)
            RadioListTile<int>(
              dense: true,
              value: o.value,
              // ignore: deprecated_member_use
              groupValue: settings.choiceOf(item.key),
              activeColor: ShareColors.accent,
              title: Text(o.label, style: const TextStyle(fontSize: 14.5)),
              // ignore: deprecated_member_use
              onChanged: (v) async {
                if (v != null) {
                  notifier.setPref(item.key, v);
                  if (item.key == 'ic_launcher') {
                    final switched = await ShareCore.instance.setLauncherIcon(v);
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(
                          content: Text(
                            switched
                                ? '应用图标已切换为：${o.label}'
                                : '已记录图标偏好「${o.label}」（当前打包仅含默认桌面图标资源）',
                          ),
                        ),
                      );
                    }
                  }
                }
                if (ctx.mounted) Navigator.pop(ctx);
              },
            ),
        ],
      ),
    );
  }

  void _showSlider(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _SliderDialog(
        item: item,
        notifier: notifier,
        initial: settings.choiceOf(item.key),
      ),
    );
  }

  void _pickMulti(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _MultiDialog(
        item: item,
        notifier: notifier,
        initial: settings.multiOf(item.key),
      ),
    );
  }
}

class _SliderDialog extends StatefulWidget {
  final PrefItem item;
  final SettingsNotifier notifier;
  final int initial;

  const _SliderDialog({
    required this.item,
    required this.notifier,
    required this.initial,
  });

  @override
  State<_SliderDialog> createState() => _SliderDialogState();
}

class _SliderDialogState extends State<_SliderDialog> {
  late int _value;

  @override
  void initState() {
    super.initState();
    _value = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.item.title, style: const TextStyle(fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$_value%',
              style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
          Slider(
            value: _value.toDouble(),
            min: widget.item.min.toDouble(),
            max: widget.item.max.toDouble(),
            divisions: widget.item.max - widget.item.min,
            activeColor: ShareColors.accent,
            onChanged: (v) {
              setState(() => _value = v.round());
              widget.notifier.setPref(widget.item.key, v.round());
            },
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('完成')),
      ],
    );
  }
}

class _MultiDialog extends StatefulWidget {
  final PrefItem item;
  final SettingsNotifier notifier;
  final List<int> initial;

  const _MultiDialog({
    required this.item,
    required this.notifier,
    required this.initial,
  });

  @override
  State<_MultiDialog> createState() => _MultiDialogState();
}

class _MultiDialogState extends State<_MultiDialog> {
  late Set<int> _picked;

  @override
  void initState() {
    super.initState();
    _picked = widget.initial.toSet();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.item.title, style: const TextStyle(fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final o in widget.item.options)
            CheckboxListTile(
              dense: true,
              value: _picked.contains(o.value),
              activeColor: ShareColors.accent,
              title: Text(o.label, style: const TextStyle(fontSize: 14.5)),
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    _picked.add(o.value);
                  } else {
                    _picked.remove(o.value);
                  }
                });
                widget.notifier.setPref(widget.item.key, _picked.toList()..sort());
              },
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('完成')),
      ],
    );
  }
}

Future<void> openRoute(
  BuildContext context,
  PrefItem item, {
  AppSettings? settings,
  SettingsNotifier? notifier,
}) async {
  final route = item.route ?? '';
  if (route.startsWith('http')) {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => InAppWebPage(url: route, title: item.title),
    ));
    return;
  }
  if (!context.mounted) return;

  switch (route) {
    case 'blacklist':
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const KeywordPage(initialTab: 0),
      ));
      return;
    case 'black_content':
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const KeywordPage(initialTab: 1),
      ));
      return;
    case 'block_status':
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const KeywordPage(initialTab: 2),
      ));
      return;
    case 'recently_visit':
    case 'recent_info':
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const HistoryPage(initialTab: 1),
      ));
      return;
    case 'donate':
    case 'terms':
    case 'history_version':
    case 'version_code':
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const AboutPage(),
      ));
      return;
    case 'drawer_menu':
      if (settings != null && notifier != null) {
        await _openDrawerMenuEditor(context, settings, notifier);
        return;
      }
    case 'drawer_cover':
      if (settings != null && notifier != null) {
        await _openDrawerCoverPicker(context, settings, notifier);
        return;
      }
    case 'night_duration':
      if (settings != null && notifier != null) {
        await _openNightDurationPicker(context, settings, notifier);
        return;
      }
    case 'publish_source':
      if (settings != null && notifier != null) {
        await _openPublishTailPicker(context, settings, notifier);
        return;
      }
    case 'clear_photo_cache':
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('清除图片缓存'),
          content: const Text('清除内存及本地临时图片缓存，确定继续吗？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx, true);
                final freed = await clearImageCache();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('图片缓存已清除（${formatBytes(freed)}）')),
                  );
                }
              },
              child: const Text('清除'),
            ),
          ],
        ),
      );
      return;
  }

  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Text(
            _routeHint(route),
            style: TextStyle(fontSize: 13, height: 1.6, color: ShareColors.textSecondary),
          ),
        ],
      ),
    ),
  );
}

Future<void> _openDrawerMenuEditor(
  BuildContext context,
  AppSettings settings,
  SettingsNotifier notifier,
) async {
  const labels = {
    'home': '首页',
    'hot': '热门',
    'friends': '我的关注',
    'topic': '超话',
    'search': '搜索',
    'favorites': '收藏',
    'drafts': '草稿箱',
    'message': '消息',
    'dm': '私信',
    'groups': '分组管理',
    'blacklist': '黑名单与过滤',
    'history': '浏览历史',
    'theme': '主题',
    'settings': '设置',
  };
  final order = [...settings.drawerMenuOrder];
  for (final k in AppSettings.defaultDrawerOrder) {
    if (!order.contains(k)) order.add(k);
  }
  final hidden = {...settings.drawerHiddenKeys};

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => DraggableScrollableSheet(
        initialChildSize: 0.72,
        expand: false,
        builder: (_, sc) => Column(
          children: [
            ListTile(
              title: const Text('侧栏菜单拖拽排序与显隐'),
              trailing: TextButton(
                onPressed: () {
                  notifier.setPref('drawer_menu_order', AppSettings.defaultDrawerOrder);
                  notifier.setPref('drawer_menu_hidden', <String>[]);
                  Navigator.pop(ctx);
                },
                child: const Text('恢复默认'),
              ),
            ),
            Expanded(
              child: ReorderableListView.builder(
                scrollController: sc,
                itemCount: order.length,
                onReorderItem: (oldIndex, newIndex) {
                  setLocal(() {
                    final moved = order.removeAt(oldIndex);
                    order.insert(newIndex, moved);
                  });
                  notifier.setPref('drawer_menu_order', [...order]);
                },
                itemBuilder: (_, i) {
                  final key = order[i];
                  return CheckboxListTile(
                    key: ValueKey(key),
                    value: !hidden.contains(key),
                    title: Text(labels[key] ?? key),
                    secondary: const Icon(Icons.drag_handle),
                    onChanged: (show) {
                      setLocal(() {
                        if (show == true) {
                          hidden.remove(key);
                        } else {
                          hidden.add(key);
                        }
                      });
                      notifier.setPref('drawer_menu_hidden', hidden.toList());
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _openDrawerCoverPicker(
  BuildContext context,
  AppSettings settings,
  SettingsNotifier notifier,
) async {
  var current = settings.choiceOf('drawer_cover_type');
  await showDialog<void>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('侧栏封面模式'),
      children: [
        RadioListTile<int>(
          value: 1,
          // ignore: deprecated_member_use
          groupValue: current,
          title: const Text('跟随主题颜色'),
          // ignore: deprecated_member_use
          onChanged: (v) {
            if (v != null) notifier.setPref('drawer_cover_type', v);
            Navigator.pop(ctx);
          },
        ),
        RadioListTile<int>(
          value: 2,
          // ignore: deprecated_member_use
          groupValue: current,
          title: const Text('选择本地背景图'),
          // ignore: deprecated_member_use
          onChanged: (v) async {
            final img = await ImagePicker().pickImage(source: ImageSource.gallery);
            if (img != null) {
              notifier.setPref('drawer_cover_type', 2);
              notifier.setCustomTheme(
                settings.customTheme.copyWith(backgroundImagePath: img.path),
              );
            }
            if (ctx.mounted) Navigator.pop(ctx);
          },
        ),
        RadioListTile<int>(
          value: 3,
          // ignore: deprecated_member_use
          groupValue: current,
          title: const Text('使用个人主页封面'),
          // ignore: deprecated_member_use
          onChanged: (v) {
            if (v != null) notifier.setPref('drawer_cover_type', v);
            Navigator.pop(ctx);
          },
        ),
      ],
    ),
  );
}

Future<void> _openNightDurationPicker(
  BuildContext context,
  AppSettings settings,
  SettingsNotifier notifier,
) async {
  final start = await showTimePicker(
    context: context,
    initialTime: const TimeOfDay(hour: 22, minute: 0),
    helpText: '选择夜间模式开始时间',
  );
  if (start == null || !context.mounted) return;
  final end = await showTimePicker(
    context: context,
    initialTime: const TimeOfDay(hour: 7, minute: 0),
    helpText: '选择夜间模式结束时间',
  );
  if (end == null || !context.mounted) return;
  String fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final formatted = '${fmt(start)}-${fmt(end)}';
  notifier.setPref('auto_night_mode_duration', formatted);
  notifier.setPref('auto_night_mode', true);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('已设定自动夜间时段：$formatted')),
  );
}

const _tailPresets = <({String value, String label, String subtitle})>[
  (value: '', label: '默认 (Share)', subtitle: '使用客户端默认尾巴标识'),
  (value: 'intl', label: '微博国际版 (Weibo.intl)', subtitle: '使用原版国际版预设来源 (4215535043)'),
  (value: 'weico', label: 'Weico客户端', subtitle: '使用 Weico 预设来源 (211160679)'),
  (value: 'none', label: '不显示尾巴', subtitle: '发微博时不附带来源 (-1)'),
];

/// Reusable Weibo tail picker supporting Share presets (including 微博国际版
/// Weibo.intl) as well as free-form custom tail text.
Future<String?> showPublishTailPicker(BuildContext context, String currentRaw) async {
  final current = currentRaw.trim();
  final picked = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: ShareColors.cardBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
    ),
    builder: (ctx) {
      final isCustom = current.isNotEmpty &&
          !_tailPresets.any((p) =>
              p.value == current ||
              (p.value == 'intl' && current == '4215535043') ||
              (p.value == 'weico' && current == '211160679') ||
              (p.value == 'none' && current == '-1'));
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '选择微博尾巴',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: ShareColors.textPrimary,
                  ),
                ),
              ),
            ),
            for (final preset in _tailPresets)
              ListTile(
                dense: true,
                title: Text(preset.label,
                    style: TextStyle(fontSize: 14.5, color: ShareColors.textPrimary)),
                subtitle: Text(preset.subtitle,
                    style: TextStyle(fontSize: 11.5, color: ShareColors.textSecondary)),
                trailing: ((current == preset.value) ||
                        (preset.value == 'intl' && current == '4215535043') ||
                        (preset.value == 'weico' && current == '211160679') ||
                        (preset.value == 'none' && current == '-1'))
                    ? Icon(Icons.check, size: 18, color: ShareColors.accent)
                    : null,
                onTap: () => Navigator.of(ctx).pop(preset.value),
              ),
            ListTile(
              dense: true,
              title: Text(
                isCustom ? '自定义尾巴：$current' : '自定义尾巴…',
                style: TextStyle(fontSize: 14.5, color: ShareColors.textPrimary),
              ),
              subtitle: Text(
                '输入任意显示名称，如 Share 3.9.6 / Weibo.intl',
                style: TextStyle(fontSize: 11.5, color: ShareColors.textSecondary),
              ),
              trailing: isCustom
                  ? Icon(Icons.check, size: 18, color: ShareColors.accent)
                  : Icon(Icons.edit_outlined, size: 18, color: ShareColors.textHint),
              onTap: () => Navigator.of(ctx).pop('__CUSTOM__'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (picked == null) return null;
  if (picked != '__CUSTOM__') return picked;
  if (!context.mounted) return null;

  final ctrl = TextEditingController(
    text: (current == 'intl' ||
            current == 'weico' ||
            current == 'none' ||
            current == '4215535043' ||
            current == '211160679' ||
            current == '-1')
        ? ''
        : current,
  );
  final custom = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('自定义微博尾巴'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: '留空恢复默认，如「Share 3.9.6」',
          border: OutlineInputBorder(),
        ),
      ),
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
  return custom;
}

Future<void> _openPublishTailPicker(
  BuildContext context,
  AppSettings settings,
  SettingsNotifier notifier,
) async {
  final next = await showPublishTailPicker(context, settings.publishTail);
  if (next != null) {
    notifier.setPref('publish_source', next);
  }
}

String _routeHint(String route) => switch (route) {
      'save_photo_path' || 'save_video_path' =>
        '默认保存至系统相册 Share 专辑中（Android MediaStore / iOS Photos）。',
      'system_sound' =>
        '通知铃声与振动开关由系统设置 -> 通知管理控制。',
      'privacy_common' =>
        '在线状态、粉丝列表隐藏等账号侧隐私项可前往微博网页端隐私页管理。',
      'rate' => '感谢支持 Share！',
      'check_update' => '当前为 Share v3.9.6 1:1 跨平台 Flutter + Rust 构建版本。',
      _ => '配置已在本地持久化保存。',
    };
