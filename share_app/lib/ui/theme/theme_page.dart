import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/settings.dart';
import '../../core/settings_spec.dart';
import '../app_theme.dart';
import '../settings/pref_page.dart';
import '../settings/settings_page.dart';

/// 主题外观 —— 1:1 复刻原版 `ThemeListActivity` (`C0465Kk`)：
/// 全部 21 项主题列表 + 自定义调色/透明皮肤入口 + 底部 3 项高级开关。
class ThemePage extends ConsumerWidget {
  const ThemePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final currentKey = ShareThemePreset.byKey(settings.themeKey).key;
    final visiblePresets = ShareThemePreset.all
        .where((p) => p.key != 'night_green_black')
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('主题外观')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Material(
            color: ShareColors.cardBg,
            child: Column(
              children: [
                for (var i = 0; i < visiblePresets.length; i++) ...[
                  if (i > 0)
                    Divider(height: 0.5, indent: 64, color: ShareColors.divider),
                  _ThemeRow(
                    preset: visiblePresets[i],
                    selected: visiblePresets[i].key == currentKey,
                    customConfig: settings.customTheme,
                    onTap: () => _onSelectPreset(context, ref, visiblePresets[i]),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            child: Text(
              '高级配色与夜间设置',
              style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary),
            ),
          ),
          Material(
            color: ShareColors.cardBg,
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('普通主题强调色跟随主题', style: TextStyle(fontSize: 15)),
                  subtitle: Text(
                    '开启后按钮、链接与昵称高亮色跟随主题主色',
                    style: TextStyle(fontSize: 12, color: ShareColors.textHint),
                  ),
                  value: settings.accentColorFollowTheme,
                  onChanged: (v) =>
                      ref.read(settingsProvider.notifier).setPref('accent_color_theme', v),
                ),
                Divider(height: 0.5, indent: 16, color: ShareColors.divider),
                SwitchListTile(
                  title: const Text('普通主题标题栏颜色跟随主题', style: TextStyle(fontSize: 15)),
                  subtitle: Text(
                    '关闭时默认日间主题保持白底黑字顶栏，开启后顶栏着色',
                    style: TextStyle(fontSize: 12, color: ShareColors.textHint),
                  ),
                  value: settings.toolBarColorTheme,
                  onChanged: (v) =>
                      ref.read(settingsProvider.notifier).setPref('tool_bar_color_theme', v),
                ),
                Divider(height: 0.5, indent: 16, color: ShareColors.divider),
                ListTile(
                  title: const Text('夜间主题详细设置', style: TextStyle(fontSize: 15)),
                  subtitle: Text(
                    '默认夜间样式、跟随系统、定时切换与夜间图片压暗',
                    style: TextStyle(fontSize: 12, color: ShareColors.textHint),
                  ),
                  trailing: Icon(Icons.chevron_right, color: ShareColors.textHint),
                  onTap: () {
                    final privacyPage = PrefPage.byKey('privacy_common') ?? prefPrivacy;
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PrefPageView(
                          page: privacyPage,
                          bridges: SettingsPage.sharedBridges,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onSelectPreset(
    BuildContext context,
    WidgetRef ref,
    ShareThemePreset preset,
  ) async {
    ref.read(settingsProvider.notifier).setTheme(
          preset.key,
          platformBrightness: MediaQuery.platformBrightnessOf(context),
        );
    if (preset.isCustom || preset.isTransparent) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ThemeCustomPage(initialTransparent: preset.isTransparent),
        ),
      );
    }
  }
}

class _ThemeRow extends StatelessWidget {
  final ShareThemePreset preset;
  final bool selected;
  final CustomThemeConfig customConfig;
  final VoidCallback onTap;

  const _ThemeRow({
    required this.preset,
    required this.selected,
    required this.customConfig,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final swatchBg = preset.isCustom
        ? customConfig.primaryColor
        : (preset.isLightTheme
            ? Colors.white
            : (preset.dark ? preset.cardBg : preset.themeColor));
    final innerDot = preset.isCustom
        ? customConfig.accentColor
        : (preset.isLightTheme || preset.dark ? preset.accent : null);

    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: preset.isTransparent ? null : swatchBg,
          gradient: preset.isTransparent
              ? const LinearGradient(
                  colors: [Color(0xFF81D4FA), Color(0xFFB39DDB)],
                )
              : null,
          border: Border.all(
            color: preset.isLightTheme ? const Color(0xFFCCCCCC) : Colors.black12,
            width: 1,
          ),
        ),
        child: innerDot != null
            ? Center(
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: innerDot,
                  ),
                ),
              )
            : (preset.isTransparent
                ? const Icon(Icons.wallpaper, size: 17, color: Colors.white)
                : null),
      ),
      title: Row(
        children: [
          Text(
            preset.name,
            style: TextStyle(
              fontSize: 15,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: ShareColors.textPrimary,
            ),
          ),
          if (preset.dark) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: ShareColors.repostBg,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '夜间',
                style: TextStyle(fontSize: 10.5, color: ShareColors.textSecondary),
              ),
            ),
          ],
        ],
      ),
      subtitle: (preset.isCustom || preset.isTransparent)
          ? Text(
              preset.isTransparent ? '点击选择壁纸、高斯模糊与遮罩' : '点击打开 Material 双层调色板与 Hex',
              style: TextStyle(fontSize: 11.5, color: ShareColors.textHint),
            )
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (preset.isCustom || preset.isTransparent)
            Icon(Icons.tune, size: 18, color: ShareColors.textHint),
          if (selected) ...[
            const SizedBox(width: 8),
            Icon(Icons.check_circle, color: ShareColors.accent, size: 21),
          ],
        ],
      ),
    );
  }
}

