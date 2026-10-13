import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../widgets/fnos_image.dart';
import 'person_detail_page.dart';

/// 人物：直接展示fnOS设备端人脸识别的聚类结果
/// 头像接口实测：GET /p/api/v1/stream/person_poster/{personId} → JPEG
class PeoplePage extends StatefulWidget {
  const PeoplePage({super.key});
  @override
  State<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<PeoplePage>
    with AutomaticKeepAliveClientMixin {
  List<PersonItem> _people = const [];
  bool _loading = true;
  String? _err;
  bool _aiEnabled = false;

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
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final c = AppState.I.client;
      if (c == null) throw StateError('尚未连接到 NAS');
      final list = await c.people();
      bool enabled = false;
      try {
        final st = await c.aiFaceStatus();
        enabled = st['enabled'] == true;
      } catch (_) {}
      if (mounted) {
        setState(() {
          _people = list;
          _aiEnabled = enabled;
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
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _err != null
                ? ListView(children: [
                    const SizedBox(height: 140),
                    Center(child: Text('加载失败：$_err')),
                  ])
                : _people.isEmpty
                    ? ListView(children: [
                        const SizedBox(height: 120),
                        Icon(Icons.face_retouching_natural,
                            size: 56,
                            color: Theme.of(context).colorScheme.outline),
                        const SizedBox(height: 12),
                        Center(
                          child: Text(
                            _aiEnabled
                                ? '人脸识别已开启，但还没有聚类结果'
                                : '设备端人脸识别尚未开启',
                            style: const TextStyle(
                                color: FnosColors.textSub),
                          ),
                        ),
                      ])
                    : _grid(),
      ),
    );
  }

  /// 人物网格。
  ///
  /// ⚠️ **不能再用 `childAspectRatio` 去凑单元格比例** ——
  /// 之前 `Column > Expanded > ClipOval` 的写法让头像高度等于
  /// 「单元格高 − 文字区高」，而单元格宽又和它不等，于是 ClipOval 裁出来的
  /// 是**横向椭圆**。现在改成：先由可用宽度算出单元格宽度，再把
  /// `mainAxisExtent` 定成「正方形边长 + 文字区高度」，头像区用固定
  /// `边长 × 边长` 的 SizedBox —— 任何屏幕宽度、任何字体缩放下都是正圆。
  Widget _grid() {
    const double pad = 20, gap = 18;
    const int cols = 3;

    return LayoutBuilder(
      builder: (context, cst) {
        final scale = MediaQuery.textScalerOf(context).scale(1.0);
        // 文字区（8 间距 + 姓名行 + 2 + 计数行）随系统字体缩放同步放大，
        // 留 6% 余量，避免大字体下正文被裁掉。
        final labelH = (8 + 17 + 2 + 15) * (scale < 1 ? 1.0 : scale) * 1.06;
        final cellW =
            (cst.maxWidth - pad * 2 - gap * (cols - 1)) / cols;

        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(pad, 12, pad, 16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            // 高度 = 正方形头像 + 文字区（不再用比例猜）
            mainAxisExtent: cellW + labelH,
          ),
          itemCount: _people.length,
          itemBuilder: (context, i) => _PersonTile(
            person: _people[i],
            index: i,
            coverVersion: _coverVer[_people[i].id] ?? 0,
            onTap: () => _open(_people[i], i),
          ),
        );
      },
    );
  }
}

class _PersonTile extends StatelessWidget {
  final PersonItem person;
  final int index;
  final int coverVersion;
  final VoidCallback onTap;

  const _PersonTile({
    required this.person,
    required this.index,
    required this.coverVersion,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final name = person.displayName == '未命名'
        ? '人物 ${index + 1}'
        : person.displayName;

    return GestureDetector(
      onTap: onTap,
      child: LayoutBuilder(
        builder: (context, cst) {
          final side = cst.maxWidth.isFinite ? cst.maxWidth : 96.0;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 严格正方形 —— 宽高都用同一个 side，ClipOval 必然是正圆
              SizedBox(
                width: side,
                height: side,
                child: ClipOval(
                  child: FnosImage(
                    // 实测：用 id 而非 faceId
                    path: '/p/api/v1/stream/person_poster/${person.id}',
                    // 换过封面才带版本参数；没换过就完全走原来的请求（更稳）
                    params: coverVersion == 0 ? null : {'v': '$coverVersion'},
                    fit: BoxFit.cover,
                    placeholder: Container(
                      color: FnosColors.field,
                      child: const Icon(Icons.person,
                          size: 34, color: FnosColors.textSub),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // 文字区吃掉剩余高度并裁剪，字体再大也不会撑破网格、不报溢出
              Expanded(
                child: ClipRect(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(name,
                          maxLines: 1,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: FnosColors.textMain)),
                      const SizedBox(height: 2),
                      Text('${person.itemCount} 项',
                          maxLines: 1,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: FnosColors.textSub)),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
