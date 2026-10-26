import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
// ScrollCacheExtent 定义在 rendering 库；material 不导出它。
// 用它把 PageView 的预构建范围从默认 1 页扩到预加载窗口大小。
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/error_text.dart';
import '../core/media_deleter.dart';
import '../core/media_downloader.dart';
import '../core/media_preloader.dart';
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

  /// 翻页时回调当前下标。
  ///
  /// 供照片墙在退回来后定位到最后看过的那一张。用回调而不是 pop 的返回值：
  /// 退出有三条路径（右滑返回、系统返回键、列表删空后自动 pop），回调一次覆盖全部。
  final ValueChanged<int>? onIndexChanged;

  const ViewerPage({
    super.key,
    required this.items,
    this.initialIndex = 0,
    this.onChanged,
    this.onIndexChanged,
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
  /// 卡片占屏幕右侧约三分之二：再宽会把正在看的画面挡死，
  /// 毛玻璃也就失去"透出背景"的意义了。
  static const double _panelWidthFactor = 2 / 3;
  late final AnimationController _panelAC = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 260));
  double get _panelV => _panelAC.value;

  /// 一次横向手势开始时，卡片是否已展开（决定本次拖动是「开」还是「关」）
  bool _panelWasOpen = false;

  /// 预热锚点页。
  ///
  /// 刻意**不在滑动过程中跟随 [_index]**：翻飞时 `_index` 会逐页变化，
  /// 若据此预热就会一边穿页一边反复 create/dispose ExoPlayer。
  /// 等滑动停下来（ScrollEndNotification）再把锚点对齐。
  late int _prewarmAnchor = widget.initialIndex;

  /// 底部下载/删除按钮列的固定高度，视频控制条据此上移避让
  static const double _barButtonsH = 58;

  PhotoItem get _current => widget.items[_index];

  // ─────────────────── 预加载窗口 ───────────────────