/// 1:1 复刻 `ThemeCustomActivity` (`C6962sk`) + `MaterialColorChooser` (`ViewOnClickListenerC2422cx`):
/// 支持自定义 19 主色 / 16 强调色二级网格、RGBA 滑块、Hex 输入，及透明背景图/模糊/蒙版/字体色调节。
class ThemeCustomPage extends ConsumerStatefulWidget {
  final bool initialTransparent;

  const ThemeCustomPage({super.key, this.initialTransparent = false});

  @override
  ConsumerState<ThemeCustomPage> createState() => _ThemeCustomPageState();
}

class _ThemeCustomPageState extends ConsumerState<ThemeCustomPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  late CustomThemeConfig _draft;

  static const _primaryColors = <Color>[
    Color(0xFFF44336), Color(0xFFE91E63), Color(0xFF9C27B0), Color(0xFF673AB7),
    Color(0xFF3F51B5), Color(0xFF2196F3), Color(0xFF03A9F4), Color(0xFF00BCD4),
    Color(0xFF009688), Color(0xFF4CAF50), Color(0xFF8BC34A), Color(0xFFCDDC39),
    Color(0xFFFFEB3B), Color(0xFFFFC107), Color(0xFFFF9800), Color(0xFFFF5722),
    Color(0xFF795548), Color(0xFF9E9E9E), Color(0xFF607D8B),
  ];

  static const _accentColors = <Color>[
    Color(0xFFFF5252), Color(0xFFFF4081), Color(0xFFE040FB), Color(0xFF7C4DFF),
    Color(0xFF536DFE), Color(0xFF448AFF), Color(0xFF40C4FF), Color(0xFF18FFFF),
    Color(0xFF64FFDA), Color(0xFF69F0AE), Color(0xFFB2FF59), Color(0xFFEEFF41),
    Color(0xFFFFFF00), Color(0xFFFFD740), Color(0xFFFFAB40), Color(0xFFFF6E40),
  ];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTransparent ? 1 : 0,
    );
    _draft = ref.read(settingsProvider).customTheme;
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _save({required bool transparent}) {
    final notifier = ref.read(settingsProvider.notifier);
    notifier.setCustomTheme(_draft);
    notifier.setTheme(
      transparent ? 'transparent' : 'custom',
      platformBrightness: MediaQuery.platformBrightnessOf(context),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('自定义外观'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '纯色配色'),
            Tab(text: '透明皮肤'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => _save(transparent: _tabs.index == 1),
            child: Text(
              '应用',
              style: TextStyle(color: ShareColors.accent, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildSolidCustomTab(),
          _buildTransparentTab(),
        ],
      ),
    );
  }

  Widget _buildSolidCustomTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _previewCard(
          primary: _draft.primaryColor,
          accent: _draft.accentColor,
          imagePath: null,
          lightFont: false,
        ),
        const SizedBox(height: 16),
        _colorSectionHeader('主题主色 (19 组 + 色阶微调)', _draft.primaryColor, (c) {
          setState(() => _draft = _draft.copyWith(primaryColorValue: c.toARGB32()));
        }),
        const SizedBox(height: 8),
        _swatchGrid(_primaryColors, _draft.primaryColor, (c) {
          setState(() => _draft = _draft.copyWith(primaryColorValue: c.toARGB32()));
        }),
        const SizedBox(height: 16),
        _colorSectionHeader('强调色 (16 组 + 色阶微调)', _draft.accentColor, (c) {
          setState(() => _draft = _draft.copyWith(accentColorValue: c.toARGB32()));
        }),
        const SizedBox(height: 8),
        _swatchGrid(_accentColors, _draft.accentColor, (c) {
          setState(() => _draft = _draft.copyWith(accentColorValue: c.toARGB32()));
        }),
      ],
    );
  }

  Widget _buildTransparentTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _previewCard(
          primary: _draft.primaryColor,
          accent: _draft.accentColor,
          imagePath: _draft.backgroundImagePath,
          lightFont: _draft.lightFont,
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _pickWallpaper,
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(_draft.backgroundImagePath == null ? '选择背景图片' : '更换背景图片'),
              ),
            ),
            if (_draft.backgroundImagePath != null) ...[
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: () => setState(() => _draft = _draft.copyWith(clearImage: true)),
                child: const Text('清除图片'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        Text('文字颜色模式', style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('白色文字（暗色背景）')),
            ButtonSegment(value: false, label: Text('黑色文字（浅色背景）')),
          ],
          selected: {_draft.lightFont},
          onSelectionChanged: (s) =>
              setState(() => _draft = _draft.copyWith(lightFont: s.first)),
        ),
        const SizedBox(height: 16),
        Text(
          '高斯模糊 (${_draft.blurRadius.toStringAsFixed(0)} / 25)',
          style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
        ),
        Slider(
          value: _draft.blurRadius.clamp(0, 25),
          min: 0,
          max: 25,
          divisions: 25,
          onChanged: (v) => setState(() => _draft = _draft.copyWith(blurRadius: v)),
        ),
        Text(
          '遮罩不透明度 (${(_draft.maskAlpha * 100).round()}%)',
          style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
        ),
        Slider(
          value: _draft.maskAlpha.clamp(0, 1),
          min: 0,
          max: 1,
          onChanged: (v) => setState(() => _draft = _draft.copyWith(maskAlpha: v)),
        ),
      ],
    );
  }

  Future<void> _pickWallpaper() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null || !mounted) return;
    setState(() {
      _draft = _draft.copyWith(backgroundImagePath: file.path);
    });
  }

  Widget _colorSectionHeader(String title, Color current, ValueChanged<Color> onPicked) {
    final hex = '#${current.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';
    return Row(
      children: [
        Expanded(
          child: Text(title, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
        ),
        ActionChip(
          avatar: CircleAvatar(backgroundColor: current, radius: 9),
          label: Text(hex, style: const TextStyle(fontSize: 12)),
          onPressed: () => _openRgbaHexDialog(current, onPicked),
        ),
      ],
    );
  }

  Widget _swatchGrid(List<Color> colors, Color current, ValueChanged<Color> onPick) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final c in colors)
          GestureDetector(
            onTap: () => onPick(c),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(
                  color: c.toARGB32() == current.toARGB32()
                      ? ShareColors.textPrimary
                      : Colors.black12,
                  width: c.toARGB32() == current.toARGB32() ? 2.5 : 1,
                ),
              ),
              child: c.toARGB32() == current.toARGB32()
                  ? const Icon(Icons.check, size: 17, color: Colors.white)
                  : null,
            ),
          ),
      ],
    );
  }

  Future<void> _openRgbaHexDialog(Color initial, ValueChanged<Color> onDone) async {
    var a = (initial.a * 255).round();
    var r = (initial.r * 255).round();
    var g = (initial.g * 255).round();
    var b = (initial.b * 255).round();
    final ctrl = TextEditingController(
      text: initial.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase(),
    );

    final picked = await showDialog<Color>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final col = Color.fromARGB(a, r, g, b);
          return AlertDialog(
            title: const Text('ARGB / Hex 取色器'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    height: 44,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: col,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: ctrl,
                    decoration: const InputDecoration(
                      prefixText: '#',
                      labelText: '6 或 8 位 Hex (AARRGGBB)',
                    ),
                    onChanged: (v) {
                      final clean = v.replaceAll('#', '').trim();
                      if (clean.length == 6 || clean.length == 8) {
                        final padded = clean.length == 6 ? 'FF$clean' : clean;
                        final val = int.tryParse(padded, radix: 16);
                        if (val != null) {
                          final c2 = Color(val);
                          setLocal(() {
                            a = (c2.a * 255).round();
                            r = (c2.r * 255).round();
                            g = (c2.g * 255).round();
                            b = (c2.b * 255).round();
                          });
                        }
                      }
                    },
                  ),
                  _chanSlider('R', r, (v) => setLocal(() => r = v), Colors.red, ctrl, a, r, g, b),
                  _chanSlider('G', g, (v) => setLocal(() => g = v), Colors.green, ctrl, a, r, g, b),
                  _chanSlider('B', b, (v) => setLocal(() => b = v), Colors.blue, ctrl, a, r, g, b),
                  _chanSlider('A', a, (v) => setLocal(() => a = v), Colors.grey, ctrl, a, r, g, b),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(ctx, col), child: const Text('确定')),
            ],
          );
        },
      ),
    );
    ctrl.dispose();
    if (picked != null) onDone(picked);
  }

  Widget _chanSlider(
    String label,
    int value,
    ValueChanged<int> onChanged,
    Color active,
    TextEditingController ctrl,
    int a,
    int r,
    int g,
    int b,
  ) {
    return Row(
      children: [
        SizedBox(width: 18, child: Text(label, style: const TextStyle(fontSize: 12))),
        Expanded(
          child: Slider(
            value: value.toDouble(),
            min: 0,
            max: 255,
            activeColor: active,
            onChanged: (v) {
              final next = v.round();
              onChanged(next);
              final col = Color.fromARGB(
                label == 'A' ? next : a,
                label == 'R' ? next : r,
                label == 'G' ? next : g,
                label == 'B' ? next : b,
              );
              ctrl.text = col.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();
            },
          ),
        ),
        SizedBox(width: 30, child: Text('$value', style: const TextStyle(fontSize: 12))),
      ],
    );
  }

  Widget _previewCard({
    required Color primary,
    required Color accent,
    required String? imagePath,
    required bool lightFont,
  }) {
    final textColor = imagePath != null
        ? (lightFont ? Colors.white : const Color(0xFF222222))
        : Colors.white;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 168,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (imagePath != null && File(imagePath).existsSync())
              Image.file(File(imagePath), fit: BoxFit.cover)
            else
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [primary, Color.lerp(primary, accent, 0.45)!],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
            if (imagePath != null)
              Container(
                color: (lightFont ? Colors.black : Colors.white)
                    .withValues(alpha: _draft.maskAlpha.clamp(0.05, 0.85)),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(backgroundColor: accent, radius: 16, child: const Text('S')),
                      const SizedBox(width: 10),
                      Text(
                        'Share 客户端预览效果',
                        style: TextStyle(color: textColor, fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    '主色与强调色将在标题栏、按钮、链接与浮动操作键即时生效。',
                    style: TextStyle(color: textColor.withValues(alpha: 0.9), fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        '强调色按钮',
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
