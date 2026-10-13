import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'core/local_media.dart';
import 'core/prefs.dart';
import 'core/theme.dart';
import 'pages/agreement_page.dart';
import 'pages/home_page.dart';
import 'pages/login_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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

  /// 同意协议后申请本机相册权限（用于「删除 NAS 照片时同步删除本机副本」）
  Future<void> _accept() async {
    await AppPrefs.setTermsAccepted(true);
    final ok = await LocalMediaSync.requestPermission();
    AppState.I.photoPermission = ok;
    if (!mounted) return;
    setState(() => _agreed = true);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('未获得相册权限：「同步删除手机本地副本」将不可用，可在系统设置中开启'),
        duration: Duration(seconds: 5),
      ));
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
