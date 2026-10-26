import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'core/local_media.dart';
import 'core/prefs.dart';
import 'core/theme.dart';
import 'pages/agreement_page.dart';
import 'pages/home_page.dart';
import 'pages/login_page.dart';
import 'widgets/fnos_image.dart' show attachPreloaderImageFetcher;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 预加载器与图片显示必须共用同一份缓存和同一套 in-flight 去重，
  // 否则会出现「预加载下好了，翻过去还在转圈」。注入一次即可。
  attachPreloaderImageFetcher();
  runApp(const NasAlbumApp());
}

class NasAlbumApp extends StatelessWidget {
  const NasAlbumApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NAS相册',
      debugShowCheckedModeBanner: false,
      theme: buildFnosTheme(),
      darkTheme: buildFnosDarkTheme(),
      // 本 App 的视觉是纯浅色的：大量页面硬编码白色卡片与 #1A1A1A 文字，
      // 而深色主题没有配套的 AppBar 背景色 —— 跟随系统深色时，五个 tab 页的
      // 大标题会变成"近黑压近黑"、几乎完全不可见。在补齐深色配色前明确锁浅色。
      themeMode: ThemeMode.light,
      home: const RootGate(),
    );
  }
}

/// 启动流程：合规门禁（用户协议/隐私政策）→ 申请相册权限 → 登录/首页
class RootGate extends StatefulWidget {
  const RootGate({super.key});
  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  bool _checking = true;
  bool _agreed = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final agreed = await AppPrefs.termsAccepted();
    await AppState.I.loadSaved();
    if (!mounted) return;
    setState(() {
      _agreed = agreed;
      _checking = false;
    });
  }

  /// 「同意并继续」是否已在处理中（防双击重入）
  bool _accepting = false;

  /// 同意协议后申请本机相册权限（用于「删除 NAS 照片时同步删除本机副本」）。
  ///
  /// 顺序很关键：**先把门禁放过去，再异步申请权限**。
  ///   · 以前是先 `await requestPermission()` 再置 UI：权限框迟迟不返回时，
  ///     内存里仍是"未同意"（卡在协议页且毫无提示），而磁盘已经写成已同意
  ///     （下次启动直接跳过门禁）—— 两边不一致。
  ///   · 也没有重入锁：双击会并发申请两次权限，第二次通常返回 denied，于是
  ///     用户明明点了「允许」，却弹出「未获得相册权限」。
  ///   · 相册权限只影响"删除时同步删本机副本"，拿不到不该挡着进 App。
  Future<void> _accept() async {
    if (_accepting) return;
    _accepting = true;
    await AppPrefs.setTermsAccepted(true);
    if (!mounted) {
      _accepting = false;
      return;
    }
    setState(() => _agreed = true);
    try {
      final ok = await LocalMediaSync.requestPermission();
      AppState.I.photoPermission = ok;
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('未获得相册权限：「同步删除手机本地副本」将不可用，可在系统设置中开启'),
          duration: Duration(seconds: 5),
        ));
      }
    } catch (_) {
      // 权限申请本身失败同样不该挡住使用
    } finally {
      _accepting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_agreed) {
      return AgreementPage(onAccepted: _accept);
    }
    return ListenableBuilder(
      listenable: AppState.I,
      builder: (context, _) =>
          AppState.I.session == null ? const LoginPage() : const HomePage(),
    );
  }
}
