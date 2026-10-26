import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/app_state.dart';
import '../core/error_text.dart';
import '../core/media_preloader.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../widgets/fnos_image.dart';
import '../widgets/square_thumb_tile.dart';
import 'viewer_page.dart';

/// 分页加载器：返回本页数据以及是否还有下一页
typedef PhotoPageLoader = Future<({List<PhotoItem> list, bool hasNext})>
    Function(int offset, int limit);

/// 通用三列照片网格页（地点 / 人物 / 相册详情共用）。
///
/// 点击打开全屏看图，在图看里删除后同步移除本页条目（无需重新拉取）。
class PhotoGridPage extends StatefulWidget {
  final String title;

  /// 可变标题（人物页改名后要就地刷新 AppBar）。
  /// 传了就用它的当前值当标题，[title] 退化为初始值。
  final ValueNotifier<String>? titleListenable;

  final PhotoPageLoader loader;
  final String emptyText;

  /// 长按某张照片（人物页用来「设为封面」，不传则长按无响应）
  final void Function(PhotoItem item)? onLongPress;

  /// 追加到 AppBar 右侧的操作按钮
  final List<Widget> actions;

  const PhotoGridPage({
    super.key,
    required this.title,
    required this.loader,
    this.titleListenable,
    this.emptyText = '这里还没有内容',
    this.onLongPress,
    this.actions = const [],
  });

  @override
  State<PhotoGridPage> createState() => _PhotoGridPageState();
}

class _PhotoGridPageState extends State<PhotoGridPage> {
  final _scroll = ScrollController();
  final List<PhotoItem> _photos = [];
  bool _loading = false;
  bool _hasMore = true;
  String? _err;
  int _offset = 0;
  static const _pageSize = 200;

  /// 加载代际：下拉刷新会自增，用于作废在飞的分页请求。
  int _gen = 0;

