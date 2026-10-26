import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/error_text.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../widgets/fnos_image.dart';
import '../widgets/square_thumb_tile.dart';
import 'photo_grid_page.dart';

/// 相册：NAS 上**已有的相册分类**（截屏录屏 / Camera / WeiXin /
/// 行车记录仪 / DJI / 各城市 …）。
///
/// 点进去用 [FnosClient.albumPhotos] 按相册真实过滤 ——
/// 早先用 `gallery/getList` 的 `album_id` 参数，实测服务端会忽略它，
/// 于是每个相册点进去都是全部照片。
class AlbumsPage extends StatefulWidget {
  const AlbumsPage({super.key});
  @override
  State<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends State<AlbumsPage>
    with AutomaticKeepAliveClientMixin {
  List<Album> _albums = const [];
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
      // 已有数据时不再整屏转圈：否则每次下拉刷新都会把整个网格销毁，
      // 滚动位置归零 + 白屏一瞬。只有首次加载（列表为空）才显示整屏 loading。
      if (_albums.isEmpty) _loading = true;
      _err = null;
    });
    try {
      // 不再用 `client?.albums() ?? const []`：会话未就绪时会静默显示
      // 「还没有相簿」，把"没连上"说成"没有数据"。
      final c = AppState.I.client;
      if (c == null) throw StateError('尚未连接到 NAS，请重新登录');
      final list = await c.albums();
      if (mounted) {
        setState(() {
          _albums = list;
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
      // 已有数据时不把整页换成错误页（网格和滚动位置都还在），改用底部提示
      if (_albums.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('刷新失败：$msg')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: FnosLargeTitle(
        text: '相册',
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
            : _err != null && _albums.isEmpty
                ? ListView(
                    // 内容不足一屏时 ListView 默认不接受拖动，
                    // RefreshIndicator 就拉不动了 —— 恰在最需要重试的状态下失效。
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 140),
                      Center(child: Text('加载失败：$_err')),
                    ],
                  )
                : _albums.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          const SizedBox(height: 120),
                          Icon(Icons.photo_album_outlined,
                              size: 56,
                              color: Theme.of(context).colorScheme.outline),
                          const SizedBox(height: 12),
                          const Center(
                            child: Text('还没有相簿',
                                style: TextStyle(color: FnosColors.textSub)),
                          ),
                        ],
                      )
                    : LayoutBuilder(
                        builder: (context, c) {
                          // 卡片高度 = 封面(正方形) + 文字区。
                          // 文字区**必须跟着系统字体缩放走**：以前写死 47px，
                          // 字体 ≥1.15 倍时标题就被裁，2.0 倍时标题压到计数行上。
                          // 改用 mainAxisExtent 精确给高，仍保持**每张卡片尺寸
                          // 完全一致**（不因封面比例或文件名长短而高低不一）。
                          const gap = 12.0, pad = 16.0;
                          // 列数随屏幕宽度自适应（横屏时卡片不再被撑得巨大）
                          final cols = gridColumns(context,
                              portrait: 2, targetCell: 180);
                          final w = (c.maxWidth - pad * 2 - gap * (cols - 1)) /
                              cols;
                          final sc =
                              MediaQuery.textScalerOf(context).scale(1.0);
                          final s = sc < 1 ? 1.0 : sc;
                          // 8(间距) + 20(标题行) + 2 + 17(计数行)，再留 6% 余量
                          final labelH = (8 + 20 * s + 2 + 17 * s) * 1.06;
                          return GridView.builder(
                            padding: const EdgeInsets.fromLTRB(
                                pad, 12, pad, pad + 8),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: cols,
                              mainAxisSpacing: 18,
                              crossAxisSpacing: gap,
                              mainAxisExtent: w + labelH,
                            ),
                            itemCount: _albums.length,
                            itemBuilder: (context, i) =>
                                _AlbumCard(album: _albums[i]),
                          );
                        },
                      ),
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  final Album album;
  const _AlbumCard({required this.album});

  @override
  Widget build(BuildContext context) {
    final poster =
        album.posterUrl.isNotEmpty ? album.posterUrl : album.posterImgUrl;
    final radius = BorderRadius.circular(FnosRadius.thumb);
    // 文字行高跟着系统字体缩放（与 build 里算 mainAxisExtent 的口径保持一致）
    final sc = MediaQuery.textScalerOf(context).scale(1.0);
    final s = sc < 1 ? 1.0 : sc;
    return InkWell(
      borderRadius: radius,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PhotoGridPage(
          title: album.albumName,
          emptyText: '这个相册还是空的',
          // 按相册真实过滤（gallery/getList 的 album_id 会被服务端忽略）
          loader: (offset, limit) async {
            // 不用 `client!`：详情页加载途中会话被清掉（退出登录）时，
            // 强解包会抛 "Null check operator used on a null value"。
            final c = AppState.I.client;
            if (c == null) throw StateError('尚未连接到 NAS，请重新登录');
            return c.albumPhotos(
              albumId: album.albumId,
              limit: limit,
              offset: offset,
            );
          },
        ),
      )),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 固定正方形封面：卡片尺寸统一的根本
          AspectRatio(
            aspectRatio: 1,
            child: poster.isEmpty
                ? Container(
                    decoration: BoxDecoration(
                      color: FnosColors.field,
                      borderRadius: radius,
                    ),
                    child: const Center(
                        child: Icon(Icons.photo_album_outlined,
                            color: FnosColors.textSub)),
                  )
                : FnosImage(path: poster, radius: radius, fit: BoxFit.cover),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 20 * s,
            child: Text(album.albumName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    height: 1.25,
                    color: FnosColors.textMain)),
          ),
          const SizedBox(height: 2),
          SizedBox(
            height: 17 * s,
            child: Text(
                album.videoCount > 0
                    ? '${album.photoCount} 张照片 · ${album.videoCount} 个视频'
                    : '${album.photoCount} 张照片',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12.5, height: 1.2, color: FnosColors.textSub)),
          ),
        ],
      ),
    );
  }
}
