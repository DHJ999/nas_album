/// 媒体预加载调度器（图片与视频分开计数）。
///
/// 背景：原实现只靠 PageView 的 `cacheExtent`（前后各一页）顺带把相邻页
/// 拉起来，于是「快速连续滑动」时新页永远是**冷启动**——图片转圈、视频重新
/// 建连。本模块把预加载从「渲染副作用」里独立出来：按锚点位置主动排任务。
///
/// 三条硬约束：
///   1. **向后 8 / 前序保留 3**：由 [MediaPreloader.update] 按锚点算窗口，
///      超出保留数的资源从内存缓存里摘掉；
///   2. **去重**：同一 URL 在飞或已完成时不会重复排任务；
///   3. **并发上限**：图片与视频各用一套配额，互不抢占 —— 视频流大、建连贵，
///      绝不能被图片预热挤掉（这正是「预热抢带宽/IO 导致视频卡」）。
library;

import 'dart:async';
import 'dart:typed_data';

import 'media_cache.dart';

/// 预加载窗口。向后多备一点（快滑命中率最高），向前只留一点点供回看。
class PreloadWindow {
  /// 向后（后续方向）预加载个数
  final int ahead;

  /// 前序（已划过的方向）保留个数，超出即释放
  final int behind;

  const PreloadWindow({this.ahead = 8, this.behind = 3});

  static const standard = PreloadWindow();
}

/// 调度统计，便于排查「到底有没有预热上」。
class PreloadStats {
  int imageQueued = 0;
  int imageCacheHit = 0;
  int imagePeakConcurrent = 0;
  int videoWarm = 0;
  int videoAlreadyWarm = 0;
  int released = 0;

  String describe() => '图片预载 $imageQueued 次（并发峰值 $imagePeakConcurrent，'
      '命中缓存 $imageCacheHit）/ 视频预热 $videoWarm 次（已在窗口 $videoAlreadyWarm）'
      '/ 释放 $released 项';

  void reset() {
    imageQueued = 0;
    imageCacheHit = 0;
    imagePeakConcurrent = 0;
    videoWarm = 0;
    videoAlreadyWarm = 0;
    released = 0;
  }
}

/// 一条预加载窗口的描述：由页面在锚点变化时算出，交给调度器执行。
class PreloadPlan {
  /// 需要预热的图片地址（按优先级从高到低，队列是 FIFO）
  final List<String> images;

  /// 需要预热的视频 / 实况流地址（仅登记，播放器由页面建）
  final List<String> videos;

  /// 本窗口内**必须保留**的图片地址（超出者会被释放）
  final Set<String> keepImages;

  /// 本窗口外、且已不在保留区内的视频流地址（页面据此释放播放器）
  final List<String> evictVideos;

  const PreloadPlan({
    required this.images,
    required this.videos,
    required this.keepImages,
    required this.evictVideos,
  });

  static const empty = PreloadPlan(
      images: [], videos: [], keepImages: {}, evictVideos: []);
}

/// 实际执行下载的函数。
///
/// **为什么要注入而不是直接 import**：图片流下载依赖 [FnosClient] 的
/// 签名与 Cookie 逻辑，而这些实现在 widgets 层（fnos_image.dart）。
/// core 直接 import widgets 会形成 core → widgets → core 的循环依赖，
/// Dart 编译期会直接报「method isn't defined」（它不做部分解析）。
/// 由 widget 层在启动时注入同一个 [loadFnosImage]，还能保证
/// **预加载与显示走同一份缓存和同一套 in-flight 去重** ——
/// 这正是「预加载下好了、翻过去还在转圈」最容易踩的坑。
typedef ImageFetcher = Future<Uint8List> Function(String path);

class MediaPreloader {
  MediaPreloader._();
  static final MediaPreloader I = MediaPreloader._();

  ImageFetcher? _fetcher;

  /// 由 widget 层（fnos_image.dart）注入真实下载实现。
  void attach(ImageFetcher fetcher) => _fetcher = fetcher;

  /// 未注入前预热直接跳过，避免空跑与报错。
  bool get ready => _fetcher != null;

  final PreloadStats stats = PreloadStats();

  /// 图片并发上限。
  ///
  /// HttpClient 的 `maxConnectionsPerHost` 是 8，若预热把连接全占满，
  /// 当前页要显示的那张图反而要排队 —— **预加载必须让路给可见内容**，
  /// 所以只给一半。
  static const int _imageMaxConcurrent = 4;

  /// 已完成或已在飞的图片（去重集合）
  final Set<String> _imageDone = {};

  /// 曾经预热过的图片（按加入顺序），用于算「谁该被释放」
  final List<String> _imageSeen = [];

  /// 视频预热登记（窗口内的流地址）
  final Set<String> _videoWarm = {};

  int _imageRunning = 0;

