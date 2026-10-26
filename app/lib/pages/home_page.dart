import 'package:flutter/material.dart';

import '../core/app_state.dart';
import 'albums_page.dart';
import 'categories_page.dart';
import 'settings_page.dart';
import 'timeline_page.dart';

/// 底部导航：图库 / 分类 / 相册 / 设置
///
/// 2026-10-21 调整：原为「图库 / 相册 / 人物 / 地点 / 设置」五个 tab。
/// 人物与地点各自内容单薄，各占一个底栏位置太浪费 —— 合成一个「分类」页
/// （内含 人物 / 地点 / 视频 / 图片 四个入口），底栏减到四个。
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // 冷启动时用保存的会话重建 client（含静默重登逻辑）
    AppState.I.ensureClient();
  }

  static const _pages = [
    TimelinePage(),
    CategoriesPage(),
    AlbumsPage(),
    SettingsPage(),
  ];

  /// 懒加载：进入过的 tab 才构建对应页面，避免冷启动时多个页面
  /// 的 initState 同时发请求造成首屏卡顿。构建后由 IndexedStack 保活。
  final Set<int> _built = {0};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          for (var i = 0; i < _pages.length; i++)
            _built.contains(i) ? _pages[i] : const SizedBox(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() {
          _built.add(i);
          _index = i;
        }),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.photo_library_outlined),
              selectedIcon: Icon(Icons.photo_library),
              label: '图库'),
          NavigationDestination(
              icon: Icon(Icons.category_outlined),
              selectedIcon: Icon(Icons.category),
              label: '分类'),
          NavigationDestination(
              icon: Icon(Icons.album_outlined),
              selectedIcon: Icon(Icons.album),
              label: '相册'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '设置'),
        ],
      ),
    );
  }
}
