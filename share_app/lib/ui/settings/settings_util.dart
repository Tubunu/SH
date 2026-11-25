import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Clears every image cache this build owns.
///
/// Images are loaded with `Image.network`, which keeps decoded bitmaps in
/// Flutter's in-memory `ImageCache` (there is no disk cache layer), so the
/// original's 「清除图片缓存」 maps to dropping that cache plus any scratch files
/// the Rust core may have written under `cache/`.
Future<int> clearImageCache() async {
  final cache = PaintingBinding.instance.imageCache;
  final freed = cache.currentSizeBytes;
  cache.clear();
  cache.clearLiveImages();

  try {
    final dir = await getApplicationSupportDirectory();
    final scratch = Directory('${dir.path}/cache');
    if (await scratch.exists()) {
      await scratch.delete(recursive: true);
    }
  } catch (_) {
    // A missing or locked cache directory is not worth surfacing.
  }
  return freed;
}

/// Human-readable size used by the settings footer.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 10 || unit == 0 ? 0 : 1)} ${units[unit]}';
}
