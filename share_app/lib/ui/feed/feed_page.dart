import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/feed_cache.dart';
import '../../core/groups.dart';
import '../../core/keyword_filter.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/settings.dart';
import '../../core/share_core.dart';
import '../app_theme.dart';
import '../common/share_actions.dart';
import '../common/status_action_sheet.dart';
import '../detail/status_detail_page.dart';
import '../media/gallery_page.dart';
import '../profile/user_page.dart';
import '../search/search_page.dart';
import '../shell/share_drawer.dart';
import 'status_card.dart';

class FeedPage extends ConsumerStatefulWidget {
  /// 抽屉里点「首页 / 热门 / 消息」时由外壳切 tab。
  final void Function(int index)? onSelectTab;

  /// 外壳提供宿主抽屉回调，避免被底部导航栏遮挡。
  final VoidCallback? onOpenDrawer;

  const FeedPage({super.key, this.onSelectTab, this.onOpenDrawer});

  @override
  ConsumerState<FeedPage> createState() => FeedPageState();
}

/// 首页两个固定时间线（其余分组统一走 [WeiboGroup]）。
enum FeedGroup { follow, hot }

class FeedPageState extends ConsumerState<FeedPage> with WidgetsBindingObserver {
  final List<Status> _items = [];
  final ScrollController _controller = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  String? _maxId;
  String? _error;
  bool _usingGuestFeed = false;
  FeedGroup? _forcedGroup;
  double _lastKnownOffset = 0;
  String _lastKnownAnchorId = '';
  double _lastKnownAnchorOffset = 0;
  double _rememberedTopToggleOffset = 0;
  String _cachedAccountUid = '';
  bool _disposing = false;
  bool _isRestoringScroll = false;
  int _restoreToken = 0;
  Timer? _saveDebounce;
  final Map<String, GlobalKey> _itemKeys = <String, GlobalKey>{};
  String _lastSavedSig = '';

  /// 当前分组；`null` = 全部关注。
  WeiboGroup? _group;
  List<WeiboGroup> _groups = const [];
  bool _groupsLoaded = false;

  GlobalKey _keyForStatus(String id) => _itemKeys.putIfAbsent(id, GlobalKey.new);

  void _pruneItemKeys() {
    if (_itemKeys.length <= _items.length + 16) return;
    final activeIds = _items.map((e) => e.id).toSet();
    _itemKeys.removeWhere((id, _) => !activeIds.contains(id));
  }

  RenderBox? _viewportBox() {
    if (!_controller.hasClients) return null;
    final ro = _controller.position.context.storageContext.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
    return ro;
  }

