import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'core/api.dart';
import 'core/settings.dart';
import 'core/share_core.dart';
import 'src/rust/frb_generated.dart';
import 'ui/app_theme.dart';
import 'ui/bootstrap_gate.dart';
import 'ui/deep_link_listener.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await RustLib.init();

  final supportDir = await getApplicationSupportDirectory();
  await WeiboApi.instance.init(supportDir.path);
  try {
    await ShareCore.instance.init(customDataDir: supportDir.path);
  } catch (_) {}

  initialSettings = await AppSettings.load();

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  runApp(const ProviderScope(child: ShareApp()));
}

class ShareApp extends ConsumerWidget {
  const ShareApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final preset = settings.effectivePreset(MediaQuery.platformBrightnessOf(context));
    final theme = ShareTheme.build(preset, settings: settings);

    return MaterialApp(
      title: 'Share',
      debugShowCheckedModeBanner: false,
      theme: theme,
      darkTheme: theme,
      themeMode: preset.dark ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) {
        if (!preset.isTransparent || child == null) {
          return child ?? const SizedBox.shrink();
        }
        final custom = settings.customTheme;
        final imgPath = custom.backgroundImagePath;
        final hasFile = imgPath != null && File(imgPath).existsSync();
        return Stack(
          fit: StackFit.expand,
          children: [
            if (hasFile)
              ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: custom.blurRadius,
                  sigmaY: custom.blurRadius,
                ),
                child: Image.file(File(imgPath), fit: BoxFit.cover),
              )
            else
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      custom.primaryColor,
                      Color.lerp(custom.primaryColor, custom.accentColor, 0.5)!,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: (custom.lightFont ? Colors.black : Colors.white)
                    .withValues(alpha: custom.maskAlpha.clamp(0.05, 0.85)),
              ),
            ),
            child,
          ],
        );
      },
      home: const DeepLinkListener(
        child: BootstrapGate(),
      ),
    );
  }
}
