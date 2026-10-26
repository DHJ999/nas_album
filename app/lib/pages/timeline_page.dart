import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/app_state.dart';
import '../core/error_text.dart';
import '../core/media_deleter.dart';
import '../core/media_downloader.dart';
import '../core/media_preloader.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../widgets/delete_confirm.dart';
import '../widgets/fnos_image.dart';
import '../widgets/square_thumb_tile.dart';
import 'viewer_page.dart';

/// 图库：两种显示样式
///   · 时间轴显示：按天分组 + 日期小标题 + 三列网格
///   · 铺满显示：不分组，缩略图零间距铺满整屏宽度
/// 下拉刷新 + 触底加载对两种样式都生效。
///
/// 长按缩略图进入多选模式，可批量下载 / 删除；时间轴样式下日期标题
/// 右侧的勾选按钮可一键选中该天全部内容。
class TimelinePage extends StatefulWidget {
  const TimelinePage({super.key});
  @override
  State<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends State<TimelinePage>
    with AutomaticKeepAliveClientMixin {
  final _scroll = ScrollController();
  final List<PhotoItem> _photos = [];
  bool _loading = false;
  bool _hasMore = true;
  String? _error;
  int _offset = 0;
  GalleryViewMode _mode = GalleryViewMode.timeline;
  static const _pageSize = 120;

  /// 加载代际：下拉刷新会自增，用于作废在飞的分页请求。
  int _gen = 0;

  /// 多选模式开关；[_selected] 存的是 PhotoItem.id
  bool _selectMode = false;
  final Set<int> _selected = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    AppPrefs.galleryViewMode().then((m) {
      if (mounted && m != _mode) setState(() => _mode = m);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  DateTime _lastScrollTrigger = DateTime.fromMillisecondsSinceEpoch(0);

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 900) {
      // 节流：滚动每帧都会触发监听，300ms 内只放行一次
      final now = DateTime.now();
      if (now.difference(_lastScrollTrigger) <
          const Duration(milliseconds: 300)) {
        return;
      }
      _lastScrollTrigger = now;
      _loadMore();
    }
  }

  Future<void> _refresh() async {
    // 以前这里是 `if (_loading) return;` —— 后台恰有分页请求在飞时，下拉刷新
    // 会被整个吞掉（连列表都不清），用户看到的是"下拉了没反应"。
    // 现在改为：作废在飞请求（_gen），立刻按 offset=0 重新加载。
    _gen++;
    setState(() {
      _error = null;
      _offset = 0;
      _hasMore = true;
      _photos.clear();
      // 列表被换掉了，多选状态必须一起清，否则「已选 N 项」与网格里的勾对不上
      _selected.clear();
      _selectMode = false;
      // 在飞请求的结果马上会被丢弃，这里直接放开，让下面的 _loadMore 接手
      _loading = false;
    });
    _invalidateGrouped();
    MediaPreloader.I.resetAll();
    await _loadMore();
  }

  Future<void> _loadMore() async {
    // 加载中（含首屏）一律拦截，否则滚动触底会再发一次 offset=0 请求导致照片重复
    if (_loading || !_hasMore) return;
    final c = AppState.I.client;
    if (c == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '尚未连接到 NAS，请重新登录';
      });
      return;
    }
    final gen = _gen;
    try {
      if (mounted) setState(() => _loading = true);
      final r = await c.getPhotos(limit: _pageSize, offset: _offset);
      // 请求期间发生过下拉刷新：本次结果已作废，直接丢弃。
      // _loading 归新请求所有，这里不能碰。
      if (!mounted || gen != _gen) return;
      setState(() {
        _photos.addAll(r.list);
        _offset += r.list.length;
        _hasMore = r.hasNext && r.list.isNotEmpty;
        _loading = false;
        _error = null;
      });
      _invalidateGrouped();
    } catch (e) {
      if (!mounted || gen != _gen) return;
      // 不再保留 _hasMore=true：否则弱网下每 300ms 就会拿同一个 offset
      // 重试一次必然失败的请求。改为停住，由页脚的「点按重试」显式再来。
      setState(() {
        _loading = false;
        _error = friendlyError(e);
        _hasMore = false;
      });
    }
  }

  /// 页脚「加载失败，点按重试」入口。
  void _retryLoad() {
    if (_loading) return;
    setState(() {
      _hasMore = true;
      _error = null;
    });
    _loadMore();
  }

  Future<void> _pickMode() async {
    final picked = await showModalBottomSheet<GalleryViewMode>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text('显示样式',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            for (final m in GalleryViewMode.values)
              ListTile(
                leading: Icon(
                  m == GalleryViewMode.timeline
                      ? Icons.view_timeline_outlined
                      : Icons.grid_view_rounded,
                  color: _mode == m ? FnosColors.primary : FnosColors.textMain,
                ),
                title: Text(m == GalleryViewMode.timeline ? '时间轴显示' : '铺满显示',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight:
                            _mode == m ? FontWeight.w600 : FontWeight.w400,
                        color: _mode == m
                            ? FnosColors.primary
                            : FnosColors.textMain)),
                subtitle: Text(
                    m == GalleryViewMode.timeline
                        ? '按日期分组，带日期小标题'
                        : '不分组，缩略图铺满整屏宽度',
                    style: const TextStyle(
                        fontSize: 12.5, color: FnosColors.textSub)),
                trailing: _mode == m
                    ? const Icon(Icons.check,
                        color: FnosColors.primary, size: 20)
                    : null,
                onTap: () => Navigator.pop(ctx, m),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || picked == _mode) return;
    setState(() => _mode = picked);
    await AppPrefs.setGalleryViewMode(picked);
  }

  /// 分组结果缓存。
  ///
  /// 以前 [_grouped] 是个 getter，每次 build 都要对全部 _photos 重做一次分组，
  /// 而且每项都会跑一次 parseFnosDate（正则）。上千张照片后，每次滚动触底、
  /// 每次多选勾选都会 O(n) 重算，明显掉帧。这里改为缓存 + 显式失效。
  List<MapEntry<String, List<int>>>? _groupedCache;

  void _invalidateGrouped() => _groupedCache = null;

  /// 把照片按天分组（保持接口返回的倒序）。
  /// 分组里存的是 [_photos] 的全局下标，避免渲染时做 O(n) 查找。
  ///
  /// ⚠️ 下标与位置绑定：任何增删 _photos 的地方都必须先调 [_invalidateGrouped]，
  /// 否则缓存会指到错误的照片上。
  List<MapEntry<String, List<int>>> get _grouped =>
      _groupedCache ??= _buildGrouped();

  List<MapEntry<String, List<int>>> _buildGrouped() {
    final map = <String, List<int>>{};
    final order = <String>[];
    for (var i = 0; i < _photos.length; i++) {
      final d = _photos[i].takenAt;
      final key = d == null ? '未知时间' : '${d.year}年${d.month}月${d.day}日';
      final list = map.putIfAbsent(key, () {
        order.add(key);
        return <int>[];
      });
      list.add(i);
    }
    return order.map((k) => MapEntry(k, map[k]!)).toList();
  }

  /// 从大图页返回时的回调：那边可能删掉了条目（直接改的就是本页的 _photos）。
  ///
  /// 必须 (1) 重算分组，因为下标全部前移；(2) 把分页偏移收敛到当前长度 ——
  /// 服务端列表已经少了一条，沿用旧 offset 会正好跳掉一张照片。
  void _onViewerChanged() {
    _invalidateGrouped();
    if (!mounted) return;
    setState(() => _offset = _photos.length);
  }

  // ─────────────────── 从大图页返回后定位 ───────────────────

  /// 大图页里翻到的最后一张。只做记录、**不 setState** ——
  /// 大图页盖在上面时重建整个照片墙纯属浪费（快速连翻会明显掉帧）。
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
    // 只是打开又退出（没翻过页）就什么都不做，避免照片墙莫名跳动
    if (target == null || target == index) return;
    await _revealIndex(target);
  }

  /// 把照片墙滚到第 [index] 张。
  ///
  /// 两步：先用布局常量估算偏移跳过去，再在下一帧用 Flutter 自己的
  /// `getOffsetToReveal` 做一次精确校正 —— 估算受字体行高 / 内边距影响，
  /// 差几十像素很正常，纯估算会让目标偏出视口。
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

  /// 日期标题那一行的真实高度：用 TextPainter 量，别猜字号行高
  double _dayHeaderHeight() {
    final tp = TextPainter(
      text: const TextSpan(
          text: '0',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return tp.height + 16 + 8; // Padding(16, 16, 16, 8)
  }

  /// 用布局常量估算第 [index] 张缩略图所在的滚动偏移。
  double _estimateOffsetFor(int index) {
    final width = MediaQuery.of(context).size.width;
    if (_mode == GalleryViewMode.fill) {
      // 铺满样式：3 列、零间距、无分组
      final side = width / 3;
      return (index ~/ 3) * side;
    }
    // 时间轴样式：SliverPadding(horizontal: 2) + 3 列 + 主/次轴间距 2
    final side = (width - 4 - 2 * 2) / 3;
    final rowH = side + 2;
    final headerH = _dayHeaderHeight();
    var offset = 0.0;
    for (final g in _grouped) {
      final rows = (g.value.length + 2) ~/ 3;
      if (index >= g.value.first && index <= g.value.last) {
        return offset + headerH + ((index - g.value.first) ~/ 3) * rowH;
      }
      offset += headerH + rows * side + (rows - 1) * 2;
    }
    return offset;
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(s)));
  }

  // ─────────────────── 多选 ───────────────────

  void _enterSelect(int id) => setState(() {
        _selectMode = true;
        _selected
          ..clear()
          ..add(id);
      });

  void _exitSelect() => setState(() {
        _selectMode = false;
        _selected.clear();
      });

  void _toggle(int id) => setState(() {
        if (!_selected.remove(id)) _selected.add(id);
      });

  bool _isDayAllSelected(List<int> idxs) =>
      idxs.isNotEmpty &&
      idxs.every((i) => _selected.contains(_photos[i].id));

  /// 该天已全选则取消，未全选则补齐到全选
  void _toggleDay(List<int> idxs) => setState(() {
        final ids = idxs.map((i) => _photos[i].id).toSet();
        if (ids.every(_selected.contains)) {
          _selected.removeAll(ids);
        } else {
          _selected.addAll(ids);
        }
      });

  bool get _allSelected =>
      _photos.isNotEmpty && _selected.length == _photos.length;

  void _toggleSelectAll() => setState(() {
        if (_allSelected) {
          _selected.clear();
        } else {
          _selected
            ..clear()
            ..addAll(_photos.map((p) => p.id));
        }
      });

  List<PhotoItem> get _selectedItems =>
      _photos.where((p) => _selected.contains(p.id)).toList();

  Future<void> _batchDelete() async {
    final items = _selectedItems;
    if (items.isEmpty) return;
    final choice = await showDeleteConfirmDialog(context, count: items.length);
    if (choice == null || !choice.confirmed) return;
    try {
      await MediaDeleter.delete(items: items, syncLocal: choice.syncLocal);
      if (!mounted) return;
      setState(() {
        _photos.removeWhere((p) => _selected.contains(p.id));
        // 分页偏移以当前列表长度为准，避免触底加载重复或跳项
        _offset = _photos.length;
        _selected.clear();
        _selectMode = false;
      });
      _invalidateGrouped();
      MediaPreloader.I.resetAll();
      if (_photos.isEmpty) _refresh();
    } catch (e) {
      _snack('删除失败：${friendlyError(e)}');
    }
  }

  Future<void> _batchDownload() async {
    final items = _selectedItems;
    if (items.isEmpty) return;

    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final progress = ValueNotifier<int>(0);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: ValueListenableBuilder<int>(
            valueListenable: progress,
            builder: (_, done, child) =>
                _DownloadProgress(done: done, total: items.length),
          ),
        ),
      ),
    );

    DownloadOutcome? outcome;
    String? err;
    try {
      outcome = await MediaDownloader.downloadAll(items,
          onProgress: (d, _) => progress.value = d);
    } catch (e) {
      err = '$e';
    } finally {
      progress.dispose();
    }
    if (!mounted) return;
    if (nav.canPop()) nav.pop(); // 关闭进度对话框

    if (err != null) {
      messenger.showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
    messenger.showSnackBar(
      SnackBar(
        content: Text(outcome!.failed == 0
            ? '已保存 ${outcome.success} 项到相册'
            : '已保存 ${outcome.success} 项，${outcome.failed} 项失败'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return PopScope(
      canPop: !_selectMode,
      onPopInvokedWithResult: (didPop, _) {
        // 多选模式下系统返回键只退出多选，不离开页面
        if (!didPop && _selectMode) _exitSelect();
      },
      child: Scaffold(
        appBar: _selectMode ? _buildSelectAppBar() : _buildNormalAppBar(),
        body: RefreshIndicator(
          onRefresh: _refresh,
          child: _error != null && _photos.isEmpty
              ? ListView(
                  children: [
                    const SizedBox(height: 120),
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            Icon(Icons.cloud_off_outlined,
                                size: 48,
                                color: Theme.of(context).colorScheme.outline),
                            const SizedBox(height: 12),
                            Text(_error!, textAlign: TextAlign.center),
                            const SizedBox(height: 16),
                            FilledButton(onPressed: _refresh, child: const Text('重试')),
                          ],
                        ),
                      ),
                    ),
                  ],
                )
              : _photos.isEmpty && _loading
                  ? const Center(child: CircularProgressIndicator())
                  : CustomScrollView(
                      controller: _scroll,
                      slivers: _mode == GalleryViewMode.fill
                          ? _fillSlivers
                          : _timelineSlivers,
                    ),
        ),
        bottomNavigationBar: _selectMode ? _buildSelectBar() : null,
      ),
    );
  }

  PreferredSizeWidget _buildNormalAppBar() => FnosLargeTitle(
        text: '图库',
        actions: [
          IconButton(
            tooltip: _mode == GalleryViewMode.timeline ? '时间轴显示' : '铺满显示',
            onPressed: _pickMode,
            icon: Icon(
              _mode == GalleryViewMode.timeline
                  ? Icons.view_timeline_outlined
                  : Icons.grid_view_rounded,
              color: FnosColors.textMain,
            ),
          ),
        ],
      );

  PreferredSizeWidget _buildSelectAppBar() => AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '退出选择',
          onPressed: _exitSelect,
        ),
        titleSpacing: 0,
        centerTitle: false,
        title: Text('已选 ${_selected.length} 项'),
        actions: [
          TextButton(
            onPressed: _toggleSelectAll,
            child: Text(_allSelected ? '取消全选' : '全选'),
          ),
        ],
      );

  /// 多选底部操作栏：下载 / 删除。贴在首页底部 tab 导航栏上方。
  /// 不加底部 SafeArea：外层层级的 tab 导航栏已经处理了系统手势条安全区。
  Widget _buildSelectBar() => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(
              top: BorderSide(color: FnosColors.line, width: 0.6)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _selected.isEmpty ? null : _batchDownload,
                icon: const Icon(Icons.download_outlined, size: 20),
                label: const Text('下载'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: FnosColors.primary,
                  side: const BorderSide(color: FnosColors.primary),
                  minimumSize: const Size.fromHeight(42),
                  shape: const StadiumBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: _selected.isEmpty ? null : _batchDelete,
                icon: const Icon(Icons.delete_outline, size: 20),
                label: const Text('删除'),
                style: FilledButton.styleFrom(
                  backgroundColor: FnosColors.danger,
                  minimumSize: const Size.fromHeight(42),
                ),
              ),
            ),
          ],
        ),
      );

  // ── 铺满显示：无分组、无间距，整屏铺满 ──
  List<Widget> get _fillSlivers => [
        if (_photos.isNotEmpty)
          SliverGrid(
            gridDelegate: AdaptiveCategoryGrid(context),
            delegate: SliverChildBuilderDelegate(
              (context, i) => _Thumb(
                key: i == _revealTarget ? _revealKey : null,
                item: _photos[i],
                selectMode: _selectMode,
                selected: _selected.contains(_photos[i].id),
                onLongPress: () => _enterSelect(_photos[i].id),
                onToggle: () => _toggle(_photos[i].id),
                onOpen: () => _openViewer(i),
              ),
              childCount: _photos.length,
            ),
          ),
        _footerSliver,
      ];

  // ── 时间轴显示：按天分组 + 日期小标题 ──
  List<Widget> get _timelineSlivers {
    final groups = _grouped;
    return [
      for (final g in groups) ...[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(g.key,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: FnosColors.textMain)),
                const SizedBox(width: 8),
                Text('${g.value.length} 项',
                    style: const TextStyle(
                        fontSize: 12, color: FnosColors.textSub)),
                // 多选模式下日期行右侧放「全选该天」按钮
                if (_selectMode) ...[
                  const Spacer(),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _toggleDay(g.value),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
                      child: Row(
                        children: [
                          Icon(
                            _isDayAllSelected(g.value)
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            size: 20,
                            color: _isDayAllSelected(g.value)
                                ? FnosColors.primary
                                : FnosColors.textSub,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _isDayAllSelected(g.value) ? '取消' : '全选',
                            style: TextStyle(
                              fontSize: 13,
                              color: _isDayAllSelected(g.value)
                                  ? FnosColors.primary
                                  : FnosColors.textSub,
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
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          sliver: SliverGrid(
            gridDelegate: AdaptiveCategoryGrid(context),
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final gi = g.value[i];
                return _Thumb(
                  key: gi == _revealTarget ? _revealKey : null,
                  item: _photos[gi],
                  selectMode: _selectMode,
                  selected: _selected.contains(_photos[gi].id),
                  onLongPress: () => _enterSelect(_photos[gi].id),
                  onToggle: () => _toggle(_photos[gi].id),
                  onOpen: () => _openViewer(gi),
                );
              },
              childCount: g.value.length,
            ),
          ),
        ),
      ],
      _footerSliver,
    ];
  }

  Widget get _footerSliver => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 28),
          child: Center(
            child: _loading
                ? const SizedBox(
                    width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.4))
                // 分页失败时给出可点按的重试入口。以前失败只写 _error，而错误
                // 界面只在"列表为空"时渲染，于是翻页失败对用户完全不可见，
                // 页脚还一直显示「上拉加载更多」。
                : _error != null && _photos.isNotEmpty
                    ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _retryLoad,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 4),
                          child: Text('加载失败，点按重试',
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error)),
                        ),
                      )
                    : Text(_hasMore ? '上拉加载更多' : '已经到底了',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.outline)),
          ),
        ),
      );
}

