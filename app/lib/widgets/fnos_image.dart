/// 带鉴权的网络图片组件
///
/// fnOS的图片流接口需要 Cookie `fnos-token` 与签名头 `authx`，
/// 因此不能直接用 Image.network，必须走自定义 HttpClient。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/fnos_client.dart';
import '../core/fnos_crypto.dart';
// 缓存本体在 core/media_cache.dart：预加载调度器（core 层）要用它，
// 放在 widgets 层会造成 core → widgets → core 的循环依赖。
// 这里整文件导入并再导出 clearImageCache —— 全工程页面都是通过
// `widgets/fnos_image.dart` 拿这个函数（历史接口，不改调用方）。
import '../core/media_cache.dart';
import '../core/media_preloader.dart' show MediaPreloader;

/// 再导出：保持既有调用面（各页面 import fnos_image 就能用）。
export '../core/media_cache.dart' show clearImageCache;

/// 全局复用的 HttpClient（连接池 + 避免频繁建连）
///
/// 为什么要两个实例：NAS 的 HTTPS 是自签证书，Dart 默认校验会抛
/// `CERTIFICATE_VERIFY_FAILED`。主客户端 [FnosClient] 在 `allowBadCertificate`
/// 为 true 时挂了 `badCertificateCallback`，但图片流走的是这里的独立客户端，
/// 必须同样放行，否则 https 登录后所有缩略图（含视频缩略图）都会加载失败
/// （http 下不校验证书所以正常——这正是「http 正常、https 图片全挂」的根因）。
/// 不放行的实例保留给证书可信的场景，避免对所有目标都降级安全策略。
final HttpClient _imgHttp = HttpClient()
  ..connectionTimeout = const Duration(seconds: 15)
  ..maxConnectionsPerHost = 8;

HttpClient? _imgHttpInsecure;

/// 按当前会话的证书策略挑选 HttpClient。
HttpClient _httpFor(FnosClient c) {
  if (!c.allowBadCertificate) return _imgHttp;
  return _imgHttpInsecure ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..maxConnectionsPerHost = 8
    ..badCertificateCallback = (cert, host, port) => true;
}

/// 内存缓存本体与增删查已移到 core/media_cache.dart（供预加载调度器共用）。

/// 把图片下载实现注入预加载器：两者共用同一份缓存与同一套 in-flight 去重，
/// 避免出现「预加载下好的图，翻过去仍然转圈」的两份缓存问题。
///
/// **只在启动时注入一次**。以前写在 [loadFnosImage] 开头，等于每加载一张图
/// 就新建一个闭包重新注入一次 —— 那是所有图片加载的必经热路径。
void attachPreloaderImageFetcher() {
  MediaPreloader.I.attach((p) => loadFnosImage(p));
}

/// 进行中请求合并（in-flight dedup）：同一 key 的并发下载只发一次请求
final Map<String, Future<Uint8List>> _inFlight = {};

Future<Uint8List> loadFnosImage(String path, {Map<String, dynamic>? params}) async {
  final key = imageCacheKey(path, params: params);
  final hit = imageCacheGet(key);
  if (hit != null) {
    imageCacheHit(key, hit);
    return hit;
  }
  // 已有相同请求在下载则直接复用，避免切 tab / 快速滑动时重复请求
  final running = _inFlight[key];
  if (running != null) return running;

  final future = _fetchFnosImage(key, path, params: params);
  _inFlight[key] = future;
  try {
    return await future;
  } finally {
    _inFlight.remove(key);
  }
}

Future<Uint8List> _fetchFnosImage(String key, String path,
    {Map<String, dynamic>? params}) async {
  final st = AppState.I;
  final c = st.client;
  if (c == null) throw StateError('未登录');

  var bytes = await _fetchOnce(c, path, params: params);

  // 401 = token 失效：静默重登成功后重试一次
  if (bytes == null) {
    if (c.relogin == null || !await c.relogin!()) {
      throw HttpException('鉴权失效（401）');
    }
    bytes = await _fetchOnce(c, path, params: params);
    if (bytes == null) throw HttpException('鉴权失效（401）');
  }

  imageCachePut(key, bytes);
  return bytes;
}

