import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../core/app_state.dart';
import '../core/error_text.dart';
import '../core/fnos_client.dart' show splitPathQuery;
import '../core/fnos_crypto.dart';
import '../core/video_proxy.dart';
import '../widgets/fnos_image.dart';

/// 视频 / 实况照片播放器
///
/// fnOS的视频流接口 `GET /p/api/v1/stream/v/{id}` 需要**完整的 Cookie jar**
/// （`fnos-token` + 门禁 `os-access-code`）与签名头 `authx`，
/// 因此用 [VideoPlayerController.networkUrl] 的 [httpHeaders] 传入。
///
/// 坑：早先这里只拼了 `fnos-token`，开了「访问码门禁」的 NAS 会直接回 401，
/// ExoPlayer 只能报 `VideoError 0.0: Source error` —— 这就是「无法播放该视频」
/// 的根因。必须用 [FnosClient.cookieHeader] 带上门禁 Cookie。
class VideoPage extends StatefulWidget {
  final int photoId;
  final String title;
  /// 实况照片模式：短小循环播放，界面更简洁
  final bool liveMode;

  /// 服务端下发的视频流路径（`additional.thumbnail.videoUrl`），
  /// 为空时回退到 `/p/api/v1/stream/v/{id}`
  final String? streamPath;

  /// 视频封面（缩略图）路径：加载 / 转屏期间垫在画面上，
  /// 避免黑屏一闪；为空时退化为纯黑 + 转圈。
  final String? posterPath;

  const VideoPage({
    super.key,
    required this.photoId,
    this.title = '',
    this.liveMode = false,
    this.streamPath,
    this.posterPath,
  });

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  VideoPlayerController? _c;
  String? _err;
  bool _ready = false;
  bool _showControls = true;
  Timer? _hideTimer;

  /// 初始化代际：重试时自增，让在飞的旧初始化自行放弃。
  /// 否则连点两次「重试」会有两个原生播放器，其中一个永远不被释放。
  int _gen = 0;

  // ── 左右滑动快进快退 ──
  /// 开始拖动时的播放位置（拖动期间只预览，松手才真正 seek）
  Duration? _seekFrom;
  /// 预览的目标位置
  Duration? _seekTo;
  /// 累计横向位移（像素）
  double _seekDx = 0;
  bool _seeking = false;

  @override
  void initState() {
    super.initState();
    if (widget.liveMode) {
      // 实况照片是竖屏小窗：不转屏、不加播放手势
      _init();
      return;
    }
    // 全屏播放页：先把窗口切成横屏（两个方向都允许，跟着握持方向转），
    // 退出时在 dispose 里还原竖屏。
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    // 关键：等转屏真正生效后再创建播放器。
    // ExoPlayer 的输出 surface 尺寸跟着布局走，若播放器已经按竖屏尺寸
    // 建好，转屏瞬间 surface 被迫重建，表现就是「切换横竖屏后缓冲一下」。
    // 等窗口变成横屏再初始化，播放器从头就是最终尺寸，不会再重建。
    _initAfterRotation();
  }

