import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../widgets/fnos_image.dart';
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

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.hasClients &&
          _scroll.position.pixels > _scroll.position.maxScrollExtent - 800) {
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

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    if (AppState.I.client == null) {
      setState(() => _err = '尚未连接到 NAS');
      return;
    }
    setState(() => _loading = true);
    try {
      final r = await widget.loader(_offset, _pageSize);
      if (!mounted) return;
      setState(() {
        _photos.addAll(r.list);
        _offset += r.list.length;
        _hasMore = r.hasNext && r.list.isNotEmpty;
        _loading = false;
        _err = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _loading = false;
        _hasMore = false;
      });
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _photos.clear();
      _offset = 0;
      _hasMore = true;
      _err = null;
    });
    clearImageCache();
    await _loadMore();
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
      body: _err != null && _photos.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off_outlined,
                        size: 44, color: Theme.of(context).colorScheme.outline),
                    const SizedBox(height: 12),
                    Text(_err!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(
                        onPressed: _refresh, child: const Text('重试')),
                  ],
                ),
              ),
            )
          : _photos.isEmpty && _loading
              ? const Center(child: CircularProgressIndicator())
              : _photos.isEmpty
                  ? Center(
                      child: Text(widget.emptyText,
                          style: const TextStyle(
                              color: FnosColors.textSub, fontSize: 14)))
                  : RefreshIndicator(
                      onRefresh: _refresh,
                      child: GridView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(3),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 3,
                          crossAxisSpacing: 3,
                        ),
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
                                    : Text(
                                        _hasMore ? '上拉加载更多' : '已经到底了',
                                        style: const TextStyle(
                                            fontSize: 12.5,
                                            color: FnosColors.textSub)),
                              ),
                            );
                          }
                          final p = _photos[i];
                          return GestureDetector(
                            onLongPress: widget.onLongPress == null
                                ? null
                                : () => widget.onLongPress!(p),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => ViewerPage(
                                  items: _photos,
                                  initialIndex: i,
                                  onChanged: () {
                                    if (mounted) setState(() {});
                                  },
                                ),
                              ),
                            ),
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
