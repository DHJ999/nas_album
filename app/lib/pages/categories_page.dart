import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/error_text.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../widgets/square_thumb_tile.dart';
import 'people_page.dart';
import 'places_page.dart';
import 'viewer_page.dart';

/// 分类：人物 / 地点 / 视频 / 图片 四个**同级**分类。
///
/// 交互：顶部 TabBar 点击切换，或**左右滑动**切换（TabBarView）。
/// 四个分类始终并存，任一时刻只显示一个，但 TabBar 始终可见 ——
/// 之前是「选了子项就把切换条收起来」，导致切到地点后看不到其它分类，
/// 用户以为内容消失了。
class CategoriesPage extends StatelessWidget {
  const CategoriesPage({super.key});

  static const _tabs = ['人物', '地点', '视频', '图片'];

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    return DefaultTabController(
      length: _tabs.length,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.white,
          foregroundColor: FnosColors.textMain,
          elevation: 0,
          scrolledUnderElevation: 0,
          automaticallyImplyLeading: false,
          titleSpacing: 16,
          title: const Text('分类',
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: FnosColors.textMain)),
          bottom: TabBar(
            // 窄屏 + 系统字体放大时四个 Tab 会等分不下（RenderFlex overflowed），
            // 改成可滚动就不会挤爆。
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: const Color(0xFF2B7FFF),
            unselectedLabelColor: FnosColors.textSub,
            indicatorColor: const Color(0xFF2B7FFF),
            indicatorSize: TabBarIndicatorSize.label,
            dividerColor: Colors.transparent,
            // 横屏时顶栏整体高度有限，Tab 字体与内边距同步收窄，
            // 否则 TabBar 会占掉小半屏（用户反馈「横屏 tab 栏太大了」）。
            labelStyle: TextStyle(
                fontSize: isLandscape ? 12 : 14,
                fontWeight: FontWeight.w600),
            unselectedLabelStyle: TextStyle(
                fontSize: isLandscape ? 12 : 14,
                fontWeight: FontWeight.w500),
            labelPadding:
                EdgeInsets.symmetric(horizontal: isLandscape ? 2 : 8),
            tabs: [for (final t in _tabs) Tab(text: t)],
          ),
        ),
        body: const TabBarView(
          children: [
            PeoplePage(embedded: true),
            PlacesPage(embedded: true),
            MediaListPage(filter: MediaFilter.video, embedded: true),
            MediaListPage(filter: MediaFilter.photo, embedded: true),
          ],
        ),
      ),
    );
  }
}

/// 视频 / 图片 的媒体列表（客户端过滤）。
///
/// ⚠️ 服务端 `gallery/getList?category=` **实测无效**（恒返回全量，
/// 见本地 API 逆向报告 C.3），所以拉全量后在本地按 [PhotoItem.category] 筛。
class MediaListPage extends StatefulWidget {
  final MediaFilter filter;

  /// 嵌在别的页面里时用 true：不自带 Scaffold / 顶栏。
  final bool embedded;

  const MediaListPage({
    super.key,
    required this.filter,
    this.embedded = false,
  });

  @override
  State<MediaListPage> createState() => _MediaListPageState();
}

