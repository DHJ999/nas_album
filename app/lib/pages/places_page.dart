import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/error_text.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../widgets/square_thumb_tile.dart';
import 'photo_grid_page.dart';

/// 地点：设备端 GPS 扫描出的城市聚类，点进去看该城市的全部照片/视频。
class PlacesPage extends StatefulWidget {
  /// 嵌在别的页面里时用 true：不自带 Scaffold / 大标题。
  final bool embedded;

  const PlacesPage({super.key, this.embedded = false});
  @override
  State<PlacesPage> createState() => _PlacesPageState();
}

class _PlacesPageState extends State<PlacesPage>
    with AutomaticKeepAliveClientMixin {
  List<GeoCluster> _geos = const [];
  bool _loading = true;
  String? _err;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      // 已有数据时不再整屏转圈：否则每次下拉刷新都会把整个列表销毁，
      // 滚动位置归零 + 白屏一瞬。只有首次加载（列表为空）才显示整屏 loading。
      if (_geos.isEmpty) _loading = true;
      _err = null;
    });
    try {
      final c = AppState.I.client;
      if (c == null) throw StateError('尚未连接到 NAS');
      final list = await c.exploreGeos();
      if (mounted) {
        setState(() {
          _geos = list;
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      final msg = friendlyError(e);
      setState(() {
        _err = msg;
        _loading = false;
      });
      // 已有数据时不把整页换成错误页（列表和滚动位置都还在），改用底部提示
      if (_geos.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('刷新失败：$msg')));
      }
    }
  }

  /// NAS 返回的是「菏泽市」这类全称，检索时去掉行政级别后缀命中率更高
  static String keywordOf(String city) => city
      .replaceAll(RegExp(r'(省|市|自治区|自治州|地区|特别行政区)$'), '')
      .trim();

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final body = RefreshIndicator(
      onRefresh: _load,
      child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _err != null && _geos.isEmpty
                ? ListView(
                    // 内容不足一屏时 ListView 默认不接受拖动，
                    // RefreshIndicator 就拉不动了 —— 恰在最需要重试的状态下失效。
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 140),
                      Center(
                        child: Column(children: [
                          Text('加载失败：$_err', textAlign: TextAlign.center),
                          const SizedBox(height: 16),
                          FilledButton(
                              onPressed: _load, child: const Text('重试')),
                        ]),
                      ),
                    ],
                  )
                : _geos.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          const SizedBox(height: 120),
                          Icon(Icons.place_outlined,
                              size: 56,
                              color: Theme.of(context).colorScheme.outline),
                          const SizedBox(height: 12),
                          const Center(
                            child: Text('还没有带地理位置的照片',
                                style: TextStyle(color: FnosColors.textSub)),
                          ),
                        ],
                      )
                    : GridView.builder(
                      // 与人物 / 视频 / 图片共用同一套栅格与卡片，
                      // 保证四个分类的卡片尺寸完全一致（原来是 2 列 0.86 比例）。
                      padding: kCategoryGridPadding,
                      gridDelegate: AdaptiveCategoryGrid(context),
                      itemCount: _geos.length,
                      itemBuilder: (context, i) {
                        final g = _geos[i];
                        return SquareThumbTile(
                          imagePath: g.posterUrl,
                          title: g.city,
                          placeholderIcon: Icons.place_outlined,
                          onTap: () {
                            Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => PhotoGridPage(
                                title: g.city,
                                emptyText: '该地点暂无照片',
                                loader: (offset, limit) async {
                                  // 搜索结果一次全量返回，本地分页
                                  if (offset > 0) {
                                    return (
                                      list: <PhotoItem>[],
                                      hasNext: false
                                    );
                                  }
                                  final list = await AppState.I.client
                                          ?.searchResults(keywordOf(g.city)) ??
                                      const <PhotoItem>[];
                                  return (list: list, hasNext: false);
                                },
                              ),
                            ));
                          },
                        );
                      },
                    ),
    );
    // 嵌入模式：只给内容，外层负责 Scaffold / 标题
    if (widget.embedded) return body;
    return Scaffold(
      appBar: FnosLargeTitle(
        text: '地点',
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh, color: FnosColors.textMain),
          ),
        ],
      ),
      body: body,
    );
  }
}
