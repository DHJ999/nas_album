/// 局域网 NAS 设备扫描。
///
/// 思路：取本机所在网段（如 192.168.10.0/24），对调用方指定的端口
/// 做并发探测，再补一次 HTTP 握手确认它是 fnOS 网关（HTTP 网关会
/// 对 `/access_code_verify` 回 401/204/404 之类，而不是超时或乱码）。
///
/// ⚠️ 不内置任何默认端口：扫哪个端口由用户在登录页填写。
///
/// 只探测当前网段，不扫公网、不依赖任何外部服务。
library;

import 'dart:convert';
import 'dart:io';

class LanDevice {
  final String host;
  final int port;

  const LanDevice(this.host, this.port);

  String get label => '$host:$port';

  /// 形如 192.168.10.23 → 10.23，列表里显示更清爽
  String get shortName {
    final p = host.split('.');
    return p.length == 4 ? '${p[2]}.${p[3]}' : host;
  }

  @override
  bool operator ==(Object other) =>
      other is LanDevice && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

class LanScanner {
  /// 单台设备的连接超时（HTTPS 时包含 TLS 握手）。局域网内未开机的主机
  /// 一般会快速 RST，真正需要等超时的不多，450ms 足够且能把整体耗时压到几秒。
  static const Duration _connectTimeout = Duration(milliseconds: 450);

  /// 拿到本机所有 IPv4 网段前缀（"192.168.10"）
  static Future<List<String>> localSubnets() async {
    final out = <String>{};
    try {
      final ifs = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final i in ifs) {
        for (final a in i.addresses) {
          final ip = a.address;
          final p = ip.split('.');
          if (p.length != 4) continue;
          if (ip.startsWith('169.254.')) continue; // 链路本地，跳过
          out.add('${p[0]}.${p[1]}.${p[2]}');
        }
      }
    } catch (_) {
      // 拿不到网卡信息就交给调用方提示手动输入
    }
    return out.toList();
  }

  /// 扫描局域网内的 NAS 设备。
  ///
  /// [port] **必填** —— 只探测调用方给出的端口（用户在登录页填写的端口），
  /// App 不内置任何默认端口；[tls] 跟随登录页的 HTTPS 开关。
  /// [onProgress] 回调 (已探测数, 总数)，用于显示进度。
  /// [isCancelled] 返回 true 时中止扫描（用户点了取消）。
  static Future<List<LanDevice>> scan({
    required int port,
    bool tls = false,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final prefixes = await localSubnets();
    if (prefixes.isEmpty) return const [];

    final hosts = <String>[];
    for (final p in prefixes) {
      for (var i = 1; i <= 254; i++) {
        hosts.add('$p.$i');
      }
    }

    final found = <LanDevice>[];
    var done = 0;
    const batch = 48;

    for (var s = 0; s < hosts.length; s += batch) {
      if (isCancelled?.call() ?? false) break;
      final end = (s + batch) > hosts.length ? hosts.length : s + batch;
      final slice = hosts.sublist(s, end);
      await Future.wait(slice.map((h) async {
        if (await _probe(h, port, tls)) found.add(LanDevice(h, port));
        done++;
      }));
      onProgress?.call(done, hosts.length);
    }

    found.sort((a, b) {
      final ai = int.tryParse(a.host.split('.').last) ?? 0;
      final bi = int.tryParse(b.host.split('.').last) ?? 0;
      return ai.compareTo(bi);
    });
    return found;
  }

  /// 连接对端端口 + 一次 HTTP 请求，确认它是 fnOS 网关。
  ///
  /// [tls] 为 true 时用 TLS 连接（跟随登录页的 HTTPS 开关）——
  /// 设备的自签证书一律放行，这里只关心「对端是否回应 HTTP」。
  static Future<bool> _probe(String host, int port, bool tls) async {
    Socket? s;
    try {
      if (tls) {
        s = await SecureSocket.connect(host, port,
            timeout: _connectTimeout, onBadCertificate: (_) => true);
      } else {
        s = await Socket.connect(host, port, timeout: _connectTimeout);
      }
      s.write('GET /access_code_verify HTTP/1.1\r\n'
          'Host: $host:$port\r\n'
          'User-Agent: okhttp/4.12.0\r\n'
          'x-access-source: app\r\n'
          'Connection: close\r\n'
          '\r\n');
      await s.flush();
      final chunk = await s.first.timeout(const Duration(seconds: 2));
      final head = utf8.decode(chunk, allowMalformed: true);
      return head.startsWith('HTTP/');
    } catch (_) {
      return false;
    } finally {
      try {
        s?.destroy();
      } catch (_) {/* 忽略 */}
    }
  }
}
