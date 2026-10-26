/// 内联视频播放器（fnOS视频流 / 实况照片动态部分）
///
/// fnOS的流接口 `GET /p/api/v1/stream/v/{id}` 需要**完整 Cookie jar**
/// （`fnos-token` + 门禁 `os-access-code`）与签名头 `authx`，
/// 因此用 [VideoPlayerController.networkUrl] 的 `httpHeaders` 传入。
/// 少带门禁 Cookie 会回 401，ExoPlayer 只会报 `VideoError 0.0: Source error`。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/app_state.dart';
import '../core/error_text.dart';
import '../core/fnos_crypto.dart';
import '../core/video_proxy.dart';

class FnosVideoView extends StatefulWidget {
  /// 相对路径（如 `/p/api/v1/stream/v/123`）。为空时按 [photoId] 拼。
  final String? path;
  final int photoId;

  /// **期望的播放状态**（声明式，不是"初始化后播一次"）。
  ///
  ///   · `false` → 只做到 `initialize()`（= 预热），不出画面也不播；
  ///   · `true`  → 就绪后（或已就绪时）开始播放。
  ///
  /// 外层按「本页是不是当前页」切换它，于是相邻页预热好的播放器在翻过去时
  /// 只需 `play()`，不再重新建连 + prepare —— 这正是原来那"转圈半秒"的来源。
  final bool play;

  /// 本页是否为当前页。从 true 变 false 时暂停并收回画面（回到"只显示封面"
  /// 的预热态），避免用户手动播过的视频在滑走后继续在后台跑。
  final bool active;

  /// 重新开始的令牌：每次自增就 seek 回 0，再按 [play] 决定是否播放。
  ///
  /// 实况照片「重播」用它复用**已经预热好的**控制器；以前是换 key 重建整个
  /// 播放器，等于把预热成果一起丢掉、又冷启动一次。
  final int restartToken;

  /// 循环播放（实况照片一般播一遍即可）
  final bool loop;

  /// 是否显示底部进度条 / 播放暂停按钮
  final bool showControls;

  /// 是否显示「暂停态中央大播放键」。
  ///
  /// 预热的相邻页要传 false —— 否则滑动过程中会在下一张上看到播放键一闪而过；
  /// 实况照片也传 false（它是自动播放的短片段，不该出现播放入口）。
  final bool showPlayButton;

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
  /// 中央大播放键（暂停态）看 [showPlayButton]。
  final bool controlsVisible;

