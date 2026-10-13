/// 本机相册访问：权限申请 + 按文件名索引 + 删除本机副本。
///
/// 只在「删除 NAS 照片时勾选了同步删除本地」这条链路上用到。
/// 索引按需构建（懒加载 + 内存缓存），不预先扫描几万张照片。
library;

import 'package:photo_manager/photo_manager.dart';

class LocalMediaSync {
  static bool _granted = false;
  static bool get granted => _granted;

  /// 文件名 → assetId 列表（同名文件可能有多份）
  static final Map<String, List<String>> _byName = {};
  static bool _indexBuilt = false;
  static bool _indexing = false;
  static int _indexedCount = 0;
  static int get indexedCount => _indexedCount;
  static bool get indexBuilt => _indexBuilt;

  /// 申请相册读取权限。返回 true 表示可读。
  static Future<bool> requestPermission() async {
    try {
      final ps = await PhotoManager.requestPermissionExtend();
      _granted = ps == PermissionState.authorized || ps == PermissionState.limited;
    } catch (_) {
      _granted = false;
    }
    return _granted;
  }

  /// 仅查询当前权限状态，不弹窗。
  static Future<bool> hasPermission() async {
    try {
      final ps = await PhotoManager.getPermissionState(
          requestOption: const PermissionRequestOption());
      _granted = ps == PermissionState.authorized || ps == PermissionState.limited;
    } catch (_) {
      _granted = false;
    }
    return _granted;
  }

  static final PMFilter _filter = FilterOptionGroup(
    imageOption: const FilterOption(needTitle: true),
    videoOption: const FilterOption(needTitle: true),
  );

  /// 遍历本机全部照片/视频建立「文件名 → id」索引。
  ///
  /// 分页拉取，每页 400 条；最多 100 页（40000 条）兜底，避免异常情况下死循环。
  static Future<void> buildIndex({void Function(int loaded)? onProgress}) async {
    if (_indexBuilt || _indexing) return;
    _indexing = true;
    try {
      const pageSize = 400;
      for (var page = 0; page < 100; page++) {
        final list = await PhotoManager.getAssetListPaged(
          page: page,
          pageCount: pageSize,
          type: RequestType.common,
          filterOption: _filter,
        );
        if (list.isEmpty) break;
        for (final a in list) {
          var name = a.title ?? '';
          if (name.isEmpty) {
            try {
              name = await a.titleAsync;
            } catch (_) {
              name = '';
            }
          }
          if (name.isEmpty) continue;
          _byName.putIfAbsent(name, () => []).add(a.id);
        }
        _indexedCount += list.length;
        onProgress?.call(_indexedCount);
        if (list.length < pageSize) break;
      }
      _indexBuilt = true;
    } finally {
      _indexing = false;
    }
  }

  /// 按 NAS 端 fileName 找到本机对应的 assetId
  static Future<List<String>> findIdsByFileNames(
      Iterable<String> fileNames) async {
    if (!_granted) return const [];
    await buildIndex();
    final ids = <String>[];
    for (final n in fileNames) {
      final hit = _byName[n];
      if (hit != null && hit.isNotEmpty) ids.addAll(hit);
    }
    return ids;
  }

  /// 删除本机副本，返回实际删除的数量。
  ///
  /// Android 11+ 系统会弹出「是否允许删除」的确认框；用户拒绝时抛异常，
  /// 由调用方决定如何提示（NAS 端的删除已成功，不应回滚）。
  static Future<int> deleteByFileNames(Iterable<String> fileNames) async {
    if (!_granted) return 0;
    final ids = await findIdsByFileNames(fileNames);
    if (ids.isEmpty) return 0;
    final done = await PhotoManager.editor.deleteWithIds(ids);
    // 索引里同步剔除，避免下次误命中已删除的 id
    for (final n in fileNames) {
      _byName.remove(n);
    }
    return done.length;
  }

  /// 单文件是否存在本机副本（用于在弹窗里给出更准确的提示）
  static Future<bool> hasLocalCopy(String fileName) async {
    if (!_granted) return false;
    await buildIndex();
    return (_byName[fileName] ?? const []).isNotEmpty;
  }

  static void resetIndex() {
    _byName.clear();
    _indexBuilt = false;
    _indexedCount = 0;
  }
}
