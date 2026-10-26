import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/error_text.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../widgets/square_thumb_tile.dart';
import 'person_detail_page.dart';

/// 人物：直接展示fnOS设备端人脸识别的聚类结果
/// 头像接口实测：GET /p/api/v1/stream/person_poster/{personId} → JPEG
class PeoplePage extends StatefulWidget {
  /// 嵌在别的页面里时用 true：不自带 Scaffold / 大标题，
  /// 由外层提供外壳（避免嵌套 Scaffold 出现两条顶栏）。
  final bool embedded;

  const PeoplePage({super.key, this.embedded = false});
  @override
  State<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<PeoplePage>
    with AutomaticKeepAliveClientMixin {
  List<PersonItem> _people = const [];
  bool _loading = true;
  String? _err;

  /// 人脸识别状态：三态。
  ///   true  = 已开启；false = 确实没开启；null = 状态查询失败（未知）。
  /// 以前是 bool，`catch (_) {}` 会把"查询失败"与"没开启"混为一谈，
  /// 于是空态一律断言"设备端人脸识别尚未开启"，误导用户去 NAS 后台排查
  /// 一个根本不存在的问题。
  bool? _aiEnabled;

  /// 头像缓存版本号：从人物详情页返回后 +1，用来绕过 [FnosImage] 的
  /// 内存缓存（换过封面后 URL 不变，只能靠缓存键变化强制重拉）。
  final Map<int, int> _coverVer = {};

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
      // 已有数据时不再整屏转圈：否则每次下拉刷新都会把 GridView 整个销毁，
      // 滚动位置归零 + 白屏一瞬。只有首次加载（列表为空）才显示整屏 loading。
      if (_people.isEmpty) _loading = true;
      _err = null;
    });
    try {
      final c = AppState.I.client;
      if (c == null) throw StateError('尚未连接到 NAS');
      final list = await c.people();
      bool? enabled;
      try {
        final st = await c.aiFaceStatus();
        enabled = st['enabled'] == true;
      } catch (_) {
        enabled = null; // 查询失败，状态未知
      }
      if (!mounted) return;
      setState(() {
        _people = list;
        _aiEnabled = enabled;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      final msg = friendlyError(e);
      setState(() {
        _err = msg;
        _loading = false;
      });
      // 已有数据时不把整页换成错误页（列表和滚动位置都还在），改用底部提示
      if (_people.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('刷新失败：$msg')));
      }
    }
  }

  Future<void> _open(PersonItem p, int index) async {
    final name = p.displayName == '未命名' ? '人物 ${index + 1}' : p.displayName;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PersonDetailPage(person: p, displayName: name),
    ));
    if (!mounted) return;
    // 详情页里可能改过姓名或封面 —— 换掉封面图的缓存键，再拉一次列表
    _coverVer[p.id] = (_coverVer[p.id] ?? 0) + 1;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final body = RefreshIndicator(
      onRefresh: _load,
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err != null && _people.isEmpty
              ? ListView(
                  // 内容不足一屏时 ListView 默认不接受拖动，
                  // RefreshIndicator 就拉不动了 —— 恰在最需要重试的状态下失效。
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    const SizedBox(height: 140),
                    Center(child: Text('加载失败：$_err')),
                  ],
                )
              : _people.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 120),
                        Icon(Icons.face_retouching_natural,
                            size: 56,
                            color: Theme.of(context).colorScheme.outline),
                        const SizedBox(height: 12),
                        Center(
                          child: Text(
                            _aiEnabled == true
                                ? '人脸识别已开启，但还没有聚类结果'
                                : _aiEnabled == false
                                    ? '设备端人脸识别尚未开启'
                                    : '未能读取人脸识别状态，请下拉刷新重试',
                            style: const TextStyle(
                                color: FnosColors.textSub),
                          ),
                        ),
                      ],
                    )
                  : _grid(),
    );
    // 嵌入模式：只给内容，外层负责 Scaffold / 标题
    if (widget.embedded) return body;
    return Scaffold(
      appBar: FnosLargeTitle(
        text: '人物',
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

  /// 人物网格。
  ///
  /// 与地点 / 视频 / 图片**共用同一套栅格与卡片**（[SquareThumbTile] +
  /// [CategoryGridDelegate]，3 列正方形），保证四个分类的卡片尺寸完全一致。
  /// 姓名叠在头像底部的渐变蒙层上，不再占用额外高度。
  Widget _grid() {
    return GridView.builder(
      padding: kCategoryGridPadding,
      gridDelegate: AdaptiveCategoryGrid(context),
      itemCount: _people.length,
      itemBuilder: (context, i) {
        final p = _people[i];
        final name = p.displayName == '未命名' ? '人物 ${i + 1}' : p.displayName;
        return SquareThumbTile(
          // 实测：用 id 而非 faceId
          imagePath: '/p/api/v1/stream/person_poster/${p.id}',
          // 换过封面才带版本参数；没换过就完全走原来的请求（更稳）
          params: (_coverVer[p.id] ?? 0) == 0
              ? null
              : {'v': '${_coverVer[p.id]}'},
          title: name,
          placeholderIcon: Icons.person,
          onTap: () => _open(p, i),
        );
      },
    );
  }
}