class _MediaListPageState extends State<MediaListPage>
    with AutomaticKeepAliveClientMixin {
  final _scroll = ScrollController();
  List<PhotoItem> _all = const [];
  List<PhotoItem> _shown = const [];
  // ⚠️ 初始值必须是 false：_loadMore() 第一行是 `if (_loading) return`，
  // 初始为 true 会导致首次调用被跳过、请求永远不发，于是永远转圈
  // （photo_grid_page 也是 false，这里之前写错了）。
  bool _loading = false;
  String? _err;
  int _offset = 0;
  bool _hasMore = true;
  static const _pageSize = 200;

  /// 加载代际：下拉刷新会自增，用于作废在飞的分页请求。
  /// 没有它时，刷新时的旧响应会和刷新后的新响应一起 append，出现重复照片。
  int _gen = 0;

  /// 上一次触发分页的时间（节流用）
  DateTime _lastPagingAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 大图页可能删掉了条目（它直接改的就是本页传进去的 `_shown`）。
  ///
  /// 把删除结果反投回 `_all`，并让分页偏移与当前长度一致 ——
  /// 否则服务端列表已少一条、沿用旧 offset 会正好跳掉一张。
  void _onViewerChanged() {
    if (!mounted) return;
    setState(() {
      final alive = _shown.map((e) => e.id).toSet();
      _all = _all.where((e) => alive.contains(e.id)).toList();
      _offset = _all.length;
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // 节流：以前是纯端口式判据（pixels > max - 800），一页内容不足一屏时
    // maxScrollExtent≈0 恒成立，于是每一帧都发分页请求。改用 extentAfter
    // 表达「离底部还有多远」，再加 300ms 节流兜住长屏/高列数的情况。
    if (_scroll.position.extentAfter < 400) _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    // 节流：真机高刷 + 高列数时滚动回调非常密集
    final now = DateTime.now();
    if (now.difference(_lastPagingAt) < const Duration(milliseconds: 300)) {
      return;
    }
    _lastPagingAt = now;
    final gen = _gen;
    setState(() => _loading = true);
    try {
      final c = AppState.I.client;
      if (c == null) throw StateError('尚未连接到 NAS');
      final r = await c.getPhotos(limit: _pageSize, offset: _offset);
      // 请求期间发生过下拉刷新：本次结果已作废，直接丢弃。
      // _loading 归新请求所有，这里不能碰。
      if (!mounted || gen != _gen) return;
      setState(() {
        _all = [..._all, ...r.list];
        _offset += r.list.length;
        _hasMore = r.hasNext && r.list.isNotEmpty;
        _shown = widget.filter.apply(_all);
        _loading = false;
        _err = null;
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _err = friendlyError(e);
        _loading = false;
        _hasMore = false;
      });
    }
  }

  Future<void> _refresh() async {
    _gen++; // 作废在飞的分页请求
    setState(() {
      _all = const [];
      _shown = const [];
      _offset = 0;
      _hasMore = true;
      _err = null;
      _loading = false; // 在飞结果会被丢弃，放开让下面的 _loadMore 接手
    });
    await _loadMore();
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

  /// 网格页脚：加载中 / 失败重试 / 仍在扫描全库。
  Widget _footer() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.4))
              : _err != null
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _retryLoad,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 4),
                        child: Text('加载失败，点按重试',
                            style: TextStyle(
                                fontSize: 12.5,
                                color: Theme.of(context).colorScheme.error)),
                      ),
                    )
                  : Text('继续上滑加载更多（已扫描 ${_all.length} 项）',
                      style: const TextStyle(
                          fontSize: 12.5, color: FnosColors.textSub)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final body = RefreshIndicator(
      onRefresh: _refresh,
      child: _err != null && _all.isEmpty
          ? ListView(
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
          : _loading && _all.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    SizedBox(height: 160),
                    Center(child: CircularProgressIndicator()),
                  ],
                )
              // 扫描中断（_err != null）时**不能**落进「还没有图片」：
              // 本页要扫完整库才能在本地过滤，中途失败时 _shown 很可能就是空的，
              // 若照旧报「还没有视频」，等于把故障伪装成空数据。
              : _err != null && _shown.isEmpty
                  ? ListView(
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
                                    color:
                                        Theme.of(context).colorScheme.outline),
                                const SizedBox(height: 12),
                                Text('扫描中断：$_err',
                                    textAlign: TextAlign.center),
                                const SizedBox(height: 6),
                                Text('已扫描 ${_all.length} 项，可点按重试',
                                    style: const TextStyle(
                                        fontSize: 12.5,
                                        color: FnosColors.textSub)),
                                const SizedBox(height: 16),
                                FilledButton(
                                    onPressed: _refresh,
                                    child: const Text('重试')),
                              ],
                            ),
                          ),
                        ),
                      ],
                    )
                  : _shown.isEmpty && !_hasMore && !_loading
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            const SizedBox(height: 120),
                            Center(
                              child: Text(
                                  widget.filter == MediaFilter.video
                                      ? '还没有视频'
                                      : '还没有图片',
                                  style: const TextStyle(
                                      color: FnosColors.textSub)),
                            ),
                          ],
                        )
                  : CustomScrollView(
                      controller: _scroll,
                      slivers: [
                        SliverPadding(
                          padding: kCategoryGridPadding,
                          sliver: SliverGrid(
                            gridDelegate: AdaptiveCategoryGrid(context),
                            delegate: SliverChildBuilderDelegate(
                              (context, i) {
                                final p = _shown[i];
                                return SquareThumbTile(
                                  key: ValueKey(p.id),
                                  imagePath: _thumbOf(p),
                                  isVideo: p.isVideo,
                                  isLive: p.isLivePhoto,
                                  onTap: () {
                                    // 兜底：列表可能因删除而变短
                                    if (i >= _shown.length) return;
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => ViewerPage(
                                          items: _shown,
                                          initialIndex: i,
                                          // ViewerPage 会直接改 widget.items（即 _shown），
                                          // 那是本页的**派生列表**，_all 与 _offset 不会跟着变。
                                          // 必须在返回时把删除结果反投到 _all，否则
                                          // 网格仍渲染已删条目、再点即 _shown 越界崩溃。
                                          onChanged: _onViewerChanged,
                                        ),
                                      ),
                                    );
                                  },
                                );
                              },
                              childCount: _shown.length,
                            ),
                          ),
                        ),
                        // 视频/图片分类要先分页扫完整库才能在本地过滤，
                        // 页脚明确告诉用户「还在扫描」而不是让人以为已经到底。
                        if (_hasMore || _err != null)
                          SliverToBoxAdapter(child: _footer()),
                      ],
                    ),
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: FnosColors.textMain,
        elevation: 0,
        title: Text(widget.filter.label,
            style:
                const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: body,
    );
  }

  /// 网格缩略图用最小档（列表里只需要辨识度，不需要清晰度）
  static String _thumbOf(PhotoItem p) => p.thumb.s.isNotEmpty
      ? p.thumb.s
      : (p.thumb.xs.isNotEmpty ? p.thumb.xs : p.thumb.m);
}
