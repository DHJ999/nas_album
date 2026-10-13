import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/media_deleter.dart';
import '../core/media_downloader.dart';
import '../core/prefs.dart';
import '../models/models.dart';
import '../widgets/delete_confirm.dart';
import '../widgets/fnos_image.dart';
import '../widgets/fnos_video.dart';
import 'video_page.dart';

/// 全屏看图 / 看视频。
///
/// 交互：
///   · **上下滑动**切换上一张 / 下一张（PageView 纵向）
///   · **左滑**：从右侧跟手拉出当前照片 / 视频的信息卡片，右滑或点遮罩收起
///   · **右滑**：跟手返回照片墙（系统返回键同效）
///   · 顶部：页码 +「原图」开关 +「信息」；底部：下载、删除
///   · 双指缩放、双击放大/还原；放大查看时所有翻页 / 侧滑手势都让给图片平移
///   · 实况照片进入即自动播放一遍，左上角按钮可重播
///   · 视频默认内联播放（是否自动开始由「自动播放视频」开关决定）
///
/// [items] 由调用方持有；删除时直接从这里移除元素并回调 [onChanged]，
/// 这样网格页无需重新拉取数据就能立刻反映删除结果。
class ViewerPage extends StatefulWidget {
  final List<PhotoItem> items;
  final int initialIndex;
  final VoidCallback? onChanged;