  const FnosVideoView({
    super.key,
    required this.photoId,
    this.path,
    this.play = true,
    this.active = true,
    this.restartToken = 0,
    this.loop = false,
    this.showControls = false,
    this.showPlayButton = true,
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

  /// 视频是否已经真正开始出画面。
  ///
  /// 用来把「绘制视频」推迟到确实有画面之后。原因：插件是在 ExoPlayer
  /// `STATE_READY` 时就上报 `initialized`（见 TextureExoPlayerEventListener），
  /// **并不保证已经渲染出首帧** —— 预热出来的播放器直接叠上去可能是一块黑帧，
  /// 把下层那张静态封面盖住。置位后保持（暂停时仍要显示当前帧）。
  bool _frameReady = false;

  /// 初始化代际：每次重建 / 重试都自增，让在飞的旧初始化自行放弃。
  /// 否则快速连点「重试」会留下一个没人释放的原生播放器（一直吊着一条流）。
  int _gen = 0;

  /// 上一次的播放状态，用于判断是否需要重建（大播放键的显隐）
  bool _lastPlaying = false;

  /// 带控件时的进度条节流：原来每个 tick 都 setState（60~120 次/秒），
  /// 既浪费又会让预加载的解码/IO 更紧张。
  DateTime _lastPosAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _lastPosTick = false;

  /// 判定「播完」的容差。视频码率波动下最后一个 GOP 的时长不定，
  /// 180ms 足够；再大就会把「刚播完就停」误判成没播完。
  static const Duration _endSlack = Duration(milliseconds: 180);

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(covariant FnosVideoView old) {
    super.didUpdateWidget(old);
    // 换了条目（PageView 元素复用 / 照片墙换页）必须重建控制器，
    // 否则会继续播上一条流。
    if (old.path != widget.path || old.photoId != widget.photoId) {
      _reset();
      return;
    }
    if (old.active && !widget.active) {
      // 离开本页：暂停 + 收回画面，退回"只显示封面"的预热态
      _pauseAndHide();
    } else if (old.restartToken != widget.restartToken) {
      _restart();
    } else if (old.play != widget.play) {
      _applyPlay();
    }
  }

  @override
  void dispose() {
    _gen++; // 让在飞的初始化自行放弃
    _c?.removeListener(_onTick);
    _c?.dispose();
    super.dispose();
  }

  /// 丢掉当前控制器与状态并重新初始化。
  /// 旧控制器等这一帧渲染完再释放，避免它仍挂在 VideoPlayer 上时被 dispose。
  void _reset() {
    _gen++;
    final old = _c;
    _c = null;
    _ready = false;
    _err = null;
    _completed = false;
    _frameReady = false;
    _lastPlaying = false;
    if (old != null) {
      old.removeListener(_onTick);
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    _init();
  }

  /// 按 [FnosVideoView.play] 同步播放/暂停。
  Future<void> _applyPlay() async {
    final c = _c;
    if (c == null || !_ready) return;
    try {
      if (widget.play) {
        // 播完的控制器如果被保活（相邻页预热不再销毁播放器），再 play() 是
        // **回不到开头**的：media3 在 STATE_ENDED 下只把 playWhenReady 置 true，
        // isPlaying 仍是 false —— 于是 _frameReady 永不 latch、_waiting 永真，
        // 表现为"滑回刚看完的视频时永久转圈却放不出画面"。先回到 0 再播。
        final v = c.value;
        final atEnd = v.duration > Duration.zero && v.position >= v.duration;
        if (_completed || atEnd) {
          await c.seekTo(Duration.zero);
          _completed = false;
        }
        if (!c.value.isPlaying) await c.play();
      } else {
        if (c.value.isPlaying) await c.pause();
        // 明确要求不播（例如实况播完了）→ 收回画面，让下层静态图重新透出来
        if (mounted && _frameReady) setState(() => _frameReady = false);
      }
    } catch (_) {/* 控制器可能正在被释放 */}
  }

  /// 离开本页：暂停并收回画面。
  Future<void> _pauseAndHide() async {
    final c = _c;
    if (c != null && _ready && c.value.isPlaying) {
      try {
        await c.pause();
      } catch (_) {/* 同上 */}
    }
    if (mounted && _frameReady) setState(() => _frameReady = false);
  }

  /// 用户点画面切换播放 / 暂停。
  ///
  /// 这里是**唯一**能置 `_userPaused` 的地方：只有用户明确按了暂停，
  /// 才不该被「缓冲恢复自动续播」打断；反过来，播放器因为喂不饱而
  /// 自己停住的（`_userPaused == false`）会在缓冲恢复时自动接着播。
  void _togglePlay() {
    final c = _c;
    if (c == null) return;
    setState(() {
      if (c.value.isPlaying) {
        _userPaused = true;
        _autoResumePending = false;
      } else {
        _userPaused = false;
        _stalledSince = null;
      }
    });
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
  }

  /// 回到开头重播（复用已预热好的控制器，不再重新 initialize）。
  Future<void> _restart() async {
    final c = _c;
    if (c == null || !_ready) return;
    try {
      await c.seekTo(Duration.zero);
      _completed = false;
      if (widget.play) await c.play();
    } catch (_) {/* 同上 */}
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
    final gen = ++_gen;
    final c = AppState.I.client;
    if (c == null) {
      if (mounted) setState(() => _err = '未登录');
      return;
    }
    final path = _path;
    VideoPlayerController? ctrl;
    try {
      // https 自签证书下 ExoPlayer 无法放行证书，走本地代理转发；
      // http 场景 rewriteUrl 直接返回原地址，行为不变。
      final url = await VideoProxy.I.rewriteUrl(path);
      final created = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: _headers(path),
      );
      ctrl = created;
      await created.initialize();
      // 已被下一次重建/重试取代，或页面已卸载：自己收尾，别留孤儿控制器
      if (!mounted || gen != _gen) {
        await created.dispose();
        return;
      }
      await created.setLooping(widget.loop);
      created.addListener(_onTick);
      setState(() {
        _c = created;
        _ready = true;
        _completed = false;
      });
      if (widget.play) await created.play();
    } catch (e) {
      if (ctrl != null) {
        try {
          await ctrl.dispose();
        } catch (_) {/* 已经释放过就算了 */}
      }
      if (mounted && gen == _gen) setState(() => _err = friendlyError(e));
    }
  }

  void _onTick() {
    final v = _c?.value;
    if (v == null || !v.isInitialized) return;
    if (!_completed) {
      final d = v.duration;
      // ⚠️ 「播完」判定必须**同时**要求：
      //   · 播放头真的到了尾部附近；
      //   · 播放器自己报告「已完成」（isCompleted），且**不在缓冲中**。
      //
      // 原来只看 `!v.isPlaying && position >= d - 180ms`。而在**缓冲卡顿**时
      // isPlaying 同样会短暂变成 false，而此时 position 往往还没到底 ——
      // 于是卡顿被误判成「播完了」，触发 onCompleted，上层随即把自动播放
      // 置false 并收回画面。表现就是：视频看着看着自己停住、还得手动点一下。
      // 这才是自动暂停的真正原因，与磁盘速度无关，是判定条件缺失。
      //
      // 另：正在拖进度条时 position 会先跳到目标位置再起播，同样不能算「播完」——
      // 用 isBuffering 排除（拖动瞬间必然要缓冲）。
      final atEnd = d > Duration.zero && v.position >= d - _endSlack;
      if (atEnd && v.isCompleted && !v.isBuffering) {
        _completed = true;
        widget.onCompleted?.call();
      }
    }
    if (!mounted) return;
    // 真正开始播了才认为"画面已经出来"，此后保持显示（暂停也要看到当前帧）。
    // 这是把视频绘制推迟到确有画面的依据，避免预热期的黑帧盖住封面。
    final frameReady = _frameReady || v.isPlaying;

    // ⚠️ **卡顿自动恢复**（2026-10-21，v1.0.3）：
    // NAS 用机械盘时读取会顶到 100MB/s，喂不饱大码率视频 → ExoPlayer
    // 缓冲耗尽后**自己暂停**等数据（isPlaying=false）。用户看到的却是
    // 「视频莫名停住 + 顶部进度条一直动」，还得再点一下。
    //
    // 这里做两件事：
    //   1) 记住「是自己停的」而不是用户按的（_userPaused）；
    //   2) 一旦缓冲恢复（isBuffering 转 false 且内容就绪），**自动续播**。
    if (v.isPlaying) {
      _stalledSince = null;
      if (_autoResumePending) {
        _autoResumePending = false;
        unawaited(_resumeAfterBuffer());
      }
    } else if (v.isBuffering && !_userPaused && widget.play) {
      _stalledSince ??= DateTime.now();
    }

    // 播放状态变化必须重建（否则大播放键不会消失）；
    // 带控件时要随进度重建进度条。
    if (frameReady != _frameReady ||
        v.isPlaying != _lastPlaying ||
        (widget.showControls && !_lastPosTick)) {
      _frameReady = frameReady;
      _lastPlaying = v.isPlaying;
      _lastPosTick = false;
      setState(() {});
      return;
    }
    // 带控件时按固定间隔（~200ms）重建进度条，不必每帧 setState
    if (widget.showControls && v.isPlaying) {
      final now = DateTime.now();
      if (now.difference(_lastPosAt) >=
          const Duration(milliseconds: 200)) {
        _lastPosAt = now;
        _lastPosTick = true;
        setState(() {});
      }
    }
  }

  /// 记录「卡顿始于何时」。超过 [_stallGrace] 仍没恢复才算真异常。
  DateTime? _stalledSince;

  /// 缓冲恢复后自动续播。
  ///
  /// 为什么要延迟一点：ExoPlayer 在 `isBuffering` 由 true 转 false 的那一帧，
  /// 内部可能刚把 playWhenReady 置回 true，直接 play() 会与它的恢复动作打架，
  /// 表现为「点了没反应」。让播放器自己先走完恢复流程更稳。
  Future<void> _resumeAfterBuffer() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final c = _c;
    if (!mounted || c == null || _userPaused || !widget.play) return;
    if (c.value.isPlaying || c.value.isCompleted) return;
    try {
      await c.play();
    } catch (_) {/* 控制器可能正在被释放*/}
  }

  /// 加载中的转圈。
  Widget get _loadingIndicator => const Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(
              color: Colors.white70, strokeWidth: 2.4),
        ),
      );

  /// 缓冲中的提示：**画面正中**的圆圈 + 「缓冲中」文字。
  ///
  /// 与 [_loadingIndicator] 的区别：这个用于「已经出过画面、播放途中喂不饱」
  /// 的场景，用户明确要求用中央圆圈而不是顶部进度条。
  Widget get _bufferingIndicator => Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2.4),
              ),
              SizedBox(height: 10),
              Text('缓冲中...',
                  style: TextStyle(color: Colors.white, fontSize: 12.5)),
            ],
          ),
        ),
      );

  /// 是否处于「在等画面」的状态。
  ///
  /// 条件有三条，缺一不可：
  ///   · `widget.active` —— **只有当前页才显示转圈**。预热的相邻页是离屏内容，
  ///     滑动经过时看到转圈闪一下，正是原来那种"翻过去先转半圈"的观感；
  ///   · `!_frameReady` —— 画面一旦出来就立刻让位；
  ///   · `widget.play || !_ready` —— 期望播放的页在等首帧 / 缓冲时继续给反馈；
  ///     而"暂停态"（例如关了自动播放视频）不算，那时该出现的是播放键。
  ///
  /// 补充：已出过画面之后（`_frameReady` 为真）就不再显示转圈 ——
  /// 播放途中缓冲时画面停在当前帧上，叠加转圈只会让人以为卡死。
  bool get _waiting =>
      widget.active && !_frameReady && (widget.play || !_ready);

  /// 播放途中正在缓冲：画面保留，只给一个轻量的顶部进度条。
  bool get _buffering =>
      widget.active &&
      _frameReady &&
      _c?.value.isBuffering == true &&
      !_c!.value.isPlaying &&
      !_c!.value.isCompleted;

  /// 当前是否处于「卡顿中」——即**因为喂不饱而暂停**，而不是用户主动暂停。
  ///
  /// 这是 NAS 机械盘（读取上限约 100MB/s）+ 大码率视频的必然结果：
  /// 缓冲耗尽 → 播放器暂停等数据 → 画面停在当前帧。
  /// 用户的期望是「缓冲完自动接着播」，而不是停在那儿等手动点击。
  bool get _stalled =>
      widget.active &&
      _frameReady &&
      (_c?.value.isBuffering == true || _c?.value.isPlaying == false) &&
      !_c!.value.isCompleted &&
      _userPaused == false &&
      widget.play;

  /// 用户是否主动暂停过。主动暂停**不该**被自动续播打断。
  bool _userPaused = false;

  /// 缓冲恢复后需要补一次 play()。见 [_resumeAfterBuffer]。
  bool _autoResumePending = false;

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
                onPressed: () => setState(_reset),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (!_ready || _c == null) {
      // 初始化中显示转圈（仅当前页，见 _waiting）；预热的相邻页保持透明，
      // 让下层那张静态封面透出来。
      return _waiting ? _loadingIndicator : const SizedBox.shrink();
    }

    final v = _c!.value;
    final ar = v.aspectRatio == 0 ? 16 / 9 : v.aspectRatio;

    return Stack(
      children: [
        // 画面只在确认出图之后才绘制：预热期间这里是透明的，
        // 下层封面照常可见（黑帧不会盖住照片）
        if (_frameReady)
          Positioned.fill(
            child: GestureDetector(
              onTap: widget.tapToToggle
                  ? () => _togglePlay()
                  : null,
              child: Center(
                child: AspectRatio(
                  aspectRatio: ar,
                  child: VideoPlayer(_c!),
                ),
              ),
            ),
          ),
        // 已就绪但首帧 / 缓冲还没到位：当前页继续给转圈反馈
        if (_waiting) _loadingIndicator,
        // 播放途中缓冲：画面中央一个圆圈 + 「缓冲中」文字。
        // 用户明确要求：**不要顶部进度条**（那个一直动的条容易让人以为卡死），
        // 只在中央给标准加载反馈。
        if (_buffering || _stalled) _bufferingIndicator,
        // 暂停时中央给一个醒目的大播放键（是否提供见 [FnosVideoView.showPlayButton]）。
        // 关闭自动播放进入时视频是暂停态，靠它给用户明确的播放入口；
        // 它自己消费点击，不会穿透到外层「切换顶/底栏」的手势。
        // 正在等画面时不叠加播放键，免得转圈和播放键同时出现。
        if (widget.showPlayButton &&
            !v.isPlaying &&
            !_waiting &&
            !_buffering &&
            !_stalled)
          Center(
            child: GestureDetector(
              onTap: () {
                setState(() => _userPaused = false);
                _c!.play();
              },
              child: const Icon(Icons.play_circle_fill,
                  color: Colors.white,
                  size: 68,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black54)]),
            ),
          ),
        // 控制条与全屏入口只在**当前页**渲染：预热的相邻页是离屏内容，
        // 若也画出来，滑动经过时封面上会闪一条「00:07 / 01:23 ────」+ 全屏图标。
        // 全屏按钮已并入 [_controls] 的进度条右端（用户要求），这里不再单独画。
        if (widget.active && widget.showControls && widget.controlsVisible)
          _controls(v),
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
              onPressed: () => _togglePlay(),
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
            // 全屏入口放在进度条**右端**（用户要求），与暂停键、时间同一行，
            // 不再浮在画面右上角遮挡内容。
            if (widget.onFullscreen != null)
              IconButton(
                tooltip: '全屏播放',
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.only(left: 8),
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.fullscreen, color: Colors.white, size: 22),
                onPressed: widget.onFullscreen,
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
