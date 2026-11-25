import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/session.dart';
import '../../core/settings.dart';
import '../../core/share_core.dart';
import '../../src/rust/api/share_api.dart' show BlacklistRuleDto;
import '../app_theme.dart';

/// 1:1 复刻 `CommonSearchActivity` / `C6634oooooooO` 黑名单与过滤三合一页：
/// Tab 0: 屏蔽用户 (`type=0`)
/// Tab 1: 屏蔽关键词 (`type=1`)
/// Tab 2: 屏蔽微博尾巴/来源 (`type=2`)
/// 直接持久化于 SQLite `BLACK_LIST` 表，并支持 `.share_backup` JSON 导出/导入。
class KeywordPage extends ConsumerStatefulWidget {
  final int initialTab;

  const KeywordPage({super.key, this.initialTab = 1});

  @override
  ConsumerState<KeywordPage> createState() => _KeywordPageState();
}

class _KeywordPageState extends ConsumerState<KeywordPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _inputCtrl = TextEditingController();
  final _focus = FocusNode();

  List<BlacklistRuleDto> _rules = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 2),
    );
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging && mounted) setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _inputCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _uid => ref.read(sessionProvider).account?.uid ?? '';

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // 自动迁移旧 SharedPreferences 中的关键词进入 SQLite BLACK_LIST
      final legacy = ref.read(settingsProvider).hiddenKeywords;
      final existing = await ShareCore.instance.blacklistList(_uid);
      final existingKeys =
          existing.where((r) => r.ruleType == 1).map((r) => r.key).toSet();
      for (final word in legacy) {
        if (!existingKeys.contains(word)) {
          await ShareCore.instance.blacklistUpsert(
            uid: _uid,
            key: word,
            ruleType: 1,
          );
        }
      }
      final list = await ShareCore.instance.blacklistList(_uid);
      if (!mounted) return;
      setState(() {
        _rules = list;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;
    final type = _tabs.index;
    await ShareCore.instance.blacklistUpsert(
      uid: _uid,
      key: text,
      ruleType: type,
    );
    if (type == 1) {
      final kw = ref.read(settingsProvider).hiddenKeywords;
      if (!kw.contains(text)) {
        ref.read(settingsProvider.notifier).setPref('block_keywords', [...kw, text]);
      }
    }
    _inputCtrl.clear();
    _focus.requestFocus();
    await _load();
  }

  Future<void> _toggle(BlacklistRuleDto rule, bool enabled) async {
    await ShareCore.instance.blacklistToggle(rule.id, enabled ? 1 : 0);
    await _load();
  }

  Future<void> _delete(BlacklistRuleDto rule) async {
    await ShareCore.instance.blacklistDelete(rule.id);
    if (rule.ruleType == 1) {
      final next =
          ref.read(settingsProvider).hiddenKeywords.where((w) => w != rule.key).toList();
      ref.read(settingsProvider.notifier).setPref('block_keywords', next);
    }
    await _load();
  }

  Future<void> _exportBackup() async {
    try {
      final jsonStr = await ShareCore.instance.blacklistExportBackup(_uid);
      await Clipboard.setData(ClipboardData(text: jsonStr));
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('已导出并复制 .share_backup 配置'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: SelectableText(jsonStr, style: const TextStyle(fontSize: 12)),
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('完成'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }

  Future<void> _importBackup() async {
    final ctrl = TextEditingController();
    final jsonStr = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入 .share_backup 配置'),
        content: TextField(
          controller: ctrl,
          maxLines: 6,
          decoration: const InputDecoration(
            hintText: '粘贴黑名单 JSON 备份内容',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (jsonStr == null || jsonStr.isEmpty) return;
    try {
      final count = await ShareCore.instance.blacklistImportBackup(_uid, jsonStr);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('成功导入 $count 条屏蔽规则')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = switch (_tabs.index) {
      0 => '输入要屏蔽的博主 UID 或昵称',
      1 => '输入要屏蔽的关键词，回车添加',
      _ => '输入要屏蔽的微博来源尾巴（如：微博极速版）',
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('黑名单与内容屏蔽'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'export') _exportBackup();
              if (v == 'import') _importBackup();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'export', child: Text('导出 .share_backup 备份')),
              PopupMenuItem(value: 'import', child: Text('导入 .share_backup 备份')),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: ShareColors.accent,
          unselectedLabelColor: ShareColors.textSecondary,
          indicatorColor: ShareColors.accent,
          tabs: const [
            Tab(text: '屏蔽用户'),
            Tab(text: '关键词'),
            Tab(text: '微博尾巴'),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _inputCtrl,
              focusNode: _focus,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                hintText: hint,
                filled: true,
                fillColor: ShareColors.inputBg,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: IconButton(
                  icon: Icon(Icons.add, color: ShareColors.accent),
                  onPressed: _add,
                ),
              ),
              onSubmitted: (_) => _add(),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : TabBarView(
                    controller: _tabs,
                    children: [
                      _buildRuleList(0),
                      _buildRuleList(1),
                      _buildRuleList(2),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildRuleList(int ruleType) {
    final items = _rules.where((r) => r.ruleType == ruleType).toList();
    if (items.isEmpty) {
      final emptyMsg = switch (ruleType) {
        0 => '暂无屏蔽用户',
        1 => '暂无屏蔽关键词',
        _ => '暂无屏蔽尾巴规则',
      };
      return Center(
        child: Text(emptyMsg, style: TextStyle(color: ShareColors.textHint)),
      );
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => Divider(height: 0.5, color: ShareColors.divider),
      itemBuilder: (context, i) {
        final rule = items[i];
        return ListTile(
          title: Text(
            rule.key,
            style: TextStyle(
              color: rule.state == 1 ? ShareColors.textPrimary : ShareColors.textHint,
              decoration: rule.state == 1 ? null : TextDecoration.lineThrough,
            ),
          ),
          subtitle: rule.info.isNotEmpty
              ? Text(rule.info, style: TextStyle(fontSize: 12, color: ShareColors.textHint))
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                value: rule.state == 1,
                onChanged: (v) => _toggle(rule, v),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline, color: ShareColors.textHint, size: 20),
                onPressed: () => _delete(rule),
              ),
            ],
          ),
        );
      },
    );
  }
}
