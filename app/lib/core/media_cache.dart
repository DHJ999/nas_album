/// 媒体字节缓存（图片流下载结果）。
///
/// 为什么单独成文件：`fnos_image.dart` 属于 widgets 层，
/// 而 `core/media_preloader.dart` 需要在 **core 层**查询/释放缓存。
/// 若让 preloader 去 import widgets，会形成 core → widgets → core 的
/// 循环依赖，编译期直接报「method isn't defined」（Dart 不允许部分解析）。
/// 所以把「缓存本体 + 增删查」放在 core，widget 层只负责发请求与解码。
library;

import 'dart:typed_data';

/// 缓存 key：path + 排序后的 params，保证同一资源的不同写法命中同一项。
String imageCacheKey(String path, {Map<String, dynamic>? params}) =>
    params == null || params.isEmpty
        ? path
        : '$path?${(params.entries.map((e) => '${e.key}=${e.value}').toList()..sort()).join('&')}';

/// 内存 LRU 缓存，避免瀑布流滚动时重复请求。
/// 真 LRU：命中即移到队尾；同时受条数与字节总量双重上限约束。
final Map<String, Uint8List> _memCache = {};
int _memCacheBytes = 0;
const int _memCacheMax = 260;
const int _memCacheMaxBytes = 128 * 1024 * 1024; // 128MB 字节上限

/// 命中：移到队尾，标记为最近使用
void imageCacheHit(String key, Uint8List bytes) {
  _memCache.remove(key);
  _memCache[key] = bytes;
}

/// 写入并按两个上限淘汰（队首最久未使用）
void imageCachePut(String key, Uint8List bytes) {
  final old = _memCache.remove(key);
  if (old != null) _memCacheBytes -= old.length;
  _memCache[key] = bytes;
  _memCacheBytes += bytes.length;
  while (_memCache.isNotEmpty &&
      (_memCache.length > _memCacheMax || _memCacheBytes > _memCacheMaxBytes)) {
    final k = _memCache.keys.first;
    _memCacheBytes -= _memCache[k]!.length;
    _memCache.remove(k);
  }
}

/// 直接读缓存原始字节（供已经拿到 key 的调用方使用）
Uint8List? imageCacheGet(String key) => _memCache[key];

/// 缓存里是否已有该图片 —— 预加载调度器用它避免重复请求。
bool isImageCached(String path, {Map<String, dynamic>? params}) =>
    _memCache.containsKey(imageCacheKey(path, params: params));

/// 释放单个缓存条目，返回是否真的释放了。
///
/// 用于「滑出预加载窗口的资源要丢弃」——只从内存里摘掉，
/// 正在飞的请求不强杀（那会浪费已下字节），落地后由 LRU 自然淘汰。
bool releaseImage(String path, {Map<String, dynamic>? params}) {
  final old = _memCache.remove(imageCacheKey(path, params: params));
  if (old == null) return false;
  _memCacheBytes -= old.length;
  return true;
}

/// 当前缓存条目数（调试 / 预加载统计用）
int get imageCacheLength => _memCache.length;

/// 当前缓存占用字节数（调试 / 内存监控用）
int get imageCacheBytes => _memCacheBytes;

void clearImageCache() {
  _memCache.clear();
  _memCacheBytes = 0;
}