import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_spec.dart';

/// Custom / Transparent skin configuration serialized in `theme_custom_value`.
class CustomThemeConfig {
  final int primaryColorValue;
  final int accentColorValue;
  final String? backgroundImagePath;
  final double blurRadius; // 0..25
  final double maskAlpha; // 0..1
  final bool lightFont; // true=white text on dark/photo, false=dark text

  const CustomThemeConfig({
    this.primaryColorValue = 0xFFB693AE,
    this.accentColorValue = 0xFFDDA5AD,
    this.backgroundImagePath,
    this.blurRadius = 6.0,
    this.maskAlpha = 0.25,
    this.lightFont = true,
  });

  Color get primaryColor => Color(primaryColorValue);
  Color get accentColor => Color(accentColorValue);

  CustomThemeConfig copyWith({
    int? primaryColorValue,
    int? accentColorValue,
    String? backgroundImagePath,
    bool clearImage = false,
    double? blurRadius,
    double? maskAlpha,
    bool? lightFont,
  }) {
    return CustomThemeConfig(
      primaryColorValue: primaryColorValue ?? this.primaryColorValue,
      accentColorValue: accentColorValue ?? this.accentColorValue,
      backgroundImagePath:
          clearImage ? null : (backgroundImagePath ?? this.backgroundImagePath),
      blurRadius: blurRadius ?? this.blurRadius,
      maskAlpha: maskAlpha ?? this.maskAlpha,
      lightFont: lightFont ?? this.lightFont,
    );
  }

  Map<String, dynamic> toJson() => {
        'primary': primaryColorValue,
        'accent': accentColorValue,
        'imagePath': backgroundImagePath,
        'blur': blurRadius,
        'maskAlpha': maskAlpha,
        'lightFont': lightFont,
      };

  factory CustomThemeConfig.fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return const CustomThemeConfig();
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return const CustomThemeConfig();
      return CustomThemeConfig(
        primaryColorValue: (m['primary'] as num?)?.toInt() ?? 0xFFB693AE,
        accentColorValue: (m['accent'] as num?)?.toInt() ?? 0xFFDDA5AD,
        backgroundImagePath: m['imagePath'] as String?,
        blurRadius: (m['blur'] as num?)?.toDouble() ?? 6.0,
        maskAlpha: (m['maskAlpha'] as num?)?.toDouble() ?? 0.25,
        lightFont: (m['lightFont'] as bool?) ?? true,
      );
    } catch (_) {
      return const CustomThemeConfig();
    }
  }
}

/// Complete exact palette specification for all 21+1 Share v3.9.6 themes.
class ShareThemePreset {
  final String key;
  final String name;
  final Color themeColor;
  final Color themeDarkColor;
  final Color accent;
  final Color windowBg;
  final Color mainBg;
  final Color cardBg;
  final Color repostBg;
  final Color divider;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final bool dark;
  final bool pureBlack;
  final bool isLightTheme; // white / white_blue have white toolbar by design
  final bool isTransparent;
  final bool isCustom;

  const ShareThemePreset({
    required this.key,
    required this.name,
    required this.themeColor,
    required this.themeDarkColor,
    required this.accent,
    this.windowBg = const Color(0xFFF2F2F5),
    this.mainBg = const Color(0xFFFFFFFF),
    this.cardBg = const Color(0xFFFFFFFF),
    this.repostBg = const Color(0xFFF5F5F8),
    this.divider = const Color(0xFFECECF0),
    this.textPrimary = const Color(0xFF222226),
    this.textSecondary = const Color(0xFF8A8A93),
    this.textTertiary = const Color(0xFFA0A0A8),
    this.dark = false,
    this.pureBlack = false,
    this.isLightTheme = false,
    this.isTransparent = false,
    this.isCustom = false,
  });

