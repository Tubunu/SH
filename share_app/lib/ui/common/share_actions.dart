import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/models.dart';
import '../../core/settings.dart';
import '../app_theme.dart';

/// 保存图片 / 系统分享 / 复制文本。
///
/// These are the three actions the original client puts behind a long-press on
/// any status card and inside `GalleryActivity`. They need no Weibo endpoint —
/// the image bytes come straight from `*.sinaimg.cn`, which is why they work
/// without a login.
class ShareActions {
  ShareActions._();

  /// 保存图片时默认保存原图 (`save_image_original`): rewrite the CDN path from
  /// `large` / `bmiddle` / `thumbnail` to `original`.
  static String originalUrl(String url) {
    for (final size in const ['/orj1080/', '/large/', '/bmiddle/', '/mw690/', '/thumb150/', '/thumbnail/']) {
      if (url.contains(size)) {
        return url.replaceFirst(size, '/original/');
      }
    }
    return url;
  }

  static Future<Uint8List?> _download(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('Referer', 'https://weibo.com/');
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final builder = BytesBuilder(copy: false);
      await response.forEach(builder.add);
      return builder.takeBytes();
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Deterministic filename derived from the CDN URL basename so re-saving
  /// the same photo overwrites/skips duplicates when `same_photo_name` is on.
  static String deterministicImageName(String url) {
    final uri = Uri.tryParse(url);
    final last = (uri != null && uri.pathSegments.isNotEmpty)
        ? uri.pathSegments.last
        : url.split('/').last.split('?').first;
    final stem = last.replaceFirst(RegExp(r'\.[a-zA-Z0-9]+$'), '').trim();
    final safe = stem.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    if (safe.isNotEmpty) return 'share_$safe';
    return 'share_${url.hashCode.toUnsigned(32)}';
  }

  /// Writes one image into the system gallery. Returns `false` when permission
  /// was refused or the CDN did not answer, so the caller can show the truth.
  static Future<bool> saveImage(
    BuildContext context,
    String url, {
    bool original = false,
    bool deduplicateName = false,
    String? name,
  }) {
    final resolved = original ? originalUrl(url) : url;
    final effectiveName =
        name ?? (deduplicateName ? deterministicImageName(resolved) : null);
    return _saveResolved(context, resolved, name: effectiveName);
  }

  static Future<bool> _saveResolved(BuildContext context, String url, {String? name}) async {
    final granted = await Gal.hasAccess() || await Gal.requestAccess();
    if (!granted) {
      if (context.mounted) _toast(context, '没有相册权限，无法保存图片');
      return false;
    }
    final bytes = await _download(url);
    if (bytes == null) {
      if (context.mounted) _toast(context, '图片下载失败，请稍后再试');
      return false;
    }
    try {
      await Gal.putImageBytes(
        bytes,
        album: 'Share',
        name: name ?? 'share_${DateTime.now().millisecondsSinceEpoch}',
      );
      if (context.mounted) _toast(context, '已保存到相册');
      return true;
    } on GalException catch (e) {
      if (context.mounted) _toast(context, '保存失败：${e.type.message}');
      return false;
    }
  }

  /// Saves every picture of a status, honouring 保存图片时默认保存原图.
  static Future<void> saveImages(
    BuildContext context,
    List<String> urls, {
    required bool original,
    bool deduplicateName = false,
  }) async {
    if (urls.isEmpty) return;
    _toast(context, '正在保存 ${urls.length} 张原图…');
    var saved = 0;
    for (var i = 0; i < urls.length; i++) {
      final url = original ? originalUrl(urls[i]) : urls[i];
      final name = deduplicateName
          ? deterministicImageName(url)
          : 'share_${DateTime.now().millisecondsSinceEpoch}_$i';
      final ok = await _saveResolved(context, url, name: name);
      if (!ok) break;
      saved++;
    }
    if (context.mounted && saved == urls.length) {
      _toast(context, urls.length == 1 ? '已保存到相册' : '已保存 ${urls.length} 张图片');
    }
  }

  /// Share's classic image long-press menu (`DialogInterfaceOnClickListenerC1916Tl`):
  /// cleanly separates saving ONLY the selected photo (`保存原图到手机`) from
  /// saving ALL photos (`保存所有原图到手机`).
  static Future<void> showPicLongPressMenu(
    BuildContext context,
    List<Pic> pics,
    int index, {
    bool deduplicateName = false,
    VoidCallback? onViewOriginal,
  }) async {
    if (index < 0 || index >= pics.length) return;
    final current = pics[index];
    final currentRawUrl = current.large ?? current.url;
    final allUrls = pics.map((p) => p.large ?? p.url).toList();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: ShareColors.cardBg,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onViewOriginal != null)
              ListTile(
                leading: const Icon(Icons.zoom_in_rounded, size: 20),
                title: const Text('查看原图'),
                onTap: () {
                  Navigator.pop(ctx);
                  onViewOriginal();
                },
              ),
            ListTile(
              leading: const Icon(Icons.download_rounded, size: 20),
              title: const Text('保存原图到手机'),
              onTap: () {
                Navigator.pop(ctx);
                saveImage(
                  context,
                  currentRawUrl,
                  original: true,
                  deduplicateName: deduplicateName,
                );
              },
            ),
            if (pics.length > 1)
              ListTile(
                leading: const Icon(Icons.collections_bookmark_outlined, size: 20),
                title: Text('保存所有原图到手机 (${pics.length}张)'),
                onTap: () {
                  Navigator.pop(ctx);
                  saveImages(
                    context,
                    allUrls,
                    original: true,
                    deduplicateName: deduplicateName,
                  );
                },
              ),
            ListTile(
              leading: const Icon(Icons.ios_share_rounded, size: 20),
              title: const Text('分享图片'),
              onTap: () {
                Navigator.pop(ctx);
                shareImage(context, originalUrl(currentRawUrl));
              },
            ),
            ListTile(
              leading: const Icon(Icons.link_rounded, size: 20),
              title: const Text('复制图片链接'),
              onTap: () {
                Navigator.pop(ctx);
                copyText(context, originalUrl(currentRawUrl), toast: '图片链接已复制');
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Shares image bytes through the system sheet (WeChat, QQ, …).
  static Future<void> shareImage(BuildContext context, String url, {String? text}) async {
    final bytes = await _download(url);
    if (bytes == null) {
      if (context.mounted) _toast(context, '图片下载失败，请稍后再试');
      return;
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/share_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await file.writeAsBytes(bytes);
    if (!context.mounted) return;
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: 'image/jpeg')],
      text: text,
      sharePositionOrigin: _originOf(context),
    ));
  }

