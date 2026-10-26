/// 异常 → 用户可读中文文案。
///
/// 背景：登录链路早就把 `SocketException` / `HandshakeException` 翻译成了
/// 人能照着做的提示，但**页面级请求没有**。NAS 关机或手机不在同一网段时，
/// 人物 / 地点 / 相册 / 设置 / 已下载数据几个页面会把底层异常原文摊给用户：
///
///   `加载失败：SocketException: Connection refused (OS Error: Connection
///    refused, errno = 111), address = 192.168.1.2, port = 6006`
///
/// 这里做统一收口。翻译只处理**能确定语义**的几类，其余一律退化为原始描述
/// ——绝不吞掉信息，避免出现"出错了但不知道为什么"。
library;

import 'dart:async';
import 'dart:io';

import 'fnos_client.dart';

/// 把任意异常转成适合直接显示的一行中文。
String friendlyError(Object e) {
  if (e is FnosException) {
    final m = e.message.trim();
    return m.isNotEmpty ? m : 'NAS 返回错误（code=${e.code}）';
  }
  if (e is TimeoutException) {
    return '连接超时：NAS 没有响应，请检查网络、端口，以及 NAS 是否在运行';
  }
  if (e is HandshakeException) {
    return 'HTTPS 证书校验失败：该 NAS 使用的是自签名证书，'
        '请在登录页打开「信任自签名证书」后重试';
  }
  if (e is SocketException) {
    return '连接不上 NAS：请确认手机与 NAS 在同一网络、NAS 已开机，且端口填写正确';
  }
  if (e is HttpException) {
    return '请求失败：${e.message}';
  }
  if (e is StateError) {
    return e.message;
  }
  final s = '$e';
  return s.isEmpty ? '未知错误' : s;
}
