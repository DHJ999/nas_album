/// TLS / WebSocket 握手探测脚本（一次性排查用，不参与 App 构建）
///
/// 目的：验证「信任自签名证书」这条链路在真机上到底能不能通，
/// 并证明它确实是「开 HTTPS 后进不去」的根因。
///
/// 用法：D:\flutter\bin\dart.bat tools\ws_probe.dart 192.168.10.2 60001 [tls|plain]
library;

import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : '192.168.10.2';
  final port = args.length > 1 ? args[1] : '60001';
  final tls = args.length < 3 || args[2] != 'plain';
  final hp = '$host:$port';
  final scheme = tls ? 'https' : 'http';
  final wsScheme = tls ? 'wss' : 'ws';

  stdout.writeln('=== 探测目标 $scheme://$hp ===\n');

  if (tls) {
    // ── A. 默认证书校验：复现用户报错 ──
    await _step('A. 默认证书校验（应复现用户报错）', () async {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final req = await c.getUrl(Uri.parse('$scheme://$hp/access_code_verify'));
      final resp = await req.close();
      await resp.drain<void>();
      c.close(force: true);
      return 'HTTP ${resp.statusCode}（居然通过了，说明证书受信任）';
    });

    // ── B. 放行自签名证书后请求门禁接口 ──
    await _step('B. 放行自签名证书后请求门禁接口', () async {
      final c = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8)
        ..badCertificateCallback = (cert, h, p) => true;
      final req = await c.getUrl(Uri.parse('$scheme://$hp/access_code_verify'));
      req.headers.set('x-access-source', 'app');
      req.headers.set('User-Agent', 'okhttp/4.12.0');
      final resp = await req.close();
      final cookies = resp.cookies.map((e) => '${e.name}=${e.value}').join('; ');
      final code = resp.statusCode;
      await resp.drain<void>();
      c.close(force: true);
      return 'HTTP $code'
          '${cookies.isEmpty ? '' : '  cookies=[$cookies]'}'
          '${code == 401 ? '  ← TLS 层已通，401 只是门禁（NAS 开了访问码）' : ''}';
    });

    // ── C. 同一 API 但不放行证书：应再次复现报错（证明 customClient 生效）──
    await _step('C. WebSocket.connect 不放行证书（应复现报错）', () async {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      try {
        final ws = await WebSocket.connect('$wsScheme://$hp/websocket',
            customClient: c);
        await ws.close();
        return '居然连上了（证书受信任）';
      } finally {
        c.close(force: true);
      }
    });
  }

  // ── D. App 同款实现：WebSocket.connect + customClient（放行证书）──
  await _step('D. App 同款实现 WebSocket.connect(customClient: 放行证书)', () async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    if (tls) c.badCertificateCallback = (cert, h, p) => true;
    try {
      final ws = await WebSocket.connect(
        '$wsScheme://$hp/websocket',
        headers: {'Origin': '$scheme://$hp'},
        customClient: c,
      );
      await ws.close();
      return '✓ 握手成功（101），WebSocket 通道可用';
    } on WebSocketException catch (e) {
      final s = e.message;
      final hint = s.contains('401') || s.contains('upgraded')
          ? '  ← 到达网关但被鉴权拦下（本机 NAS 开了访问码门禁，正式流程会先过 checkGate 带上 Cookie）'
          : '';
      return '△ WebSocketException: $s$hint';
    } finally {
      c.close(force: true);
    }
  });

  stdout.writeln('\n=== 完成 ===');
}

Future<void> _step(String title, Future<String> Function() body) async {
  stdout.writeln('▶ $title');
  try {
    stdout.writeln('   ${await body()}\n');
  } on HandshakeException catch (e) {
    stdout.writeln(
        '   ✗ HandshakeException: ${e.message} ${e.osError?.message ?? ''}\n');
  } on SocketException catch (e) {
    stdout.writeln('   ✗ SocketException: ${e.message}\n');
  } catch (e) {
    stdout.writeln('   ✗ ${e.runtimeType}: $e\n');
  }
}