/// 批量下载进度对话框内容
class _DownloadProgress extends StatelessWidget {
  final int done;
  final int total;
  const _DownloadProgress({required this.done, required this.total});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.6)),
        const SizedBox(width: 18),
        Text('正在下载 $done / $total',
            style: const TextStyle(fontSize: 15)),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  final PhotoItem item;

  /// 是否处于多选模式
  final bool selectMode;

  /// 当前项是否被选中
  final bool selected;

  /// 长按进入多选
  final VoidCallback onLongPress;

  /// 多选模式下点击切换选中
  final VoidCallback onToggle;

  /// 非多选模式下点击：打开大图页（由父级负责导航，便于回传"最后看到第几张"）
  final VoidCallback onOpen;

  const _Thumb({
    super.key,
    required this.item,
    required this.selectMode,
    required this.selected,
    required this.onLongPress,
    required this.onToggle,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final url = item.thumb.s.isNotEmpty
        ? item.thumb.s
        : (item.thumb.xs.isNotEmpty ? item.thumb.xs : item.thumb.m);
    return GestureDetector(
      // 多选模式下点击只切换勾选；非多选时长按进入多选、点击进大图
      onTap: selectMode ? onToggle : onOpen,
      onLongPress: selectMode ? null : onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (url.isEmpty)
            Container(color: Theme.of(context).colorScheme.surfaceContainerHighest)
          else
            FnosImage(path: url),
          if (item.isVideo)
            const Positioned(
              right: 5, bottom: 5,
              child: Icon(Icons.play_circle_fill,
                  color: Colors.white, size: 20,
                  shadows: [Shadow(blurRadius: 4, color: Colors.black54)]),
            ),
          if (item.isLivePhoto && !item.isVideo)
            const Positioned(
              left: 5, bottom: 5,
              child: Icon(Icons.motion_photos_on,
                  color: Colors.white, size: 16,
                  shadows: [Shadow(blurRadius: 4, color: Colors.black54)]),
            ),
          // 多选模式下右上角勾选标记
          if (selectMode)
            Positioned(
              top: 6,
              right: 6,
              child: _CheckMark(selected: selected),
            ),
        ],
      ),
    );
  }
}

/// 缩略图右上角的圆形勾选标记
class _CheckMark extends StatelessWidget {
  final bool selected;
  const _CheckMark({required this.selected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? FnosColors.primary : Colors.transparent,
        border: Border.all(color: Colors.white, width: 1.8),
        // 未选中时给一圈淡黑阴影，保证在浅色图片上也看得清
        boxShadow: selected
            ? null
            : const [BoxShadow(color: Colors.black38, blurRadius: 2)],
      ),
      child: selected
          ? const Icon(Icons.check, size: 15, color: Colors.white)
          : null,
    );
  }
}