/// 返回 null 表示 401（可重登重试）；抛异常表示其它错误。
Future<Uint8List?> _fetchOnce(FnosClient c, String path,
    {Map<String, dynamic>? params}) async {
  // 设备下发的部分 URL 自带 query。签名基准必须与**实际发出的 query**一致，
  // 否则 authx 的 a 分量对不上 → 401（与 FnosClient._request 同一口径）。
  final split = splitPathQuery(path, params);
  final uri = Uri.parse('${c.baseUrl}${split.path}').replace(
    queryParameters: split.params?.map((k, v) => MapEntry(k, '$v')),
  );
  // 关键：按会话证书策略选客户端，https 自签证书下必须用放行实例，
  // 否则 HandshakeException 会让所有图片请求失败。
  final req = await _httpFor(c).getUrl(uri);
  req.headers.set('x-access-source', 'app');
  req.headers.set('Accept', '*/*');
  req.headers.set('User-Agent', 'okhttp/4.12.0');
  req.headers.set('authx',
      buildAuthx(method: 'GET', path: split.path, params: split.params,
          apiKey: c.apiKey));
  // 关键：用 client 的完整 Cookie jar（含门禁 os-access-code）。
  // 只拼 fnos-token 时，开启「访问码门禁」的 NAS 会拒绝所有图片请求。
  final cookie = c.cookieHeader;
  if (cookie.isNotEmpty) req.headers.set('Cookie', cookie);

  final resp = await req.close();
  if (resp.statusCode == 401) {
    await resp.drain<void>();
    return null;
  }
  if (resp.statusCode != 200) {
    await resp.drain<void>();
    throw HttpException('HTTP ${resp.statusCode}', uri: uri);
  }
  // 网关把未鉴权请求重定向到 HTML 登录页时状态码是 200，
  // 按 content-type 拦截，避免把 HTML 当图片缓存。
  final ct = resp.headers.value('content-type') ?? '';
  if (ct.contains('text/html')) {
    await resp.drain<void>();
    throw HttpException('图片流返回了 HTML（鉴权失效）', uri: uri);
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in resp) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

// ─────────────────────── 图片固有尺寸 & 解码目标 ───────────────────────
//
// 为什么需要它：`Image` 的 `cacheWidth` / `cacheHeight` **同时给定时**，
// 引擎会把图片**强制缩放到该像素尺寸**（忽略原始宽高比）——
// 这正是「横屏 / 4:3 照片被统一拉成 9:16 铺满屏幕」的根因。
// 只给其中一轴时，引擎按原始比例推导另一轴，因此永远不会变形。

/// 从图片字节头部读出固有宽高（只解析头，不做完整解码，开销可忽略）
({int w, int h})? imageSizeOf(Uint8List b) {
  try {
    // PNG
    if (b.length > 24 &&
        b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return (
        w: (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19],
        h: (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23],
      );
    }
    // GIF
    if (b.length > 10 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
      return (w: b[6] | (b[7] << 8), h: b[8] | (b[9] << 8));
    }
    // BMP
    if (b.length > 26 && b[0] == 0x42 && b[1] == 0x4D) {
      int le(int i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);
      return (w: le(18).abs(), h: le(22).abs());
    }
    // WEBP
    if (b.length > 30 &&
        b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      final cc = String.fromCharCodes(b.sublist(12, 16));
      if (cc == 'VP8 ') {
        return (w: (b[26] | (b[27] << 8)) & 0x3FFF, h: (b[28] | (b[29] << 8)) & 0x3FFF);
      }
      if (cc == 'VP8L') {
        final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
        return (w: (bits & 0x3FFF) + 1, h: ((bits >> 14) & 0x3FFF) + 1);
      }
      if (cc == 'VP8X') {
        return (
          w: (b[24] | (b[25] << 8) | (b[26] << 16)) + 1,
          h: (b[27] | (b[28] << 8) | (b[29] << 16)) + 1,
        );
      }
    }
    // JPEG（扫描 SOFn 段取宽高）
    if (b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) {
      var i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = b[i + 1];
        if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
          i += 2;
          continue;
        }
        final len = (b[i + 2] << 8) | b[i + 3];
        if (len < 2) break;
        final isSof = marker >= 0xC0 && marker <= 0xCF &&
            marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
        if (isSof) {
          return (
            h: (b[i + 5] << 8) | b[i + 6],
            w: (b[i + 7] << 8) | b[i + 8],
          );
        }
        i += 2 + len;
      }
    }
  } catch (_) {/* 解析失败就退化为「无固有尺寸」分支 */}
  return null;
}

