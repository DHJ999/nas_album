/// 删除编排：NAS 端移入回收站 + 可选的本机副本删除。
library;

import '../models/models.dart';
import 'app_state.dart';
import 'local_media.dart';

class DeleteOutcome {
  /// NAS 端成功删除的条目数
  final int nasCount;

  /// 本机相册成功删除的副本数
  final int localCount;

  /// 本机删除失败的原因（NAS 端已成功，不回滚）
  final String? localError;

  const DeleteOutcome({
    required this.nasCount,
    required this.localCount,
    this.localError,
  });
}

class MediaDeleter {
  /// [items] 要删除的条目；[syncLocal] 为 true 时按文件名删除本机同名副本。
  ///
  /// NAS 端失败会直接抛出 [FnosException]，由界面提示。
  static Future<DeleteOutcome> delete({
    required List<PhotoItem> items,
    required bool syncLocal,
  }) async {
    final c = AppState.I.client;
    if (c == null) throw StateError('未登录');

    final ids = items.map((e) => e.id).toList();
    // 1) NAS：POST /recycle-bin/add {ids}（可在 NAS 回收站还原）
    await c.deleteToRecycleBin(ids);

    // 2) 本机副本：按 displayName 精确匹配后删除
    var localCount = 0;
    String? localError;
    if (syncLocal) {
      final names = items
          .map((e) => e.fileName)
          .where((n) => n.isNotEmpty)
          .toList();
      if (names.isNotEmpty) {
        try {
          if (LocalMediaSync.granted || await LocalMediaSync.requestPermission()) {
            localCount = await LocalMediaSync.deleteByFileNames(names);
          } else {
            localError = '未获得相册访问权限，本机副本未删除';
          }
        } catch (e) {
          localError = '本机副本删除失败：$e';
        }
      }
    }
    return DeleteOutcome(
        nasCount: ids.length, localCount: localCount, localError: localError);
  }
}
