/// fnOS REST 接口请求签名（authx 头）
///
/// 签名输入与组装顺序对齐设备 HTTP 接口的可观察行为，
/// 用于用户自有设备的互操作。
///
/// 密钥参数不随源码仓库分发：构建前运行 `dart tool/gen_secrets.dart`
/// 生成 lib/core/secrets.g.dart（已 gitignore）。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'secrets.g.dart';

export 'secrets.g.dart';

final Random _rnd = Random.secure();

String md5Hex(String input) =>
    md5.convert(utf8.encode(input)).toString();

/// 生成 6 位随机 nonce
String genNonce() => (_rnd.nextInt(900000) + 100000).toString();

/// 构造 GET 请求的 `a` 分量：排序 query string → 解码 → md5
///
/// 签名基准要求把编码产生的 '+' 统一还原为 '%20' 后再解码取 md5，
/// 否则含空格的参数（如日期时间）会产生签名不一致。
String paramContentForGet(Map<String, dynamic>? params) {
  final entries = <MapEntry<String, String>>[];
  if (params != null) {
    params.forEach((k, v) {
      if (v == null) return;
      entries.add(MapEntry(k, '$v'));
    });
  }
  entries.sort((a, b) => a.key.compareTo(b.key));

  final buf = StringBuffer();
  for (var i = 0; i < entries.length; i++) {
    if (i > 0) buf.write('&');
    buf.write('${Uri.encodeQueryComponent(entries[i].key)}='
        '${Uri.encodeQueryComponent(entries[i].value)}');
  }
  final normalized = buf.toString().replaceAll('+', '%20');
  final decoded = Uri.decodeComponent(normalized);
  return md5Hex(decoded);
}

/// 构造 POST 请求的 `a` 分量：紧凑 JSON（无空格）→ md5
String paramContentForPost(Object? body) {
  if (body == null) return md5Hex('');
  return md5Hex(jsonEncode(body));
}

/// 计算 `authx` 请求头
String buildAuthx({
  required String method,
  required String path,
  Map<String, dynamic>? params,
  Object? body,
  String apiKey = kPhotoApiKey,
  String? nonce,
  String? timestamp,
}) {
  final upper = method.toUpperCase();
  final a = upper == 'GET'
      ? paramContentForGet(params)
      : paramContentForPost(body);
  final n = nonce ?? genNonce();
  final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch.toString();
  final sign = md5Hex([kSignSalt, path, n, ts, a, apiKey].join('_'));
  return 'nonce=$n&timestamp=$ts&sign=$sign';
}
