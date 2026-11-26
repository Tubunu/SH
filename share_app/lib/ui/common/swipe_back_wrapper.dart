import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings.dart';

/// 注册一个作用域开关，允许子页面在特定状态下临时禁用中屏滑动返回
/// （例如 `GalleryPage` 图片双指/双击放大时、播放器锁屏时）。
class SwipeBackGuard extends StatefulWidget {
  const SwipeBackGuard({
    super.key,
    required this.disabled,
    required this.child,
  });

  final bool disabled;
  final Widget child;

  @override
  State<SwipeBackGuard> createState() => _SwipeBackGuardState();
}

class _SwipeBackGuardState extends State<SwipeBackGuard> {
  final Object _token = Object();
  _SwipeBackRegistry? _registry;

  void _sync() {
    _registry?.setSuppressed(_token, widget.disabled);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = _SwipeBackScope.maybeOf(context);
    if (!identical(next, _registry)) {
      _registry?.setSuppressed(_token, false);
      _registry = next;
    }
    _sync();
  }

  @override
  void didUpdateWidget(covariant SwipeBackGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.disabled != widget.disabled) {
      _sync();
    }
  }

  @override
  void dispose() {
    _registry?.setSuppressed(_token, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _SwipeBackRegistry {
  final Set<Object> _tokens = <Object>{};

  bool get isSuppressed => _tokens.isNotEmpty;

  void setSuppressed(Object token, bool suppressed) {
    if (suppressed) {
      _tokens.add(token);
    } else {
      _tokens.remove(token);
    }
  }
}

class _SwipeBackScope extends InheritedWidget {
  const _SwipeBackScope({
    required this.registry,
    required super.child,
  });

  final _SwipeBackRegistry registry;

  static _SwipeBackRegistry? maybeOf(BuildContext context) {
    return context.getInheritedWidgetOfExactType<_SwipeBackScope>()?.registry;
  }

  @override
  bool updateShouldNotify(_SwipeBackScope oldWidget) =>
      !identical(registry, oldWidget.registry);
}

/// 统一的页面转场构建器：
/// - 保留各平台原生转场与 iOS 左边缘原生返回手势；
/// - 为所有可返回的二级页面增加“屏幕中部左/右滑动返回”支持，并遵循
///   `AppSettings.swipeBackMode`（1=右滑，2=左滑，3=左或右滑，4=禁用）。
class ShareSwipeBackPageTransitionsBuilder extends PageTransitionsBuilder {
  const ShareSwipeBackPageTransitionsBuilder({
    required this.platform,
    this.fallbackSwipeBackMode = 3,
  });

  final TargetPlatform platform;
  final int fallbackSwipeBackMode;

  PageTransitionsBuilder get _delegate => switch (platform) {
        TargetPlatform.iOS ||
        TargetPlatform.macOS =>
          const CupertinoPageTransitionsBuilder(),
        TargetPlatform.android => const PredictiveBackPageTransitionsBuilder(),
        TargetPlatform.fuchsia ||
        TargetPlatform.linux ||
        TargetPlatform.windows =>
          const ZoomPageTransitionsBuilder(),
      };

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      _delegate.delegatedTransition;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final wrapped = _MidScreenSwipeBackHost<T>(
      route: route,
      platform: platform,
      fallbackSwipeBackMode: fallbackSwipeBackMode,
      child: child,
    );
    return _delegate.buildTransitions<T>(
      route,
      context,
      animation,
      secondaryAnimation,
      wrapped,
    );
  }
}

class _MidScreenSwipeBackHost<T> extends StatefulWidget {
  const _MidScreenSwipeBackHost({
    required this.route,
    required this.platform,
    required this.fallbackSwipeBackMode,
    required this.child,
  });

  final PageRoute<T> route;
  final TargetPlatform platform;
  final int fallbackSwipeBackMode;
  final Widget child;

  @override
  State<_MidScreenSwipeBackHost<T>> createState() =>
      _MidScreenSwipeBackHostState<T>();
}

class _MidScreenSwipeBackHostState<T> extends State<_MidScreenSwipeBackHost<T>> {
  static const double _commitDistance = 72.0;
  static const double _commitFlingVelocity = 360.0;
  static const double _minFlingDistance = 24.0;
  static const double _cupertinoEdgeWidth = 22.0;

  final _SwipeBackRegistry _registry = _SwipeBackRegistry();

  double _dragStartGlobalX = 0.0;
  double _dragDelta = 0.0;
  int _dragDirection = 0; // 1 = right swipe, -1 = left swipe, 0 = none
  bool _canInteractiveSession = false;
  bool _interactiveBackActive = false;
  NavigatorState? _gestureNavigator;

  double _pillOffset = 0.0;
  int _pillDirection = 0;

  bool _edgeRightArmed = false;
  double _edgeRightDx = 0.0;
  int? _edgePointerId;
  VelocityTracker? _edgeVelocityTracker;

  bool get _isCupertinoPlatform =>
      widget.platform == TargetPlatform.iOS ||
      widget.platform == TargetPlatform.macOS;

  int _resolveMode() {
    try {
      return ProviderScope.containerOf(context, listen: false)
          .read(settingsProvider)
          .swipeBackMode;
    } catch (_) {
      return widget.fallbackSwipeBackMode;
    }
  }

  bool _allowsRight(int mode) => mode == 1 || mode == 3;
  bool _allowsLeft(int mode) => mode == 2 || mode == 3;

  bool _canAcceptPointer(Offset globalPosition) {
    if (!mounted || _registry.isSuppressed) return false;
    if (!widget.route.canPop || widget.route.isFirst) return false;
    if (!widget.route.isCurrent) return false;
    final mode = _resolveMode();
    if (mode == 4) return false;
    if (_isCupertinoPlatform && widget.route.popGestureEnabled) {
      final edgeWidth = math.max(
        _cupertinoEdgeWidth,
        MediaQuery.paddingOf(context).left,
      );
      if (globalPosition.dx <= edgeWidth) {
        return false;
      }
    }
    return true;
  }

  bool _allowsDirection(int dir) {
    final mode = _resolveMode();
    if (dir > 0) return _allowsRight(mode);
    if (dir < 0) return _allowsLeft(mode);
    return false;
  }

  void _handleDragStart(DragStartDetails details) {
    _dragStartGlobalX = details.globalPosition.dx;
    _dragDelta = 0.0;
    _dragDirection = 0;
    _interactiveBackActive = false;
    _canInteractiveSession = _isCupertinoPlatform &&
        widget.route.popGestureEnabled &&
        _allowsRight(_resolveMode());
    _pillOffset = 0.0;
    _pillDirection = 0;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (!mounted || _registry.isSuppressed || !widget.route.isCurrent) {
      _cancelActiveGesture();
      return;
    }

    final rawDx = details.globalPosition.dx - _dragStartGlobalX;

    // 已经进入 iOS 交互式右滑跟手返回阶段后，锁定在交互会话内按全局坐标更新进度，
    // 禁止每帧重查 popGestureEnabled（否则 animation.isCompleted 变 false 会触发反复取消与抽动）。
    if (_interactiveBackActive) {
      _dragDelta = math.max(0.0, rawDx);
      _dragDirection = 1;
      final width = math.max(MediaQuery.sizeOf(context).width, 200.0);
      final progress = (1.0 - (_dragDelta / width)).clamp(0.0, 1.0);
      widget.route.handleUpdateBackGestureProgress(progress: progress);
      return;
    }

    _dragDelta = rawDx;
    if (_dragDelta == 0) return;

    final dir = _dragDelta > 0 ? 1 : -1;
    _dragDirection = dir;
    if (!_allowsDirection(dir)) {
      if (_pillOffset != 0.0) {
        setState(() {
          _pillOffset = 0.0;
          _pillDirection = 0;
        });
      }
      return;
    }

    if (_canInteractiveSession && dir > 0) {
      _pillOffset = 0.0;
      _pillDirection = 0;
      _gestureNavigator = Navigator.maybeOf(context);
      widget.route.handleStartBackGesture(progress: 1.0);
      _interactiveBackActive = true;
      final width = math.max(MediaQuery.sizeOf(context).width, 200.0);
      final progress = (1.0 - (_dragDelta / width)).clamp(0.0, 1.0);
      widget.route.handleUpdateBackGestureProgress(progress: progress);
      return;
    }

    setState(() {
      _pillDirection = dir;
      _pillOffset = _dragDelta.abs();
    });
  }

  void _handleDragEnd(DragEndDetails details) {
    final dx = _dragDelta;
    final dir = _dragDirection;
    final vx = details.velocity.pixelsPerSecond.dx;
    _dragDelta = 0.0;
    _dragDirection = 0;
    _canInteractiveSession = false;

    if (!mounted || _registry.isSuppressed || dir == 0 || !_allowsDirection(dir)) {
      _cancelActiveGesture();
      return;
    }

    final width = math.max(MediaQuery.sizeOf(context).width, 200.0);
    final commitDistance = _interactiveBackActive
        ? math.min(width * 0.32, _commitDistance * 1.4)
        : _commitDistance;
    final signedDistance = dir > 0 ? dx : -dx;
    final signedVelocity = dir > 0 ? vx : -vx;
    final committed = signedDistance >= commitDistance ||
        (signedVelocity >= _commitFlingVelocity &&
            signedDistance >= _minFlingDistance);

    if (_interactiveBackActive) {
      _commitOrCancelInteractiveBack(committed);
      return;
    }

    setState(() {
      _pillOffset = 0.0;
      _pillDirection = 0;
    });
    if (committed) {
      _tryMaybePop();
    }
  }

  void _handleDragCancel() {
    _dragDelta = 0.0;
    _dragDirection = 0;
    _canInteractiveSession = false;
    _cancelActiveGesture();
  }

  void _cancelActiveGesture() {
    _cancelInteractiveBackIfNeeded();
    if (_pillOffset != 0.0 && mounted) {
      setState(() {
        _pillOffset = 0.0;
        _pillDirection = 0;
      });
    } else {
      _pillOffset = 0.0;
      _pillDirection = 0;
    }
  }

  void _cancelInteractiveBackIfNeeded() {
    if (!_interactiveBackActive) return;
    _interactiveBackActive = false;
    _gestureNavigator = null;
    widget.route.handleCancelBackGesture();
  }

  void _commitOrCancelInteractiveBack(bool committed) {
    _interactiveBackActive = false;
    final nav = _gestureNavigator ?? Navigator.maybeOf(context);
    _gestureNavigator = null;
    if (!committed || nav == null || !widget.route.isCurrent) {
      widget.route.handleCancelBackGesture();
      return;
    }
    if (widget.route.willHandlePopInternally ||
        widget.route.popDisposition == RoutePopDisposition.doNotPop) {
      widget.route.handleCancelBackGesture();
      nav.maybePop();
      return;
    }

    final anim = widget.route.animation;
    if (anim != null && !anim.isDismissed) {
      late final AnimationStatusListener listener;
      listener = (AnimationStatus status) {
        if (status == AnimationStatus.dismissed ||
            status == AnimationStatus.completed) {
          anim.removeStatusListener(listener);
          if (nav.userGestureInProgress) {
            nav.didStopUserGesture();
          }
        }
      };
      anim.addStatusListener(listener);
      nav.pop();
      if (anim.isDismissed && nav.userGestureInProgress) {
        anim.removeStatusListener(listener);
        nav.didStopUserGesture();
      }
    } else {
      nav.pop();
      if (nav.userGestureInProgress) {
        nav.didStopUserGesture();
      }
    }
  }

  void _tryMaybePop() {
    if (!mounted || !widget.route.isCurrent || !widget.route.canPop) return;
    Navigator.maybeOf(context)?.maybePop();
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_edgePointerId != null) {
      // Multi-touch cancels any leading-edge overscroll tracking.
      _resetEdgeOverscroll();
      return;
    }
    _edgePointerId = event.pointer;
    _edgeVelocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _edgePointerId) return;
    _edgeVelocityTracker?.addPosition(event.timeStamp, event.position);
  }

  void _handlePointerUpOrCancel(PointerEvent event, {required bool cancelled}) {
    if (event.pointer != _edgePointerId) return;
    final vx =
        _edgeVelocityTracker?.getVelocity().pixelsPerSecond.dx ?? 0.0;
    final armed = _edgeRightArmed;
    final dist = _edgeRightDx;
    _edgePointerId = null;
    _edgeVelocityTracker = null;
    if (!armed || cancelled) {
      _resetEdgeOverscroll();
      return;
    }
    _finalizeEdgeOverscroll(dist: dist, vx: vx);
  }

  void _finalizeEdgeOverscroll({required double dist, required double vx}) {
    _resetEdgeOverscroll();
    if (!mounted || _registry.isSuppressed) return;
    final mode = _resolveMode();
    if (!_allowsRight(mode)) return;
    if (dist >= _commitDistance ||
        (vx >= _commitFlingVelocity && dist >= _minFlingDistance)) {
      _tryMaybePop();
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (!mounted ||
        _registry.isSuppressed ||
        !widget.route.canPop ||
        widget.route.isFirst ||
        !widget.route.isCurrent) {
      _resetEdgeOverscroll();
      return false;
    }
    if (notification.metrics.axis != Axis.horizontal) return false;
    final screenWidth = MediaQuery.sizeOf(context).width;
    if (notification.metrics.viewportDimension < screenWidth * 0.85) {
      return false;
    }

    final mode = _resolveMode();
    if (!_allowsRight(mode)) {
      _resetEdgeOverscroll();
      return false;
    }

    if (notification is ScrollStartNotification) {
      final atLeadingEdge =
          notification.metrics.pixels <= notification.metrics.minScrollExtent + 0.5;
      _edgeRightArmed = notification.dragDetails != null && atLeadingEdge;
      _edgeRightDx = 0.0;
      return false;
    }

    if (notification is ScrollUpdateNotification) {
      if (!_edgeRightArmed) return false;
      if (notification.metrics.pixels >
          notification.metrics.minScrollExtent + 4.0) {
        _resetEdgeOverscroll();
        return false;
      }
      final deltaDx = notification.dragDetails?.delta.dx ?? 0.0;
      if (deltaDx != 0.0 ||
          notification.metrics.pixels < notification.metrics.minScrollExtent) {
        final next = (_edgeRightDx + deltaDx).clamp(0.0, 240.0);
        if (next != _edgeRightDx) {
          setState(() {
            _edgeRightDx = next;
            _pillDirection = 1;
            _pillOffset = next;
          });
        }
      }
      return false;
    }

    if (notification is OverscrollNotification) {
      if (!_edgeRightArmed &&
          notification.dragDetails != null &&
          notification.overscroll < 0 &&
          notification.metrics.pixels <=
              notification.metrics.minScrollExtent + 0.5) {
        _edgeRightArmed = true;
      }
      if (!_edgeRightArmed) return false;
      if (notification.overscroll < 0) {
        final dragDx = notification.dragDetails?.delta.dx ?? 0.0;
        final inc = math.max(-notification.overscroll, dragDx);
        final next = (_edgeRightDx + inc).clamp(0.0, 240.0);
        setState(() {
          _edgeRightDx = next;
          _pillDirection = 1;
          _pillOffset = next;
        });
      }
      return false;
    }

    if (notification is ScrollEndNotification && _edgeRightArmed) {
      final vx =
          notification.dragDetails?.velocity.pixelsPerSecond.dx ?? 0.0;
      _finalizeEdgeOverscroll(dist: _edgeRightDx, vx: vx);
    }

    return false;
  }

  void _resetEdgeOverscroll() {
    _edgeRightArmed = false;
    _edgeRightDx = 0.0;
    if (_pillOffset != 0.0 && mounted) {
      setState(() {
        _pillOffset = 0.0;
        _pillDirection = 0;
      });
    } else {
      _pillOffset = 0.0;
      _pillDirection = 0;
    }
  }

  @override
  void dispose() {
    if (_interactiveBackActive) {
      _interactiveBackActive = false;
      final nav = _gestureNavigator;
      _gestureNavigator = null;
      if (nav != null && nav.userGestureInProgress) {
        nav.didStopUserGesture();
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pillActive = _pillOffset >= 8.0 && _pillDirection != 0;
    final progress = (_pillOffset / _commitDistance).clamp(0.0, 1.0);
    final committedLook = _pillOffset >= _commitDistance;

    return _SwipeBackScope(
      registry: _registry,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: (e) => _handlePointerUpOrCancel(e, cancelled: false),
        onPointerCancel: (e) => _handlePointerUpOrCancel(e, cancelled: true),
        child: NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: RawGestureDetector(
            behavior: HitTestBehavior.translucent,
            gestures: <Type, GestureRecognizerFactory>{
              _DirectionalSwipeBackRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                      _DirectionalSwipeBackRecognizer>(
                () => _DirectionalSwipeBackRecognizer(
                  canAcceptPointer: _canAcceptPointer,
                  allowsRight: () => _allowsRight(_resolveMode()),
                  allowsLeft: () => _allowsLeft(_resolveMode()),
                ),
                (_DirectionalSwipeBackRecognizer instance) {
                  instance.onlyAcceptDragOnThreshold = true;
                  instance.canAcceptPointer = _canAcceptPointer;
                  instance.allowsRight = () => _allowsRight(_resolveMode());
                  instance.allowsLeft = () => _allowsLeft(_resolveMode());
                  instance.onStart = _handleDragStart;
                  instance.onUpdate = _handleDragUpdate;
                  instance.onEnd = _handleDragEnd;
                  instance.onCancel = _handleDragCancel;
                },
              ),
            },
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                widget.child,
                if (pillActive)
                  _SwipeBackIndicatorPill(
                    fromLeft: _pillDirection > 0,
                    progress: progress,
                    ready: committedLook,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SwipeBackIndicatorPill extends StatelessWidget {
  const _SwipeBackIndicatorPill({
    required this.fromLeft,
    required this.progress,
    required this.ready,
  });

  final bool fromLeft;
  final double progress;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = ready
        ? theme.colorScheme.primary.withValues(alpha: 0.92)
        : Colors.black.withValues(alpha: 0.62);
    final fg = ready ? theme.colorScheme.onPrimary : Colors.white;
    final slideOffset = 8.0 + 18.0 * Curves.easeOutCubic.transform(progress);

    return Positioned(
      top: 0,
      bottom: 0,
      left: fromLeft ? slideOffset : null,
      right: fromLeft ? null : slideOffset,
      child: IgnorePointer(
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            width: ready ? 36 : 30,
            height: ready ? 48 : 42,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(18),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 10,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Icon(
              fromLeft ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
              color: fg,
              size: 24,
            ),
          ),
        ),
      ),
    );
  }
}

class _DirectionalSwipeBackRecognizer extends HorizontalDragGestureRecognizer {
  _DirectionalSwipeBackRecognizer({
    required this.canAcceptPointer,
    required this.allowsRight,
    required this.allowsLeft,
  });

  bool Function(Offset globalPosition) canAcceptPointer;
  bool Function() allowsRight;
  bool Function() allowsLeft;

  final Map<int, Offset> _downPositions = <int, Offset>{};
  bool _accepted = false;

  @override
  bool isPointerAllowed(PointerEvent event) {
    if (event is PointerDownEvent && !canAcceptPointer(event.position)) {
      return false;
    }
    return super.isPointerAllowed(event);
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _downPositions[event.pointer] = event.position;
    super.addAllowedPointer(event);
  }

  @override
  void acceptGesture(int pointer) {
    _accepted = true;
    super.acceptGesture(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    _downPositions.remove(pointer);
    _accepted = false;
    super.rejectGesture(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _downPositions.remove(pointer);
    _accepted = false;
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent && !_accepted) {
      final start = _downPositions[event.pointer];
      if (start != null) {
        final dx = event.position.dx - start.dx;
        final dy = event.position.dy - start.dy;
        final slop = computeHitSlop(event.kind, gestureSettings);
        if ((dx > slop * 0.6 && !allowsRight()) ||
            (dx < -slop * 0.6 && !allowsLeft()) ||
            (dy.abs() > slop * 0.7 && dy.abs() > dx.abs() * 1.15)) {
          rejectGesture(event.pointer);
          return;
        }
      }
    }
    super.handleEvent(event);
  }
}