  /// Ordered list of the 21 visible theme rows in `ThemeListActivity` (`C0465Kk`)
  /// plus the hidden `night_green_black` (`ShareAppTheme_GreenBlack`) style.
  static const all = <ShareThemePreset>[
    ShareThemePreset(
      key: 'transparent',
      name: '透明',
      themeColor: Color(0xFF3F51B5),
      themeDarkColor: Color(0xFF00796B),
      accent: Color(0xFFFD5523),
      windowBg: Colors.transparent,
      mainBg: Color(0x33FFFFFF),
      cardBg: Color(0x28FFFFFF),
      repostBg: Color(0x22FFFFFF),
      divider: Color(0x16000000),
      textPrimary: Color(0xFFFFFFFF),
      textSecondary: Color(0xFFEEEEEE),
      textTertiary: Color(0xFFDDDDDD),
      isTransparent: true,
    ),
    ShareThemePreset(
      key: 'custom',
      name: '自定义',
      themeColor: Color(0xFF607D8B),
      themeDarkColor: Color(0xFF455A64),
      accent: Color(0xFFFF6826),
      isCustom: true,
    ),
    ShareThemePreset(
      key: 'elegant_purple',
      name: '淡雅紫',
      themeColor: Color(0xFFB693AE),
      themeDarkColor: Color(0xFF666BB3),
      accent: Color(0xFFDDA5AD),
    ),
    ShareThemePreset(
      key: 'green',
      name: '小草绿',
      themeColor: Color(0xFF50BBA7),
      themeDarkColor: Color(0xFF309887),
      accent: Color(0xFFE27866),
    ),
    ShareThemePreset(
      key: 'night_blue',
      name: '夜间蓝',
      themeColor: Color(0xFF263238),
      themeDarkColor: Color(0xFF212C30),
      accent: Color(0xFF208FB9),
      windowBg: Color(0xFF212B30),
      mainBg: Color(0xFF37474F),
      cardBg: Color(0xFF314047),
      repostBg: Color(0xFF2B3940),
      divider: Color(0xFF232E33),
      textPrimary: Color(0xFFE5E7E8),
      textSecondary: Color(0xFFA3ABAE),
      textTertiary: Color(0xFF798F97),
      dark: true,
    ),
    ShareThemePreset(
      key: 'night',
      name: '夜间黑',
      themeColor: Color(0xFF212121),
      themeDarkColor: Color(0xFF000000),
      accent: Color(0xFF009688),
      windowBg: Color(0xFF212121),
      mainBg: Color(0xFF181818),
      cardBg: Color(0xFF303030),
      repostBg: Color(0xFF282828),
      divider: Color(0xFF202020),
      textPrimary: Color(0xFFFFFFFF),
      textSecondary: Color(0xFFCCCCCC),
      textTertiary: Color(0xFF888888),
      dark: true,
    ),
    ShareThemePreset(
      key: 'white',
      name: '今夜白',
      themeColor: Color(0xFFFFFFFF),
      themeDarkColor: Color(0xFFFFFFFF),
      accent: Color(0xFF15C6B5),
      textPrimary: Color(0xFF333333),
      isLightTheme: true,
    ),
    ShareThemePreset(
      key: 'light_blue',
      name: '天空蓝',
      themeColor: Color(0xFF638CCC),
      themeDarkColor: Color(0xFF537BBA),
      accent: Color(0xFFF38393),
    ),
    ShareThemePreset(
      key: 'pink',
      name: '少女粉',
      themeColor: Color(0xFFFB7299),
      themeDarkColor: Color(0xFFD66182),
      accent: Color(0xFF859CA3),
    ),
    ShareThemePreset(
      key: 'grey',
      name: '低调灰',
      themeColor: Color(0xFF607D8B),
      themeDarkColor: Color(0xFF4C748A),
      accent: Color(0xFFF9AA33),
    ),
    ShareThemePreset(
      key: 'dark_red',
      name: '暗影红',
      themeColor: Color(0xFFBE3144),
      themeDarkColor: Color(0xFF872341),
      accent: Color(0xFFBE3144),
    ),
    ShareThemePreset(
      key: 'blue',
      name: '知乎蓝',
      themeColor: Color(0xFF2196F3),
      themeDarkColor: Color(0xFF1976D2),
      accent: Color(0xFF916FFF),
    ),
    ShareThemePreset(
      key: 'teal',
      name: '水鸭青',
      themeColor: Color(0xFF009688),
      themeDarkColor: Color(0xFF00796B),
      accent: Color(0xFFFD5523),
    ),
    ShareThemePreset(
      key: 'red',
      name: '姨妈红',
      themeColor: Color(0xFFDB4437),
      themeDarkColor: Color(0xFFC53929),
      accent: Color(0xFFDB615B),
    ),
    ShareThemePreset(
      key: 'orange',
      name: '伊藤橙',
      themeColor: Color(0xFFFF9800),
      themeDarkColor: Color(0xFFF57C00),
      accent: Color(0xFFDB7D98),
    ),
    ShareThemePreset(
      key: 'deep_blue',
      name: '绅士蓝',
      themeColor: Color(0xFF3F51B5),
      themeDarkColor: Color(0xFF303F9F),
      accent: Color(0xFFFF4081),
    ),
    ShareThemePreset(
      key: 'purple',
      name: '基佬紫',
      themeColor: Color(0xFF673AB7),
      themeDarkColor: Color(0xFF4925A0),
      accent: Color(0xFF0BC4B1),
    ),
    ShareThemePreset(
      key: 'brown',
      name: '古铜棕',
      themeColor: Color(0xFF9C6D5C),
      themeDarkColor: Color(0xFFA2624F),
      accent: Color(0xFF3B4B77),
    ),
    ShareThemePreset(
      key: 'black',
      name: '嘿嘿嘿',
      themeColor: Color(0xFF212121),
      themeDarkColor: Color(0xFF000000),
      accent: Color(0xFF000000),
    ),
    ShareThemePreset(
      key: 'amoled',
      name: 'A屏黑',
      themeColor: Color(0xFF000000),
      themeDarkColor: Color(0xFF000000),
      accent: Color(0xFF009688),
      windowBg: Color(0xFF000000),
      mainBg: Color(0xFF000000),
      cardBg: Color(0xFF000000),
      repostBg: Color(0xFF212121),
      divider: Color(0xFF202020),
      textPrimary: Color(0xFFFFFFFF),
      textSecondary: Color(0xFFCCCCCC),
      textTertiary: Color(0xFF888888),
      dark: true,
      pureBlack: true,
    ),
    ShareThemePreset(
      key: 'white_blue',
      name: '微博蓝',
      themeColor: Color(0xFFFFFFFF),
      themeDarkColor: Color(0xFFFFFFFF),
      accent: Color(0xFF5F88BA),
      textPrimary: Color(0xFF333333),
      isLightTheme: true,
    ),
    ShareThemePreset(
      key: 'night_green_black',
      name: '青黑夜',
      themeColor: Color(0xFF00BCD4),
      themeDarkColor: Color(0xFF00ADB5),
      accent: Color(0xFFEEFD54),
      windowBg: Color(0xFF212B30),
      mainBg: Color(0xFF37474F),
      cardBg: Color(0xFF314047),
      repostBg: Color(0xFF2B3940),
      divider: Color(0xFF232E33),
      textPrimary: Color(0xFFE5E7E8),
      textSecondary: Color(0xFFA3ABAE),
      textTertiary: Color(0xFF798F97),
      dark: true,
    ),
  ];

