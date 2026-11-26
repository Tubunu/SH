import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/settings.dart';
import '../app_theme.dart';
import '../compose/compose_page.dart';
import '../discover/discover_page.dart';
import '../feed/feed_page.dart';
import '../message/message_page.dart';
import '../profile/profile_page.dart';
import 'share_drawer.dart';

class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  int _index = 0;
  bool _navVisible = true;
  bool _drawerOpen = false;
  Offset? _dragStart;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _feedKey = GlobalKey<FeedPageState>();
  int _unread = 0;
  Timer? _unreadTimer;

  late final _pages = [
    FeedPage(
      key: _feedKey,
      onSelectTab: _goToTab,
      onOpenDrawer: _openDrawer,
    ),
    const DiscoverPage(),
    const MessagePage(),
    const ProfilePage(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadUnread();
      WeiboApi.instance.warmEmotions();
    });
  }

  @override
  void dispose() {
    _unreadTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadUnread() async {
    if (!ref.read(sessionProvider).isLoggedIn) {
      if (mounted && _unread != 0) setState(() => _unread = 0);
      return;
    }
    try {
      final hint = await WeiboApi.instance.unreadHint();
      if (!mounted) return;
      setState(() => _unread = hint.total);
    } catch (_) {}
  }

  void _tickUnread() {
    if (!mounted || _index != 2) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    _loadUnread();
  }

  void _syncUnreadPolling() {
    _unreadTimer?.cancel();
    _unreadTimer = null;
    if (_index != 2) return;
    _unreadTimer = Timer.periodic(const Duration(seconds: 60), (_) => _tickUnread());
  }

  void _select(int index) {
    final target = index.clamp(0, _pages.length - 1);
    if (target != _index) {
      setState(() {
        _index = target;
        _navVisible = true;
      });
      if (target == 2) _loadUnread();
      _syncUnreadPolling();
    }
  }

  void _goToTab(int index) {
    if (!mounted) return;
    _select(index);
  }

  void _openDrawer() {
    if (ref.read(settingsProvider).showDrawerFromLeft) {
      _scaffoldKey.currentState?.openDrawer();
    } else {
      _scaffoldKey.currentState?.openEndDrawer();
    }
  }

  void _onDrawerChanged(bool isOpened) {
    if (!mounted) return;
    setState(() {
      _drawerOpen = isOpened;
      _dragStart = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);

    ref.listen<SessionState>(sessionProvider, (previous, next) {
      if ((previous?.isLoggedIn ?? false) == next.isLoggedIn) return;
      if (next.isLoggedIn) {
        _loadUnread();
      } else {
        setState(() => _unread = 0);
      }
      _syncUnreadPolling();
    });

    final hideBottomNav = settings.navigationPosition == 3;
    final fab = _buildFab(settings);
    final fabLeft = settings.showFabFromLeft;
    final hideHotTab = settings.hideHotTab;

    final coloredNav =
        settings.navigationThemeColor && settings.toolBarColorTheme && !ShareColors.isDark;
    final navBg = coloredNav ? ShareColors.toolbarBg : ShareColors.cardBg;

    final bar = hideBottomNav
        ? null
        : DecoratedBox(
            decoration: BoxDecoration(
              color: navBg,
              border: Border(
                top: BorderSide(
                  color: coloredNav ? Colors.transparent : ShareColors.divider,
                  width: 0.5,
                ),
              ),
            ),
            child: BottomAppBar(
              height: 52,
              padding: EdgeInsets.zero,
              color: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              child: Row(
                children: [
                  _tab(0, Icons.home_filled, Icons.home_outlined, '首页',
                      onColoredBg: coloredNav),
                  if (!hideHotTab)
                    _tab(1, Icons.local_fire_department, Icons.local_fire_department_outlined,
                        '热门',
                        onColoredBg: coloredNav),
                  _tab(
                    2,
                    Icons.chat_bubble,
                    Icons.chat_bubble_outline,
                    '消息',
                    badge: _unread > 0 ? (_unread > 99 ? '99+' : '$_unread') : null,
                    onColoredBg: coloredNav,
                  ),
                  _tab(3, Icons.person, Icons.person_outline, '我', onColoredBg: coloredNav),
                ],
              ),
            ),
          );

    final fabLocation = fab == null
        ? null
        : (fabLeft
            ? FloatingActionButtonLocation.startFloat
            : FloatingActionButtonLocation.endFloat);

    final fromLeft = settings.showDrawerFromLeft;
    final drawer = ShareDrawer(onSelectTab: _goToTab);

    return Scaffold(
      key: _scaffoldKey,
      drawer: fromLeft ? drawer : null,
      endDrawer: fromLeft ? null : drawer,
      drawerEnableOpenDragGesture: _index == 0,
      endDrawerEnableOpenDragGesture: _index == 0,
      onDrawerChanged: fromLeft ? _onDrawerChanged : null,
      onEndDrawerChanged: fromLeft ? null : _onDrawerChanged,
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          if (_drawerOpen) return;
          _dragStart = e.position;
        },
        onPointerMove: (e) {
          if (_drawerOpen) return;
          final start = _dragStart;
          if (start == null || _navVisible) return;
          if (!ref.read(settingsProvider).navHideOnScroll) return;
          final dy = e.position.dy - start.dy;
          final dx = (e.position.dx - start.dx).abs();
          // Dragging finger downward (scrolling back up) restores the bar even on short non-scrollable pages.
          if (dy > 14 && dy > dx * 1.2) {
            _dragStart = null;
            setState(() => _navVisible = true);
          }
        },
        onPointerUp: (_) => _dragStart = null,
        onPointerCancel: (_) => _dragStart = null,
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (_drawerOpen || !ref.read(settingsProvider).navHideOnScroll) {
              return false;
            }
            if (notification.metrics.axis != Axis.vertical) return false;
            if (notification is ScrollUpdateNotification) {
              if (notification.metrics.outOfRange &&
                  notification.metrics.pixels <=
                      notification.metrics.minScrollExtent) {
                if (!_navVisible) setState(() => _navVisible = true);
                return false;
              }
              final delta = notification.scrollDelta ?? 0;
              if (delta > 1.2 && _navVisible) {
                setState(() => _navVisible = false);
              } else if (delta < -1.2 && !_navVisible) {
                setState(() => _navVisible = true);
              }
            } else if (notification is OverscrollNotification) {
              if (notification.overscroll < -1.5 && !_navVisible) {
                setState(() => _navVisible = true);
              } else if (notification.overscroll > 1.5 && _navVisible) {
                setState(() => _navVisible = false);
              }
            } else if (notification is UserScrollNotification) {
              if (notification.direction == ScrollDirection.forward && !_navVisible) {
                setState(() => _navVisible = true);
              }
            }
            return false;
          },
          child: IndexedStack(index: _index, children: _pages),
        ),
      ),
      floatingActionButton: fab,
      floatingActionButtonLocation: fabLocation,
      bottomNavigationBar: (!hideBottomNav && (_navVisible || fab == null))
          ? bar
          : const SizedBox.shrink(),
    );
  }

  Widget? _buildFab(AppSettings settings) {
    final option = settings.fabOption;
    if (option == 1) return null;
    return SizedBox(
      width: 52,
      height: 52,
      child: FloatingActionButton(
        elevation: 3,
        highlightElevation: 5,
        onPressed: () => switch (option) {
          2 => _pickGroup(),
          3 => _refresh(),
          _ => _compose(),
        },
        shape: const CircleBorder(),
        child: Icon(
          switch (option) {
            2 => Icons.swap_horiz,
            3 => Icons.refresh,
            _ => Icons.edit,
          },
          size: 22,
        ),
      ),
    );
  }

  void _compose() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ComposePage()),
    );
  }

  void _refresh() {
    if (_index == 0) {
      _feedKey.currentState?.scrollToTopAndRefresh();
      return;
    }
    setState(() {});
  }

  void _pickGroup() {
    final feed = _feedKey.currentState;
    if (feed == null) return;
    feed.openGroupMenu();
  }

  Widget _tab(
    int index,
    IconData active,
    IconData inactive,
    String label, {
    String? badge,
    bool onColoredBg = false,
  }) {
    final selected = _index == index;
    final color = onColoredBg
        ? (selected ? Colors.white : Colors.white.withValues(alpha: 0.72))
        : (selected ? ShareColors.accent : ShareColors.textSecondary);
    return Expanded(
      child: InkWell(
        onTap: () {
          if (_index == index) {
            if (index == 0) {
              if (ref.read(settingsProvider).reselectRefresh) {
                _feedKey.currentState?.scrollToTopAndRefresh();
              } else {
                _feedKey.currentState?.toggleTopOrLastPosition();
              }
            }
            return;
          }
          _select(index);
        },
        onDoubleTap: index == 0
            ? () {
                if (_index != 0) _select(0);
                _feedKey.currentState?.scrollToTopAndRefresh();
              }
            : null,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _badgedIcon(selected ? active : inactive, color, badge),
            const SizedBox(height: 1.5),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _badgedIcon(IconData data, Color color, String? badge) {
    final icon = Icon(data, size: 21, color: color);
    if (badge == null) return icon;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(top: -3, right: -9, child: _badge(badge)),
      ],
    );
  }

  Widget _badge(String text) {
    return Container(
      height: 14,
      constraints: const BoxConstraints(minWidth: 14),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: ShareColors.accent,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 9.5, color: Colors.white, height: 1.05),
      ),
    );
  }
}
