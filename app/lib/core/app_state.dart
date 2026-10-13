/// 全局状态：会话持久化 + 相册数据缓存
library;

import 'dart:async' show unawaited;
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'fnos_client.dart';
import 'prefs.dart';

class AppState extends ChangeNotifier {
  static final AppState I = AppState._();
  AppState._();

  FnosClient? client;
  FnosSession? session;

  bool connecting = false;
  String? error;

  /// 最近一次连接失败的错误码（登录页据此判断是否要弹访问码输入框）
  int? errorCode;

  /// 本机相册权限是否已授予（协议页同意后申请）
  bool photoPermission = false;

  String serverName = '';
  List<TimelineDay> timeline = const [];
  List<Album> albums = const [];
  List<PersonItem> people = const [];
  List<PhotoFolder> folders = const [];

  /// 内存中的登录密码（用于 token 失效后静默重登）。
  /// 未勾选「记住密码」时不会写盘，仅进程内有效。
  String _password = '';
  bool _rememberPwd = false;

  /// 是否放行自签名证书（NAS 的 HTTPS 默认是自签证书）。
  /// 冷启动重建 client 时要沿用上次的选择，否则重登会撞证书错误。
  bool _trustCert = true;

  bool get isLoggedIn => client != null && session != null;

  // ───────────── 持久化 ─────────────

  static const _kSession = 'fnos_session_v1';

