import 'package:flutter/material.dart';

import '../../core/deep_link.dart';
import '../../core/share_core.dart';
import '../app_theme.dart';
import '../common/in_app_web_page.dart';
import '../profile/user_page.dart';

/// 1:1 复刻 `QRCodeScanActivity`（二维码链接确认 PC 登录 + 微博短链/主页解析）。
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final _urlCtrl = TextEditingController();
  bool _busy = false;
  String? _status;

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      if (url.startsWith('https://passport.weibo.cn/signin/qrcode/scan')) {
        await ShareCore.instance.qrConfirm(qrUrl: url);
        if (!mounted) return;
        setState(() {
          _busy = false;
          _status = '网页/桌面端扫码登录确认成功';
        });
        return;
      }

      if (url.contains('t.cn/')) {
        final expanded = await ShareCore.instance.shortUrlExpand(url);
        if (!mounted) return;
        final longUrl = expanded['urls'] is List && (expanded['urls'] as List).isNotEmpty
            ? '${(expanded['urls'] as List).first['url_long'] ?? url}'
            : url;
        setState(() {
          _busy = false;
          _status = '短链还原：$longUrl';
        });
        _openParsed(longUrl);
        return;
      }

      setState(() => _busy = false);
      _openParsed(url);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '处理失败：$e';
      });
    }
  }

  void _openParsed(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return;
    final target = DeepLinkTarget.parse(uri);
    if (target != null && target.kind == DeepLinkKind.user) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => UserPage(uid: target.value)),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => InAppWebPage(url: raw, title: '扫码内容')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫码登录与链接解析')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '粘贴 `https://passport.weibo.cn/signin/qrcode/scan?...` 二维码内容即可用当前已登录账号确认网页端扫码登录；也支持粘贴 `t.cn` 短链与微博个人主页二维码链接。',
            style: TextStyle(fontSize: 13, height: 1.5, color: ShareColors.textSecondary),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _urlCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '二维码链接 / t.cn 短链',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 46,
            child: FilledButton.icon(
              onPressed: _busy ? null : _handleUrl,
              icon: const Icon(Icons.qr_code_2),
              label: Text(_busy ? '执行中…' : '确认登录 / 打开链接'),
            ),
          ),
          if (_status != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: ShareColors.repostBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_status!, style: const TextStyle(fontSize: 13.5)),
            ),
          ],
        ],
      ),
    );
  }
}
