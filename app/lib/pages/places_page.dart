import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../widgets/fnos_image.dart';
import 'photo_grid_page.dart';

/// 地点：设备端 GPS 扫描出的城市聚类，点进去看该城市的全部照片/视频。
class PlacesPage extends StatefulWidget {
  const PlacesPage({super.key});
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
    setState(() {
      _loading = true;
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
      if (mounted) {
        setState(() {
          _err = '$e';
          _loading = false;
        });
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
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _err != null
                ? ListView(children: [
                    const SizedBox(height: 140),
                    Center(
                      child: Column(children: [
                        Text('加载失败：$_err', textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton(
                            onPressed: _load, child: const Text('重试')),
                      ]),
                    ),
                  ])
                : _geos.isEmpty
                    ? ListView(children: [
                        const SizedBox(height: 120),
                        Icon(Icons.place_outlined,
                            size: 56,
                            color: Theme.of(context).colorScheme.outline),
                        const SizedBox(height: 12),
                        const Center(
                          child: Text('还没有带地理位置的照片',
                              style: TextStyle(color: FnosColors.textSub)),
                        ),
                      ])
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 14,
                          childAspectRatio: 0.86,
                        ),
                        itemCount: _geos.length,
                        itemBuilder: (context, i) => _GeoCard(
                          geo: _geos[i],
                          onTap: () {
                            final g = _geos[i];
                            Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => PhotoGridPage(
                                title: g.city,
                                emptyText: '该地点暂无照片',
                                loader: (offset, limit) async {
                                  // 搜索结果一次全量返回，本地分页
                                  if (offset > 0) {
                                    return (list: <PhotoItem>[], hasNext: false);
                                  }
                                  final list = await AppState.I.client
                                          ?.searchResults(keywordOf(g.city)) ??
                                      const <PhotoItem>[];
                                  return (list: list, hasNext: false);
                                },
                              ),
                            ));
                          },
                        ),
                      ),
      ),
    );
  }
}

class _GeoCard extends StatelessWidget {
  final GeoCluster geo;
  final VoidCallback onTap;

  const _GeoCard({required this.geo, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(FnosRadius.thumb),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: geo.posterUrl.isEmpty
                ? Container(
                    decoration: BoxDecoration(
                      color: FnosColors.field,
                      borderRadius: BorderRadius.circular(FnosRadius.thumb),
                    ),
                    child: const Center(
                        child: Icon(Icons.place_outlined,
                            color: FnosColors.textSub, size: 30)),
                  )
                : FnosImage(
                    path: geo.posterUrl,
                    radius: BorderRadius.circular(FnosRadius.thumb),
                    fit: BoxFit.cover,
                  ),
          ),
          const SizedBox(height: 8),
          Text(geo.city,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                  color: FnosColors.textMain)),
          const SizedBox(height: 2),
          Text('${geo.itemCount} 项',
              style: const TextStyle(
                  fontSize: 12.5, color: FnosColors.textSub)),
        ],
      ),
    );
  }
}