  static ShareThemePreset byKey(String key) {
    final normalized = switch (key) {
      'default' => 'elegant_purple',
      'nightblue' => 'night_blue',
      _ => key,
    };
    return all.firstWhere(
      (e) => e.key == normalized,
      orElse: () => all.firstWhere((e) => e.key == 'elegant_purple'),
    );
  }
}

/// Persisted user preferences mirroring Share v3.9.6 `SharedPreferences`.
class AppSettings {
  final String themeKey;
  final bool followSystemDark;
  final bool showSource;
  final bool showVerified;
  final bool confirmBeforeExit;
  final bool vibrateOnLike;
  final CustomThemeConfig customTheme;
  final Map<String, Object?> prefs;

  const AppSettings({
    this.themeKey = 'elegant_purple',
    this.followSystemDark = false,
    this.showSource = true,
    this.showVerified = true,
    this.confirmBeforeExit = true,
    this.vibrateOnLike = true,
    this.customTheme = const CustomThemeConfig(),
    this.prefs = const <String, Object?>{},
  });

  static const _prefix = 'prefs_';

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    final prefs = <String, Object?>{};

    for (final entry in prefIndex.entries) {
      final item = entry.value;
      final key = '$_prefix${entry.key}';
      switch (item.kind) {
        case PrefKind.toggle:
          final v = p.getBool(key);
          if (v != null) prefs[entry.key] = v;
        case PrefKind.choice:
        case PrefKind.slider:
          final v = p.get(key);
          if (v is int) {
            prefs[entry.key] = v;
          } else if (v is double) {
            prefs[entry.key] = v.round();
          } else if (v is String) {
            final parsed = int.tryParse(v);
            if (parsed != null) prefs[entry.key] = parsed;
          }
        case PrefKind.multi:
          final v = p.getStringList(key);
          if (v != null) {
            prefs[entry.key] = v.map(int.tryParse).whereType<int>().toList();
          }
        case PrefKind.nav:
          break;
      }
    }