  /// 等窗口转成横屏后再初始化；设备不支持转屏时最多等 1.2s 照常开始。
  Future<void> _initAfterRotation() async {
    for (var i = 0; i < 24; i++) {
      if (!mounted) return;
      final views = WidgetsBinding.instance.platformDispatcher.views;
      if (views.isEmpty) break;
      final s = views.first.physicalSize / views.first.devicePixelRatio;
      if (s.width > s.height) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (mounted) await _init();
  }

  @override
  void dispose() {
    _gen++; // 让在飞的初始化自行放弃
    _hideTimer?.cancel();
    _c?.dispose();
    if (!widget.liveMode) {
      // 返回大图页必须回到竖屏，否则整个 App 会停在横屏
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
    }
    super.dispose();
  }

  /// 丢掉当前控制器并重新初始化（重试入口）。
  void _reset() {
    _gen++;
    final old = _c;
    _c = null;
    _ready = false;
    _err = null;
    if (old != null) {
      // 等这一帧渲染完再释放，避免它仍挂在 VideoPlayer 上时被 dispose
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    _init();
  }

  String get _path {
    final c = AppState.I.client;
    if (widget.streamPath != null && widget.streamPath!.isNotEmpty) {
      return widget.streamPath!;
    }
    return c?.videoPath(widget.photoId) ?? '/p/api/v1/stream/v/${widget.photoId}';
  }

  Map<String, String> _headers(String path) {
    final c = AppState.I.client;
    if (c == null) return {};
    // 设备下发的地址可能自带 query；签名基准必须与实际请求的 query 一致
    // （与 FnosClient._request / fnos_image 同一口径）。
    final split = splitPathQuery(path, null);
    return {
      'x-access-source': 'app',
      'User-Agent': 'okhttp/4.12.0',
      'authx': buildAuthx(
        method: 'GET',
        path: split.path,
        params: split.params,
        apiKey: c.apiKey,
      ),
      // 关键：完整 cookie jar（含门禁 os-access-code），少一个就 401
      if (c.cookieHeader.isNotEmpty) 'Cookie': c.cookieHeader,
    };
  }

  Future<void> _init() async {
    final gen = ++_gen;
    final c = AppState.I.client;
    if (c == null) {
      if (mounted) setState(() => _err = '未登录');
      return;
    }
    final path = _path;
    VideoPlayerController? ctrl;
    try {
      // https 自签证书下 ExoPlayer 无法放行证书，必须与内联播放器一样走
      // 本地代理；http 场景 rewriteUrl 原样返回，行为不变。
      final url = await VideoProxy.I.rewriteUrl(path);
      final created = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: _headers(path),
      );
      ctrl = created;
      await created.initialize();
      // 已被下一次重试取代，或页面已卸载：自己收尾
      if (!mounted || gen != _gen) {
        await created.dispose();
        return;
      }
      await created.setLooping(widget.liveMode);
      setState(() {
        _c = created;
        _ready = true;
      });
      await created.play();
      if (!widget.liveMode) _scheduleHide();
    } catch (e) {
      if (ctrl != null) {
        try {
          await ctrl.dispose();
        } catch (_) {/* 已经释放过就算了 */}
      }
      if (mounted && gen == _gen) {
        setState(() => _err = friendlyError(e));
      }
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  // ─────────────────── 双击暂停 / 左右滑动快进快退 ───────────────────

  /// 双击：播放 ↔ 暂停。暂停时把控制条亮出来，方便继续操作。
  void _togglePlay() {
    final c = _c;
    if (c == null) return;
    setState(() {
      if (c.value.isPlaying) {
        c.pause();
        _showControls = true;
      } else {
        c.play();
      }
    });
    _scheduleHide();
  }

  void _onHorizontalStart(DragStartDetails d) {
    final c = _c;
    if (c == null) return;
    _seekFrom = c.value.position;
    _seekTo = c.value.position;
    _seekDx = 0;
    _hideTimer?.cancel();
    setState(() {
      _seeking = true;
      _showControls = true;
    });
  }

  void _onHorizontalUpdate(DragUpdateDetails d) {
    final c = _c;
    final from = _seekFrom;
    if (c == null || from == null) return;
    final w = MediaQuery.sizeOf(context).width;
    final dur = c.value.duration;
    if (dur.inMilliseconds <= 0) return;
    _seekDx += d.primaryDelta ?? 0;
    // 滑满整屏 = 整段时长，向左为后退、向右为快进
    final delta = Duration(
        milliseconds: (dur.inMilliseconds * (_seekDx / w)).round());
    var t = from + delta;
    if (t < Duration.zero) t = Duration.zero;
    if (t > dur) t = dur;
    if (t == _seekTo) return;
    setState(() => _seekTo = t);
  }

  void _onHorizontalEnd(DragEndDetails d) {
    final c = _c;
    final to = _seekTo;
    // 拖动时只预览时间点，松手才真正 seek：NAS 上每一次 seek 都是一次
    // 新的 Range 请求，按帧 seek 会把带宽和连接数瞬间打满。
    if (c != null && to != null) c.seekTo(to);
    setState(() {
      _seeking = false;
      _seekFrom = null;
      _seekTo = null;
    });
    _scheduleHide();
  }

  /// 快进 / 快退时画面中央的时间提示
  Widget _seekHud() {
    final to = _seekTo;
    final from = _seekFrom;
    if (to == null || from == null) return const SizedBox.shrink();
    final forward = to >= from;
    final diff = (to - from).inSeconds.abs();
    final d = _c?.value.duration ?? Duration.zero;
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(forward ? Icons.fast_forward : Icons.fast_rewind,
                      color: Colors.white, size: 20),
                  const SizedBox(width: 6),
                  Text('${forward ? '+' : '-'}${_fmt(Duration(seconds: diff))}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 6),
              Text('${_fmt(to)} / ${_fmt(d)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // 顶栏跟随控制条一起显隐：横屏观看时若常驻，半透明底和标题会一直
      // 压在画面上方（用户反馈"文字不会消失"）。extendBodyBehindAppBar
      // 让 body 始终占满整屏，所以移除顶栏不会引起画面跳动。
      appBar: widget.liveMode || !_showControls
          ? null
          : AppBar(
              backgroundColor: Colors.black26,
              foregroundColor: Colors.white,
              title: Text(widget.title.isEmpty ? '视频' : widget.title,
                  style: const TextStyle(fontSize: 15)),
            ),
      extendBodyBehindAppBar: !widget.liveMode,
      body: _err != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline,
                        color: Colors.white70, size: 48),
                    const SizedBox(height: 14),
                    Text('无法播放该视频\n$_err',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 18),
                    FilledButton(
                        onPressed: () => setState(_reset),
                        child: const Text('重试')),
                  ],
                ),
              ),
            )
          : !_ready
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    // 封面垫底：转屏 / 建连期间画面上是视频的缩略图而不是
                    // 一片纯黑，观感上不再"黑屏一下"。
                    if (widget.posterPath != null &&
                        widget.posterPath!.isNotEmpty)
                      FnosImage(path: widget.posterPath!, fit: BoxFit.contain),
                    const Center(
                        child: CircularProgressIndicator(color: Colors.white)),
                  ],
                )
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.liveMode ? null : _toggleControls,
                  // 双击暂停 / 继续；单击仍然只负责显隐控制条。
                  // 双击识别会让单击晚 ~300ms 生效，这是标准取舍。
                  onDoubleTap: widget.liveMode ? null : _togglePlay,
                  // 横屏全屏时左右滑动快进 / 快退（滑满一屏 = 整段时长）
                  onHorizontalDragStart:
                      widget.liveMode ? null : _onHorizontalStart,
                  onHorizontalDragUpdate:
                      widget.liveMode ? null : _onHorizontalUpdate,
                  onHorizontalDragEnd:
                      widget.liveMode ? null : _onHorizontalEnd,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Center(
                        child: AspectRatio(
                          aspectRatio: _c!.value.aspectRatio == 0
                              ? 16 / 9
                              : _c!.value.aspectRatio,
                          child: VideoPlayer(_c!),
                        ),
                      ),
                      if (_seeking) _seekHud(),
                      if (widget.liveMode)
                        Positioned(
                          right: 12, top: 40,
                          child: IconButton(
                            icon: const Icon(Icons.close,
                                color: Colors.white, size: 28),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ),
                      if (!widget.liveMode && _showControls) _controls(),
                    ],
                  ),
                ),
    );
  }

  Widget _controls() {
    final v = _c!.value;
    return Positioned(
      left: 0, right: 0, bottom: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black87],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(10, 24, 10, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            VideoProgressIndicator(_c!,
                allowScrubbing: true,
                colors: const VideoProgressColors(
                  playedColor: Color(0xFF0066FF),
                  bufferedColor: Colors.white24,
                  backgroundColor: Colors.white10,
                )),
            const SizedBox(height: 4),
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    v.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                  ),
                  onPressed: () {
                    setState(() =>
                        v.isPlaying ? _c!.pause() : _c!.play());
                    _scheduleHide();
                  },
                ),
                Text('${_fmt(v.position)} / ${_fmt(v.duration)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
                const Spacer(),
                if (v.duration.inSeconds > 0)
                  Text('${v.size.width.toInt()}×${v.size.height.toInt()}',
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