/// 该条目用于大图页显示的图片地址。
///
/// ⚠️ **清晰度分流**（2026-10-21，v1.0.3 关键修复）：
/// `thumb.m` 是中尺寸缩略图（约 100KB 级），`originalPath` 是原图（手机拍的照片
/// 常有 5~10MB）。NAS 用机械盘时实测读取会顶到 100MB/s —— **原图的预加载会把
/// 带宽瞬间抽干，正在播放的视频反而被饿死、反复缓冲**（用户实机反馈的现象）。
///
/// 因此：
///   · HD（原图）**关闭** → 用 `thumb.m`，随便预热，滑动始终顺滑；
///   · HD 打开 → 走原图，但**当前页立即加载、相邻页不预热**（见 [_planFor]），
///     否则原图预热同样会拖垮视频。
String _imageOf(PhotoItem it) => _original
      ? it.originalPath
      : it.thumb.viewHalf;

  /// 该条目的视频 / 实况流地址（与 _PhotoView._streamPath 同口径）。
  String _videoOf(PhotoItem it) => it.thumb.video;

  /// 算出以 [index] 为锚点的预加载计划。
  ///
  /// 图片向后 8 / 前序保留 3（超出的从缓存释放），视频同样按 8 / 3
  /// 登记 —— 视频与图片**分开计数**，互不抢占对方的配额。
  ///
  /// ⚠️ **原图模式（HD 打开）下只预热当前页**，相邻页一律不预热。
  /// 原图单张动辄 5~10MB，NAS 机械盘读取上限约 100MB/s ——
  /// 预热 8 张原图等于把整个带宽占满，正在播的视频会被彻底饿死。
  /// 用户实机确认过这条因果（原图模式一开视频就频繁卡顿）。
  /// 「HD 关闭用低清随便滑、HD 打开只保证当前页清晰」是两头的最优解。
  PreloadPlan _planFor(int index, PreloadWindow w) {
    final items = widget.items;
    if (items.isEmpty || index < 0 || index >= items.length) {
      return PreloadPlan.empty;
    }
    final endAhead = (index + w.ahead).clamp(0, items.length - 1);
    final startBehind = (index - w.behind).clamp(0, items.length - 1);

    final images = <String>[];
    final videos = <String>[];
    final keep = <String>{};

    // 原图模式：只排当前页；其余相邻项一律不预热（见上方说明）
    final endPrefetch = _original ? index : endAhead;

    for (int i = index; i <= endPrefetch; i++) {
      final it = items[i];
      final img = _imageOf(it);
      if (img.isNotEmpty) {
        images.add(img);
        keep.add(img);
      }
      final v = _videoOf(it);
      if (v.isNotEmpty) videos.add(v);
    }

    // 前序保留区：低清模式下才值得留（滑回去立刻有图）；
    // 原图模式下这些原图留着纯占内存，不要。
    if (!_original) {
      for (int i = startBehind; i < index; i++) {
        final it = items[i];
        final img = _imageOf(it);
        if (img.isNotEmpty) {
          images.add(img);
          keep.add(img);
        }
        final v = _videoOf(it);
        if (v.isNotEmpty) videos.add(v);
      }
    }

    // 注意：比 startBehind 更靠前的**不加入 keep** —— 它们会被 apply()
    // 从内存缓存里释放掉，这正是「前序只保留 3 个」的实现点。
    return PreloadPlan(
        images: images, videos: videos, keepImages: keep, evictVideos: const []);
  }

  /// 锚点变化后重新排预热。
  void _refreshPreload() {
    if (!mounted || widget.items.isEmpty) return;
    MediaPreloader.I.apply(_planFor(_prewarmAnchor, _preloadWindow));
  }

  /// 预加载窗口。向后 8、前序保留 3 —— 快速滑动时 8 个足够覆盖手指连续
  /// 划过的距离，又不至于把 NAS 的带宽一次抽干。
  static const PreloadWindow _preloadWindow =
      PreloadWindow(ahead: 8, behind: 3);

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshPreload());
  }

  @override
  void dispose() {
    // 沉浸模式是全局系统 UI 状态，页面退出时必须还原，否则用户返回图库后
    // 状态栏/导航栏会一直消失到进程被杀（全工程只有 _toggleChrome 会设它）。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
    // 信息卡展开时，点一下画面先收起卡片（原先的遮罩点击已随"挤压"布局移除）
    if (_panelV > 0.001) {
      _panelAC.reverse();
      return;
    }
    setState(() => _showChrome = !_showChrome);
    SystemChrome.setEnabledSystemUIMode(
        _showChrome ? SystemUiMode.edgeToEdge : SystemUiMode.immersive);
  }

  void _onPageChanged(int i) {
    setState(() {
      _index = i;
      _zoomed = false;
    });
    widget.onIndexChanged?.call(i);
    // 当前页变了就立刻按新位置排预热 —— 滑动过程中 _index 每次都在变，
    // 预热队列因此能持续跟进手指方向（PageView 的构建范围仍只用于建 UI）。
    _refreshPreload();
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
      _snack('保存失败：${friendlyError(e)}');
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
      // 缓存与预热去重状态必须一起清：只清缓存会让这些 key 永远不再预热
      MediaPreloader.I.resetAll();

      if (widget.items.isEmpty) {
        Navigator.of(context).pop();
      } else {
        setState(() {
          _index = _index.clamp(0, widget.items.length - 1);
          // 列表变了，预热锚点也要跟着落到新的当前页
          _prewarmAnchor = _index;
          _resetPager();
        });
        // 删掉一条后窗口整体前移，重新排一次（否则会继续预热已删除的条目）
        _refreshPreload();
        // 列表变短了，父级记的「最后看到第几张」必须一起收敛 —— 否则退出后
        // 照片墙会按删除前的下标定位到**另一张**（删得多时越界，表现为静默不定位）。
        widget.onIndexChanged?.call(_index);
      }
      // 删除成功后不弹提示：操作结果在界面上已直接体现（照片消失），
      // 无需再告知回收站/本机副本细节。
    } catch (e) {
      _snack('删除失败：${friendlyError(e)}');
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
    // 信息卡展开时顶/底栏让位：画面被挤压到左侧，只在左栏展示媒体
    final chromeVisible = _showChrome && _panelV < 0.01;
    final bottomInset =
        chromeVisible ? MediaQuery.of(context).padding.bottom + 76 : 0.0;
    final panelW = sw * _panelWidthFactor;

    return Scaffold(
      // 右滑返回时渐隐，露出后面的照片墙
      backgroundColor: Color.fromRGBO(0, 0, 0, 1 - dismissRatio * 0.7),
      // ⚠️ 必须是 true（2026-10-21 修复「视频被底栏挤下去」）：
      // body 始终占满整屏，顶栏只是**覆盖**在上面。若为 false，顶栏显隐会改变
      // body 的高度与起点，居中内容随之上下跳 —— 用户看到的就是
      // 「显示按钮时视频跑到下方、点一下隐藏后又回到中央」。
      // 之前为修「页码发灰」把它改成 false，是治错了病：真正原因是顶栏背景
      // 半透明（black38）透出底层内容，改成实色 0xD9000000 即可，不必动布局。
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
              // ── 媒体区：信息卡展开时同步被挤压到左侧剩余宽度 ──
              // 用真实布局宽度（而不是缩放）挤压：竖构图照片/视频会保持
              // 自身比例缩到左栏内，与"被卡片盖住"完全不同——画面始终完整可见。
              Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: sw - panelW * _panelV,
                  child: NotificationListener<ScrollEndNotification>(
                    // 滑动结束才把预热锚点对齐到当前页（见 _prewarmAnchor 的说明）
                    onNotification: (_) {
                      if (_prewarmAnchor != _index && mounted) {
                        setState(() => _prewarmAnchor = _index);
                        _refreshPreload();
                      }
                      return false;
                    },
                    child: PageView.builder(
                      scrollDirection: Axis.vertical,
                      controller: _pc,
                      // 提前构建前后各一页，让相邻页的图片在停在当前页时就开始下载、
                      // 进内存缓存，翻过去时直接有图。相邻页的视频 / 实况也会在这时
                      // 只做 prepare（= 预热），翻过去瞬间开播 —— 见 _PhotoView.prewarm。
                      allowImplicitScrolling: true,
                      // 只额外构建锚点前后各 1 页：足够让「紧邻页」建好播放器
                      // （只 prepare 不播），也避免一次构建十几页。
                      // ⚠️ Flutter 的 cacheExtent 是**前后各生效一次**
                      // （fullCacheExtent = viewport + 2 × cacheExtent），
                      // 用 viewport(8) 实际会构建最多 17 页，每页都会加载并解码
                      // 图片，内存/带宽峰值远超预期。
                      // 图片字节由 MediaPreloader 独立预热，不依赖这里。
                      scrollCacheExtent: const ScrollCacheExtent.viewport(1.0),
                      physics: _zoomed
                          ? const NeverScrollableScrollPhysics()
                          : const PageScrollPhysics(),
                      itemCount: widget.items.length,
                      onPageChanged: _onPageChanged,
                      itemBuilder: (context, i) => _PhotoView(
                        key: ValueKey(widget.items[i].id),
                        item: widget.items[i],
                        active: i == _index,
                        // 「预热」范围 = 锚点前后窗口内（供图片预加载表与标记使用）
                        prewarm:
                            (i - _prewarmAnchor).abs() <= _preloadWindow.ahead,
                        // 「紧邻」= 锚点前后各 1：只有它才真的建播放器
                        nearby: (i - _prewarmAnchor).abs() == 1,
                        preferOriginal: _original,
                        autoVideo: _autoVideo,
                        autoAnim: _autoAnim,
                        videoControlsInset: bottomInset,
                        videoControlsVisible: chromeVisible,
                        onToggleChrome: _toggleChrome,
                        onZoomChanged: (z) {
                          if (mounted && z != _zoomed) {
                            setState(() => _zoomed = z);
                          }
                        },
                      ),
                    ),
                  ),
                ),
              ),
              if (chromeVisible) _bottomBar(),
              // ── 左滑信息卡片（画面已被挤压到左侧，卡片不再遮挡内容）──
              if (_panelV > 0) ...[
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
      // 实色半黑：保证页码与「原图 / 信息」始终清晰可读。
      // 原来是 black38（38% 黑），在深色视频画面上会与内容叠成灰色。
      backgroundColor: const Color(0xD9000000),
      foregroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      systemOverlayStyle: SystemUiOverlayStyle.light,
      // ⚠️ M3 的 IconButton 默认取 `colorScheme.onSurface`（灰），
      // **不跟随** AppBar.foregroundColor —— 于是 actions 里的图标在黑色顶栏上
      // 呈灰色（用户实机反馈的「信息按钮是灰的」）。
      // 这里用 iconTheme 给整条 actions 兜底成白色。
      iconTheme: const IconThemeData(color: Colors.white),
      title: Text('${_index + 1} / ${widget.items.length}',
          style: const TextStyle(fontSize: 15, color: Colors.white)),
      actions: [
        // 「原图」开关：默认 480p，开启后才加载原图。
        // 用户要求去掉 HD 图标，只保留「原图」二字（用颜色区分开关状态）。
        TextButton(
          onPressed: () {
            setState(() => _original = !_original);
            // 换了清晰度 → 整窗地址都变了，预热要按新地址重排。
            // 原图模式只排当前页（见 _planFor），此时窗口外的低清图会被
            // apply() 按 keepImages 释放掉，不会两种清晰度一起占内存。
            _refreshPreload();
          },
          style: TextButton.styleFrom(
            foregroundColor:
                _original ? const Color(0xFF7FB6FF) : Colors.white,
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
          child: const Text('原图',
              style: TextStyle(fontSize: 13.5)),
        ),
        IconButton(
          tooltip: '信息',
          // 显式指定白色：M3 的 IconButton 不吃 AppBar.foregroundColor，
          // 不写死就一直是灰的。
          icon: const Icon(Icons.info_outline, color: Colors.white),
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

    // 半透明毛玻璃：BackdropFilter 实时模糊身后的照片/视频（由 Flutter 引擎
    // 在 GPU 上完成，不引入任何依赖），再叠 5% 的深色底。
    // 这么低的底色几乎完全靠模糊本身拉开层次，文字可读性依赖 blur 的柔化。
    // 阴影必须留在 ClipRRect **外面**，否则会被圆角裁剪一起裁掉。
    return DecoratedBox(
      decoration: const BoxDecoration(
        borderRadius: BorderRadius.horizontal(left: Radius.circular(18)),
        boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 24)],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(18)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            color: const Color(0x0D1C1C1E),
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
                    padding: const EdgeInsets.fromLTRB(16, 12, 4, 6),
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
                  const Divider(color: Colors.white24, height: 1),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 14, 14, 24),
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
          ),
        ),
      ),
    );
  }

  /// 标签列固定宽度、标签**右对齐**，值紧随其后左对齐：
  /// 行的左右两端都成一条直线（"两端对齐"），值列不会因为标签长短而参差。
  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 66,
              child: Text(k,
                  textAlign: TextAlign.right,
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 13)),
            ),
            const SizedBox(width: 10),
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

  /// 是否处于「预热窗口内」。预热只做 prepare 不播。
  ///
  /// 窗口由父级给出（向后 8 / 前序 3）——**不含**当前页自己。
  final bool prewarm;

  /// 是否**紧邻**当前页（锚点前后各 1）。
  ///
  /// 只有紧邻的条目才真的建 ExoPlayer：常驻播放器很贵（一条连接 + 一份
  /// 缓冲 + 一个原生实例），窗口内 8 个全建会瞬间占满 NAS 的连接数，
  /// 反而把当前页的带宽抢走 —— 这正是「预热抢占带宽/IO」的真正代价。
  /// 更远的条目靠图片预加载命中，等滑到前 1 页时它就变成紧邻、此时才建。
  final bool nearby;

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
    required this.prewarm,
    required this.nearby,
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

  /// 实况「重播」令牌：自增让播放器 seek 回 0 再播。
  ///
  /// 以前是用 `_liveKey++` 换掉整个 FnosVideoView 的 key 来强制重建 ——
  /// 那等于把预热好的控制器一起丢掉、重新 initialize，重播又要等一次。
  int _restartToken = 0;

  @override
  void initState() {
    super.initState();
    // 首屏直接落在实况照片上时也要自动播一遍
    // （新控制器本来就在 0 位，不需要 restartToken）
    if (widget.active && _shouldAutoPlay) _livePlaying = true;
  }

  @override
  void didUpdateWidget(covariant _PhotoView old) {
    super.didUpdateWidget(old);
    // 换了条目（PageView 元素复用 / 照片墙换页）必须把状态清干净。
    // 原来只判active，元素被复用成**另一条**时 `_livePlaying` / `_restartToken`
    // 会原样带过去 —— 表现为「滑到某个实况照片，它自己不动了」或
    // 「上一张的重播令牌作用到了这一张」。
    if (old.item.id != widget.item.id) {
      _livePlaying = false;
      _restartToken = 0;
    }
    if (!widget.active) {
      // 滑走就停掉，别在后台空跑（控制器由 FnosVideoView 自己按 active 收起画面，
      // 相邻页会保留预热好的实例）
      _livePlaying = false;
      return;
    }
    // 刚滑到这一页：按开关自动播一遍实况
    // （这里不需要 setState —— 本方法紧接着就会 build）
    if (!old.active && _shouldAutoPlay) {
      // 预热的那个控制器可能已经播到过末尾了，必须回到开头
      _restartToken++;
      _livePlaying = true;
    }
  }

  bool get _shouldAutoPlay =>
      !widget.item.isVideo && widget.item.isLivePhoto && widget.autoAnim;

  void _playLive() {
    if (!mounted) return;
    setState(() {
      _restartToken++;
      _livePlaying = true;
    });
  }

  /// 只有**当前页**且打开「原图」时才取原图。
  ///
  /// PageView 的缓存范围会同时构建相邻页；若相邻页也取原图，一次滑动就会
  /// 有多张大图同时下载/解码，既占内存又抽干 NAS 带宽（与 [_planFor] 的
  /// 「原图只预热当前页」约束冲突）。相邻页一律用中等图，翻过去变 active
  /// 后再通过 didUpdateWidget 换成原图。
  String get _stillPath =>
      widget.preferOriginal && widget.active
          ? widget.item.originalPath
          : widget.item.thumb.viewHalf;

  String? get _streamPath =>
      widget.item.thumb.video.isEmpty ? null : widget.item.thumb.video;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    if (item.isVideo) return _buildVideo(item);

    // 实况按钮固定在图片左上角（不随缩放移动）。
    // body 延伸到了 AppBar 之下（extendBodyBehindAppBar=true，为了让居中
    // 内容不随顶栏显隐跳动），所以这里要自己让开状态栏 + 工具栏的高度。
    final topInset =
        MediaQuery.of(context).padding.top + kToolbarHeight + 10;

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
              // 实况照片的动态部分：叠在静态图之上，播完自动收起。
              // 窗口内就建播放器（只 prepare 不播），滑过来时只需 play()。
              //
              // ⚠️ 只给**紧邻当前页**的 1 个建播放器，其余窗口内的条目只登记到
              // MediaPreloader（视频与图片分开计数）：一个 ExoPlayer 实例常驻
              // 就要占一条连接 + 一份缓冲，8 页全建会把 NAS 的连接数占满，
              // 反而拖慢当前页 —— 这就是「预热抢占带宽/IO」的真正代价。
              // 紧邻 1 个足以覆盖滑动节奏，更远的等滑到前再由 didUpdateWidget 建。
              if (item.isLivePhoto &&
                  (_livePlaying || (widget.autoAnim && (widget.active || widget.nearby))))
                Positioned.fill(
                  child: FnosVideoView(
                    // key 里**不再**带 _liveKey：以前"刚滑到本页"会 +1，
                    // 等于每次都重建播放器、把预热成果丢掉。重播改走 restartToken。
                    key: ValueKey('live_${item.id}'),
                    photoId: item.id,
                    path: _streamPath,
                    active: widget.active,
                    play: widget.active && _livePlaying,
                    restartToken: _restartToken,
                    loop: false,
                    showControls: false,
                    showPlayButton: false,
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
    final poster = item.thumb.viewHalf;
    // 中封面未就绪时先用更小的缩略图占位（它在照片墙通常已缓存），避免黑屏
    final posterPh = item.thumb.s.isNotEmpty && item.thumb.s != poster
        ? FnosImage(path: item.thumb.s, fit: BoxFit.contain)
        : null;
    // 当前页建播放器并开播；**紧邻页**也建，但只 prepare 不播（预热 ——
    // 翻过去只需 play()，不再有"转圈半秒"）。
    // ⚠️ 只有紧邻 1 个才建：ExoPlayer 每个实例独占一条连接 + 一份缓冲，
    // 窗口内 8 个全建会把 NAS 连接数占满，反而让当前页抢不到带宽。
    // 更远的视频条目已由 MediaPreloader 登记在窗口里（滑到前 1 页时它就
    // 变成紧邻，此时才建），因此这里不需要也不应该建。
    if (!widget.active && !widget.nearby) {
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
          // 封面在最底层。播放器在确认出画面之前是透明的一层，
          // 所以预热期间（以及还没出首帧时）用户看到的仍然是这张封面，
          // 既没有转圈、也不会被黑帧盖住。
          if (poster.isNotEmpty)
            Center(
              child: FnosImage(
                  path: poster, fit: BoxFit.contain, placeholder: posterPh),
            ),
          FnosVideoView(
            // 与实况分支对齐：没有 key 时元素在插槽上被复用（列表增删导致）
            // 可能继续播上一条流。
            key: ValueKey('video_${item.id}'),
            photoId: item.id,
            path: _streamPath,
            active: widget.active,
            // 只有当前页、且用户开了「自动播放视频」才开播；
            // 其余情况只预热 —— 用户点播放键时画面已经就绪。
            play: widget.active && widget.autoVideo,
            showControls: true,
            // 预热的相邻页不显示大播放键，免得滑动过程中一闪而过
            showPlayButton: widget.active,
            tapToToggle: false,
            controlsBottomInset: widget.videoControlsInset,
            controlsVisible: widget.videoControlsVisible,
            onFullscreen: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => VideoPage(
                photoId: item.id,
                title: item.fileName,
                streamPath: _streamPath,
                // 转屏 / 建连期间用封面垫底，避免黑屏
                posterPath: item.thumb.viewHalf,
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
      // 双击缩放的 200ms 动画期间页面可能已被 pop，动画 tick 仍会落到
      // 已卸载的 State 上（debug 下直接抛 setState after dispose）。
      if (!mounted) return;
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

  void _onPinchStart(Offset focal) {
    _ac.stop();
    _startScale = _scale;
    _startOffset = _offset;
    _startFocal = focal;
  }

  void _onPinchUpdate(double scaleMultiplier, Offset focal) {
    final next = (_startScale * scaleMultiplier).clamp(1.0, _maxScale);
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
    final off = focal - (_startFocal - _startOffset) * k;
    setState(() {
      _scale = next;
      _offset = _clamp(off, next);
    });
    _reportZoom();
  }

  /// 已放大后的单指平移（翻页/侧滑此时已被外层禁用）
  void _onPanUpdate(Offset delta) {
    setState(() {
      _offset = _clamp(_offset + delta, _scale);
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
            _PinchRecognizer:
                GestureRecognizerFactoryWithHandlers<_PinchRecognizer>(
              () => _PinchRecognizer(
                onPinchStart: _onPinchStart,
                onPinchUpdate: _onPinchUpdate,
                onPanUpdate: _onPanUpdate,
                onPinchEnd: () {},
                isZoomed: () => _scale > 1.01,
              ),
              (s) {
                // updater 里同步最新闭包（State 可能被复用）
                s
                  ..onPinchStart = _onPinchStart
                  ..onPinchUpdate = _onPinchUpdate
                  ..onPanUpdate = _onPanUpdate
                  ..isZoomed = () => _scale > 1.01;
              },
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
/// 之前用 `ScaleGestureRecognizer` + 覆写 `handleEvent` 吞掉「单指移动」来阻止
/// 它抢 PageView 的翻页手势。但这会**破坏指针位置追踪**：第一根手指的 move 被吞
/// 之后 `_pointerPositions` 就停在陈旧位置，第二根手指按下时算出的 `_initialSpan`
/// 是错的，于是 scale 永远算不出来 —— 表现为「双指放大完全没反应，只能双击放大」。
///
/// 这里干脆自己实现：不依赖 ScaleGestureRecognizer 的状态机，直接按指针数分流：
///   · **双指** → 立即 accept（吃掉手势，不让 PageView 翻页），自己算 scale；
///   · **单指 + 已放大** → accept，处理平移（此时 PageView 已被外层禁用）；
///   · **单指 + 未放大** → 不 resolve，把纵向翻页让给 PageView、横向让给外层。
class _PinchRecognizer extends OneSequenceGestureRecognizer {
  _PinchRecognizer({
    required this.onPinchStart,
    required this.onPinchUpdate,
    required this.onPanUpdate,
    required this.onPinchEnd,
    required this.isZoomed,
  });

  /// 双指手势开始（给出初始焦点，用于算平移基准）
  void Function(Offset focalPoint) onPinchStart;

  /// 双指手势更新：[scaleMultiplier] 是相对起点的倍数
  void Function(double scaleMultiplier, Offset focalPoint) onPinchUpdate;

  /// 单指平移（仅在已放大时触发）
  void Function(Offset delta) onPanUpdate;

  void Function() onPinchEnd;

  /// 外部提供：当前图片是否已放大
  bool Function() isZoomed;

  /// 当前活跃指针的位置（本地坐标）
  final Map<int, Offset> _pointers = {};
  double _initialSpan = 0;
  Offset _lastSingle = Offset.zero;
  bool _pinching = false;

  /// 放大态下的单指平移是否已启动（移动超过 slop 才算）
  bool _panning = false;

  /// 与 Flutter 内置手势一致的平移阈值。
  ///
  /// 放大态下单指**不能一按下就 accept**：那会把 DoubleTapGestureRecognizer
  /// 从竞技场里踢掉，导致「双击放大后再次双击无法缩小」。
  /// 必须先让用户有机会完成一次不移动的点击（双击），
  /// 只有移动超过这个阈值才认定是「平移」并抢下竞技场。
  static const double _kPanSlop = 18.0;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer);
    _pointers[event.pointer] = event.localPosition;

    if (_pointers.length == 2) {
      // 双指：立刻抢下竞技场，PageView 就不会被第一根指针的移动触发翻页
      final v = _pointers.values.toList();
      _initialSpan = (v[0] - v[1]).distance;
      _pinching = true;
      // ⚠️ 必须用 resolvePointer 逐指针 accept，不能用 resolve()：
      // stopTrackingPointer 不会清理 _entries，被 PageView 拒绝过的指针
      // 会在其中留下已 resolved 的残留 entry，resolve() 遍历它们会二次
      // 调用 entry.resolve() → 触发 assert(!_resolved)。
      for (final p in _pointers.keys.toList()) {
        resolvePointer(p, GestureDisposition.accepted);
      }
      onPinchStart((v[0] + v[1]) / 2);
    } else if (_pointers.length == 1 && isZoomed()) {
      // 已放大 + 单指：只记录起点，**不 accept**（见 _kPanSlop 的说明）
      _lastSingle = event.localPosition;
      _panning = false;
    }
    // 未放大 + 单指：故意不 resolve，把纵向翻页让给 PageView
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent && _pointers.containsKey(event.pointer)) {
      _pointers[event.pointer] = event.localPosition;
      if (_pointers.length >= 2 && _pinching) {
        final v = _pointers.values.toList();
        final span = (v[0] - v[1]).distance;
        final focal = (v[0] + v[1]) / 2;
        onPinchUpdate(_initialSpan > 0 ? span / _initialSpan : 1.0, focal);
      } else if (_pointers.length == 1 && isZoomed() && !_pinching) {
        final delta = event.localPosition - _lastSingle;
        if (!_panning) {
          // 没过 slop 前什么都不做：这可能是一次双击的第二下，
          // 抢竞技场会让 DoubleTap 失效。
          if (delta.distance <= _kPanSlop) return;
          _panning = true;
          resolvePointer(event.pointer, GestureDisposition.accepted);
        }
        _lastSingle = event.localPosition;
        onPanUpdate(delta);
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pointers.remove(event.pointer);
      if (_pointers.isEmpty) {
        if (_pinching) {
          _pinching = false;
          onPinchEnd();
        }
        _panning = false;
        stopTrackingPointer(event.pointer);
      }
    }
  }

  @override
  void acceptGesture(int pointer) {
    // 竞技场判我们赢：放大态下的单指平移就此生效
    if (!_pinching) _panning = true;
  }

  /// 🔥 被别的 recognizer（PageView 翻页 / 外层侧滑）拒绝时必须清理。
  ///
  /// 之前这里是空实现，导致被拒绝的指针**残留在 `_pointers` 里**：
  /// 用户滑动翻页时单指被 PageView 赢走 → 该指针一直留在表中 →
  /// 之后在新页面双指，第一根手指落下就让 `_pointers.length == 2`，
  /// 于是立即误触发 pinch，且 `_initialSpan` 是基于**陈旧位置**算出来的，
  /// scale 恒趋近 0 —— 表现就是「上下滑过一张之后，双指放大再也用不了」。
  ///
  /// `ScaleGestureRecognizer` 也是这么做的（见 scale.dart 的 rejectGesture）。
  @override
  void rejectGesture(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.isEmpty) {
      _pinching = false;
      _panning = false;
    }
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'pinch';
}
