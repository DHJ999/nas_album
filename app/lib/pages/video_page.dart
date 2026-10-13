import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/app_state.dart';
import '../core/fnos_crypto.dart';

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

  const VideoPage({
    super.key,
    required this.photoId,
    this.title = '',
    this.liveMode = false,
    this.streamPath,
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

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _c?.dispose();
    super.dispose();
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
    return {
      'x-access-source': 'app',
      'User-Agent': 'okhttp/4.12.0',
      'authx': buildAuthx(method: 'GET', path: path, apiKey: c.apiKey),
      // 关键：完整 cookie jar（含门禁 os-access-code），少一个就 401
      if (c.cookieHeader.isNotEmpty) 'Cookie': c.cookieHeader,
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
      final ctrl = VideoPlayerController.networkUrl(
        Uri.parse('${c.baseUrl}$path'),
        httpHeaders: _headers(path),
      );
      await ctrl.initialize();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      await ctrl.setLooping(widget.liveMode);
      setState(() {
        _c = ctrl;
        _ready = true;
      });
      await ctrl.play();
      if (!widget.liveMode) _scheduleHide();
    } catch (e) {
      if (mounted) {
        setState(() => _err = '$e');
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

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: widget.liveMode
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
                        onPressed: () {
                          setState(() {
                            _err = null;
                            _ready = false;
                          });
                          _init();
                        },
                        child: const Text('重试')),
                  ],
                ),
              ),
            )
          : !_ready
              ? const Center(
                  child: CircularProgressIndicator(color: Colors.white))
              : GestureDetector(
                  onTap: widget.liveMode ? null : _toggleControls,
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
