import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings.dart';
import '../app_theme.dart';
import '../common/in_app_web_page.dart';

/// 1:1 复刻原版 `SettingAboutActivity` (`C0512Mb`)：
/// 连点 3 次版本号解锁隐藏实验室模式、捐赠对话框 (支付宝链接)、使用手册、历史版本、协议许可。
class AboutPage extends ConsumerStatefulWidget {
  const AboutPage({super.key});

  static const _version = '3.9.6';
  static const _buildCode = 'Build 925 · Flutter + Rust';
  static const _alipayDonateUrl =
      'https://qr.alipay.com/FKX01024C3AP041QWPDF7A';

  @override
  ConsumerState<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends ConsumerState<AboutPage> {
  int _versionTapCount = 0;

  void _onTapVersion() {
    _versionTapCount += 1;
    if (_versionTapCount >= 3) {
      _versionTapCount = 0;
      final unlocked = !ref.read(settingsProvider).developerUnlocked;
      ref.read(settingsProvider.notifier).setPref('is_developer_unlocked', unlocked);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            unlocked ? '已解锁隐藏实验室与高级样式开关！' : '已关闭隐藏开发者功能',
          ),
        ),
      );
    }
  }

  void _showDonateDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('捐赠支持原版与开源致谢'),
        content: const Text(
          '原版 Share 开发者捐赠链接：\n${AboutPage._alipayDonateUrl}\n\n可点击复制或通过浏览器打开原版支付宝打赏页。',
          style: TextStyle(fontSize: 13.5, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(const ClipboardData(text: AboutPage._alipayDonateUrl));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制捐赠链接')),
              );
            },
            child: const Text('复制链接'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _openWeb(context, AboutPage._alipayDonateUrl, '捐赠');
            },
            child: const Text('打开页面'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final unlocked = ref.watch(settingsProvider).developerUnlocked;

    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        children: [
          Container(
            color: ShareColors.cardBg,
            padding: const EdgeInsets.fromLTRB(16, 28, 16, 24),
            child: Column(
              children: [
                Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    color: ShareColors.themeColor,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Center(
                    child: Text(
                      'S',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 38,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Share',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: ShareColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'v${AboutPage._version} · ${AboutPage._buildCode}',
                  style: TextStyle(fontSize: 12, color: ShareColors.textSecondary),
                ),
                if (unlocked) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: ShareColors.accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '开发者/隐藏功能已解锁',
                      style: TextStyle(fontSize: 11, color: ShareColors.accent),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          _group([
            _row(
              context,
              Icons.verified_outlined,
              '版本号',
              _onTapVersion,
              trailing: '${AboutPage._version} (连点3次)',
            ),
            _row(
              context,
              Icons.menu_book_outlined,
              '使用手册',
              () => _openWeb(context, 'https://github.com/aaaddress1/Share', '使用手册'),
            ),
            _row(
              context,
              Icons.history_outlined,
              '历史版本',
              () => showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Share 版本演进'),
                  content: const Text(
                    '• v3.9.6 (Build 925): 原版最终稳定版\n'
                    '• Flutter + Rust 双协议重构版：完整还原 21+1 套主题、177 离线表情、SQLite 9 表、libwbutil + RSA-1024 移动接口与 Web Ajax 自动切换。',
                    style: TextStyle(fontSize: 13, height: 1.6),
                  ),
                  actions: [
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('知道了'),
                    ),
                  ],
                ),
              ),
            ),
            _row(context, Icons.favorite_border, '捐赠开发者', _showDonateDialog),
          ]),
          const SizedBox(height: 10),
          _group([
            _row(
              context,
              Icons.description_outlined,
              '用户协议',
              () => _openWeb(context, 'https://weibo.com/signup/v5/protocol', '用户协议'),
            ),
            _row(
              context,
              Icons.privacy_tip_outlined,
              '隐私政策',
              () => _openWeb(context, 'https://weibo.com/signup/v5/privacy', '隐私政策'),
            ),
            _row(context, Icons.code, '开源许可', () {
              showLicensePage(
                context: context,
                applicationName: 'Share',
                applicationVersion: 'v${AboutPage._version}',
                applicationLegalese: 'Flutter + Rust 1:1 跨平台重构 (Android / iOS)',
              );
            }),
          ]),
          const SizedBox(height: 10),
          _group([
            _row(context, Icons.cloud_outlined, '协议栈', null,
                trailing: 'api.weibo.cn/2 + weibo.com/ajax'),
            _row(context, Icons.storage_outlined, '本地引擎', null,
                trailing: 'Rust SQLite 9 表 + WeSync Codec'),
          ]),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 30),
            child: Text(
              '本应用基于原版 Share v3.9.6 1:1 跨平台复刻（支持 Android 与 iOS），'
              '所有密码学签名与账号会话仅在本机运行，不经过任何第三方服务器。',
              style: TextStyle(fontSize: 11.5, height: 1.6, color: ShareColors.textHint),
            ),
          ),
        ],
      ),
    );
  }

  Widget _group(List<Widget> children) {
    return Material(
      color: ShareColors.cardBg,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 0.5, indent: 52, color: ShareColors.divider),
            children[i],
          ],
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    IconData icon,
    String title,
    VoidCallback? onTap, {
    String? trailing,
  }) {
    return ListTile(
      leading: Icon(icon, size: 20, color: ShareColors.textSecondary),
      title: Text(title, style: const TextStyle(fontSize: 15)),
      trailing: trailing != null
          ? Text(trailing, style: TextStyle(fontSize: 12.5, color: ShareColors.textHint))
          : (onTap != null ? Icon(Icons.chevron_right, color: ShareColors.textHint) : null),
      onTap: onTap,
    );
  }

  void _openWeb(BuildContext context, String url, String title) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => InAppWebPage(url: url, title: title)),
    );
  }
}
