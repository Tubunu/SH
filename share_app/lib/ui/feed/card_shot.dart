import 'package:flutter/widgets.dart';

/// Tracks active [RepaintBoundary] keys per status id without reusing a single
/// [GlobalKey] across tabs or stacked routes (preventing Duplicate GlobalKey
/// assertions/detachment inside [IndexedStack] and [Navigator]).
final Map<String, List<GlobalKey>> _shotKeys = {};

void registerStatusCardShotKey(String statusId, GlobalKey key) {
  if (statusId.isEmpty) return;
  final list = _shotKeys.putIfAbsent(statusId, () => <GlobalKey>[]);
  if (!list.contains(key)) {
    list.add(key);
  }
}

void unregisterStatusCardShotKey(String statusId, GlobalKey key) {
  if (statusId.isEmpty) return;
  final list = _shotKeys[statusId];
  if (list == null) return;
  list.remove(key);
  if (list.isEmpty) {
    _shotKeys.remove(statusId);
  }
}

GlobalKey? statusCardShotKeyOrNull(String statusId) {
  final list = _shotKeys[statusId];
  if (list == null || list.isEmpty) return null;
  for (var i = list.length - 1; i >= 0; i--) {
    if (list[i].currentContext != null) return list[i];
  }
  return list.last;
}

GlobalKey statusCardShotKey(String statusId) =>
    statusCardShotKeyOrNull(statusId) ?? GlobalKey();