/// 计算解码目标。**返回值里最多只有一个非 null**（见上面的说明）。
({int? w, int? h}) resolveDecodeTarget(
  BoxFit fit,
  double? boxW,
  double? boxH,
  ({int w, int h})? src,
  double dpr,
) {
  final w = (boxW != null && boxW > 0 && boxW.isFinite) ? boxW : null;
  final h = (boxH != null && boxH > 0 && boxH.isFinite) ? boxH : null;
  if (w == null && h == null) return (w: null, h: null);

  // 只有单边约束时直接用对应的轴
  if (w != null && h == null) return (w: (w * dpr).round(), h: null);
  if (w == null && h != null) return (w: null, h: (h * dpr).round());

  final bw = w!, bh = h!;

  // 没有固有尺寸：优先宽度轴。略大于实际所需，只会稍费内存，绝不糊/变形。
  if (src == null || src.w <= 0 || src.h <= 0) {
    return (w: (bw * dpr).round(), h: null);
  }

  final boxAR = bw / bh;
  final srcAR = src.w / src.h;

  // contain/scaleDown：谁的比例更小谁受限；cover 等：谁的比例更大谁受限。
  final bool byWidth = switch (fit) {
    BoxFit.contain || BoxFit.scaleDown => srcAR > boxAR,
    _ => srcAR < boxAR,
  };
  return byWidth
      ? (w: (bw * dpr).round(), h: null)
      : (w: null, h: (bh * dpr).round());
}

/// 相册图片：自动带鉴权、带内存缓存与占位图
class FnosImage extends StatefulWidget {
  final String path;
  final Map<String, dynamic>? params;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget? placeholder;
  final BorderRadius? radius;

  const FnosImage({
    super.key,
    required this.path,
    this.params,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholder,
    this.radius,
  });

  @override
  State<FnosImage> createState() => _FnosImageState();
}

class _FnosImageState extends State<FnosImage> {
  Uint8List? _bytes;
  Object? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant FnosImage old) {
    super.didUpdateWidget(old);
    // 必须连 params 一起比：人物页正是靠 `?v=<封面版本号>` 来击穿缓存的
    // （path 不变、params 变）。只比 path 的话换完封面这里什么都不做，
    // 内存缓存里的旧图会一直显示到进程重启。
    if (old.path != widget.path || !mapEquals(old.params, widget.params)) {
      _bytes = null;
      _err = null;
      _load();
    }
  }

  Future<void> _load() async {
    // 记下本次请求对应的 (path, params)：请求在飞期间控件可能已被复用成
    // 另一个条目，那时的结果必须丢弃，否则会把旧图盖到新条目上。
    final path = widget.path;
    final params = widget.params;
    bool stale() =>
        !mounted || widget.path != path || !mapEquals(widget.params, params);
    try {
      final b = await loadFnosImage(path, params: params);
      if (stale()) return;
      setState(() {
        _bytes = b;
        _err = null;
      });
    } catch (e) {
      if (stale()) return;
      setState(() => _err = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ph = widget.placeholder ??
        Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Center(
            child: SizedBox(
              width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );

    Widget child;
    if (_bytes != null) {
      // 关键：按实际显示尺寸解码，避免按原始像素解码（一张 4000×3000
      // 的照片解码后约 48MB，瀑布流里几张就会 OOM 闪退）。
      // 同时**只传单轴** cache 尺寸，保证图片按原始比例显示不被拉伸。
      final bytes = _bytes!;
      child = LayoutBuilder(
        builder: (context, constraints) {
          final dpr = MediaQuery.devicePixelRatioOf(context);
          final w = widget.width ??
              (constraints.maxWidth.isFinite ? constraints.maxWidth : null);
          final h = widget.height ??
              (constraints.maxHeight.isFinite ? constraints.maxHeight : null);
          final t = resolveDecodeTarget(widget.fit, w, h, imageSizeOf(bytes), dpr);
          return Image.memory(
            bytes,
            fit: widget.fit,
            // 用户指定了尺寸就用用户的；否则用 LayoutBuilder 算出的父容器实际尺寸，
            // 强制 Image 填满父区域，避免 loose 约束下按图片原始比例自适应。
            width: widget.width ?? w,
            height: widget.height ?? h,
            gaplessPlayback: true,
            cacheWidth: t.w,
            cacheHeight: t.h,
            filterQuality: FilterQuality.medium,
          );
        },
      );
    } else if (_err != null) {
      child = Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(Icons.broken_image_outlined,
            color: Theme.of(context).colorScheme.outline),
      );
    } else {
      child = ph;
    }

    if (widget.radius != null) {
      child = ClipRRect(borderRadius: widget.radius!, child: child);
    }
    if (widget.width != null || widget.height != null) {
      return SizedBox(width: widget.width, height: widget.height, child: child);
    }
    // 未指定尺寸时强制填满父容器：避免在 Column(crossAxisAlignment.start)
    // 的 loose 宽度约束下，Image/占位/错误态按内容自适应，导致网格卡片大小不一。
    return SizedBox.expand(child: child);
  }
}