    for (final extraListKey in const [
      'block_keywords',
      'drawer_menu_order',
      'drawer_menu_hidden',
    ]) {
      final val = p.getStringList('$_prefix$extraListKey');
      if (val != null) prefs[extraListKey] = val;
    }
    for (final extraBoolKey in const [
      'accent_color_theme',
      'tool_bar_color_theme',
      'is_developer_unlocked',
      'theme_transparent_font_color',
    ]) {
      final val = p.getBool('$_prefix$extraBoolKey');
      if (val != null) prefs[extraBoolKey] = val;
    }
    for (final extraStrKey in const [
      'theme_custom_value',
      'auto_night_mode_duration',
      'publish_source',
      'save_photo_path',
    ]) {
      final val = p.getString('$_prefix$extraStrKey');
      if (val != null) prefs[extraStrKey] = val;
    }

    return AppSettings(
      themeKey: p.getString('${_prefix}theme') ?? 'elegant_purple',
      followSystemDark: p.getBool('${_prefix}follow_system_dark') ?? false,
      showSource: p.getBool('${_prefix}show_source') ?? true,
      showVerified: p.getBool('${_prefix}show_verified') ?? true,
      confirmBeforeExit: p.getBool('${_prefix}confirm_exit') ?? true,
      vibrateOnLike: p.getBool('${_prefix}vibrate_like') ?? true,
      customTheme: CustomThemeConfig.fromJsonString(
        p.getString('${_prefix}theme_custom_value'),
      ),
      prefs: prefs,
    );
  }

  Object? pref(String key) {
    if (prefs.containsKey(key)) return prefs[key];
    return prefIndex[key]?.defaultValue;
  }

  bool flag(String key) => pref(key) is bool ? pref(key)! as bool : false;

  int choiceOf(String key) {
    final v = pref(key);
    if (v is int) return v;
    if (v is num) return v.round();
    return 0;
  }

  List<int> multiOf(String key) {
    final v = pref(key);
    if (v is List<int>) return v;
    if (v is List) return v.whereType<int>().toList();
    return const [];
  }

  List<String> stringListOf(String key, [List<String> fallback = const []]) {
    final v = prefs[key];
    if (v is List<String>) return v;
    if (v is List) return v.whereType<String>().toList();
    return fallback;
  }

  List<String> get hiddenKeywords => stringListOf('block_keywords');

  // -- Theme flags & resolution ---------------------------------------------

  bool get accentColorFollowTheme => flag('accent_color_theme');
  bool get toolBarColorTheme => flag('tool_bar_color_theme');
  bool get developerUnlocked => flag('is_developer_unlocked');
  bool get transparentWhiteFont =>
      prefs['theme_transparent_font_color'] as bool? ?? customTheme.lightFont;

  bool get autoNight => flag('auto_night_mode');
  bool get nightFollowSystem => flag('auto_night_mode_follow_system');
  String get autoNightDuration =>
      (prefs['auto_night_mode_duration'] as String?) ?? '22:00-07:00';

  String get nightThemeKey => switch (choiceOf('night_theme')) {
        1 => 'night',
        2 => 'amoled',
        4 => 'night_green_black',
        _ => 'night_blue',
      };

  ShareThemePreset effectivePreset(Brightness platformBrightness) {
    final base = ShareThemePreset.byKey(themeKey);
    if (base.dark) return base;
    if ((followSystemDark || nightFollowSystem) &&
        platformBrightness == Brightness.dark) {
      return ShareThemePreset.byKey(nightThemeKey);
    }
    if (autoNight && _isInNightWindow(autoNightDuration)) {
      return ShareThemePreset.byKey(nightThemeKey);
    }
    return base;
  }

  // -- Reading / Typography (`xml/q.xml` & `xml/o.xml`) ----------------------

  double get fontSize => choiceOf('font_size').clamp(12, 26).toDouble();
  double get lineSpacing =>
      (1.22 + choiceOf('font_spacing_value') / 220).clamp(1.22, 1.72);

  int get avatarStyle => choiceOf('avatar_style');
  double get avatarRadius => switch (avatarStyle) {
        1 => 0,
        2 => 6,
        _ => 100,
      };

  bool get cardStyle => flag('show_status_card');
  bool get cardBackground => flag('show_status_card_background');
  bool get cardDivider => flag('show_status_card_divider');
  bool get leftIndent => flag('show_status_space');
  bool get nameIcon => flag('status_icon_show');
  bool get nameBold => flag('status_name_bold');
  bool get nameAccent => flag('status_name_theme');
  bool get nameWithRemark => flag('status_origin_name_show');
  bool get showOptions => flag('show_status_options');
  bool get showCollect => flag('show_status_collect_btn');

  // -- Images / Traffic (`xml/j.xml`) ---------------------------------------

  int get imageQuality => choiceOf('download_image_quality');
  bool get loadImageOnMobile => imageQuality != 1;
  bool get saveImageOriginal => flag('save_image_original');

  int? get uploadCompression => switch (choiceOf('photo_upload_quality')) {
        1 => 85,
        2 => null,
        _ => 92,
      };

  bool get nightShade => flag('night_shade_mode');

  // -- Feed & Layout (`xml/k.xml`, `xml/n.xml`, `xml/i.xml`) -----------------

  int get feedPageSize => switch (choiceOf('load_status_count')) {
        2 => 30,
        3 => 50,
        4 => 88,
        5 => 100,
        _ => 20,
      };

  bool get preread => flag('preread');
  bool get reselectRefresh => flag('reselect_tab_refresh');
  bool get hotCommentPreview => flag('hot_status_comment_preview');
  bool get commentFloor => flag('comment_floor');
  bool get commentByTime => flag('comment_sort_by_time');
  bool get likeLongPress => flag('like_status_long_click');
  bool get fastScroll => flag('fast_scroll_indicator');
  bool get navHideOnScroll => flag('navigation_hide_on_scroll');
  bool get toolbarFixOnScroll => flag('toolbar_fix_on_scroll');
  bool get navigationThemeColor => flag('navigation_theme_color');
  int get navigationPosition => choiceOf('navigation_position') == 3 ? 3 : 2;
  bool get showDrawerFromLeft => flag('show_drawer_from_left');
  bool get showFabFromLeft => flag('show_fab_from_left');
  int get drawerCoverType => choiceOf('drawer_cover_type');
  int get swipeBackMode => choiceOf('swipe_back');
  int get launcherIconIndex => choiceOf('ic_launcher');

  bool get hideHotTab => flag('hide_hot_tab');
  bool get hideHotSearch => flag('hide_hot_search');
  bool get hideOftenVisit => flag('hide_often_visit');
  bool get samePhotoName => flag('same_photo_name');
  bool get hotSearchTag => flag('hot_search_tag');
  bool get statusTranslation => flag('status_translation');
  String get translationLocale => switch (choiceOf('status_translation_default')) {
        1 => 'zh',
        3 => 'ja',
        4 => 'ko',
        _ => 'en',
      };
  bool get hideStatusAvatar => multiOf('show_avatar').contains(1);
  bool get hideCommentAvatar => multiOf('show_avatar').contains(2);

  int get fabOption => choiceOf('fab_options');
  bool get statusDetailTabScroll => flag('status_detail_tab_scroll');

  static const defaultDrawerOrder = <String>[
    'home',
    'hot',
    'friends',
    'topic',
    'search',
    'favorites',
    'drafts',
    'message',
    'dm',
    'groups',
    'blacklist',
    'history',
    'theme',
    'settings',
  ];

  List<String> get drawerMenuOrder =>
      stringListOf('drawer_menu_order', defaultDrawerOrder);

  Set<String> get drawerHiddenKeys =>
      stringListOf('drawer_menu_hidden').toSet();

  // -- Messaging / Lab / Privacy --------------------------------------------

  bool get dmEnterToSend => flag('direct_message_enter');
  bool get newDm2Mode => flag('new_dm_2_mode');
  List<int> get redDotTypes => multiOf('remind_unread_type');
  bool get webviewNight => flag('webview_night');
  bool get browserHttps => flag('browser_https');
  bool get textBoom => flag('text_boom');
  bool get soundOff => flag('sound_off');
  bool get directRepost => flag('direct_repost');

  String get publishTail => (prefs['publish_source'] as String?) ?? '';

  static String formatPublishTailLabel(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '默认 (Share)';
    if (trimmed == 'intl' || trimmed == '4215535043') return '微博国际版 (Weibo.intl)';
    if (trimmed == 'weico' || trimmed == '211160679') return 'Weico客户端';
    if (trimmed == 'none' || trimmed == '-1') return '不显示';
    return trimmed;
  }

  AppSettings copyWith({
    String? themeKey,
    bool? followSystemDark,
    bool? showSource,
    bool? showVerified,
    bool? confirmBeforeExit,
    bool? vibrateOnLike,
    CustomThemeConfig? customTheme,
    Map<String, Object?>? prefs,
  }) {
    return AppSettings(
      themeKey: themeKey ?? this.themeKey,
      followSystemDark: followSystemDark ?? this.followSystemDark,
      showSource: showSource ?? this.showSource,
      showVerified: showVerified ?? this.showVerified,
      confirmBeforeExit: confirmBeforeExit ?? this.confirmBeforeExit,
      vibrateOnLike: vibrateOnLike ?? this.vibrateOnLike,
      customTheme: customTheme ?? this.customTheme,
      prefs: prefs ?? this.prefs,
    );
  }

  static bool _isInNightWindow(String range) {
    final parts = range.split('-');
    if (parts.length != 2) return false;
    final startMin = _parseMinutes(parts[0]);
    final endMin = _parseMinutes(parts[1]);
    if (startMin == null || endMin == null) return false;
    final now = DateTime.now();
    final cur = now.hour * 60 + now.minute;
    if (startMin <= endMin) {
      return cur >= startMin && cur < endMin;
    }
    return cur >= startMin || cur < endMin;
  }

  static int? _parseMinutes(String hhmm) {
    final p = hhmm.trim().split(':');
    if (p.length != 2) return null;
    final h = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }
}

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier(super.initial);

  void setTheme(String key) {
    state = state.copyWith(themeKey: key);
    _persist('theme', key);
  }

  void setCustomTheme(CustomThemeConfig config) {
    final jsonStr = jsonEncode(config.toJson());
    final next = Map<String, Object?>.from(state.prefs);
    next['theme_custom_value'] = jsonStr;
    next['theme_transparent_font_color'] = config.lightFont;
    state = state.copyWith(customTheme: config, prefs: next);
    _persist('theme_custom_value', jsonStr);
    _persist('theme_transparent_font_color', config.lightFont);
  }

  void setFollowSystemDark(bool value) {
    state = state.copyWith(followSystemDark: value);
    _persist('follow_system_dark', value);
    setPref('auto_night_mode_follow_system', value);
  }

  void setFontSize(double value) => setPref('font_size', value.round());

  void setShowSource(bool value) {
    state = state.copyWith(showSource: value);
    _persist('show_source', value);
  }

  void setShowVerified(bool value) {
    state = state.copyWith(showVerified: value);
    _persist('show_verified', value);
  }

  void setConfirmBeforeExit(bool value) {
    state = state.copyWith(confirmBeforeExit: value);
    _persist('confirm_exit', value);
  }

  void setVibrateOnLike(bool value) {
    state = state.copyWith(vibrateOnLike: value);
    _persist('vibrate_like', value);
  }

  void setPref(String key, Object value) {
    final next = Map<String, Object?>.from(state.prefs);
    next[key] = value;
    state = state.copyWith(prefs: next);
    _persist(key, value);

    if (key == 'vibration_feedback' && value is bool) {
      state = state.copyWith(vibrateOnLike: value);
    }
    if (key == 'night_theme' && value is int) {
      if (ShareThemePreset.byKey(state.themeKey).dark) {
        setTheme(state.nightThemeKey);
      }
    }
  }

  void toggleThemeDark(bool dark) {
    if (dark) {
      setTheme(state.nightThemeKey);
    } else {
      setTheme('elegant_purple');
    }
  }

  Future<void> _persist(String key, Object value) async {
    final p = await SharedPreferences.getInstance();
    final k = '${AppSettings._prefix}$key';
    if (value is bool) {
      await p.setBool(k, value);
    } else if (value is int) {
      await p.setInt(k, value);
    } else if (value is double) {
      await p.setDouble(k, value);
    } else if (value is String) {
      await p.setString(k, value);
    } else if (value is List<int>) {
      await p.setStringList(k, value.map((e) => '$e').toList());
    } else if (value is List<String>) {
      await p.setStringList(k, value);
    }
  }
}

late AppSettings initialSettings;

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>(
        (ref) => SettingsNotifier(initialSettings));
