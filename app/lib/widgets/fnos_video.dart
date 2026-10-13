/// 内联视频播放器（fnOS视频流 / 实况照片动态部分）
///
/// fnOS的流接口 `GET /p/api/v1/stream/v/{id}` 需要**完整 Cookie jar**
/// （`fnos-token` + 门禁 `os-access-code`）与签名头 `authx`，
/// 因此用 [VideoPlayerController.networkUrl] 的 `httpHeaders` 传入。
/// 少带门禁 Cookie 会回 401，ExoPlayer 只会报 `VideoError 0.0: Source error`。
library;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/app_state.dart';
import '../core/fnos_crypto.dart';
import '../core/video_proxy.dart';

class FnosVideoView extends StatefulWidget {
  /// 相对路径（如 `/p/api/v1/stream/v/123`）。为空时按 [photoId] 拼。
  final String? path;
  final int photoId;

  /// 初始化完成后是否立刻播放
  final bool autoPlay;

  /// 循环播放（实况照片一般播一遍即可）
  final bool loop;

  /// 是否显示底部进度条 / 播放暂停按钮
  final bool showControls;

  /// 播放到结尾时回调（实况照片据此切回静态图）
  final VoidCallback? onCompleted;

  /// 右上角「全屏」入口，为 null 时不显示
  final VoidCallback? onFullscreen;

  final BoxFit fit;

  /// 是否可点击切换播放/暂停
  final bool tapToToggle;

  /// 底部控制条距播放器底边的距离。
  /// 大图页内联播放时，外层底部还有下载/删除操作栏，
  /// 传入操作栏高度把进度条顶到其上方，避免被遮挡；默认 0 贴底。
  final double controlsBottomInset;

  /// 控制条 / 全屏按钮是否可见。大图页点击画面进入沉浸时由外层置 false，
  /// 让进度条、播放暂停键、全屏入口随顶/底栏一起隐藏；默认 true。
  /// 中央大播放键（暂停态）不受此影响，始终保留作为播放入口。
  final bool controlsVisible;

  const FnosVideoView({
    super.key,
    required this.photoId,
    this.path,
    this.autoPlay = true,
    this.loop = false,
    this.showControls = false,
    this.onCompleted,
    this.onFullscreen,
    this.fit = BoxFit.contain,
    this.tapToToggle = true,
    this.controlsBottomInset = 0,
    this.controlsVisible = true,
  });

  @override
  State<FnosVideoView> createState() => _FnosVideoViewState();
}

class _FnosVideoViewState extends State<FnosVideoView> {
  VideoPlayerController? _c;
  String? _err;
  bool _ready = false;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _c?.removeListener(_onTick);
    _c?.dispose();
    super.dispose();
  }

  String get _path {
    if (widget.path != null && widget.path!.isNotEmpty) return widget.path!;
    final c = AppState.I.client;
    return c?.videoPath(widget.photoId) ?? '/p/api/v1/stream/v/${widget.photoId}';
  }

  Map<String, String> _headers(String path) {
    final c = AppState.I.client;
    if (c == null) return {};
    return {
      'x-access-source': 'app',
      'User-Agent': 'okhttp/4.12.0',
      'authx': buildAuthx(method: 'GET', path: path, apiKey: c.apiKey),
      'Cookie': c.cookieHeader,
    };
  }

  Future<void> _init() async {
    final c = AppState.I.client;
    if (c == null) {
      setState(() => _err = '未登录');
      return;
    }
    final path = _path;
    try {
      // https 自签证书下 ExoPlayer 无法放行证书，走本地代理转发；
      // http 场景 rewriteUrl 直接返回原地址，行为不变。
      final url = await VideoProxy.I.rewriteUrl(path);
      final ctrl = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: _headers(path),
      );
      await ctrl.initialize();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      await ctrl.setLooping(widget.loop);
      ctrl.addListener(_onTick);
      setState(() {
        _c = ctrl;
        _ready = true;
        _completed = false;
      });
      if (widget.autoPlay) await ctrl.play();
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  bool _lastPlaying = false;

  void _onTick() {
    final v = _c?.value;
    if (v == null || !v.isInitialized) return;
    if (!_completed) {
      final d = v.duration;
      if (d > Duration.zero && !v.isPlaying &&
          v.position >= d - const Duration(milliseconds: 180)) {
        _completed = true;
        widget.onCompleted?.call();
      }
    }
    if (!mounted) return;
    // 播放状态变化必须重建（否则大播放键不会消失）；
    // 带控件时要随进度重建进度条。
    if (v.isPlaying != _lastPlaying || widget.showControls) {
      _lastPlaying = v.isPlaying;
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white70, size: 40),
              const SizedBox(height: 12),
              Text('无法播放\n$_err',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 14),
              FilledButton(
                style: FilledButton.styleFrom(
                    minimumSize: const Size(96, 38),
                    backgroundColor: Colors.white24),
                onPressed: () {
                  setState(() {
                    _err = null;
                    _ready = false;
                  });
                  _init();
                },
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (!_ready || _c == null) {
      return const Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(color: Colors.white70, strokeWidth: 2.4),
        ),
      );
    }

    final v = _c!.value;
    final ar = v.aspectRatio == 0 ? 16 / 9 : v.aspectRatio;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.tapToToggle
                ? () => setState(() {
                      v.isPlaying ? _c!.pause() : _c!.play();
                    })
                : null,
            child: Center(
              child: AspectRatio(
                aspectRatio: ar,
                child: VideoPlayer(_c!),
              ),
            ),
          ),
        ),
        // 暂停时中央始终给一个醒目的大播放键（无论是否显示底部控制条）。
        // 关闭自动播放进入时视频是暂停态，靠它给用户明确的播放入口；
        // 它自己消费点击，不会穿透到外层「切换顶/底栏」的手势。
        if (!v.isPlaying)
          Center(
            child: GestureDetector(
              onTap: () => _c!.play(),
              child: const Icon(Icons.play_circle_fill,
                  color: Colors.white,
                  size: 68,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black54)]),
            ),
          ),
        if (widget.showControls && widget.controlsVisible) _controls(v),
        if (widget.onFullscreen != null && widget.controlsVisible)
          Positioned(
            right: 10,
            top: 8,
            child: IconButton(
              tooltip: '全屏播放',
              onPressed: widget.onFullscreen,
              icon: const Icon(Icons.fullscreen, color: Colors.white, size: 24),
            ),
          ),
      ],
    );
  }

  Widget _controls(VideoPlayerValue v) {
    final dur = v.duration;
    final pos = v.position > dur ? dur : v.position;
    final p = dur.inMilliseconds == 0
        ? 0.0
        : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
    return Positioned(
      left: 0,
      right: 0,
      bottom: widget.controlsBottomInset,
      // 不加渐变背景：竖屏视频上下本就有黑边，进度条落在黑边上即可，
      // 渐变会平白遮住一截画面。
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Row(
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white),
              onPressed: () =>
                  setState(() => v.isPlaying ? _c!.pause() : _c!.play()),
            ),
            Text('${_fmt(pos)} / ${_fmt(dur)}',
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 18,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2.4,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: const Color(0xFF2B7FFF),
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: p.toDouble(),
                    onChanged: dur.inMilliseconds == 0
                        ? null
                        : (x) => _c!
                            .seekTo(Duration(
                                milliseconds:
                                    (x * dur.inMilliseconds).round()))
                            .then((_) => setState(() {})),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }
}
