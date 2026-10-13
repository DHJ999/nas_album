/// 本地偏好设置：登录表单记忆、协议同意状态、同步删除开关。
///
/// 与 [AppState] 的会话持久化分开管理——这里是「用户设置」，
/// 会话是「凭据 + token」，两者生命周期不同（退出登录不该清掉协议同意）。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// 登录表单快照
///
/// [port] 默认**留空**：同一台 NAS 上 HTTP 与 HTTPS 的端口分别配置，
/// App 不替用户假定端口（2026-10-09 用户明确要求），首次由用户填写。
class LoginForm {
  final String host;
  final String port;
  final String user;
  final String password;
  final bool useTls;
  final bool rememberPassword;

  /// 是否信任自签名证书（NAS 的 HTTPS 默认用自签证书，必须放行）
  final bool trustCert;

  const LoginForm({
    this.host = '',
    this.port = '',
    this.user = '',
    this.password = '',
    this.useTls = false,
    this.rememberPassword = false,
    this.trustCert = true,
  });
}

class AppPrefs {
  static SharedPreferences? _sp;

  static Future<SharedPreferences> _get() async =>
      _sp ??= await SharedPreferences.getInstance();

  // ───────────── key ─────────────
  static const _kTerms = 'fnos_terms_accepted_v1';
  static const _kRemember = 'fnos_remember_pwd_v1';
  static const _kHost = 'fnos_form_host_v1';
  static const _kPort = 'fnos_form_port_v1';
  static const _kTls = 'fnos_form_tls_v1';
  static const _kUser = 'fnos_form_user_v1';
  static const _kPwd = 'fnos_form_pwd_v1';
  static const _kSyncDelete = 'fnos_sync_delete_local_v1';
  static const _kAccessCode = 'fnos_form_access_code_v1';
  static const _kAddrHistory = 'fnos_addr_history_v1';
  static const _kAutoPlayVideo = 'fnos_autoplay_video_v1';
  static const _kAutoPlayAnim = 'fnos_autoplay_anim_v1';
  static const _kViewMode = 'fnos_gallery_view_mode_v1';
  static const _kTrustCert = 'fnos_trust_self_signed_cert_v1';
  static const _kDownloadPath = 'fnos_download_relative_path_v1';

  // ───────────── 协议同意 ─────────────

  static Future<bool> termsAccepted() async =>
      (await _get()).getBool(_kTerms) ?? false;

  static Future<void> setTermsAccepted(bool v) async =>
      (await _get()).setBool(_kTerms, v);

  // ───────────── 登录表单 ─────────────

  static Future<LoginForm> loadLoginForm() async {
    final sp = await _get();
    return LoginForm(
      host: sp.getString(_kHost) ?? '',
      port: sp.getString(_kPort) ?? '',
      user: sp.getString(_kUser) ?? '',
      password: sp.getString(_kPwd) ?? '',
      useTls: sp.getBool(_kTls) ?? false,
      rememberPassword: sp.getBool(_kRemember) ?? false,
      trustCert: sp.getBool(_kTrustCert) ?? true,
    );
  }

  /// 记住密码关闭时也要写入（会清掉旧密码），避免上一次的密码残留。
  static Future<void> saveLoginForm({
    required String host,
    required String port,
    required String user,
    required String password,
    required bool useTls,
    required bool rememberPassword,
    required bool trustCert,
  }) async {
    final sp = await _get();
    await sp.setString(_kHost, host);
    await sp.setString(_kPort, port);
    await sp.setString(_kUser, user);
    await sp.setBool(_kTls, useTls);
    await sp.setBool(_kRemember, rememberPassword);
    await sp.setBool(_kTrustCert, trustCert);
    await sp.setString(_kPwd, rememberPassword ? password : '');
  }

  /// 访问码单独存：登录成功一次后就记住，下次不再弹窗。
  static Future<String> accessCode() async =>
      (await _get()).getString(_kAccessCode) ?? '';

  static Future<void> setAccessCode(String v) async =>
      (await _get()).setString(_kAccessCode, v);