  const ViewerPage({
    super.key,
    required this.items,
    this.initialIndex = 0,
    this.onChanged,
  });

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage>
    with SingleTickerProviderStateMixin {
  late PageController _pc = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _showChrome = true;
  bool _original = false;
  bool _saving = false;
  bool _deleting = false;

  /// 当前页是否处于放大状态（放大时禁翻页、禁侧滑手势）
  bool _zoomed = false;

  bool _autoVideo = false;
  bool _autoAnim = true;

  // ── 右滑返回：内容跟手右移的距离 ──
  double _dismissX = 0;

  // ── 左滑信息卡片：0=收在右侧屏外，1=完全展开 ──
  static const double _panelWidthFactor = 0.82;
  late final AnimationController _panelAC = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 260));
  double get _panelV => _panelAC.value;

  /// 一次横向手势开始时，卡片是否已展开（决定本次拖动是「开」还是「关」）
  bool _panelWasOpen = false;

  /// 底部下载/删除按钮列的固定高度，视频控制条据此上移避让
  static const double _barButtonsH = 58;

  PhotoItem get _current => widget.items[_index];

  @override
  void initState() {
    super.initState();
    _panelAC.addListener(() {
      if (mounted) setState(() {});
    });
    AppPrefs.autoPlayVideo().then((v) {
      if (mounted) setState(() => _autoVideo = v);
    });
    AppPrefs.autoPlayAnim().then((v) {
      if (mounted) setState(() => _autoAnim = v);
    });
  }

  @override
  void dispose() {
    _pc.dispose();
    _panelAC.dispose();
    super.dispose();
  }

  /// 删除条目后重建控制器：PageView 的 itemCount 变短时，
  /// 沿用旧控制器会因 currentPage 越界触发断言，直接换一个 initialPage 合法的控制器最稳。
  /// 旧控制器要等这一帧渲染完（元素已卸载）再释放，否则会在仍挂载时被 dispose。
  void _resetPager() {
    final old = _pc;
    _pc = PageController(initialPage: _index);
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  void _toggleChrome() {
    setState(() => _showChrome = !_showChrome);
    SystemChrome.setEnabledSystemUIMode(
        _showChrome ? SystemUiMode.edgeToEdge : SystemUiMode.immersive);
  }

  void _onPageChanged(int i) {
    setState(() {
      _index = i;
      _zoomed = false;
    });
  }

  // ─────────────────── 横向手势：左滑信息 / 右滑返回 ───────────────────

  void _onHorizontalStart(DragStartDetails d) {
    _panelWasOpen = _panelV > 0.5;
  }

  void _onHorizontalUpdate(DragUpdateDetails d) {
    final dx = d.primaryDelta ?? 0;
    final panelW = MediaQuery.of(context).size.width * _panelWidthFactor;
    if (_panelWasOpen) {
      // 卡片已展开：只响应向右拖，跟手关闭
      if (dx >= 0) {
        _panelAC.value = (_panelV - dx / panelW).clamp(0.0, 1.0);
      }
      return;
    }
    if (dx < 0) {
      // 左滑：跟手拉出信息卡片
      if (_dismissX > 0) return;
      _panelAC.value = (_panelV + (-dx) / panelW).clamp(0.0, 1.0);
    } else if (_panelV < 0.01) {
      // 右滑：内容跟手右移准备返回（卡片未拉出时才生效）
      final sw = MediaQuery.of(context).size.width;
      setState(() => _dismissX = (_dismissX + dx).clamp(0.0, sw));
    }
  }

  void _onHorizontalEnd(DragEndDetails d) {
    final vx = d.velocity.pixelsPerSecond.dx;
    if (_panelV > 0.001) {
      // 卡片在动：快甩优先，否则按是否过半决定吸附
      if (vx < -500) {
        _panelAC.forward();
      } else if (vx > 500) {
        _panelAC.reverse();
      } else if (_panelV >= 0.5) {
        _panelAC.forward();
      } else {
        _panelAC.reverse();
      }
      return;
    }
    final sw = MediaQuery.of(context).size.width;
    if (_dismissX > sw * 0.18 || vx > 800) {
      Navigator.of(context).pop();
    } else if (_dismissX != 0) {
      setState(() => _dismissX = 0);
    }
  }

  void _onHorizontalCancel() {
    if (_panelV > 0.001 && _panelV < 0.999) {
      _panelWasOpen ? _panelAC.forward() : _panelAC.reverse();
    }
    if (_dismissX != 0) setState(() => _dismissX = 0);
  }

  // ─────────────────── 保存 / 删除 ───────────────────

  Future<void> _saveCurrent() async {
    final item = _current;
    setState(() => _saving = true);
    try {
      // 统一保存到系统相册（目录在设置里可配，默认 DCIM/NAS相册下载），
      // 保存后在系统图库可见，不再写入用户看不到的应用私有目录。
      await MediaDownloader.downloadOne(item);
      final path = await AppPrefs.downloadRelativePath();
      _snack('已保存到系统相册「$path」');
    } catch (e) {
      _snack('保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 删除当前条目：NAS 移入回收站，可选同步删除手机本地副本
  Future<void> _deleteCurrent() async {
    if (_deleting) return;
    if (AppState.I.client == null) {
      _snack('尚未连接到 NAS，请重新登录');
      return;
    }
    final item = _current;
    final choice = await showDeleteConfirmDialog(
      context,
      count: 1,
      fileName: item.fileName,
    );
    if (choice == null || !choice.confirmed) return;

    setState(() => _deleting = true);
    try {
      await MediaDeleter.delete(
        items: [item],
        syncLocal: choice.syncLocal,
      );
      if (!mounted) return;
      // 从共享列表里移除，父级网格同步刷新
      widget.items.remove(item);
      widget.onChanged?.call();
      clearImageCache();

      if (widget.items.isEmpty) {
        Navigator.of(context).pop();
      } else {
        setState(() {
          _index = _index.clamp(0, widget.items.length - 1);
          _resetPager();
        });
      }
      // 删除成功后不弹提示：操作结果在界面上已直接体现（照片消失），
      // 无需再告知回收站/本机副本细节。
    } catch (e) {
      _snack('删除失败：$e');
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  static String _size(int b) {
    if (b <= 0) return '-';
    const u = ['B', 'KB', 'MB', 'GB'];
    var v = b.toDouble();
    var i = 0;
    while (v >= 1024 && i < u.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${u[i]}';
  }

  static String _duration(int sec) {
    if (sec <= 0) return '';
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final s = sec % 60;
    String two(int x) => x.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  // ─────────────────── build ───────────────────

  @override
  Widget build(BuildContext context) {
    final sw = MediaQuery.of(context).size.width;
    final dismissRatio = (_dismissX / sw).clamp(0.0, 1.0);
    // 信息卡片完全盖住画面时，连同顶/底栏一起隐藏，呈现纯卡片
    final chromeVisible = _showChrome && _panelV < 0.01;
    final bottomInset =
        chromeVisible ? MediaQuery.of(context).padding.bottom + 76 : 0.0;
    final panelW = sw * _panelWidthFactor;

    return Scaffold(
      // 右滑返回时渐隐，露出后面的照片墙
      backgroundColor: Color.fromRGBO(0, 0, 0, 1 - dismissRatio * 0.7),
      extendBodyBehindAppBar: true,
      appBar: chromeVisible ? _appBar() : null,
      body: GestureDetector(
        // 只在未放大时接管横向手势（放大时要留给图片平移）；
        // 纵向手势由纵向 PageView 接管，二者方向正交、互不打架。
        onHorizontalDragStart: _zoomed ? null : _onHorizontalStart,
        onHorizontalDragUpdate: _zoomed ? null : _onHorizontalUpdate,
        onHorizontalDragEnd: _zoomed ? null : _onHorizontalEnd,
        onHorizontalDragCancel: _zoomed ? null : _onHorizontalCancel,
        child: Transform.translate(
          offset: Offset(_dismissX, 0),
          child: Stack(
            children: [
              PageView.builder(
                scrollDirection: Axis.vertical,
                controller: _pc,
                // 提前构建前后各一页，让相邻页的图片在停在当前页时就开始下载、
                // 进内存缓存，翻过去时直接有图，而不是先黑屏转圈（相邻视频页只构建
                // 封面、不初始化视频流，预建不会额外拉流）。
                allowImplicitScrolling: true,
                physics: _zoomed
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                itemCount: widget.items.length,
                onPageChanged: _onPageChanged,
                itemBuilder: (context, i) => _PhotoView(
                  key: ValueKey(widget.items[i].id),
                  item: widget.items[i],
                  active: i == _index,
                  preferOriginal: _original,
                  autoVideo: _autoVideo,
                  autoAnim: _autoAnim,
                  videoControlsInset: bottomInset,
                  videoControlsVisible: chromeVisible,
                  onToggleChrome: _toggleChrome,
                  onZoomChanged: (z) {
                    if (mounted && z != _zoomed) setState(() => _zoomed = z);
                  },
                ),
              ),
              if (chromeVisible) _bottomBar(),
              // ── 左滑信息卡片：遮罩 + 跟手面板 ──
              if (_panelV > 0) ...[
                Positioned.fill(
                  child: IgnorePointer(
                    // 跟手过程中（未过半）不拦截，避免和拖动手势抢触点
                    ignoring: _panelV < 0.5,
                    child: GestureDetector(
                      onTap: _panelAC.reverse,
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: 0.5 * _panelV),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 0,
                  width: panelW,
                  child: Transform.translate(
                    offset: Offset((1 - _panelV) * panelW, 0),
                    child: _InfoCard(
                        item: _current, onClose: _panelAC.reverse),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _appBar() {
    return AppBar(
      backgroundColor: Colors.black38,
      foregroundColor: Colors.white,
      elevation: 0,
      systemOverlayStyle: SystemUiOverlayStyle.light,
      title: Text('${_index + 1} / ${widget.items.length}',
          style: const TextStyle(fontSize: 15)),
      actions: [
        // 「原图」开关（原 HD）
        TextButton.icon(
          onPressed: () => setState(() => _original = !_original),
          style: TextButton.styleFrom(
            foregroundColor:
                _original ? const Color(0xFF7FB6FF) : Colors.white,
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          icon: Icon(_original ? Icons.hd_rounded : Icons.hd_outlined,
              size: 20),
          label: const Text('原图', style: TextStyle(fontSize: 13.5)),
        ),
        IconButton(
          tooltip: '信息',
          icon: const Icon(Icons.info_outline),
          onPressed: _panelAC.forward,
        ),
      ],
    );
  }

  Widget _bottomBar() {
    final pad = MediaQuery.of(context).padding;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(8, 30, 8, pad.bottom + 14),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black87],
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _barButton(
              icon: Icons.download_outlined,
              label: '下载',
              busy: _saving,
              onTap: _saving ? null : _saveCurrent,
            ),
            _barButton(
              icon: Icons.delete_outline,
              label: '删除',
              busy: _deleting,
              danger: true,
              onTap: _deleting ? null : _deleteCurrent,
            ),
          ],
        ),
      ),
    );
  }

  Widget _barButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool busy = false,
    bool danger = false,
  }) {
    final color = danger ? const Color(0xFFFF6B6B) : Colors.white;
    return SizedBox(
      height: _barButtonsH,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 26,
              height: 26,
              child: busy
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      ),
                    )
                  : Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: color, fontSize: 11.5)),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────── 左滑信息卡片 ───────────────────────────

/// 从右侧跟手滑入的半屏信息卡片。深色表面与全屏看图页的黑色沉浸背景协调。
class _InfoCard extends StatelessWidget {
  final PhotoItem item;
  final VoidCallback onClose;
  const _InfoCard({required this.item, required this.onClose});

  static String _pad2(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final p = item;
    final d = p.takenAt;
    final time = d == null
        ? p.dateTime
        : '${d.year}-${_pad2(d.month)}-${_pad2(d.day)} ${_pad2(d.hour)}:${_pad2(d.minute)}:${_pad2(d.second)}';

    final sizeText = _ViewerPageState._size(p.fileSize);
    final res = '${p.width} × ${p.height}'
        '${p.mp.isNotEmpty ? "   ${p.mp}" : ""}';

    final type = [
      p.fileType,
      if (p.isRaw) 'RAW',
      if (p.isLivePhoto) '实况',
    ].where((s) => s.isNotEmpty).join(' · ');

    // 机型：model 通常已含厂商（如 "Xiaomi 13"），缺失时退回 make
    final camera = p.cameraModel.isNotEmpty
        ? p.cameraModel
        : p.make;

    final rows = <Widget>[];
    void add(String k, String v) {
      if (v.trim().isNotEmpty) rows.add(_kv(k, v));
    }

    add('拍摄时间', time);
    if (p.isVideo) {
      add('分辨率', res);
      add('时长', _ViewerPageState._duration(p.mediaDuration));
    } else {
      add('机型', camera);
      add('光圈', p.fNumber);
      add('快门', p.exposureTime);
      add('感光度', p.isoSpeedRatings);
      add('焦距', p.focalLength);
      add('曝光程序', p.exposureProgram);
      add('测光模式', p.meteringMode);
      add('拍摄位置', p.geo);
      add('分辨率', res);
    }
    add('大小', sizeText);
    add('类型', type);
    add('路径', p.filePath);

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        borderRadius: BorderRadius.horizontal(left: Radius.circular(18)),
        boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 24)],
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('信息',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                children: [
                  Text(
                    p.fileName.isEmpty ? '未命名' : p.fileName,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.white),
                  ),
                  const SizedBox(height: 12),
                  ...rows,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 72,
              child: Text(k,
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 13)),
            ),
            Expanded(
              child: SelectableText(v,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          ],
        ),
      );
}

// ─────────────────────────── 单页内容 ───────────────────────────

class _PhotoView extends StatefulWidget {
  final PhotoItem item;
  final bool active;
  final bool preferOriginal;
  final bool autoVideo;
  final bool autoAnim;

  /// 内联视频控制条距底部的高度（避让大图页下载/删除栏）
  final double videoControlsInset;

  /// 内联视频控制条 / 全屏按钮是否可见（随大图页顶/底栏一起沉浸隐藏）
  final bool videoControlsVisible;

  final VoidCallback onToggleChrome;
  final ValueChanged<bool> onZoomChanged;

  const _PhotoView({
    super.key,
    required this.item,
    required this.active,
    required this.preferOriginal,
    required this.autoVideo,
    required this.autoAnim,
    required this.videoControlsInset,
    required this.videoControlsVisible,
    required this.onToggleChrome,
    required this.onZoomChanged,
  });

  @override
  State<_PhotoView> createState() => _PhotoViewState();
}

class _PhotoViewState extends State<_PhotoView> {
  bool _livePlaying = false;
  int _liveKey = 0;

  @override
  void initState() {
    super.initState();
    // 首屏直接落在实况照片上时也要自动播一遍
    if (widget.active && _shouldAutoPlay) {
      _liveKey++;
      _livePlaying = true;
    }
  }

  @override
  void didUpdateWidget(covariant _PhotoView old) {
    super.didUpdateWidget(old);
    if (!widget.active) {
      // 滑走就停掉，别在后台空跑
      _livePlaying = false;
      return;
    }
    // 刚滑到这一页：按开关自动播一遍实况
    // （这里不需要 setState —— 本方法紧接着就会 build）
    if (!old.active && _shouldAutoPlay) {
      _liveKey++;
      _livePlaying = true;
    }
  }

  bool get _shouldAutoPlay =>
      !widget.item.isVideo && widget.item.isLivePhoto && widget.autoAnim;

  void _playLive() {
    if (!mounted) return;
    setState(() {
      _liveKey++;
      _livePlaying = true;
    });
  }

  String get _stillPath => widget.preferOriginal
      ? widget.item.originalPath
      : (widget.item.thumb.m.isNotEmpty
          ? widget.item.thumb.m
          : (widget.item.thumb.s.isNotEmpty
              ? widget.item.thumb.s
              : widget.item.originalPath));

  String? get _streamPath =>
      widget.item.thumb.video.isEmpty ? null : widget.item.thumb.video;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    if (item.isVideo) return _buildVideo(item);

    final topInset = MediaQuery.of(context).padding.top + kToolbarHeight + 10;

    return Stack(
      fit: StackFit.expand,
      children: [
        _Zoomable(
          onTap: widget.onToggleChrome,
          onZoomChanged: widget.onZoomChanged,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: FnosImage(
                  path: _stillPath,
                  fit: BoxFit.contain,
                  placeholder: item.thumb.s.isEmpty
                      ? null
                      : FnosImage(path: item.thumb.s, fit: BoxFit.contain),
                ),
              ),
              // 实况照片的动态部分：叠在静态图之上，播完自动淡出
              if (_livePlaying)
                Positioned.fill(
                  child: FnosVideoView(
                    key: ValueKey('live_${item.id}_$_liveKey'),
                    photoId: item.id,
                    path: _streamPath,
                    autoPlay: true,
                    loop: false,
                    showControls: false,
                    tapToToggle: false,
                    onCompleted: () {
                      if (mounted) setState(() => _livePlaying = false);
                    },
                  ),
                ),
            ],
          ),
        ),
        // 实况按钮固定在图片左上角（不随缩放移动）
        if (item.isLivePhoto)
          Positioned(
            left: 12,
            top: topInset,
            child: Material(
              color: Colors.black45,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _playLive,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.motion_photos_on,
                      color: Colors.white, size: 22),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildVideo(PhotoItem item) {
    final poster = item.thumb.m.isNotEmpty ? item.thumb.m : item.thumb.s;
    // 中封面未就绪时先用更小的缩略图占位（它在照片墙通常已缓存），避免黑屏
    final posterPh = item.thumb.s.isNotEmpty && item.thumb.s != poster
        ? FnosImage(path: item.thumb.s, fit: BoxFit.contain)
        : null;
    // 非当前页只放静态封面：避免 PageView 预建时把相邻视频也拉流
    if (!widget.active) {
      return Center(
        child: poster.isEmpty
            ? const SizedBox.shrink()
            : FnosImage(
                path: poster, fit: BoxFit.contain, placeholder: posterPh),
      );
    }
    return GestureDetector(
      onTap: widget.onToggleChrome,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (poster.isNotEmpty)
            Center(
              child: FnosImage(
                  path: poster, fit: BoxFit.contain, placeholder: posterPh),
            ),
          FnosVideoView(
            photoId: item.id,
            path: _streamPath,
            autoPlay: widget.autoVideo,
            showControls: true,
            tapToToggle: false,
            controlsBottomInset: widget.videoControlsInset,
            controlsVisible: widget.videoControlsVisible,
            onFullscreen: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => VideoPage(
                photoId: item.id,
                title: item.fileName,
                streamPath: _streamPath,
              ),
            )),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────── 缩放容器 ───────────────────────────

/// 自实现的捏合缩放 / 双击缩放。
///
/// 没有直接用 [InteractiveViewer]，因为需要精确控制"未放大时才允许侧滑/翻页"，
/// 而 [InteractiveViewer] 会无条件吃掉手势。
/// 这里用 [GestureDetector.onScale*]：其平移判定阈值（36px）高于
/// 翻页/侧滑的判定阈值（18px），因此纵向交给 PageView、横向交给外层侧滑，
/// 缩放只在真正捏合时生效，互不打架。
class _Zoomable extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoomChanged;

  const _Zoomable({
    required this.child,
    required this.onTap,
    required this.onZoomChanged,
  });

  @override
  State<_Zoomable> createState() => _ZoomableState();
}

class _ZoomableState extends State<_Zoomable>
    with SingleTickerProviderStateMixin {
  static const double _maxScale = 5;
  static const double _doubleTapScale = 2.5;

  double _scale = 1;
  Offset _offset = Offset.zero;
  Size _viewSize = Size.zero;
  bool _zoomed = false;

  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  late final AnimationController _ac = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 200));
  double _fromScale = 1, _toScale = 1;
  Offset _fromOffset = Offset.zero, _toOffset = Offset.zero;

  Offset _lastTapPos = Offset.zero;

  @override
  void initState() {
    super.initState();
    _ac.addListener(() {
      final t = Curves.easeOutCubic.transform(_ac.value);
      setState(() {
        _scale = _fromScale + (_toScale - _fromScale) * t;
        _offset = Offset.lerp(_fromOffset, _toOffset, t) ?? _offset;
      });
      _reportZoom();
    });
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  void _reportZoom() {
    final z = _scale > 1.01;
    if (z != _zoomed) {
      _zoomed = z;
      widget.onZoomChanged(z);
    }
  }

  /// 把位移限制在「图片始终铺满可视区」的范围内
  Offset _clamp(Offset o, double s) {
    final maxX = (_viewSize.width * (s - 1)).clamp(0.0, double.infinity);
    final maxY = (_viewSize.height * (s - 1)).clamp(0.0, double.infinity);
    return Offset(o.dx.clamp(-maxX, 0.0), o.dy.clamp(-maxY, 0.0));
  }

  void _onScaleStart(ScaleStartDetails d) {
    _ac.stop();
    _startScale = _scale;
    _startOffset = _offset;
    _startFocal = d.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final next = (_startScale * d.scale).clamp(1.0, _maxScale);
    if (next <= 1.0001 && _startScale <= 1.0001) {
      // 未放大：不做任何变换，交回外层处理翻页/侧滑
      if (_scale != 1 || _offset != Offset.zero) {
        setState(() {
          _scale = 1;
          _offset = Offset.zero;
        });
        _reportZoom();
      }
      return;
    }
    final k = next / _startScale;
    // 保持起始焦点处的内容不动，并叠加手指平移量
    final off = d.localFocalPoint - (_startFocal - _startOffset) * k;
    setState(() {
      _scale = next;
      _offset = _clamp(off, next);
    });
    _reportZoom();
  }

  void _onDoubleTapDown(TapDownDetails d) => _lastTapPos = d.localPosition;

  void _onDoubleTap() {
    if (_scale > 1.01) {
      _fromScale = _scale;
      _toScale = 1;
      _fromOffset = _offset;
      _toOffset = Offset.zero;
    } else {
      final f = _lastTapPos;
      _fromScale = _scale;
      _toScale = _doubleTapScale;
      _fromOffset = _offset;
      _toOffset = _clamp(f * (1 - _doubleTapScale), _doubleTapScale);
    }
    _ac.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        _viewSize = Size(c.maxWidth, c.maxHeight);
        // 直接构造矩阵，避免 Matrix4.translate/scale 的 API 歧义
        final m = Matrix4.identity()
          ..setEntry(0, 0, _scale)
          ..setEntry(1, 1, _scale)
          ..setEntry(0, 3, _offset.dx)
          ..setEntry(1, 3, _offset.dy);

        // 用 RawGestureDetector 自定义缩放识别器的单指拖拽权限：
        // 未放大时，单指拖拽明确让给纵向 PageView（上下翻页）和外层横向手势
        //（左滑信息 / 右滑返回），缩放层不参与竞争，否则 ScaleGestureRecognizer
        // 默认会把单指拖动也当平移接受、偶尔抢赢竞技场，表现为翻页"不跟手、要划好几次"；
        // 放大后才接管单指平移。双指缩放始终由缩放识别器处理，不受此权限影响。
        return RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            TapGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              () => TapGestureRecognizer(),
              (t) => t..onTap = widget.onTap,
            ),
            DoubleTapGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
              () => DoubleTapGestureRecognizer(),
              (d) => d
                ..onDoubleTapDown = _onDoubleTapDown
                ..onDoubleTap = _onDoubleTap,
            ),
            _ZoomableScaleRecognizer:
                GestureRecognizerFactoryWithHandlers<_ZoomableScaleRecognizer>(
              () => _ZoomableScaleRecognizer(),
              (s) => s
                ..isZoomed = (() => _scale > 1.01)
                ..onStart = _onScaleStart
                ..onUpdate = _onScaleUpdate,
            ),
          },
          child: ClipRect(
            child: Transform(
              alignment: Alignment.topLeft,
              transform: m,
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}

/// 大图页专用缩放识别器。
///
/// 官方 [ScaleGestureRecognizer] 在单指移动超过 panSlop 时就会主动 accept
/// 手势（这个版本没有「放大后才接管单指拖动」的开关）。快速滑动时它位于手势
/// 命中链最内层、最先收到移动事件，会抢先赢下竞技场，导致纵向 PageView 被
/// reject —— 表现为上下翻页「有时滑不动、要划好几次」。
///
/// 这里在「未放大 + 单指移动」时直接不交给父级状态机，使其不触发 accept，
/// 把纵向拖动让给 PageView、横向拖动让给外层侧滑/返回手势；放大后才接管单指
/// 平移。双指缩放不受影响（pointerCount==2 的移动照常处理）。
class _ZoomableScaleRecognizer extends ScaleGestureRecognizer {
  /// 外部提供：当前图片是否已放大。
  bool Function()? isZoomed;

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent &&
        pointerCount == 1 &&
        !(isZoomed?.call() ?? false)) {
      return;
    }
    super.handleEvent(event);
  }
}