  /// 触底节流（与图库页保持一致）：滚动监听每帧都触发，不加节流会在贴底时
  /// 一个请求接一个地发。
  DateTime _lastScrollTrigger = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.hasClients &&
          _scroll.position.pixels > _scroll.position.maxScrollExtent - 800) {
        final now = DateTime.now();
        if (now.difference(_lastScrollTrigger) <
            const Duration(milliseconds: 300)) {
          return;
        }
        _lastScrollTrigger = now;
        _loadMore();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 预加载窗口。网格里是缩略图，体积小、并发可以稍多，
  /// 向前 8 / 向后保留 3 —— 向前多备一点，因为网格滑动更连续。
  static const PreloadWindow _gridWindow = PreloadWindow(ahead: 8, behind: 3);

  /// 可见区首项下标（由 itemBuilder 记账），预加载围绕它计算。
  int _firstVisible = 0;
  int _lastBuilt = 0;

  /// 按当前可见范围排缩略图预加载。
  ///
  /// GridView 的 cacheExtent 只有 200px（≈1 行），快速滑动时新行必然冷启动；
  /// 这里显式向前多拉 8 张。图片与视频分开计数：网格里只预热图片，
  /// 视频流一律不碰（那是大文件 + 独占连接，在网格阶段毫无收益）。
  void _preloadAround(int first, int last) {
    if (!mounted || _photos.isEmpty) return;
    final photos = _photos;
    final start = (first - _gridWindow.behind).clamp(0, photos.length - 1);
    final end = (last + _gridWindow.ahead).clamp(0, photos.length - 1);

    final images = <String>[];
    final keep = <String>{};
    for (int i = start; i <= end; i++) {
      final u = _thumbOf(photos[i]);
      if (u.isEmpty) continue;
      images.add(u);
      keep.add(u);
    }
    MediaPreloader.I.apply(PreloadPlan(
        images: images,
        videos: const [],
        keepImages: keep,
        evictVideos: const []));
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    if (AppState.I.client == null) {
      if (!mounted) return;
      setState(() => _err = '尚未连接到 NAS，请重新登录');
      return;
    }
    final gen = _gen;
    setState(() => _loading = true);
    try {
      final r = await widget.loader(_offset, _pageSize);
      // 请求期间发生过下拉刷新：本次结果已作废，直接丢弃
      // （_loading 归新请求所有，这里不能碰）。
      if (!mounted || gen != _gen) return;
      setState(() {
        _photos.addAll(r.list);
        _offset += r.list.length;
        _hasMore = r.hasNext && r.list.isNotEmpty;
        _loading = false;
        _err = null;
      });
      // 新一页进来：立刻为「从旧末尾往后的新尾部」排预热
      _preloadAround(_firstVisible, _photos.length - 1);
    } catch (e) {
      if (!mounted || gen != _gen) return;
      // 不停在"已经到底了"：以前这里把 _hasMore 置 false 且 _err 只在列表
      // 为空时渲染，翻页失败会被伪装成"相册只有这些内容"，用户既看不到
      // 失败也无法再加载。
      setState(() {
        _err = friendlyError(e);
        _loading = false;
        _hasMore = false;
      });
    }
  }

  /// 页脚「加载失败，点按重试」入口。
  void _retryLoad() {
    if (_loading) return;
    setState(() {
      _hasMore = true;
      _err = null;
    });
    _loadMore();
  }

  Future<void> _refresh() async {
    _gen++; // 作废在飞请求
    setState(() {
      _photos.clear();
      _offset = 0;
      _hasMore = true;
      _err = null;
      _loading = false; // 在飞结果会被丢弃，放开让下面的 _loadMore 接手
      _firstVisible = 0;
      _lastBuilt = 0;
    });
    MediaPreloader.I.resetAll();
    await _loadMore();
  }

  /// 从大图页返回：那边可能删掉了条目（直接改的就是本页的 _photos）。
  /// 分页偏移必须收敛到当前长度，否则服务端列表已少一条、沿用旧 offset
  /// 会正好跳掉一张照片。
  void _onViewerChanged() {
    if (!mounted) return;
    setState(() => _offset = _photos.length);
  }

  // ─────────────────── 从大图页返回后定位 ───────────────────

  /// 大图页里翻到的最后一张。只做记录、**不 setState** ——
  /// 大图页盖在上面时重建整个网格纯属浪费（快速连翻会明显掉帧）。
  int? _lastSeenIndex;

  /// 正在被定位的那一张：临时给它挂上 [_revealKey]，便于下一帧量真实位置
  int? _revealTarget;
  final GlobalKey _revealKey = GlobalKey();

  Future<void> _openViewer(int index) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ViewerPage(
        items: _photos,
        initialIndex: index,
        onChanged: _onViewerChanged,
        onIndexChanged: (i) => _lastSeenIndex = i,
      ),
    ));
    if (!mounted) return;
    final target = _lastSeenIndex;
    _lastSeenIndex = null;
    // 只是打开又退出（没翻过页）就什么都不做，避免网格莫名跳动
    if (target == null || target == index) return;
    await _revealIndex(target);
  }

  /// 把网格滚到第 [index] 张。
  ///
  /// 两步：先用布局常量估算偏移跳过去，再在下一帧用 Flutter 自己的
  /// `getOffsetToReveal` 做一次精确校正。
  Future<void> _revealIndex(int index) async {
    if (!mounted || !_scroll.hasClients) return;
    if (index < 0 || index >= _photos.length) return;

    setState(() => _revealTarget = index);
    _scroll.jumpTo(_estimateOffsetFor(index)
        .clamp(0.0, _scroll.position.maxScrollExtent));

    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_scroll.hasClients) return;
    final box = _revealKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.attached) {
      final viewport = RenderAbstractViewport.maybeOf(box);
      if (viewport != null) {
        final exact = viewport
            .getOffsetToReveal(box, 0.05)
            .offset
            .clamp(0.0, _scroll.position.maxScrollExtent);
        if ((exact - _scroll.offset).abs() > 0.5) _scroll.jumpTo(exact);
      }
    }
    if (mounted) setState(() => _revealTarget = null);
  }

  /// 用布局常量估算第 [index] 张缩略图所在的滚动偏移。
  double _estimateOffsetFor(int index) {
    // GridView: padding 3、3 列、主轴/交叉轴间距 3
    final width = MediaQuery.of(context).size.width;
    final side = (width - 3 * 2 - 3 * 2) / 3;
    return 3.0 + (index ~/ 3) * (side + 3);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: widget.titleListenable == null
            ? Text(widget.title)
            : ValueListenableBuilder<String>(
                valueListenable: widget.titleListenable!,
                builder: (context, v, _) => Text(v),
              ),
        actions: widget.actions,
      ),
      // RefreshIndicator 必须包住全部状态：以前只包了"有数据"分支，于是首屏
      // 失败后只能点按钮，而空态连按钮都没有 —— 用户按平台习惯下拉毫无反应。
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _err != null && _photos.isEmpty
            ? ListView(
                // 内容不足一屏时 ListView 默认不接受拖动，RefreshIndicator
                // 就拉不动了 —— 恰好在最需要重试的两个状态下失效。
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  const SizedBox(height: 120),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.cloud_off_outlined,
                              size: 44,
                              color: Theme.of(context).colorScheme.outline),
                          const SizedBox(height: 12),
                          Text(_err!, textAlign: TextAlign.center),
                          const SizedBox(height: 16),
                          FilledButton(
                              onPressed: _refresh, child: const Text('重试')),
                        ],
                      ),
                    ),
                  ),
                ],
              )
            : _photos.isEmpty && _loading
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 160),
                      Center(child: CircularProgressIndicator()),
                    ],
                  )
                : _photos.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          const SizedBox(height: 120),
                          Center(
                            child: Text(widget.emptyText,
                                style: const TextStyle(
                                    color: FnosColors.textSub, fontSize: 14)),
                          ),
                        ],
                      )
                    : GridView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(3),
                        gridDelegate: AdaptiveCategoryGrid(context),
                        itemCount: _photos.length + 1,
                        itemBuilder: (context, i) {
                          if (i == _photos.length) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 18),
                              child: Center(
                                child: _loading
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2.4))
                                    // 翻页失败要能被看见、能被重试，而不是
                                    // 伪装成「已经到底了」。
                                    : _err != null
                                        ? GestureDetector(
                                            behavior: HitTestBehavior.opaque,
                                            onTap: _retryLoad,
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 16,
                                                      vertical: 4),
                                              child: Text('加载失败，点按重试',
                                                  style: TextStyle(
                                                      fontSize: 12.5,
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .error)),
                                            ),
                                          )
                                        : Text(
                                            _hasMore ? '上拉加载更多' : '已经到底了',
                                            style: const TextStyle(
                                                fontSize: 12.5,
                                                color: FnosColors.textSub)),
                              ),
                            );
                          }
                          final p = _photos[i];
                          // 可见范围记账：每构建到更靠后的一项就顺手
                          // 往前多预热几张（不等到滑动结束，快速滑动时
                          // 下一行的字节往往已经在缓存里）。
                          if (i > _lastBuilt) {
                            _lastBuilt = i;
                            if (i - _firstVisible >= 6) {
                              _firstVisible = i;
                              _preloadAround(_firstVisible, i);
                            }
                          } else if (i < _firstVisible) {
                            _firstVisible = i;
                            _preloadAround(i, _lastBuilt);
                          }
                          return GestureDetector(
                            key: i == _revealTarget ? _revealKey : null,
                            onLongPress: widget.onLongPress == null
                                ? null
                                : () => widget.onLongPress!(p),
                            onTap: () => _openViewer(i),
                            child: Stack(fit: StackFit.expand, children: [
                              FnosImage(path: _thumbOf(p)),
                              if (p.isVideo)
                                const Positioned(
                                  right: 5,
                                  bottom: 5,
                                  child: Icon(Icons.play_circle_fill,
                                      color: Colors.white,
                                      size: 20,
                                      shadows: [
                                        Shadow(
                                            blurRadius: 4,
                                            color: Colors.black54)
                                      ]),
                                ),
                              if (p.isLivePhoto && !p.isVideo)
                                const Positioned(
                                  left: 5,
                                  bottom: 5,
                                  child: Icon(Icons.motion_photos_on,
                                      color: Colors.white,
                                      size: 16,
                                      shadows: [
                                        Shadow(
                                            blurRadius: 4,
                                            color: Colors.black54)
                                      ]),
                                ),
                            ]),
                          );
                        },
                      ),
      ),
    );
  }

  static String _thumbOf(PhotoItem p) => p.thumb.s.isNotEmpty
      ? p.thumb.s
      : (p.thumb.xs.isNotEmpty ? p.thumb.xs : p.thumb.m);
}