  static Future<void> shareStatus(BuildContext context, Status status) async {
    final text = statusShareText(status);
    if (status.pics.isNotEmpty) {
      await shareImage(context, status.pics.first.large ?? status.pics.first.url, text: text);
      return;
    }
    await SharePlus.instance.share(ShareParams(
      text: text,
      subject: '分享微博',
      sharePositionOrigin: _originOf(context),
    ));
  }

  static String statusShareText(Status status) {
    final name = status.user?.displayName ?? '';
    final link = statusLink(status);
    return '${name.isEmpty ? '' : '@$name：'}${status.textRaw}\n$link';
  }

  static String statusLink(Status status) {
    final uid = status.user?.id ?? '';
    return uid.isEmpty
        ? 'https://m.weibo.cn/detail/${status.id}'
        : 'https://weibo.com/$uid/${status.mblogid}';
  }

  static Future<void> copyText(BuildContext context, String text, {String toast = '已复制'}) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) _toast(context, toast);
  }

  /// The long-press menu every status card shows.
  static Future<void> showStatusMenu(
    BuildContext context,
    Status status, {
    required bool saveOriginal,
    bool deduplicateName = false,
  }) async {
    final pics = status.pics.map((p) => p.large ?? p.url).toList();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: ShareColors.cardBg,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_rounded, size: 20),
              title: const Text('复制微博内容'),
              onTap: () {
                Navigator.pop(ctx);
                copyText(context, status.textRaw, toast: '微博内容已复制');
              },
            ),
            ListTile(
              leading: const Icon(Icons.link_rounded, size: 20),
              title: const Text('复制链接'),
              onTap: () {
                Navigator.pop(ctx);
                copyText(context, statusLink(status), toast: '链接已复制');
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share_rounded, size: 20),
              title: const Text('分享…'),
              onTap: () {
                Navigator.pop(ctx);
                shareStatus(context, status);
              },
            ),
            if (pics.length == 1)
              ListTile(
                leading: const Icon(Icons.download_rounded, size: 20),
                title: const Text('保存原图到手机'),
                onTap: () {
                  Navigator.pop(ctx);
                  saveImage(
                    context,
                    pics.first,
                    original: saveOriginal,
                    deduplicateName: deduplicateName,
                  );
                },
              ),
            if (pics.length > 1)
              ListTile(
                leading: const Icon(Icons.collections_bookmark_outlined, size: 20),
                title: Text('保存所有原图到手机 (${pics.length}张)'),
                onTap: () {
                  Navigator.pop(ctx);
                  saveImages(
                    context,
                    pics,
                    original: saveOriginal,
                    deduplicateName: deduplicateName,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  static Rect? _originOf(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  static void _toast(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }
}

/// Reads 保存图片时默认保存原图 from the settings map.
bool saveImageOriginal(AppSettings settings) => settings.flag('save_image_original');
