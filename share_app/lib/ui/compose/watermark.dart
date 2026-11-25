import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// 把「昵称 + Share」烧录到图片右下角。
///
/// 为什么用 `dart:ui` 手画而不是引第三方水印库：项目约定不新增 pubspec 依赖，
/// 而这里只需要「叠一层半透明文字」，Canvas 三行代码就够，没必要背一个包。
///
/// 失败时**返回传入的同一个实例**（`identical` 为 true），调用方据此判断是否
/// 需要改用 PNG 的 mime / 文件名；不抛异常，避免因为水印把整条微博卡死。
Future<Uint8List> applyWatermark(Uint8List source, {required String text}) async {
  ui.Image? image;
  ui.Codec? codec;
  try {
    codec = await ui.instantiateImageCodec(source);
    final frame = await codec.getNextFrame();
    image = frame.image;

    final width = image.width;
    final height = image.height;
    if (width <= 0 || height <= 0) return source;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // 原图 1:1 draw 上去：不缩放、不旋转、不裁剪，宽高比保持不变。
    canvas.drawImage(image, Offset.zero, Paint());

    // 字号按图片宽度的 3% 走，缩略图不被糊满、大图也不至于看不见；14 是下限。
    final fontSize = math.max(14.0, width * 0.03);
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          // 70% 白 + 1~2px、30% 黑的阴影：亮底靠阴影、暗底靠白字，任何底色都能读。
          color: const Color(0xB3FFFFFF),
          shadows: const [
            Shadow(color: Color(0x4D000000), blurRadius: 2, offset: Offset(0, 1)),
          ],
        ),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width * 0.92);

    final margin = math.max(8.0, width * 0.02);
    painter.paint(
      canvas,
      Offset(
        math.max(0.0, width - painter.width - margin),
        math.max(0.0, height - painter.height - margin),
      ),
    );
    painter.dispose();

    final picture = recorder.endRecording();
    final out = await picture.toImage(width, height);
    picture.dispose();
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    out.dispose();

    if (data == null) return source;
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    return bytes.isEmpty ? source : bytes;
  } catch (_) {
    // 任何解码/编码失败都退回原图：宁可少一个水印，也不要发不出去。
    return source;
  } finally {
    codec?.dispose();
    image?.dispose();
  }
}

/// 从文件头判断真实格式 —— 水印合成后是 PNG，而原始 MIME 可能仍是 jpeg，
/// 传错 MIME 微博侧会拒收，所以按字节嗅探比按文件名猜更可靠。
String? sniffImageMime(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 6 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}
