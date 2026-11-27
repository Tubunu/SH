import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/share_core.dart';
import '../app_theme.dart';
import '../common/in_app_web_page.dart';
import 'qr_scan_page.dart';

/// 1:1 复刻原版完整登录中心 (`WeiboWebAuthorizeActivity` + `WeiboSafetyVerifyActivity` +
/// `WeiboSmsVerifyActivity` + `QRCodeScanActivity` + `OP.java` 游客引导)。
///
/// 支持 5 种入口：
/// 1. 账号密码（RSA-1024 官方协议 + 自动处理图文验证码 / 风控短信二次校验）
/// 2. 短信验证码免密登录（区号选择 + 获取验证码倒计时）
/// 3. WebView 网页授权（Android `CookieManager` / iOS `WKHTTPCookieStore` 原生提取完整 `HttpOnly` Cookie）
/// 4. Cookie 手动粘贴导入（`SUB=...`）
/// 5. 游客免登录先逛逛（`/2/guest/login` 浏览热门与超话）
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  WebViewController? _webController;
  WebViewCookieManager? _cookieManager;

  // Password form
  final _userCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  bool _obscurePwd = true;

  // SMS form
  final _phoneCtrl = TextEditingController();
  final _smsCodeCtrl = TextEditingController();
  String _areaCode = '0086';
  String _smsNumber = '';
  int _smsCountdown = 0;
  Timer? _smsTimer;

  // Manual cookie
  final _cookieCtrl = TextEditingController();

  bool _busy = false;
  bool _webViewReady = false;
  String? _hint;

  static const _loginUrl =
      'https://passport.weibo.com/sso/signin?entry=wapsso&source=wapssowb&url=https%3A%2F%2Fweibo.com%2F';

  static const _areaChoices = <({String code, String label})>[
    (code: '0086', label: '+86 中国大陆'),
    (code: '00852', label: '+852 中国香港'),
    (code: '00853', label: '+853 中国澳门'),
    (code: '00886', label: '+886 中国台湾'),
    (code: '001', label: '+1 北美'),
    (code: '0081', label: '+81 日本'),
    (code: '0082', label: '+82 韩国'),
    (code: '0044', label: '+44 英国'),
  ];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    try {
      _cookieManager = WebViewCookieManager();
      _webController = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.white)
        ..setNavigationDelegate(NavigationDelegate(
          onPageStarted: (_) {
            if (!_webViewReady && mounted) setState(() => _webViewReady = true);
          },
          onPageFinished: (_) => _tryCaptureWebView(silent: true),
          onWebResourceError: (error) {
            if (mounted && error.isForMainFrame == true) {
              setState(() => _hint = '网页加载失败：${error.description}');
            }
          },
        ))
        ..loadRequest(Uri.parse(_loginUrl));
    } catch (_) {
      _webController = null;
      _cookieManager = null;
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    _userCtrl.dispose();
    _pwdCtrl.dispose();
    _phoneCtrl.dispose();
    _smsCodeCtrl.dispose();
    _cookieCtrl.dispose();
    _smsTimer?.cancel();
    super.dispose();
  }

  Future<void> _submitPassword({String? cptId, String? cptCode}) async {
    final u = _userCtrl.text.trim();
    final p = _pwdCtrl.text;
    if (u.isEmpty || p.isEmpty) {
      setState(() => _hint = '请输入微博账号与密码');
      return;
    }
    setState(() {
      _busy = true;
      _hint = null;
    });
    final res = await ref.read(sessionProvider.notifier).loginWithPassword(
          username: u,
          password: p,
          cptId: cptId,
          cptCode: cptCode,
        );
    if (!mounted) return;
    setState(() => _busy = false);

    if (res['status'] == 'ok') {
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      }
      return;
    }

    final raw = jsonMap(res['raw']) ?? const <String, dynamic>{};
    final errno = jsonNullableInt(res['errno']) ??
        jsonNullableInt(raw['errno']) ??
        jsonNullableInt(raw['error_code']);

    // 风控短信二次验证 (phone_list / phone / retcode)
    if (errno == -1005 || errno == 20031 || raw['phone_list'] != null) {
      await _openSafetyVerifyDialog(u, p, raw);
      return;
    }

    // 图形验证码风控
    if (raw['cpt'] != null ||
        ('${res['errmsg'] ?? ''}').contains('验证码') ||
        errno == 100001 ||
        errno == 20016) {
      await _openCaptchaDialog(
        raw['cpt']?.toString(),
        (id, code) => _submitPassword(cptId: id, cptCode: code),
      );
      return;
    }

    setState(() => _hint = '${res['errmsg'] ?? '登录失败，可切换网页授权或短信登录'}');
  }

  Future<void> _openCaptchaDialog(
    String? initialCptId,
    Future<void> Function(String cptId, String code) onSubmit,
  ) async {
    try {
      final cap = await ShareCore.instance.loginCaptchaGet(cptId: initialCptId);
      final cptId = '${cap['cpt'] ?? initialCptId ?? ''}';
      final b64 = '${cap['image'] ?? cap['pic'] ?? ''}';
      final bytes = _decodeBase64Image(b64);
      if (!mounted) return;
      final ctrl = TextEditingController();
      final code = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('输入图形验证码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (bytes != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Image.memory(bytes, height: 56, fit: BoxFit.contain),
                )
              else
                const Text('请输入新浪返回的验证码'),
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(hintText: '验证码'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('验证'),
            ),
          ],
        ),
      );
      ctrl.dispose();
      if (code != null && code.isNotEmpty) {
        await onSubmit(cptId, code);
      }
    } catch (e) {
      if (mounted) setState(() => _hint = '获取验证码失败：$e');
    }
  }

  Future<void> _openSafetyVerifyDialog(
    String username,
    String password,
    Map<String, dynamic> raw,
  ) async {
    final phones = <({String area, String phone, String label})>[];
    final list = raw['phone_list'];
    if (list is List) {
      for (final item in list) {
        if (item is Map) {
          final ph = '${item['phone'] ?? ''}';
          final area = '${item['code'] ?? item['area'] ?? '0086'}';
          final mask = '${item['msg'] ?? item['phone_mask'] ?? ph}';
          if (ph.isNotEmpty) phones.add((area: area, phone: ph, label: mask));
        }
      }
    }
    if (phones.isEmpty && raw['phone'] != null) {
      phones.add((
        area: '${raw['code'] ?? '0086'}',
        phone: '${raw['phone']}',
        label: '${raw['phone']}',
      ));
    }
    final retcode = '${raw['retcode'] ?? ''}';
    if (phones.isEmpty) {
      setState(() => _hint = '当前登录触发微博安全风控，请前往「网页授权」登录');
      return;
    }

    var selected = phones.first;
    final smsCtrl = TextEditingController();
    var sentNumber = '';

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('登录安全验证'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('检测到非常用设备，请选择绑定手机接收短信验证码：',
                  style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                initialValue: 0,
                items: [
                  for (var i = 0; i < phones.length; i++)
                    DropdownMenuItem(value: i, child: Text(phones[i].label)),
                ],
                onChanged: (idx) {
                  if (idx != null) setLocal(() => selected = phones[idx]);
                },
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: smsCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(hintText: '6 位短信验证码'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () async {
                      try {
                        final res = await ShareCore.instance.loginSafetySendSms(
                          phone: selected.phone,
                          area: selected.area,
                          retcode: retcode,
                        );
                        setLocal(() => sentNumber = '${res['number'] ?? ''}');
                      } catch (e) {
                        if (mounted) setState(() => _hint = '发送短信失败：$e');
                      }
                    },
                    child: const Text('发送验证码'),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                final code = smsCtrl.text.trim();
                if (code.isEmpty) return;
                Navigator.pop(ctx);
                final ok = await ref.read(sessionProvider.notifier).completeSmsLogin(
                      phone: selected.phone,
                      area: selected.area,
                      number: sentNumber,
                      code: code,
                      isSmsLogin: false,
                      username: username,
                      password: password,
                      retcode: retcode,
                    );
                if (ok && mounted && Navigator.of(context).canPop()) {
                  Navigator.of(context).pop(true);
                }
              },
              child: const Text('确认登录'),
            ),
          ],
        ),
      ),
    );
    smsCtrl.dispose();
  }

  Future<void> _sendSmsCode() async {
    final phone = _phoneCtrl.text.trim();
    if (phone.isEmpty) {
      setState(() => _hint = '请输入手机号码');
      return;
    }
    setState(() {
      _busy = true;
      _hint = null;
    });
    try {
      final res = await ShareCore.instance.loginSmsSend(phone: phone, area: _areaCode);
      if (!mounted) return;
      setState(() {
        _smsNumber = '${res['number'] ?? ''}';
        _busy = false;
        _smsCountdown = 60;
      });
      _smsTimer?.cancel();
      _smsTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted || _smsCountdown <= 1) {
          t.cancel();
          if (mounted) setState(() => _smsCountdown = 0);
        } else {
          setState(() => _smsCountdown -= 1);
        }
      });
    } catch (e) {
      if (mounted) setState(() => _hint = '发送验证码失败：$e');
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitSmsLogin() async {
    final phone = _phoneCtrl.text.trim();
    final code = _smsCodeCtrl.text.trim();
    if (phone.isEmpty || code.isEmpty) {
      setState(() => _hint = '请输入手机号和短信验证码');
      return;
    }
    setState(() {
      _busy = true;
      _hint = null;
    });
    final ok = await ref.read(sessionProvider.notifier).completeSmsLogin(
          phone: phone,
          area: _areaCode,
          number: _smsNumber,
          code: code,
          isSmsLogin: true,
        );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) _hint = ref.read(sessionProvider).error ?? '短信登录失败';
    });
    if (ok && Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    }
  }

  Future<String?> _collectCookiesAllLayers() async {
    // 1. Native Android CookieManager / iOS WKHTTPCookieStore (preserves HttpOnly SUB)
    final nativeHeader = await ShareCore.instance.getNativeWebCookies(allDomains: true);
    if (nativeHeader != null && nativeHeader.contains('SUB=')) {
      return nativeHeader;
    }

    // 2. Fallback: Flutter WebViewCookieManager
    final values = <String, String>{};
    final manager = _cookieManager;
    if (manager == null) return null;
    for (final uri in const [
      'https://weibo.com',
      'https://passport.weibo.com',
      'https://m.weibo.cn',
      'https://api.weibo.cn',
    ]) {
      try {
        final cookies = await manager.getCookies(domain: Uri.parse(uri));
        for (final cookie in cookies) {
          if (cookie.value.isNotEmpty) {
            values[cookie.name] = cookie.value;
          }
        }
      } catch (_) {}
    }
    if (!values.containsKey('SUB')) return null;
    return values.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  Future<void> _tryCaptureWebView({bool silent = false}) async {
    if (_busy) return;
    if (!silent) setState(() => _busy = true);
    try {
      final cookie = await _collectCookiesAllLayers();
      if (cookie == null) {
        if (!silent && mounted) {
          setState(() {
            _busy = false;
            _hint = '尚未获取到 SUB 登录态，请完成微博登录后再点击完成';
          });
        }
        return;
      }
      final ok = await ref.read(sessionProvider.notifier).loginWithCookie(cookie);
      if (!mounted) return;
      setState(() => _busy = false);
      if (!ok) {
        setState(() => _hint = ref.read(sessionProvider).error ?? 'Cookie 验证失败');
      } else if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _hint = '$e';
      });
    }
  }

  Future<void> _importPastedCookie() async {
    final text = _cookieCtrl.text.trim();
    if (text.isEmpty) {
      setState(() => _hint = '请粘贴包含 SUB= 的微博 Cookie');
      return;
    }
    setState(() {
      _busy = true;
      _hint = null;
    });
    final ok = await ref.read(sessionProvider.notifier).loginWithCookie(text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) _hint = ref.read(sessionProvider).error ?? 'Cookie 无效或已过期';
    });
    if (ok && Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录微博账号'),
        leading: canPop ? const BackButton() : null,
        actions: [
          IconButton(
            tooltip: '扫码登录/解析二维码',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const QrScanPage()),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const InAppWebPage(
                  url:
                      'https://kefu.weibo.com/?entry=client&sinainternalbrowser=topnav&showmenu=1&share_menu=1&lang=zh_CN',
                  title: '登录疑问',
                ),
              ),
            ),
            child: Text('登录疑问', style: TextStyle(color: ShareColors.toolbarFg)),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: ShareColors.accent,
          unselectedLabelColor: ShareColors.textSecondary,
          indicatorColor: ShareColors.accent,
          tabs: const [
            Tab(text: '网页授权'),
            Tab(text: '账号密码'),
            Tab(text: '短信登录'),
            Tab(text: 'Cookie'),
          ],
        ),
      ),
      body: Column(
        children: [
          if (_hint != null)
            MaterialBanner(
              content: Text(_hint!, style: const TextStyle(fontSize: 13)),
              backgroundColor: ShareColors.repostBg,
              actions: [
                TextButton(
                  onPressed: () => setState(() => _hint = null),
                  child: const Text('关闭'),
                ),
              ],
            ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _buildWebViewTab(),
                _buildPasswordTab(),
                _buildSmsTab(),
                _buildCookieTab(),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              decoration: BoxDecoration(
                color: ShareColors.cardBg,
                border: Border(top: BorderSide(color: ShareColors.divider)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              await ref.read(sessionProvider.notifier).continueAsGuest();
                              if (!context.mounted) return;
                              if (Navigator.of(context).canPop()) {
                                Navigator.of(context).pop(true);
                              }
                            },
                      child: const Text('先以游客身份逛逛（免登录看热门）'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWebViewTab() {
    final controller = _webController;
    if (controller == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '当前环境不支持内置网页组件，请使用上方“账号密码 / 短信登录 / Cookie”方式登录。',
            textAlign: TextAlign.center,
            style: TextStyle(color: ShareColors.textSecondary, fontSize: 13.5),
          ),
        ),
      );
    }
    return Stack(
      children: [
        WebViewWidget(controller: controller),
        if (!_webViewReady) const LinearProgressIndicator(minHeight: 2),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.extended(
            onPressed: _busy ? null : () => _tryCaptureWebView(silent: false),
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.check),
            label: Text(_busy ? '提取中…' : '我已登录，导入凭证'),
          ),
        ),
      ],
    );
  }

  Widget _buildPasswordTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          '通过 Share 官方客户端同源 RSA-1024 接口直连微博验证',
          style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _userCtrl,
          decoration: const InputDecoration(
            labelText: '手机号 / 邮箱 / 登录名',
            prefixIcon: Icon(Icons.person_outline),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _pwdCtrl,
          obscureText: _obscurePwd,
          decoration: InputDecoration(
            labelText: '密码',
            prefixIcon: const Icon(Icons.lock_outline),
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(_obscurePwd ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _obscurePwd = !_obscurePwd),
            ),
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          height: 46,
          child: FilledButton(
            onPressed: _busy ? null : () => _submitPassword(),
            child: Text(_busy ? '登录中…' : '立即登录'),
          ),
        ),
      ],
    );
  }

  Widget _buildSmsTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        DropdownButtonFormField<String>(
          initialValue: _areaCode,
          decoration: const InputDecoration(
            labelText: '国家/地区',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final a in _areaChoices)
              DropdownMenuItem(value: a.code, child: Text(a.label)),
          ],
          onChanged: (v) {
            if (v != null) setState(() => _areaCode = v);
          },
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _phoneCtrl,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: '手机号码',
            prefixIcon: Icon(Icons.phone_android),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _smsCodeCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '短信验证码',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              height: 52,
              child: OutlinedButton(
                onPressed: (_busy || _smsCountdown > 0) ? null : _sendSmsCode,
                child: Text(_smsCountdown > 0 ? '${_smsCountdown}s' : '获取验证码'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SizedBox(
          height: 46,
          child: FilledButton(
            onPressed: _busy ? null : _submitSmsLogin,
            child: Text(_busy ? '验证中…' : '短信验证码登录'),
          ),
        ),
      ],
    );
  }

  Widget _buildCookieTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          '适用于浏览器或桌面抓包获取的微博 Cookie（需包含 SUB= 字段）。凭证加密保存在本地 SQLite USER 表。',
          style: TextStyle(fontSize: 12.5, height: 1.5, color: ShareColors.textSecondary),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _cookieCtrl,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'SUB=...; SUBP=...; XSRF-TOKEN=...',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 46,
          child: FilledButton(
            onPressed: _busy ? null : _importPastedCookie,
            child: Text(_busy ? '验证并导入中…' : '验证并导入账号'),
          ),
        ),
      ],
    );
  }

  Uint8List? _decodeBase64Image(String raw) {
    if (raw.isEmpty) return null;
    final clean = raw.contains(',') ? raw.split(',').last : raw;
    try {
      return base64Decode(clean);
    } catch (_) {
      return null;
    }
  }
}