  Future<void> loadSaved() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kSession);
    final form = await AppPrefs.loadLoginForm();
    _rememberPwd = form.rememberPassword;
    _trustCert = form.trustCert;
    if (raw == null) return;
    try {
      final s = FnosSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      // 未记住密码时，磁盘上的会话里没有 password，
      // 但表单里可能还留着（用户只是没勾选记住密码）——以文件为准，不跨启动复用。
      _password = s.password;
      session = s;
    } catch (_) {
      session = null;
    }
  }

  Future<void> saveSession(FnosSession s, {bool withPassword = true}) async {
    final sp = await SharedPreferences.getInstance();
    final map = s.toJson();
    if (!withPassword) map.remove('password');
    await sp.setString(_kSession, jsonEncode(map));
  }

  Future<void> logout() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kSession);
    client?.close();
    client = null;
    session = null;
    _password = '';
    serverName = '';
    timeline = const [];
    albums = const [];
    people = const [];
    folders = const [];
    notifyListeners();
  }

  // ───────────── 地址归一化 ─────────────

  /// 把用户输入拆成 `host:port` + 是否 HTTPS。
  ///
  /// ⚠️ **不内置任何端口**（用户明确要求）：
  /// 同一个 NAS 上 HTTP 与 HTTPS 的端口是**分别配置**的，
  /// 由 App 猜一个端口必然连不上。因此端口只从用户输入取，
  /// 取不到就返回 null，让调用方提示用户补输 —— 绝不替用户假定任何默认端口。
  ///
  /// 规则：
  ///  · `192.168.10.2` + 端口 `<port>`     → `192.168.10.2:<port>`
  ///  · `http://192.168.10.2:<port>`       → 地址内已带端口，以地址为准
  ///  · 端口为空且地址不含端口             → `null`
  ///  · **FN ID**（不含点、不是 IP）       → `abc123.fnos.net` + HTTPS
  ///    （FN Connect 域名池 fnos.net / 5ddd.com / trzznas.com；
  ///     该通道本应用不支持，仅做归一化以便给出明确报错）
  static ({String host, bool tls, String display})? resolveAddress({
    required String address,
    required String port,
    required bool tls,
  }) {
    var a = address.trim();
    a = a.replaceFirst(RegExp(r'^[a-zA-Z]+://'), '');
    a = a.replaceAll(RegExp(r'/+$'), '');
    // 去掉可能残留的路径
    final slash = a.indexOf('/');
    if (slash >= 0) a = a.substring(0, slash);

    String? inlinePort;
    final m = RegExp(r'^(.+):(\d+)$').firstMatch(a);
    if (m != null) {
      a = m.group(1)!;
      inlinePort = m.group(2);
    }
    if (a.isEmpty) return null;

    final isIp = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(a);
    final isFnId = !isIp && !a.contains('.') && !a.contains(':');
    var useTls = tls;

    // 端口来源优先级：地址里写的 > 端口输入框。两者都空就不猜。
    var p = inlinePort ?? port.trim();

    if (isFnId) {
      a = '$a.fnos.net';
      useTls = true;
      // ⚠️ 这里**不补任何默认端口**（用户明确要求）：FN 中继通道本应用
      // 不支持，补一个端口只会掩盖「必须自己填端口」这条规则。
      // 端口为空一律返回 null，由调用方提示用户补输。
    }
    if (p.isEmpty) return null;

    return (host: '$a:$p', tls: useTls, display: '$a:$p');
  }

  // ───────────── 登录 ─────────────

  /// [address] 主机名/IP/FN ID（不含端口），[port] 单独输入。
  /// [accessCode] 为空时，如果 NAS 开了门禁会返回 false 并把
  /// [errorCode] 置为 [kErrNeedAccessCode]，由登录页弹窗补输。
  Future<bool> connect({
    required String address,
    required String port,
    required String user,
    required String password,
    required String accessCode,
    required bool useTls,
    required bool rememberPassword,
    bool trustSelfSigned = true,
  }) async {
    connecting = true;
    error = null;
    errorCode = null;
    notifyListeners();
    try {
      final r = resolveAddress(address: address, port: port, tls: useTls);
      if (r == null) {
        throw const FnosException(
            -2, '请填写端口号：同一台 NAS 上 HTTP 与 HTTPS 的端口是分别配置的，请按 NAS 里的实际端口填写。');
      }
      final c = FnosClient(
        host: r.host,
        accessCode: accessCode,
        useTls: r.tls,
        // 自签证书只在 TLS 下才有意义；HTTP 传不传都不影响
        allowBadCertificate: r.tls && trustSelfSigned,
      );
      final s = await c.login(user: user, password: password);
      c.relogin = _autoRelogin;
      client = c;
      session = s;
      _password = password;
      _rememberPwd = rememberPassword;
      _trustCert = trustSelfSigned;
      await saveSession(s, withPassword: rememberPassword);
      await AppPrefs.saveLoginForm(
        host: address,
        port: port,
        user: user,
        password: password,
        useTls: useTls,
        rememberPassword: rememberPassword,
        trustCert: trustSelfSigned,
      );
      if (accessCode.isNotEmpty) await AppPrefs.setAccessCode(accessCode);
      connecting = false;
      notifyListeners();
      unawaited(_loadCore());
      return true;
    } on FnosException catch (e) {
      error = e.message;
      errorCode = e.code;
    } catch (e) {
      error = '连接失败：$e';
    }
    connecting = false;
    notifyListeners();
    return false;
  }

  /// 冷启动时用保存的会话重建 client（HomePage 进入时调用）
  void ensureClient() {
    if (client != null || session == null) return;
    final s = session!;
    final c = FnosClient(
        host: s.host,
        accessCode: s.accessCode,
        useTls: s.useTls,
        allowBadCertificate: s.useTls && _trustCert);
    c.restore(s);
    c.relogin = _autoRelogin;
    client = c;
    if (_password.isNotEmpty) {
      // token 是短时效的：杀进程重启后大概率已过期，直接静默重登换新 token，
      // 避免首屏先撞一次 401（退出清理后台再进报 401 的根因）。
      unawaited(_autoRelogin());
    } else if (s.accessCode.isNotEmpty) {
      // 没存密码也要把门禁 Cookie（os-access-code）拿回来
      unawaited(c.checkGate().catchError((_) => GateResult.passed));
    }
    // 后台预热
    unawaited(c.userInfo().catchError((_) => <String, dynamic>{}));
  }

  /// 用保存的凭据静默重登，刷新 token 并补齐门禁 Cookie。
  /// 供 FnosClient.relogin 回调使用（请求遇 401/4224/65534 时自动触发）。
  ///
  /// 没记住密码时无法续期 —— 直接把会话清掉，让 RootGate 回到登录页
  /// （登录表单已预填，用户只需再输一次密码），避免停在一个报 401 的空壳首页。
  Future<bool> _autoRelogin() async {
    final c = client;
    final s = session;
    if (c == null || s == null) return false;
    if (_password.isEmpty) {
      await logout();
      return false;
    }
    try {
      final ns = await c.login(user: s.userName, password: _password);
      session = ns;
      await saveSession(ns, withPassword: _rememberPwd);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _loadCore() async {
    final c = client;
    if (c == null) return;
    try {
      final info = await c.userInfo();
      serverName = '${info['name'] ?? ''}';
    } catch (_) {}
    notifyListeners();
  }

  // ───────────── 数据加载 ─────────────

  Future<void> loadTimeline() async {
    final c = client;
    if (c == null) return;
    timeline = await c.timeline();
    notifyListeners();
  }

  Future<void> loadAlbums() async {
    final c = client;
    if (c == null) return;
    albums = await c.albums();
    notifyListeners();
  }

  Future<void> loadPeople() async {
    final c = client;
    if (c == null) return;
    people = await c.people();
    notifyListeners();
  }

  Future<void> loadFolders() async {
    final c = client;
    if (c == null) return;
    folders = await c.folders();
    notifyListeners();
  }
}