  ({String statusId, double anchorOffset})? _captureAnchor() {
    if (_items.isEmpty) return null;
    final viewportBox = _viewportBox();
    if (viewportBox == null) return null;

    for (final status in _items) {
      final ro = _itemKeys[status.id]?.currentContext?.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) continue;
      final top = ro.localToGlobal(Offset.zero, ancestor: viewportBox).dy;
      final bottom = top + ro.size.height;
      if (bottom <= 0.5 || top > viewportBox.size.height) continue;

      var anchorOffset = -top;
      if (_controller.offset <= 0.5 && anchorOffset < 0) {
        anchorOffset = 0;
      }
      return (statusId: status.id, anchorOffset: anchorOffset);
    }
    return null;
  }

  void _cancelRestore() {
    _restoreToken++;
    _isRestoringScroll = false;
  }

  @override
  void initState() {
    super.initState();
    _cachedAccountUid = ref.read(sessionProvider).account?.uid ?? '';
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadGroups();
      _restoreOrLoadFirst();
    });
  }

  @override
  void dispose() {
    _disposing = true;
    _cancelRestore();
    _saveDebounce?.cancel();
    if (_items.isNotEmpty) {
      unawaited(_saveCacheSnapshot());
    }
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _saveDebounce?.cancel();
      if (_items.isNotEmpty) {
        unawaited(_saveCacheSnapshot());
      }
    }
  }

  void _onScroll() {
    if (!mounted || _disposing || _isRestoringScroll) return;
    if (_controller.hasClients) {
      _lastKnownOffset = _controller.offset;
      if (_lastKnownOffset <= 0.5 && _items.isNotEmpty) {
        _lastKnownAnchorId = _items.first.id;
        _lastKnownAnchorOffset = 0;
      } else {
        final anchor = _captureAnchor();
        if (anchor != null) {
          _lastKnownAnchorId = anchor.statusId;
          _lastKnownAnchorOffset = anchor.anchorOffset;
        }
      }
      _saveDebounce?.cancel();
      _saveDebounce = Timer(const Duration(milliseconds: 350), () {
        if (mounted && !_disposing && _items.isNotEmpty) {
          unawaited(_saveCacheSnapshot());
        }
      });
    }
    // 预读模式 loads the next page earlier so the reader never waits.
    final margin = ref.read(settingsProvider).preread ? 900.0 : 200.0;
    if (_controller.hasClients &&
        _controller.position.pixels > _controller.position.maxScrollExtent - margin) {
      _loadMore();
    }
  }

  bool get _loggedIn => ref.read(sessionProvider).isLoggedIn;
  String get _accountUid => (mounted && !_disposing)
      ? (_cachedAccountUid = ref.read(sessionProvider).account?.uid ?? '')
      : _cachedAccountUid;

  String get _currentGroupKey {
    if (_forcedGroup == FeedGroup.hot || (_group?.isHotChannel ?? false)) {
      return 'hot';
    }
    final gid = _group?.gid.trim() ?? '';
    return gid.isNotEmpty ? 'group_$gid' : 'all';
  }

  /// 关键词 / 博主 / 来源 三段过滤。
  List<Status> _filter(List<Status> source) =>
      applyStatusFilters(source, ref.read(settingsProvider));

  Future<void> _restoreOrLoadFirst() async {
    final settings = ref.read(settingsProvider);
    final startRefresh = settings.flag('start_refresh_status');
    final uid = _accountUid;

    CachedGroupSelection? last;
    CachedTimelineSnapshot? snap;
    if (!startRefresh && _forcedGroup == null && _group == null) {
      final results = await Future.wait<Object?>([
        FeedCacheStore.instance.loadLastGroup(uid),
        FeedCacheStore.instance.loadSnapshot(uid, groupKey: 'all'),
      ]);
      last = results[0] as CachedGroupSelection?;
      snap = results[1] as CachedTimelineSnapshot?;

      if (last != null && mounted) {
        if (last.groupKey == 'hot') {
          setState(() => _forcedGroup = FeedGroup.hot);
          snap = await FeedCacheStore.instance.loadSnapshot(uid, groupKey: 'hot');
        } else if (last.groupKey.startsWith('group_')) {
          final gid = last.groupKey.substring('group_'.length);
          if (gid.isNotEmpty) {
            setState(() {
              _group = WeiboGroup(
                gid: gid,
                title: last!.title.isEmpty ? '分组' : last.title,
                containerId: last.isHotChannel ? '102803' : '',
                type: last.isHotChannel ? '8888' : '',
              );
            });
            snap = await FeedCacheStore.instance.loadSnapshot(uid, groupKey: last.groupKey);
          }
        }
      }
    } else {
      snap = await FeedCacheStore.instance.loadSnapshot(
        uid,
        groupKey: _currentGroupKey,
      );
    }

    if (!mounted) return;
    final restored = snap;

    if (restored != null && restored.items.isNotEmpty && !startRefresh) {
      _applyRestoredSnapshot(restored);
      return;
    }

    await _loadFirst(scrollToTopAfter: true, force: true);
  }

  void _applyRestoredSnapshot(CachedTimelineSnapshot snap) {
    final filtered = _filter(snap.items);
    setState(() {
      _items
        ..clear()
        ..addAll(filtered);
      _maxId = snap.maxId;
      _page = snap.page;
      _hasMore = snap.hasMore;
      _usingGuestFeed = snap.usingGuestFeed;
      _loading = false;
      _error = null;
      _lastKnownOffset = snap.scrollOffset;
      _lastKnownAnchorId = snap.anchorStatusId;
      _lastKnownAnchorOffset = snap.anchorOffset;
    });
    _pruneItemKeys();
    _restoreScrollPosition(
      snap.scrollOffset,
      anchorStatusId: snap.anchorStatusId,
      anchorOffset: snap.anchorOffset,
    );
  }

  void _restoreScrollPosition(
    double offset, {
    String anchorStatusId = '',
    double anchorOffset = 0,
  }) {
    final token = ++_restoreToken;
    final anchorIndex = anchorStatusId.isEmpty
        ? -1
        : _items.indexWhere((s) => s.id == anchorStatusId);
    if (offset <= 0.5 &&
        (anchorIndex < 0 || (anchorIndex == 0 && anchorOffset <= 0.5))) {
      _isRestoringScroll = false;
      return;
    }
    _isRestoringScroll = true;

    var controllerWaitAttempts = 0;
    var layoutAttempts = 0;
    var didInitialJump = false;
    var stalledCount = 0;
    double? lastJumpTarget;

    void finish() {
      if (!mounted || token != _restoreToken) return;
      _isRestoringScroll = false;
      if (_controller.hasClients) {
        _lastKnownOffset = _controller.offset;
        final live = _captureAnchor();
        if (live != null) {
          _lastKnownAnchorId = live.statusId;
          _lastKnownAnchorOffset = live.anchorOffset;
        }
      }
    }

    void step() {
      if (!mounted || token != _restoreToken) return;
      if (!_controller.hasClients) {
        if (controllerWaitAttempts < 6) {
          controllerWaitAttempts++;
          WidgetsBinding.instance.addPostFrameCallback((_) => step());
        } else {
          finish();
        }
        return;
      }

      final position = _controller.position;
      final maxExtent = position.maxScrollExtent;

      if (!didInitialJump) {
        didInitialJump = true;
        final initialGuess = offset > 0.5
            ? offset
            : (anchorIndex > 0 ? anchorIndex * 240.0 + anchorOffset : anchorOffset);
        final initialTarget = initialGuess.clamp(0.0, maxExtent);
        if ((_controller.offset - initialTarget).abs() > 0.5) {
          _controller.jumpTo(initialTarget);
        }
        if (anchorIndex < 0) {
          if (maxExtent < offset && layoutAttempts < 4) {
            layoutAttempts++;
            Future<void>.delayed(const Duration(milliseconds: 50), step);
          } else {
            finish();
          }
          return;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => step());
        return;
      }

      if (anchorIndex < 0) {
        final target = offset.clamp(0.0, maxExtent);
        if ((_controller.offset - target).abs() > 0.5) {
          _controller.jumpTo(target);
        }
        if (maxExtent < offset && layoutAttempts < 4) {
          layoutAttempts++;
          Future<void>.delayed(const Duration(milliseconds: 50), step);
        } else {
          finish();
        }
        return;
      }

      final viewportBox = _viewportBox();
      if (viewportBox == null) {
        if (layoutAttempts < 6) {
          layoutAttempts++;
          WidgetsBinding.instance.addPostFrameCallback((_) => step());
        } else {
          finish();
        }
        return;
      }

      final anchorRo = _itemKeys[anchorStatusId]?.currentContext?.findRenderObject();
      if (anchorRo is RenderBox && anchorRo.attached && anchorRo.hasSize) {
        final cardTop = anchorRo.localToGlobal(Offset.zero, ancestor: viewportBox).dy;
        final desiredTop = -anchorOffset;
        final delta = cardTop - desiredTop;
        final target = (_controller.offset + delta).clamp(0.0, maxExtent);
        final move = target - _controller.offset;
        if (move.abs() > 0.75 && layoutAttempts < 12) {
          layoutAttempts++;
          _controller.jumpTo(target);
          WidgetsBinding.instance.addPostFrameCallback((_) => step());
          return;
        }
        finish();
        return;
      }

      if (layoutAttempts >= 12) {
        finish();
        return;
      }

      int? minIdx;
      int? maxIdx;
      double minTop = 0;
      double maxBottom = 0;
      for (var i = 0; i < _items.length; i++) {
        final ro = _itemKeys[_items[i].id]?.currentContext?.findRenderObject();
        if (ro is! RenderBox || !ro.attached || !ro.hasSize) continue;
        final top = ro.localToGlobal(Offset.zero, ancestor: viewportBox).dy;
        final bottom = top + ro.size.height;
        if (minIdx == null) {
          minIdx = i;
          minTop = top;
        }
        maxIdx = i;
        maxBottom = bottom;
      }

      if (minIdx == null || maxIdx == null) {
        layoutAttempts++;
        WidgetsBinding.instance.addPostFrameCallback((_) => step());
        return;
      }

      final visibleSpan = maxBottom - minTop;
      final visibleCount = maxIdx - minIdx + 1;
      final avgStride = (visibleCount > 0 && visibleSpan > 20)
          ? visibleSpan / visibleCount
          : 240.0;

      final double estimatedDelta;
      if (anchorIndex > maxIdx) {
        final remaining = anchorIndex - maxIdx - 1;
        estimatedDelta = math.max(
          viewportBox.size.height * 0.5,
          maxBottom + remaining * avgStride + anchorOffset,
        );
      } else {
        final remaining = minIdx - anchorIndex;
        estimatedDelta = math.min(
          -viewportBox.size.height * 0.5,
          minTop - remaining * avgStride + anchorOffset,
        );
      }

      final nextTarget = (_controller.offset + estimatedDelta).clamp(0.0, maxExtent);
      final prevTarget = lastJumpTarget;
      if (prevTarget != null &&
          (nextTarget - prevTarget).abs() < 0.5 &&
          (nextTarget - _controller.offset).abs() < 0.5) {
        stalledCount++;
        if (stalledCount >= 2) {
          finish();
          return;
        }
      } else {
        stalledCount = 0;
      }
      lastJumpTarget = nextTarget;
      layoutAttempts++;
      _controller.jumpTo(nextTarget);
      WidgetsBinding.instance.addPostFrameCallback((_) => step());
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => step());
  }

  Future<void> _saveCacheSnapshot({
    double? offsetOverride,
    String? anchorIdOverride,
    double? anchorOffsetOverride,
  }) async {
    _saveDebounce?.cancel();
    if (_items.isEmpty) return;
    final uid = _cachedAccountUid;
    final offset = offsetOverride ??
        (_controller.hasClients ? _controller.offset : _lastKnownOffset);
    _lastKnownOffset = offset;

    String anchorId;
    double anchorOffset;
    if (offset <= 0.5) {
      anchorId = _items.first.id;
      anchorOffset = 0;
    } else if (anchorIdOverride != null) {
      anchorId = anchorIdOverride;
      anchorOffset = anchorOffsetOverride ?? 0;
    } else {
      final live = _captureAnchor();
      if (live != null) {
        anchorId = live.statusId;
        anchorOffset = live.anchorOffset;
      } else {
        final keepLast = _lastKnownAnchorId.isNotEmpty &&
            _items.any((s) => s.id == _lastKnownAnchorId);
        anchorId = keepLast ? _lastKnownAnchorId : '';
        anchorOffset = keepLast ? _lastKnownAnchorOffset : 0;
      }
    }
    _lastKnownAnchorId = anchorId;
    _lastKnownAnchorOffset = anchorOffset;

    final sig =
        '$uid|$_currentGroupKey|${_items.length}|${_items.first.id}|${_items.last.id}|$_maxId|${offset.toStringAsFixed(1)}|$anchorId|${anchorOffset.toStringAsFixed(1)}';
    if (sig == _lastSavedSig) return;
    _lastSavedSig = sig;

    await FeedCacheStore.instance.saveSnapshot(
      uid,
      CachedTimelineSnapshot(
        groupKey: _currentGroupKey,
        items: List<Status>.from(_items),
        maxId: _maxId,
        page: _page,
        hasMore: _hasMore,
        usingGuestFeed: _usingGuestFeed,
        scrollOffset: offset,
        anchorStatusId: anchorId,
        anchorOffset: anchorOffset,
      ),
    );
    await FeedCacheStore.instance.saveLastGroup(
      uid,
      CachedGroupSelection(
        groupKey: _currentGroupKey,
        title: _group?.label ?? '',
        isHotChannel: _group?.isHotChannel ?? (_forcedGroup == FeedGroup.hot),
      ),
    );
  }

  Future<void> _loadGroups() async {
    try {
      final set = await WeiboApi.instance.groups();
      if (!mounted) return;
      final loaded = set.categories
          .expand((c) => c.groups)
          .where((g) => g.gid.isNotEmpty && !g.isHotChannel)
          .toList();
      setState(() {
        _groups = loaded;
        // Refresh cached group's display title once full groups list arrives.
        if (_group != null) {
          for (final g in loaded) {
            if (g.gid == _group!.gid) {
              _group = g;
              break;
            }
          }
        }
        _groupsLoaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _groupsLoaded = true);
    }
  }

  /// Called by the shell when the FAB asks for a different group.
  Future<void> switchGroup(FeedGroup group) async {
    if (_forcedGroup == group && _group == null) return;
    unawaited(_saveCacheSnapshot());
    setState(() {
      _forcedGroup = group;
      _group = null;
    });
    await _loadAfterGroupChange();
  }

  Future<void> selectGroup(WeiboGroup? group) async {
    unawaited(_saveCacheSnapshot());
    if (group == null) {
      setState(() {
        _group = null;
        _forcedGroup = null;
      });
      await _loadAfterGroupChange();
      return;
    }
    if (group.isHotChannel) {
      setState(() => _group = group);
      return switchGroup(FeedGroup.hot);
    }
    if (!_loggedIn) {
      _toast('分组时间线需要登录后查看');
      return;
    }
    setState(() {
      _group = group;
      _forcedGroup = null;
    });
    await _loadAfterGroupChange();
  }

  Future<void> _loadAfterGroupChange() async {
    final uid = _accountUid;
    final key = _currentGroupKey;
    unawaited(FeedCacheStore.instance.saveLastGroup(
      uid,
      CachedGroupSelection(
        groupKey: key,
        title: _group?.label ?? '',
        isHotChannel: _group?.isHotChannel ?? (_forcedGroup == FeedGroup.hot),
      ),
    ));

    final autoRefresh = ref.read(settingsProvider).flag('auto_refresh_status');
    final snap = autoRefresh
        ? null
        : await FeedCacheStore.instance.loadSnapshot(uid, groupKey: key);
    if (!mounted) return;
    if (snap != null && snap.items.isNotEmpty) {
      _applyRestoredSnapshot(snap);
      return;
    }
    await _reload();
  }

  Future<void> _reload() async {
    _cancelRestore();
    setState(() {
      _items.clear();
      _maxId = null;
      _hasMore = true;
      _lastKnownOffset = 0;
      _lastKnownAnchorId = '';
      _lastKnownAnchorOffset = 0;
    });
    _pruneItemKeys();
    await _loadFirst(scrollToTopAfter: true);
  }

  Future<void> refresh() => _loadFirst(scrollToTopAfter: true);

  Future<void> scrollToTopAndRefresh() async {
    _cancelRestore();
    if (_controller.hasClients && _controller.offset > 0) {
      _rememberedTopToggleOffset = _controller.offset;
      unawaited(_controller.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      ));
    }
    await _loadFirst(scrollToTopAfter: true);
  }

  void scrollToTop() {
    _cancelRestore();
    if (!_controller.hasClients) return;
    if (_controller.offset > 40) {
      _rememberedTopToggleOffset = _controller.offset;
    }
    _controller.animateTo(0,
        duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
  }

  void toggleTopOrLastPosition() {
    if (!_controller.hasClients) return;
    if (_controller.offset > 40) {
      _rememberedTopToggleOffset = _controller.offset;
      _controller.animateTo(0,
          duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    } else if (_rememberedTopToggleOffset > 40) {
      final target = _rememberedTopToggleOffset.clamp(
        0.0,
        _controller.position.maxScrollExtent,
      );
      _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    }
  }

  void openDrawer() {
    if (widget.onOpenDrawer != null) {
      widget.onOpenDrawer!();
      return;
    }
    if (ref.read(settingsProvider).showDrawerFromLeft) {
      _scaffoldKey.currentState?.openDrawer();
    } else {
      _scaffoldKey.currentState?.openEndDrawer();
    }
  }

  /// FAB / 顶栏共用同一个分组浮层。
  void openGroupMenu() => _showGroupMenu();

  Future<void> _loadFirst({bool scrollToTopAfter = false, bool force = false}) async {
    if (_loading && !force) return;
    setState(() {
      _loading = true;
      _error = null;
      _page = 1;
    });
    try {
      final api = WeiboApi.instance;

      final count = ref.read(settingsProvider).feedPageSize;
      final wantHot = _forcedGroup == FeedGroup.hot ||
          (_group?.isHotChannel ?? false) ||
          !_loggedIn;
      Paged<Status> page;
      if (wantHot) {
        page = await api.hotTimeline(count: count);
        _usingGuestFeed = true;
      } else if (_group != null) {
        page = await api.feedTimeline(gid: _group!.gid, count: count, page: 1);
        _usingGuestFeed = false;
      } else {
        page = await api.homeTimeline(count: count, page: 1);
        _usingGuestFeed = false;
      }

      if (!mounted) return;
      final filtered = _filter(page.items);
      if (scrollToTopAfter) {
        _cancelRestore();
      }
      setState(() {
        _items
          ..clear()
          ..addAll(filtered);
        _maxId = page.maxId;
        _hasMore = page.hasMore;
        _page = 1;
        _loading = false;
        _error = null;
        if (scrollToTopAfter) {
          _lastKnownOffset = 0;
          _lastKnownAnchorId = filtered.isNotEmpty ? filtered.first.id : '';
          _lastKnownAnchorOffset = 0;
        }
      });
      _pruneItemKeys();
      if (scrollToTopAfter && _controller.hasClients && _controller.offset > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _controller.hasClients) {
            _controller.jumpTo(0);
          }
        });
      }
      unawaited(_saveCacheSnapshot(offsetOverride: scrollToTopAfter ? 0.0 : null));
    } catch (e) {
      if (!mounted) return;
      // Only degrade to hot feed if primary load produced nothing and user wasn't explicitly refreshing an active cached feed.
      if (_loggedIn && _items.isEmpty) {
        try {
          final page = await WeiboApi.instance
              .hotTimeline(count: ref.read(settingsProvider).feedPageSize);
          if (!mounted) return;
          setState(() {
            _items
              ..clear()
              ..addAll(_filter(page.items));
            _maxId = page.maxId;
            _hasMore = page.hasMore;
            _loading = false;
            _usingGuestFeed = true;
            _error = null;
          });
          return;
        } catch (_) {}
      }
      setState(() {
        _loading = false;
        if (_items.isEmpty) _error = _humanize(e);
      });
      if (_items.isNotEmpty) _toast(_humanize(e));
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    setState(() => _loadingMore = true);
    try {
      final api = WeiboApi.instance;
      final count = ref.read(settingsProvider).feedPageSize;
      final nextPage = _page + 1;
      final Paged<Status> page;
      if (_loggedIn && !_usingGuestFeed) {
        page = _group != null
            ? await api.feedTimeline(
                gid: _group!.gid,
                maxId: _maxId,
                count: count,
                page: nextPage,
              )
            : await api.homeTimeline(maxId: _maxId, count: count, page: nextPage);
      } else {
        page = await api.hotTimeline(maxId: _maxId, count: count);
      }
      if (!mounted) return;
      setState(() {
        final seen = _items.map((s) => s.id).toSet();
        final appended = _filter(page.items).where((s) => seen.add(s.id)).toList();
        if (!_usingGuestFeed && _group?.isHotChannel != true && appended.length > 1) {
          WeiboApi.sortStatusesChronologically(appended);
        }
        _items.addAll(appended);
        _maxId = page.maxId;
        _hasMore = page.hasMore;
        _page = nextPage;
        _loadingMore = false;
      });
      unawaited(_saveCacheSnapshot());
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  Future<void> _toggleLike(Status status) async {
    final index = _items.indexWhere((e) => e.id == status.id);
    if (index < 0) return;
    final current = _items[index];
    final optimistic = current.copyWith(
      liked: !current.liked,
      attitudes: current.attitudes + (current.liked ? -1 : 1),
    );
    setState(() => _items[index] = optimistic);
    try {
      await WeiboApi.instance.like(current.id, current.liked);
    } catch (e) {
      if (!mounted) return;
      setState(() => _items[index] = current);
      _toast(_humanize(e));
    }
  }

  void _removeStatus(String id) {
    setState(() => _items.removeWhere((e) => e.id == id));
    _itemKeys.remove(id);
    unawaited(_saveCacheSnapshot());
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  String _humanize(Object error) {
    final text = error.toString();
    final marker = text.indexOf('AnyhowException(');
    if (marker >= 0) {
      return text
          .substring(marker + 'AnyhowException('.length)
          .replaceAll(RegExp(r'\)+$'), '')
          .trim();
    }
    return text;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SessionState>(sessionProvider, (previous, next) {
      final prevUid = previous?.account?.uid ?? '';
      final nextUid = next.account?.uid ?? '';
      if (prevUid != nextUid || (previous?.isLoggedIn ?? false) != next.isLoggedIn) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _cancelRestore();
          _items.clear();
          _itemKeys.clear();
          _maxId = null;
          _group = null;
          _forcedGroup = null;
          _lastKnownOffset = 0;
          _lastKnownAnchorId = '';
          _lastKnownAnchorOffset = 0;
          _loadGroups();
          _restoreOrLoadFirst();
        });
      }
    });
    final fromLeft = ref.watch(settingsProvider).showDrawerFromLeft;
    final drawer = widget.onOpenDrawer == null
        ? ShareDrawer(onSelectTab: widget.onSelectTab ?? (_) {})
        : null;
    return Scaffold(
      key: _scaffoldKey,
      drawer: fromLeft ? drawer : null,
      endDrawer: fromLeft ? null : drawer,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leadingWidth: 50,
        leading: _avatarButton(),
        titleSpacing: 0,
        title: _groupSelector(),
        shape: Border(
          bottom: BorderSide(color: ShareColors.divider.withValues(alpha: 0.7), width: 0.5),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 22),
            tooltip: '发微博',
            onPressed: () => openComposer(context),
          ),
          IconButton(
            icon: const Icon(Icons.search, size: 22),
            tooltip: '搜索',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SearchPage()),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _buildBody(),
    );
  }

  /// 顶栏左侧头像 —— 单击滑出抽屉，长按快速切账号。
  Widget _avatarButton() {
    final account = ref.watch(sessionProvider).account;
    final profile = ref.watch(meProfileProvider).valueOrNull;
    final avatar = profile?.avatar.isNotEmpty == true
        ? profile!.avatar
        : (account?.avatar ?? '');
    return InkWell(
      onTap: openDrawer,
      onLongPress: openDrawer,
      child: Padding(
        padding: const EdgeInsets.only(left: 14, right: 6),
        child: Center(
          child: ClipOval(
            child: SizedBox(
              width: 30,
              height: 30,
              child: avatar.isEmpty
                  ? ColoredBox(
                      color: ShareColors.placeholder,
                      child: Icon(Icons.person,
                          size: 18, color: ShareColors.textSecondary),
                    )
                  : Image.network(
                      avatar,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => ColoredBox(
                        color: ShareColors.placeholder,
                        child: Icon(Icons.person,
                            size: 18, color: ShareColors.textSecondary),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// 顶栏中间的「分组 ▾」，点开就是原版的分组浮层。
  Widget _groupSelector() {
    final title = _group?.label ?? (switch (_forcedGroup) {
      FeedGroup.hot => '热门',
      _ => '全部关注',
    });

    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: _showGroupMenu,
        onDoubleTap: refresh,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w500),
                ),
              ),
              Icon(Icons.arrow_drop_down, size: 20, color: ShareColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showGroupMenu() async {
    if (!_groupsLoaded) _loadGroups();
    final picked = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: ShareColors.cardBg,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(
                children: [
                  Text('切换分组',
                      style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
                  const Spacer(),
                  if (_groups.isNotEmpty)
                    Text('${_groups.length + 2} 个',
                        style: TextStyle(fontSize: 11.5, color: ShareColors.textHint)),
                ],
              ),
            ),
            ListTile(
              dense: true,
              leading: Icon(Icons.dynamic_feed_outlined,
                  size: 20,
                  color: _group == null && _forcedGroup == null
                      ? ShareColors.accent
                      : ShareColors.textSecondary),
              title: const Text('全部关注', style: TextStyle(fontSize: 15)),
              subtitle: const Text('按关注时间排序', style: TextStyle(fontSize: 11.5)),
              onTap: () => Navigator.pop(ctx, 'follow'),
            ),
            ListTile(
              dense: true,
              leading: Icon(Icons.local_fire_department_outlined,
                  size: 20,
                  color: _forcedGroup == FeedGroup.hot
                      ? ShareColors.accent
                      : ShareColors.textSecondary),
              title: const Text('热门', style: TextStyle(fontSize: 15)),
              subtitle: const Text('公开时间线，未登录也可看', style: TextStyle(fontSize: 11.5)),
              onTap: () => Navigator.pop(ctx, 'hot'),
            ),
            for (final g in _groups)
              ListTile(
                dense: true,
                leading: Icon(
                  g.title.contains('好友') ? Icons.people_outline : Icons.folder_outlined,
                  size: 20,
                  color: _group?.gid == g.gid
                      ? ShareColors.accent
                      : ShareColors.textSecondary,
                ),
                title: Text(g.label, style: const TextStyle(fontSize: 15)),
                subtitle: g.count > 0
                    ? Text('${g.count} 个分组成员',
                        style: const TextStyle(fontSize: 11.5))
                    : null,
                onTap: () => Navigator.pop(ctx, g),
              ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
    if (!mounted || picked == null) return;

    if (picked == 'follow') return selectGroup(null);
    if (picked == 'hot') {
      setState(() => _group = null);
      return switchGroup(FeedGroup.hot);
    }
    if (picked is WeiboGroup) return selectGroup(picked);
  }

  Widget _buildBody() {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null && _items.isEmpty) {
      return _ErrorView(message: _error!, onRetry: _loadFirst);
    }
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.dynamic_feed_outlined, size: 42, color: ShareColors.textHint),
              const SizedBox(height: 12),
              Text(
                '当前关注时间线暂无动态',
                style: TextStyle(fontSize: 14, color: ShareColors.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                '如果你刚关注了博主或刚登录，可刷新重试或先浏览热门微博',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: ShareColors.textSecondary),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton(onPressed: _loadFirst, child: const Text('刷新')),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: () {
                      setState(() => _group = null);
                      switchGroup(FeedGroup.hot);
                    },
                    child: const Text('浏览热门微博'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final cardStyle = ref.watch(settingsProvider).cardStyle;
    final list = ListView.separated(
      controller: _controller,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(bottom: cardStyle ? 16 : 8),
      itemCount: _items.length + 1,
      separatorBuilder: (_, index) {
        if (index == _items.length - 1) return const SizedBox.shrink();
        if (cardStyle) return const SizedBox.shrink();
        return Divider(height: 8, thickness: 8, color: ShareColors.pageBg);
      },
      itemBuilder: (context, index) {
        if (index == _items.length) return _footer();
        final status = _items[index];
        return StatusCard(
          key: _keyForStatus(status.id),
          status: status,
          onTap: () => _openDetail(status),
          onComment: () => _openDetail(status),
          onLike: () => _toggleLike(status),
          onRepost: () => _openDetail(status),
          onAvatarTap: () => _openUser(status),
          onMore: () => showStatusActionSheet(
            context,
            ref,
            status,
            onDeleted: () => _removeStatus(status.id),
          ),
          onDeleted: () => _removeStatus(status.id),
          onImageTap: (i) => _openGallery(status, i),
          onVideoTap: () => _openVideo(status),
        );
      },
    );

    final scrollableChild = NotificationListener<ScrollStartNotification>(
      onNotification: (notification) {
        if (_isRestoringScroll && notification.dragDetails != null) {
          _cancelRestore();
        }
        return false;
      },
      child: ref.watch(settingsProvider).fastScroll
          ? Scrollbar(
              controller: _controller,
              interactive: true,
              thumbVisibility: false,
              thickness: 5,
              radius: const Radius.circular(3),
              child: list,
            )
          : list,
    );

    return RefreshIndicator(
      color: ShareColors.accent,
      onRefresh: () => _loadFirst(scrollToTopAfter: true),
      child: scrollableChild,
    );
  }

  void _openDetail(Status status) {
    final uid = ref.read(sessionProvider).account?.uid ?? '';
    ShareCore.instance
        .historyRecordStatus(
          uid: uid,
          statusId: status.id,
          username: status.user?.displayName ?? '',
          avatar: status.user?.avatar ?? '',
          totalText: status.textRaw,
          statusJson:
              '{"id":"${status.id}","mblogid":"${status.mblogid}","text":"","text_raw":""}',
        )
        .catchError((_) {});
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => StatusDetailPage(status: status)),
    );
  }

  void _openUser(Status status) {
    final user = status.user;
    if (user == null) return;
    final uid = ref.read(sessionProvider).account?.uid ?? '';
    ShareCore.instance
        .historyRecordUser(
          uid: uid,
          targetUid: user.id,
          targetUserName: user.displayName,
          targetUserAvatar: user.avatar,
        )
        .catchError((_) {});
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserPage(
          uid: user.id,
          initialName: user.name,
          initialAvatar: user.avatar,
        ),
      ),
    );
  }

  void _openGallery(Status status, int index) {
    if (status.pics.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GalleryPage(pics: status.pics, initialIndex: index),
      ),
    );
  }

  void _openVideo(Status status) {
    ShareActions.openStatusVideo(context, status);
  }

  Widget _footer() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 1.8),
          ),
        ),
      );
    }
    if (!_hasMore && _items.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: Text('没有更多了', style: TextStyle(fontSize: 12, color: ShareColors.textHint)),
        ),
      );
    }
    return const SizedBox(height: 24);
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 42, color: ShareColors.textHint),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: ShareColors.textSecondary),
            ),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
