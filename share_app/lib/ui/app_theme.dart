import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/settings.dart';
import 'common/swipe_back_wrapper.dart';

/// Dynamic Share (v3.9.6) theme token registry (`C5361oOoOooO` + `styles.xml`).
class ShareColors {
  static Color themeColor = const Color(0xFFB693AE);
  static Color themeDarkColor = const Color(0xFF666BB3);
  static Color accent = const Color(0xFFDDA5AD);
  static Color accentPressed = const Color(0xFFCC9099);

  static Color toolbarBg = const Color(0xFFFFFFFF);
  static Color toolbarFg = const Color(0xFF525252);

  static Color pageBg = const Color(0xFFF2F2F5);
  static Color mainBg = const Color(0xFFFFFFFF);
  static Color cardBg = const Color(0xFFFFFFFF);
  static Color divider = const Color(0xFFECECF0);

  static Color textPrimary = const Color(0xFF222226);
  static Color textSecondary = const Color(0xFF8A8A93);
  static Color textHint = const Color(0xFFA0A0A8);
  static Color link = const Color(0xFF507DAF);

  static Color repostBg = const Color(0xFFF5F5F8);
  static Color line = const Color(0xFFECECF0);
  static Color inputBg = const Color(0xFFF4F5F7);
  static Color placeholder = const Color(0xFFEFEFF4);

  static bool isDark = false;
  static bool isTransparent = false;
  static bool nightShade = false;

  static void apply(
    ShareThemePreset preset, {
    AppSettings? settings,
  }) {
    final accentFollowsTheme = settings?.accentColorFollowTheme ?? false;
    final toolbarFollowsTheme = settings?.toolBarColorTheme ?? false;
    final custom = settings?.customTheme ?? const CustomThemeConfig();
    nightShade = settings?.nightShade ?? false;
    isDark = preset.dark;
    isTransparent = preset.isTransparent;

    if (preset.isCustom) {
      themeColor = custom.primaryColor;
      themeDarkColor = Color.lerp(custom.primaryColor, Colors.black, 0.22)!;
      accent = accentFollowsTheme ? custom.primaryColor : custom.accentColor;
    } else if (preset.isTransparent) {
      themeColor = custom.primaryColor;
      themeDarkColor = preset.themeDarkColor;
      accent = accentFollowsTheme ? custom.primaryColor : custom.accentColor;
    } else {
      themeColor = preset.themeColor;
      themeDarkColor = preset.themeDarkColor;
      accent = (!preset.dark && !preset.isLightTheme && accentFollowsTheme)
          ? preset.themeColor
          : preset.accent;
    }
    accentPressed = accent.withValues(alpha: 0.85);

    if (preset.isTransparent) {
      final whiteFont = settings?.transparentWhiteFont ?? custom.lightFont;
      pageBg = Colors.transparent;
      mainBg = whiteFont ? const Color(0x33FFFFFF) : const Color(0x88FFFFFF);
      cardBg = whiteFont ? const Color(0x28000000) : const Color(0xCCFFFFFF);
      repostBg = whiteFont ? const Color(0x33000000) : const Color(0x22000000);
      divider = const Color(0x16000000);
      textPrimary = whiteFont ? const Color(0xFFFFFFFF) : const Color(0xFF333333);
      textSecondary = whiteFont ? const Color(0xFFEEEEEE) : const Color(0xCC000000);
      textHint = whiteFont ? const Color(0xFFDDDDDD) : const Color(0xFF666666);
      link = accent;
      line = divider;
      inputBg = whiteFont ? const Color(0x22FFFFFF) : const Color(0x16000000);
      placeholder = inputBg;
      toolbarBg = Colors.transparent;
      toolbarFg = textPrimary;
      return;
    }

    pageBg = preset.windowBg;
    mainBg = preset.mainBg;
    cardBg = preset.cardBg;
    repostBg = preset.repostBg;
    divider = preset.divider;
    textPrimary = preset.textPrimary;
    textSecondary = preset.textSecondary;
    textHint = preset.textTertiary;

    if (preset.dark) {
      link = preset.key == 'night_blue' || preset.key == 'night_green_black'
          ? preset.accent
          : const Color(0xFF7FA6CC);
      line = const Color(0xFF2C2C2E);
      inputBg = const Color(0xFF252527);
      placeholder = const Color(0xFF2A2A2C);
      toolbarBg = preset.cardBg;
      toolbarFg = preset.textPrimary;
    } else {
      link = accentFollowsTheme ? themeColor : const Color(0xFF507DAF);
      line = const Color(0xFFE6E6E6);
      inputBg = const Color(0xFFF4F5F7);
      placeholder = const Color(0xFFEFEFEF);

      final coloredToolbar = toolbarFollowsTheme &&
          !preset.isLightTheme &&
          preset.key != 'white' &&
          preset.key != 'white_blue';
      toolbarBg = coloredToolbar ? themeColor : const Color(0xFFFFFFFF);
      toolbarFg = coloredToolbar ? const Color(0xFFFFFFFF) : const Color(0xFF525252);
    }
  }

  /// Applies `night_shade_mode` image dimming when night theme is active.
  static ColorFilter? get activeImageFilter => (isDark && nightShade)
      ? const ColorFilter.mode(Color(0x55000000), BlendMode.darken)
      : null;
}

class ShareTheme {
  static ThemeData build(
    ShareThemePreset preset, {
    AppSettings? settings,
  }) {
    ShareColors.apply(preset, settings: settings);
    final isDark = preset.dark;
    final toolbarIsDark = ShareColors.toolbarBg.computeLuminance() < 0.45;

    final base = ThemeData(
      useMaterial3: true,
      brightness: isDark ? Brightness.dark : Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: ShareColors.themeColor,
        primary: ShareColors.accent,
        brightness: isDark ? Brightness.dark : Brightness.light,
        surface: ShareColors.cardBg,
      ),
      scaffoldBackgroundColor:
          preset.isTransparent ? Colors.transparent : ShareColors.pageBg,
      cardColor: ShareColors.cardBg,
      dividerColor: ShareColors.divider,
      splashFactory: InkRipple.splashFactory,
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {
          for (final platform in TargetPlatform.values)
            platform: ShareSwipeBackPageTransitionsBuilder(
              platform: platform,
              fallbackSwipeBackMode: settings?.swipeBackMode ?? 3,
            ),
        },
      ),
    );

    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: ShareColors.toolbarBg,
        foregroundColor: ShareColors.toolbarFg,
        iconTheme: IconThemeData(color: ShareColors.toolbarFg, size: 22),
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 52,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness:
              (isDark || toolbarIsDark) ? Brightness.light : Brightness.dark,
          statusBarBrightness:
              (isDark || toolbarIsDark) ? Brightness.dark : Brightness.light,
        ),
        titleTextStyle: TextStyle(
          color: ShareColors.toolbarFg,
          fontSize: 17,
          fontWeight: FontWeight.w500,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: ShareColors.divider,
        thickness: 0.5,
        space: 0.5,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: ShareColors.accent,
        foregroundColor: ShareColors.accent.computeLuminance() > 0.65
            ? const Color(0xFF181818)
            : Colors.white,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: ShareColors.textPrimary,
        displayColor: ShareColors.textPrimary,
      ),
      iconTheme: IconThemeData(color: ShareColors.textPrimary, size: 22),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return ShareColors.accent;
          return null;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return ShareColors.accent.withValues(alpha: 0.45);
          }
          return null;
        }),
      ),
    );
  }
}