  /// 递增的生成号：`clear()` 时自增，让仍在飞的请求不去动新一轮的计数。
  ///
  /// 以前 `clear()` 直接把 `_imageRunning` 置 0，但在飞的 Future 还没结束，
  /// 它们的 `finally` 照旧执行 `_imageRunning--` —— 变成负数后
  /// `while (_imageRunning < _imageMaxConcurrent)` 会放行远超上限的并发。
  int _epoch = 0;

  final List<String> _imageQueue = [];

  bool _enabled = true;

  void setEnabled(bool v) {
    if (_enabled == v) return;
    _enabled = v;
    if (!v) clear();
  }

  bool get enabled => _enabled;

  // ────────────────────────── 图片 ──────────────────────────

  /// 排一条图片预热任务。
  ///
  /// 命中内存缓存 / 已在飞 / 已完成都直接跳过（去重）。
  void warmImage(String url) {
    final fetch = _fetcher;
    if (!_enabled || fetch == null || url.isEmpty) return;
    if (_imageDone.contains(url)) return;

    // 已在内存缓存里就不必再排：网格页的缩略图通常已经缓存，
    // 进大图页直接命中，这条路径省掉的是绝大多数请求。
    // 注意这里**也记进 _imageSeen**：否则它只躺在 _imageDone 里，
    // 而 apply() 的释放循环只遍历 _imageSeen —— 这些 key 就永远不会被摘掉，
    // 等于去重集合只增不减（长时间浏览后累积成千上万条）。
    if (isImageCached(url)) {
      _imageDone.add(url);
      _imageSeen.add(url);
      stats.imageCacheHit++;
      return;
    }

    _imageDone.add(url);
    _imageSeen.add(url);
    _imageQueue.add(url);
    _pumpImages();
  }

  void _pumpImages() {
    final fetch = _fetcher;
    if (fetch == null) return;
    while (_imageRunning < _imageMaxConcurrent && _imageQueue.isNotEmpty) {
      final url = _imageQueue.removeAt(0);
      final epoch = _epoch;
      _imageRunning++;
      if (_imageRunning > stats.imagePeakConcurrent) {
        stats.imagePeakConcurrent = _imageRunning;
      }
      stats.imageQueued++;
      unawaited(() async {
        try {
          await fetch(url);
        } catch (_) {
          // 预热失败不打扰用户：真正显示时 FnosImage 会自己再请求并报错。
          // 从去重集合里摘掉，允许后续重试。
          _imageDone.remove(url);
        } finally {
          // 期间被 clear() 过：这一笔属于上一轮，不能去减新一轮的计数
          if (epoch == _epoch) {
            _imageRunning--;
            _pumpImages();
          }
        }
      }());
    }
  }

  // ────────────────────────── 视频 ──────────────────────────

  /// 登记一条视频 / 实况流为「需要预热」。
  ///
  /// 这里**只登记不建连**：ExoPlayer 的 initialize() 必须由 widget 在其
  /// 生命周期内发起（原生资源随 controller 走，脱离 widget 会泄漏）。
  /// 页面滑到该页时据此「只 prepare 不播」地建播放器 —— 那才是真预热。
  void markVideoWarm(String url) {
    if (!_enabled || url.isEmpty) return;
    if (_videoWarm.contains(url)) {
      stats.videoAlreadyWarm++;
      return;
    }
    _videoWarm.add(url);
    stats.videoWarm++;
  }

  bool isVideoWarm(String url) => _videoWarm.contains(url);

  /// 执行一个窗口计划：排图片、登记视频、释放越界资源。
  void apply(PreloadPlan plan) {
    if (!_enabled) return;

    for (final v in plan.videos) {
      markVideoWarm(v);
    }
    for (final u in plan.images) {
      warmImage(u);
    }

    // 释放：曾经预热过、但**不在本窗口保留区**的图片
    if (plan.keepImages.isNotEmpty) {
      for (final u in _imageSeen.toList(growable: false)) {
        if (plan.keepImages.contains(u)) continue;
        _imageSeen.remove(u);
        // 已在飞的不释放（会白下），只摘去重标记，落地后自然淘汰
        if (releaseImage(u)) stats.released++;
        _imageDone.remove(u);
      }
    }
  }

  /// 清空全部预热状态（退出登录 / 下拉刷新 / 删除条目）。
  void clear() {
    _imageDone.clear();
    _imageSeen.clear();
    _videoWarm.clear();
    _imageQueue.clear();
    _imageRunning = 0;
    _epoch++; // 让仍在飞的请求认清自己属于上一轮
    stats.reset();
  }

  /// **缓存与预热状态一起重置**。
  ///
  /// 之前全工程只有分类/网格页同时调用了 `clearImageCache()` 与
  /// `MediaPreloader.clear()`，而时间轴、大图页、设置页三处只清了前者 ——
  /// 于是 `_imageDone` 里留着已失效的 key，那些图片**再也不会被预热**，
  /// 表现为「明明刷过、回来还是转圈」。凡是需要清理的地方都走这一个入口。
  void resetAll() {
    clearImageCache();
    clear();
  }

  /// 调试用：当前内存缓存里的图片条数
  int get cachedImageCount => imageCacheLength;
}