  // ───────────── 地址历史（登录页 ↺ 图标） ─────────────

  static Future<List<String>> addressHistory() async =>
      (await _get()).getStringList(_kAddrHistory) ?? const <String>[];

  /// 最近用过的地址排前面，去重，最多留 8 条。
  static Future<void> pushAddress(String host) async {
    final h = host.trim();
    if (h.isEmpty) return;
    final sp = await _get();
    final list = (sp.getStringList(_kAddrHistory) ?? const <String>[]).toList();
    list.removeWhere((e) => e.toLowerCase() == h.toLowerCase());
    list.insert(0, h);
    if (list.length > 8) list.removeRange(8, list.length);
    await sp.setStringList(_kAddrHistory, list);
  }

  static Future<void> removeAddress(String host) async {
    final sp = await _get();
    final list = (sp.getStringList(_kAddrHistory) ?? const <String>[]).toList();
    list.removeWhere((e) => e == host);
    await sp.setStringList(_kAddrHistory, list);
  }

  // ───────────── 删除时是否同步删除本机副本 ─────────────

  static Future<bool> syncDeleteLocal() async =>
      (await _get()).getBool(_kSyncDelete) ?? false;

  static Future<void> setSyncDeleteLocal(bool v) async =>
      (await _get()).setBool(_kSyncDelete, v);

  // ───────────── 播放偏好 ─────────────

  /// 大图查看时，滑到视频是否自动开始播放（默认关：省流量、也避免误触）
  static Future<bool> autoPlayVideo() async =>
      (await _get()).getBool(_kAutoPlayVideo) ?? false;

  static Future<void> setAutoPlayVideo(bool v) async =>
      (await _get()).setBool(_kAutoPlayVideo, v);

  /// 打开实况照片 / 动图时是否自动播放一遍（默认开）
  static Future<bool> autoPlayAnim() async =>
      (await _get()).getBool(_kAutoPlayAnim) ?? true;

  static Future<void> setAutoPlayAnim(bool v) async =>
      (await _get()).setBool(_kAutoPlayAnim, v);

  // ───────────── 图库显示样式 ─────────────

  /// `timeline` = 时间轴显示（按天分组）；`fill` = 铺满显示（不分组、零间距）
  static Future<GalleryViewMode> galleryViewMode() async {
    final v = (await _get()).getString(_kViewMode);
    return v == 'fill' ? GalleryViewMode.fill : GalleryViewMode.timeline;
  }

  static Future<void> setGalleryViewMode(GalleryViewMode m) async =>
      (await _get()).setString(_kViewMode, m == GalleryViewMode.fill ? 'fill' : 'timeline');

  // ───────────── 批量下载保存到系统相册的目录 ─────────────

  /// 默认保存到系统相册 DCIM 下的「NAS相册下载」文件夹。
  /// 这是 MediaStore 的 RELATIVE_PATH（Android 10+ 生效），
  /// 形如 `DCIM/NAS相册下载`。
  static const defaultDownloadRelativePath = 'DCIM/NAS相册下载';

  static Future<String> downloadRelativePath() async =>
      (await _get()).getString(_kDownloadPath) ?? defaultDownloadRelativePath;

  static Future<void> setDownloadRelativePath(String v) async =>
      (await _get()).setString(_kDownloadPath, v);

  static Future<void> clearAll() async {
    final sp = await _get();
    for (final k in [
      _kTerms, _kRemember, _kHost, _kPort, _kTls, _kUser, _kPwd,
      _kSyncDelete, _kAccessCode, _kAddrHistory,
      _kAutoPlayVideo, _kAutoPlayAnim, _kViewMode, _kTrustCert,
      _kDownloadPath,
    ]) {
      await sp.remove(k);
    }
  }
}

/// 图库显示样式
enum GalleryViewMode {
  /// 时间轴：按天分组，带日期小标题
  timeline,

  /// 铺满：不分组、图片铺满整屏宽度
  fill,
}
