/// 本地视频代理：解决 ExoPlayer 无法放行自签 HTTPS 证书的问题。
///
/// 背景：
///   · 图片流走 Dart [HttpClient]，可以挂 `badCertificateCallback` 放行自签证书；
///   · `video_player` 在 Android 上用 ExoPlayer，走系统网络栈，不受 Dart 控制，
///     NAS 的自签证书不在 system/user 信任链里，会被直接拒绝
///     （http 正常、https 播放失败的根因）。
///
/// 方案：在 127.0.0.1 起一个明文 HTTP 代理，ExoPlayer 请求代理地址，
/// 代理用已放行证书的 Dart [HttpClient] 转发到 NAS，再把响应（含 Range）回灌。
/// 非 TLS 场景不走代理，行为与之前完全一致。
///
/// 未真机验证：代理转发逻辑已按 HTTP 规范处理 Range / hop-by-hop 头，
/// 但 ExoPlayer 在不同 Android 版本上的行为差异需真机确认。
library;

import 'dart:async';
import 'dart:io';

import 'app_state.dart';
import 'fnos_crypto.dart';

class VideoProxy {
  VideoProxy._();
  static final VideoProxy I = VideoProxy._();

  HttpServer? _server;
  int? _port;

  /// 校验证书的客户端（公网可信证书场景）
  final HttpClient _secure = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..maxConnectionsPerHost = 4;

  /// 放行自签证书的客户端（NAS 场景）
  final HttpClient _insecure = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..maxConnectionsPerHost = 4
    ..badCertificateCallback = (cert, host, port) => true;

  /// 启动代理（幂等），返回监听端口。
  Future<int> ensureStarted() async {
    if (_server != null) return _port!;
    // 端口传 0 由系统分配，避免冲突
    _server = await HttpServer.bind('127.0.0.1', 0);
    _port = _server!.port;
    _server!.listen(_handle);
    return _port!;
  }

  /// 把 NAS 地址改写成代理地址。
  ///
  /// 非 TLS 直接返回原地址（不走代理）；TLS 返回 `http://127.0.0.1:<port><path>`。
  Future<String> rewriteUrl(String path, {Map<String, dynamic>? params}) async {
    final c = AppState.I.client;
    final base = c?.baseUrl ?? '';
    final original = Uri.parse('$base$path').replace(
      queryParameters: params?.map((k, v) => MapEntry(k, '$v')),
    );
    if (c == null || !c.useTls) return original.toString();
    final port = await ensureStarted();
    return Uri.parse('http://127.0.0.1:$port$path')
        .replace(query: original.query)
        .toString();
  }

  /// 供「下载完整文件」使用：无论 http/https 都改写到本地代理。
  ///
  /// 播放用的 [rewriteUrl] 在明文 http 下会直连（ExoPlayer 自己能带请求头）；
  /// 但下载侧用的是普通 dart:io HttpClient，没有现成的鉴权逻辑，统一走代理
  /// 可以让代理包揽 authx 签名、Cookie 注入与自签证书放行，下载方只需
  /// 请求 127.0.0.1 并把响应流写盘即可。
  Future<String> proxyUrlAlways(String path,
      {Map<String, dynamic>? params}) async {
    final c = AppState.I.client;
    final base = c?.baseUrl ?? '';
    final original = Uri.parse('$base$path').replace(
      queryParameters: params?.map((k, v) => MapEntry(k, '$v')),
    );
    final port = await ensureStarted();
    return Uri.parse('http://127.0.0.1:$port$path')
        .replace(query: original.query)
        .toString();
  }

  Future<void> _handle(HttpRequest req) async {
    final c = AppState.I.client;
    if (c == null) {
      req.response.statusCode = HttpStatus.serviceUnavailable;
      await req.response.close();
      return;
    }
    try {
      final path = req.uri.path;
      final target = Uri.parse('${c.baseUrl}$path').replace(query: req.uri.query);
      final client = c.allowBadCertificate ? _insecure : _secure;

      final upReq = await client.openUrl(req.method, target);
      // 转发 ExoPlayer 的请求头（Range / Accept 等），跳过 host（由 target 决定）
      req.headers.forEach((key, values) {
        if (key.toLowerCase() == 'host') return;
        for (final v in values) {
          upReq.headers.add(key, v);
        }
      });
      // 注入鉴权（代理请求本身不带，ExoPlayer 带的会被下面的 set 覆盖）
      upReq.headers.set('x-access-source', 'app');
      upReq.headers.set('User-Agent', 'okhttp/4.12.0');
      upReq.headers.set(
        'authx',
        buildAuthx(
          method: req.method,
          path: path,
          params: req.uri.queryParameters.isEmpty
              ? null
              : Map<String, dynamic>.from(req.uri.queryParameters),
          apiKey: c.apiKey,
        ),
      );
      if (c.cookieHeader.isNotEmpty) {
        upReq.headers.set('Cookie', c.cookieHeader);
      }

      final upResp = await upReq.close();
      req.response.statusCode = upResp.statusCode;
      // 回灌响应头，跳过 hop-by-hop 头（由代理连接自己管理）
      upResp.headers.forEach((key, values) {
        final lk = key.toLowerCase();
        if (lk == 'transfer-encoding' ||
            lk == 'connection' ||
            lk == 'keep-alive' ||
            lk == 'proxy-authenticate' ||
            lk == 'proxy-authorization' ||
            lk == 'te' ||
            lk == 'trailer' ||
            lk == 'upgrade') {
          return;
        }
        for (final v in values) {
          req.response.headers.add(key, v);
        }
      });
      await upResp.pipe(req.response);
    } catch (_) {
      try {
        req.response.statusCode = HttpStatus.badGateway;
        await req.response.close();
      } catch (_) {}
    }
  }
}
