import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/settings.dart';
import '../../core/share_core.dart';
import '../app_theme.dart';
import '../common/in_app_web_page.dart';

/// Full-screen player for Weibo videos — `MediaPlayerActivity` 的等价实现。
///
/// 手势对齐原版：单击显隐控件、双击播放/暂停、横滑调进度、长按 2 倍速；
/// 右下角可选 0.5×–2× 倍速。是否自动播放跟随「自动播放视频和动图」设置
/// （仅 Wi-Fi / 总是 / 从不）。
class VideoPage extends ConsumerStatefulWidget {
  final String url;
  final String? objectId;
  final String? cover;
  final String? title;

  const VideoPage({
    super.key,
    required this.url,
    this.objectId,
    this.cover,
    this.title,
  });

  @override
  ConsumerState<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends ConsumerState<VideoPage> {
  static const Map<String, String> _httpHeaders = {
    'Referer': 'https://weibo.com/',
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36',
  };

  VideoPlayerController? _controller;
  bool _ready = false;
  bool _showChrome = true;
  bool _autoClosing = false;
  String? _error;

  double _speed = 1;
  bool _longPressBoost = false;
  List<({String label, String url})> _qualities = const [];
  String? _activeQualityLabel;

  /// 拖动进度时的临时位置（毫秒），null 表示没有在拖。
  double? _seekPreview;

  Timer? _chromeTimer;
  Timer? _hudTimer;
  String? _hud;

  @override
  void initState() {
    super.initState();
    _init();
  }

  static bool _isPlayableMediaUrl(String url) {
    final lower = url.toLowerCase();
    if (!lower.startsWith('http')) return false;
    if (lower.contains('weibo.com/tv/show') ||
        lower.contains('video.weibo.com/show') ||
        lower.contains('h5.video.weibo.com/show')) {
      return false;
    }
    return lower.contains('.mp4') ||
        lower.contains('.m3u8') ||
        lower.contains('.mov') ||
        lower.contains('weibocdn.com') ||
        lower.contains('miaopai') ||
        lower.contains('f.video.');
  }

  static void _addProtocolVariants(List<String> out, String raw) {
    var u = raw.trim();
    if (u.isEmpty) return;
    if (u.startsWith('//')) u = 'https:$u';
    if (!u.startsWith('http')) return;
    if (!out.contains(u)) out.add(u);
    if (u.startsWith('http://')) {
      final https = 'https://${u.substring(7)}';
      if (!out.contains(https)) out.add(https);
    } else if (u.startsWith('https://')) {
      final http = 'http://${u.substring(8)}';
      if (!out.contains(http)) out.add(http);
    }
  }

  static List<({String label, String url})> _extractLabeledQualities(
    Map<String, dynamic> map,
  ) {
    final ordered = <({int rank, String label, String url})>[];
    final seenUrls = <String>{};

    void record(int rank, String label, dynamic raw) {
      if (raw is! String) return;
      final trimmed = raw.trim();
      if (!_isPlayableMediaUrl(trimmed)) return;
      final normalized =
          trimmed.startsWith('//') ? 'https:$trimmed' : trimmed;
      if (seenUrls.add(normalized)) {
        ordered.add((rank: rank, label: label, url: normalized));
      }
    }

    void scan(dynamic node) {
      if (node is List) {
        for (final item in node) {
          scan(item);
        }
      } else if (node is Map) {
        record(1, '超清', node['mp4_1080p_mp4'] ?? node['1080p'] ?? node['1080']);
        record(
          2,
          '高清',
          node['mp4_720p_mp4'] ?? node['stream_url_hd'] ?? node['720p'] ?? node['720'],
        );
        record(
          3,
          '标清',
          node['mp4_hd_mp4'] ?? node['inch_5_5_mp4_hd'] ?? node['stream_url'] ?? node['480p'],
        );
        record(
          4,
          '流畅',
          node['mp4_sd_mp4'] ?? node['mp4_ld_mp4'] ?? node['360p'],
        );
        for (final v in node.values) {
          scan(v);
        }
      }
    }

    scan(map);
    ordered.sort((a, b) => a.rank.compareTo(b.rank));
    final dedupLabels = <String>{};
    final result = <({String label, String url})>[];
    for (final q in ordered) {
      if (dedupLabels.add(q.label)) {
        result.add((label: q.label, url: q.url));
      }
    }
    return result;
  }

  static int _preferredRankForChoice(int choice, {required bool isWifi}) {
    return switch (choice) {
      1 => 1, // 超清
      2 => 2, // 高清
      3 => 3, // 标清
      4 => 4, // 流畅
      5 => isWifi ? 2 : 3, // 自动：Wi-Fi 高清，移动网络标清
      _ => 3,
    };
  }

  static List<String> _extractFromPlaybackMap(Map<String, dynamic> map) {
    final urls = <String>[];
    void scan(dynamic node) {
      if (node is String) {
        if (_isPlayableMediaUrl(node)) _addProtocolVariants(urls, node);
      } else if (node is List) {
        for (final item in node) {
          scan(item);
        }
      } else if (node is Map) {
        for (final preferred in const [
          'mp4_720p_mp4',
          'mp4_hd_mp4',
          'inch_5_5_mp4_hd',
          'mp4_sd_mp4',
          'mp4_ld_mp4',
          'stream_url_hd',
          'stream_url',
          'url',
          'urls',
          'data',
          'media_info',
        ]) {
          if (node.containsKey(preferred)) scan(node[preferred]);
        }
        for (final v in node.values) {
          scan(v);
        }
      }
    }

    scan(map);
    return urls;
  }

  String? get _fallbackWebUrl {
    final oid = widget.objectId?.trim();
    if (oid != null && oid.isNotEmpty) {
      return 'https://h5.video.weibo.com/show/$oid';
    }
    var u = widget.url.trim();
    if (u.startsWith('//')) u = 'https:$u';
    if (u.startsWith('http') && !_isPlayableMediaUrl(u)) return u;
    return null;
  }

  Future<bool> _isWifiOrEthernet() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return false;
    }
  }

  Future<void> _init() async {
    setState(() {
      _error = null;
      _ready = false;
      _autoClosing = false;
    });

    final candidates = <String>[];
    final oid = widget.objectId?.trim();
    List<({String label, String url})> qualities = const [];
    Map<String, dynamic>? playback;

    if (oid != null && oid.isNotEmpty) {
      try {
        playback = await ShareCore.instance.videoPlayback(oid);
        qualities = _extractLabeledQualities(playback);
      } catch (_) {}
    }

    if (qualities.isNotEmpty) {
      final qualityChoice = ref.read(settingsProvider).choiceOf('video_play_quality');
      final isWifi = qualityChoice == 5 ? await _isWifiOrEthernet() : false;
      final preferredRank = _preferredRankForChoice(qualityChoice, isWifi: isWifi);
      final ordered = List<({String label, String url})>.from(qualities)
        ..sort((a, b) {
          int rankOf(String lbl) => switch (lbl) {
                '超清' => 1,
                '高清' => 2,
                '标清' => 3,
                '流畅' => 4,
                _ => 5,
              };
          return (rankOf(a.label) - preferredRank)
              .abs()
              .compareTo((rankOf(b.label) - preferredRank).abs());
        });
      _qualities = qualities;
      _activeQualityLabel = ordered.first.label;
      for (final q in ordered) {
        _addProtocolVariants(candidates, q.url);
      }
    }

    if (playback != null) {
      for (final u in _extractFromPlaybackMap(playback)) {
        _addProtocolVariants(candidates, u);
      }
    }

    if (_isPlayableMediaUrl(widget.url)) {
      _addProtocolVariants(candidates, widget.url);
    } else if (candidates.isEmpty && widget.url.trim().isNotEmpty) {
      _addProtocolVariants(candidates, widget.url);
    }

    Object? lastError;
    for (final url in candidates) {
      if (!mounted) return;
      VideoPlayerController? controller;
      try {
        controller = VideoPlayerController.networkUrl(
          Uri.parse(url),
          httpHeaders: _httpHeaders,
        );
        await controller.initialize();
        if (!mounted) {
          await controller.dispose();
          return;
        }
        final prev = _controller;
        _controller = controller;
        await prev?.dispose();
        controller.addListener(_onTick);
        if (await _shouldAutoPlay()) {
          await controller.play();
        }
        if (!mounted) return;
        setState(() {
          _ready = true;
          _error = null;
        });
        _scheduleChromeHide();
        return;
      } catch (e) {
        lastError = e;
        await controller?.dispose();
      }
    }

    if (oid != null && oid.isNotEmpty && _isPlayableMediaUrl(widget.url)) {
      try {
        final playback = await ShareCore.instance.videoPlayback(oid);
        final extra = _extractFromPlaybackMap(playback)
            .where((u) => !candidates.contains(u))
            .toList();
        for (final url in extra) {
          if (!mounted) return;
          VideoPlayerController? controller;
          try {
            controller = VideoPlayerController.networkUrl(
              Uri.parse(url),
              httpHeaders: _httpHeaders,
            );
            await controller.initialize();
            if (!mounted) {
              await controller.dispose();
              return;
            }
            _controller = controller;
            controller.addListener(_onTick);
            if (await _shouldAutoPlay()) {
              await controller.play();
            }
            if (!mounted) return;
            setState(() {
              _ready = true;
              _error = null;
            });
            _scheduleChromeHide();
            return;
          } catch (e) {
            lastError = e;
            await controller?.dispose();
          }
        }
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _error = lastError != null ? '视频加载失败：$lastError' : '该视频暂无可播放流';
    });
  }

  /// 自动播放视频和动图：1 仅 Wi-Fi / 2 总是 / 3 从不。
  Future<bool> _shouldAutoPlay() async {
    final option = ref.read(settingsProvider).choiceOf('auto_play_options');
    if (option == 3) return false;
    if (option == 2) return true;
    try {
      final results = await Connectivity().checkConnectivity();
      return results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet);
    } catch (_) {
      // 判断不了网络类型时按「仅 Wi-Fi」从严处理，避免偷跑流量。
      return false;
    }
  }

  void _onTick() {
    if (!mounted) return;
    final c = _controller;
    if (c != null && !_autoClosing) {
      final v = c.value;
      if (v.isInitialized &&
          !v.isPlaying &&
          v.duration > Duration.zero &&
          v.position >= v.duration - const Duration(milliseconds: 250)) {
        if (ref.read(settingsProvider).flag('auto_close_video')) {
          _autoClosing = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).maybePop();
          });
          return;
        }
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    _chromeTimer?.cancel();
    _hudTimer?.cancel();
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  void _scheduleChromeHide() {
    _chromeTimer?.cancel();
    if (!_showChrome) return;
    _chromeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showChrome = false);
    });
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null || !_ready) return;
    setState(() {
      controller.value.isPlaying ? controller.pause() : controller.play();
    });
    _flashHud(controller.value.isPlaying ? null : '已暂停');
  }

  void _flashHud(String? text, {Duration duration = const Duration(milliseconds: 700)}) {
    _hudTimer?.cancel();
    if (!mounted) return;
    setState(() => _hud = text);
    if (text == null) return;
    _hudTimer = Timer(duration, () {
      if (mounted) setState(() => _hud = null);
    });
  }

  Future<void> _pickSpeed() async {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    final picked = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: ShareColors.cardBg,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Row(
                children: [
                  Text('播放速度',
                      style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
                ],
              ),
            ),
            for (final speed in speeds)
              ListTile(
                dense: true,
                title: Text('${speed}x', style: const TextStyle(fontSize: 15)),
                trailing: (_speed == speed)
                    ? Icon(Icons.check, size: 18, color: ShareColors.accent)
                    : null,
                onTap: () => Navigator.pop(ctx, speed),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await _setSpeed(picked);
  }

  Future<void> _pickQuality() async {
    if (_qualities.length < 2) return;
    final picked = await showModalBottomSheet<({String label, String url})>(
      context: context,
      backgroundColor: ShareColors.cardBg,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Row(
                children: [
                  Text('视频清晰度',
                      style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
                ],
              ),
            ),
            for (final q in _qualities)
              ListTile(
                dense: true,
                title: Text(q.label, style: const TextStyle(fontSize: 15)),
                trailing: (_activeQualityLabel == q.label)
                    ? Icon(Icons.check, size: 18, color: ShareColors.accent)
                    : null,
                onTap: () => Navigator.pop(ctx, q),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked.label == _activeQualityLabel) return;

    final prev = _controller;
    final resumePos = prev?.value.position ?? Duration.zero;
    final wasPlaying = prev?.value.isPlaying ?? true;

    final urls = <String>[];
    _addProtocolVariants(urls, picked.url);
    for (final u in urls) {
      VideoPlayerController? nextCtrl;
      try {
        nextCtrl = VideoPlayerController.networkUrl(
          Uri.parse(u),
          httpHeaders: _httpHeaders,
        );
        await nextCtrl.initialize();
        if (!mounted) {
          await nextCtrl.dispose();
          return;
        }
        await nextCtrl.setPlaybackSpeed(_speed);
        if (resumePos > Duration.zero && resumePos < nextCtrl.value.duration) {
          await nextCtrl.seekTo(resumePos);
        }
        if (wasPlaying) await nextCtrl.play();
        prev?.removeListener(_onTick);
        await prev?.dispose();
        nextCtrl.addListener(_onTick);
        if (!mounted) {
          await nextCtrl.dispose();
          return;
        }
        setState(() {
          _controller = nextCtrl;
          _activeQualityLabel = picked.label;
        });
        _flashHud('已切换 ${picked.label}');
        _scheduleChromeHide();
        return;
      } catch (_) {
        await nextCtrl?.dispose();
      }
    }
    if (mounted) _flashHud('切换清晰度失败');
  }

  Future<void> _setSpeed(double speed) async {
    _speed = speed;
    await _controller?.setPlaybackSpeed(speed);
    if (!mounted) return;
    _flashHud('${speed}x');
    _scheduleChromeHide();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final disableGestures = ref.watch(settingsProvider).flag('video_controller_hide');

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() => _showChrome = !_showChrome);
          _scheduleChromeHide();
        },
        onDoubleTap: _togglePlay,
        onLongPressStart: disableGestures
            ? null
            : (_) async {
                _longPressBoost = true;
                await _controller?.setPlaybackSpeed(2.0);
                if (mounted) _flashHud('2.0x 倍速中');
              },
        onLongPressEnd: disableGestures
            ? null
            : (_) async {
                if (!_longPressBoost) return;
                _longPressBoost = false;
                await _controller?.setPlaybackSpeed(_speed);
                if (mounted) _flashHud(null);
              },
        onHorizontalDragStart: disableGestures
            ? null
            : (details) {
                if (!_ready) return;
                setState(() {
                  _showChrome = true;
                  _seekPreview = _positionMs.toDouble();
                });
                _chromeTimer?.cancel();
              },
        onHorizontalDragUpdate: disableGestures
            ? null
            : (details) {
                if (_seekPreview == null) return;
                // 全屏宽度对应全片时长，手指移动的距离直接换算成时间。
                final width = MediaQuery.sizeOf(context).width;
                final delta = details.delta.dx / width * _durationMs;
                final next =
                    (_seekPreview! + delta * 1.6).clamp(0.0, _durationMs.toDouble());
                setState(() => _seekPreview = next);
              },
        onHorizontalDragEnd: disableGestures
            ? null
            : (_) async {
                final preview = _seekPreview;
                if (preview == null) return;
                await _controller?.seekTo(Duration(milliseconds: preview.round()));
                if (!mounted) return;
                setState(() => _seekPreview = null);
                _scheduleChromeHide();
              },
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 13.5),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white54),
                          ),
                          onPressed: _init,
                          child: const Text('重试'),
                        ),
                        if (_fallbackWebUrl != null)
                          FilledButton(
                            onPressed: () {
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute(
                                  builder: (_) => InAppWebPage(
                                    url: _fallbackWebUrl!,
                                    title: (widget.title ?? '').isNotEmpty
                                        ? widget.title!
                                        : '视频播放',
                                  ),
                                ),
                              );
                            },
                            child: const Text('在网页中播放'),
                          ),
                      ],
                    ),
                  ],
                ),
              )
            else if (!_ready)
              Stack(
                alignment: Alignment.center,
                children: [
                  if (widget.cover != null)
                    Positioned.fill(
                      child: Image.network(widget.cover!, fit: BoxFit.contain),
                    ),
                  const SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                  ),
                ],
              )
            else
              Center(
                child: AspectRatio(
                  aspectRatio: controller!.value.aspectRatio == 0
                      ? 16 / 9
                      : controller.value.aspectRatio,
                  child: VideoPlayer(controller),
                ),
              ),

            // 暂停时的大播放按钮
            if (_ready && !_controller!.value.isPlaying && _hud == null)
              GestureDetector(
                onTap: _togglePlay,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 40),
                ),
              ),

            if (_hud != null) _hudPill(_hud!),
            if (_seekPreview != null)
              _hudPill(
                '${_fmt(Duration(milliseconds: _seekPreview!.round()))} / ${_fmt(Duration(milliseconds: _durationMs))}',
              ),

            if (_showChrome) ...[
              Positioned(
                top: MediaQuery.paddingOf(context).top + 4,
                left: 4,
                right: 4,
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Text(
                        widget.title ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
              if (_ready)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: EdgeInsets.fromLTRB(
                        12, 20, 12, MediaQuery.paddingOf(context).bottom + 10),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black54],
                      ),
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          icon: Icon(
                            _controller!.value.isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                            color: Colors.white,
                          ),
                          onPressed: _togglePlay,
                        ),
                        Text(
                          _fmt(_controller!.value.position),
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                        Expanded(
                          child: Slider(
                            value: _positionMs
                                .clamp(0, _durationMs)
                                .toDouble(),
                            max: _durationMs.clamp(1, 1 << 31).toDouble(),
                            activeColor: Colors.white,
                            inactiveColor: Colors.white24,
                            onChanged: (v) => _controller
                                ?.seekTo(Duration(milliseconds: v.toInt())),
                          ),
                        ),
                        Text(
                          _fmt(_controller!.value.duration),
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                        if (_qualities.length >= 2)
                          TextButton(
                            onPressed: _pickQuality,
                            style: TextButton.styleFrom(
                              minimumSize: const Size(42, 32),
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                            ),
                            child: Text(
                              _activeQualityLabel ?? '画质',
                              style: const TextStyle(color: Colors.white, fontSize: 12.5),
                            ),
                          ),
                        TextButton(
                          onPressed: _pickSpeed,
                          child: Text(
                            '${_speed}x',
                            style: const TextStyle(color: Colors.white, fontSize: 12.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  int get _positionMs => _seekPreview?.round() ??
      _controller?.value.position.inMilliseconds ??
      0;

  int get _durationMs => _controller?.value.duration.inMilliseconds ?? 0;

  Widget _hudPill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 13)),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
