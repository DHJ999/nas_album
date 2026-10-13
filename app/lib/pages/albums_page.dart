import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../widgets/fnos_image.dart';
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
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final list = await AppState.I.client?.albums() ?? const <Album>[];
      if (mounted) {
        setState(() {
          _albums = list;
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
            : _err != null
                ? ListView(children: [
                    const SizedBox(height: 140),
                    Center(child: Text('加载失败：$_err')),
                  ])
                : _albums.isEmpty
                    ? ListView(children: [
                        const SizedBox(height: 120),
                        Icon(Icons.photo_album_outlined,
                            size: 56,
                            color: Theme.of(context).colorScheme.outline),
                        const SizedBox(height: 12),
                        const Center(
                          child: Text('还没有相簿',
                              style: TextStyle(color: FnosColors.textSub)),
                        ),
                      ])
                    : LayoutBuilder(
                        builder: (context, c) {
                          // 卡片高度 = 封面(正方形) + 文字区固定 47
                          // 用动态 aspectRatio 保证**每张卡片尺寸完全一致**，
                          // 不因封面图比例或文件名长短而高低不一。
                          const gap = 12.0, pad = 16.0;
                          final w = (c.maxWidth - pad * 2 - gap) / 2;
                          return GridView.builder(
                            padding: const EdgeInsets.fromLTRB(
                                pad, 12, pad, pad + 8),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 18,
                              crossAxisSpacing: gap,
                              childAspectRatio: w / (w + 47),
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
    return InkWell(
      borderRadius: radius,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PhotoGridPage(
          title: album.albumName,
          emptyText: '这个相册还是空的',
          // 按相册真实过滤（gallery/getList 的 album_id 会被服务端忽略）
          loader: (offset, limit) async =>
              await AppState.I.client!.albumPhotos(
            albumId: album.albumId,
            limit: limit,
            offset: offset,
          ),
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
            height: 20,
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
            height: 17,
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
