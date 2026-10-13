/// 下载编排：把 NAS 上的照片/视频保存到手机系统相册（MediaStore）。
///
/// 与 [MediaDeleter] 对称：一个负责删、一个负责存。
///
/// 落盘位置：通过 photo_manager 写入系统相册，目录由设置项
/// [AppPrefs.downloadRelativePath] 决定（默认 `DCIM/NAS相册下载`），
/// 保存后在系统相册/图库内可见，而不是塞进用户看不到的应用私有目录。
///
/// 说明：图片复用 [loadFnosImage]（带内存缓存与 401 静默重登），
/// 该函数虽位于 widgets/fnos_image.dart，但本质是纯网络下载能力、
/// 不依赖任何 Widget，这里直接复用以避免重复实现鉴权与重试。
/// 视频体积大不能整段读进内存，走 [VideoProxy] 本地代理流式写临时文件，
/// 再交给 photo_manager 入库，最后清理临时文件。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../models/models.dart';
import '../widgets/fnos_image.dart' show loadFnosImage;
import 'local_media.dart';
import 'prefs.dart';
import 'video_proxy.dart';

class DownloadOutcome {
  /// 成功保存到相册的条目数
  final int success;

  /// 失败条目数
  final int failed;

  /// 失败的文件名（用于提示/排查）
  final List<String> failedNames;

  const DownloadOutcome({
    required this.success,
    required this.failed,
    required this.failedNames,
  });
}

class MediaDownloader {
  /// 批量保存 [items] 到系统相册。
  ///
  /// [onProgress] 每完成一个条目回调一次（done 从 1 开始）。
  /// 未获得相册权限时抛 [StateError]，由界面引导授权。
  static Future<DownloadOutcome> downloadAll(
    List<PhotoItem> items, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (items.isEmpty) {
      return const DownloadOutcome(success: 0, failed: 0, failedNames: []);
    }

    // 写系统相册需要相册授权（图片/视频的读写由 photo_manager 按系统版本处理）
    if (!LocalMediaSync.granted &&
        !(await LocalMediaSync.requestPermission())) {
      throw StateError('未获得相册访问权限，无法保存');
    }

    final relativePath = await AppPrefs.downloadRelativePath();
    final tmpDir = await getTemporaryDirectory();

    var success = 0;
    final failedNames = <String>[];

    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final name = _fileNameOf(item);
      try {
        if (item.isVideo) {
          await _saveVideo(item, name, relativePath, tmpDir);
        } else {
          final bytes = await loadFnosImage(item.originalPath);
          await PhotoManager.editor.saveImage(
            bytes,
            filename: name,
            relativePath: relativePath,
          );
        }
        success++;
      } catch (_) {
        failedNames.add(name);
      }
      onProgress?.call(i + 1, items.length);
    }

    return DownloadOutcome(
      success: success,
      failed: failedNames.length,
      failedNames: failedNames,
    );
  }

  /// 单个条目保存（大图查看页「保存到本机」使用）。失败直接抛异常。
  static Future<void> downloadOne(PhotoItem item) async {
    final r = await downloadAll([item]);
    if (r.failed > 0) {
      throw StateError('保存失败：${r.failedNames.join('、')}');
    }
  }

  /// 视频：经本地代理流式下载到临时文件，再入库系统相册。
  static Future<void> _saveVideo(
    PhotoItem item,
    String name,
    String relativePath,
    Directory tmpDir,
  ) async {
    // 始终走代理：代理统一注入 authx/Cookie 并放行自签证书，
    // 这里拿到的是 127.0.0.1 明文地址，普通 HttpClient 即可。
    final url = await VideoProxy.I.proxyUrlAlways(item.videoStreamPath);
    final tmp = File('${tmpDir.path}/fnos_dl_${item.id}_$name');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 30);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      // 完整下载不带 Range，NAS 正常返回 200；个别网关回 206 也接受
      if (resp.statusCode != HttpStatus.ok &&
          resp.statusCode != HttpStatus.partialContent) {
        throw HttpException('视频下载失败 HTTP ${resp.statusCode}');
      }
      final sink = tmp.openWrite();
      await resp.pipe(sink);
      await PhotoManager.editor.saveVideo(
        tmp,
        title: name,
        relativePath: relativePath,
      );
    } finally {
      client.close(force: true);
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {/* 临时文件清理失败不影响结果 */}
      }
    }
  }

  static String _fileNameOf(PhotoItem item) {
    if (item.fileName.isNotEmpty) return item.fileName;
    final ext = item.fileType.isNotEmpty ? item.fileType : 'jpg';
    return 'photo_${item.id}.$ext';
  }
}
