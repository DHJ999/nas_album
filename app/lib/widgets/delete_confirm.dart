/// 删除确认弹窗（带「同时删除手机上本机副本」勾选）
library;

import 'package:flutter/material.dart';

import '../core/prefs.dart';
import '../core/theme.dart';

class DeleteChoice {
  final bool confirmed;
  final bool syncLocal;

  const DeleteChoice({required this.confirmed, required this.syncLocal});
}

/// 弹出「取消 / 删除」确认框。
///
/// 勾选状态从上一次的选择恢复（[AppPrefs.syncDeleteLocal]），
/// 确认时把最新状态写回，下次不用重复勾。
Future<DeleteChoice?> showDeleteConfirmDialog(
  BuildContext context, {
  required int count,
  String? fileName,
}) async {
  var sync = await AppPrefs.syncDeleteLocal();
  if (!context.mounted) return null;

  final result = await showDialog<DeleteChoice>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              count > 1
                  ? '确定要删除选中的 $count 个项目吗？'
                  : '确定要删除这个项目吗？',
              style: const TextStyle(fontSize: 14.5, color: FnosColors.textMain),
            ),
            if (fileName != null && fileName.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(fileName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, color: FnosColors.textSub)),
            ],
            const SizedBox(height: 8),
            const Text('将移入 NAS 的回收站，可在 NAS 网页端还原。',
                style: TextStyle(fontSize: 12.5, color: FnosColors.textSub)),
            const SizedBox(height: 4),
            // 勾选区：紧贴内容，避免默认 ListTile 的大内边距把弹窗撑高
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setLocal(() => sync = !sync),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 26,
                      height: 26,
                      child: Checkbox(
                        value: sync,
                        visualDensity: VisualDensity.compact,
                        onChanged: (v) =>
                            setLocal(() => sync = v ?? false),
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Expanded(
                      child: Text('同时删除手机上的本地副本',
                          style: TextStyle(
                              fontSize: 14, color: FnosColors.textMain)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, DeleteChoice(confirmed: false, syncLocal: sync)),
            child: const Text('取消',
                style: TextStyle(color: FnosColors.textSub)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: FnosColors.danger,
              minimumSize: const Size(72, 40),
              shape: const StadiumBorder(),
            ),
            onPressed: () =>
                Navigator.pop(ctx, DeleteChoice(confirmed: true, syncLocal: sync)),
            child: const Text('删除'),
          ),
        ],
      ),
    ),
  );

  if (result != null && result.confirmed) {
    await AppPrefs.setSyncDeleteLocal(result.syncLocal);
  }
  return result;
}
