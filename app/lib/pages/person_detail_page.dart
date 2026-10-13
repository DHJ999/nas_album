import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/theme.dart';
import '../models/models.dart';
import 'photo_grid_page.dart';

/// 人物详情页：某个人名下的所有照片 + 编辑该人物的姓名与封面。
///
/// 编辑能力对应的fnOS接口（定义见 `_analysis/API_SPEC.md` §9.2）：
///   · 改名   `POST /p/api/v1/ai-person/rename`
///            body `{"id": <personId>, "name": "..."}`
///   · 换封面 `POST /p/api/v1/ai-person/posterFromPhoto`
///            body `{"id": <personId>, "userPhotoId": <照片 id>}`
///
/// 交互：右上角「重命名」按钮改名；在照片墙上**长按**某张照片 → 设为封面。
class PersonDetailPage extends StatefulWidget {
  final PersonItem person;

  /// 列表页算好的展示名（未命名的人物会带序号，如「人物 3」）
  final String displayName;

  const PersonDetailPage({
    super.key,
    required this.person,
    required this.displayName,
  });

  @override
  State<PersonDetailPage> createState() => _PersonDetailPageState();
}

class _PersonDetailPageState extends State<PersonDetailPage> {
  late final ValueNotifier<String> _title;

  @override
  void initState() {
    super.initState();
    _title = ValueNotifier(widget.displayName);
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(s)));
  }

  // ─────────────────────────── 重命名 ───────────────────────────

  Future<void> _rename() async {
    final c = AppState.I.client;
    if (c == null) {
      _snack('尚未连接到 NAS');
      return;
    }
    final ctrl = TextEditingController(text: widget.person.name);
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('修改人物姓名',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 32,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            hintText: '输入姓名',
            prefixIcon: Icon(Icons.person_outline, color: FnosColors.textSub),
            counterText: '',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: FnosColors.textSub)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(72, 40)),
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (input == null) return;

    final name = input.trim();
    if (name.isEmpty) {
      _snack('姓名不能为空');
      return;
    }
    if (name == widget.person.name) return;

    try {
      await c.renamePerson(widget.person.id, name);
      if (!mounted) return;
      _title.value = name;
      _snack('已保存');
    } catch (e) {
      _snack('保存失败：$e');
    }
  }

  // ─────────────────────────── 设为封面 ───────────────────────────

  Future<void> _setCover(PhotoItem p) async {
    final c = AppState.I.client;
    if (c == null) {
      _snack('尚未连接到 NAS');
      return;
    }
    if (p.isVideo) {
      _snack('请长按一张照片来作为封面');
      return;
    }

    final ok = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '将这张照片设为「${_title.value}」的封面',
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: FnosColors.textMain),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.account_box_outlined,
                  color: FnosColors.primary),
              title: const Text('设为人物封面', style: TextStyle(fontSize: 15)),
              subtitle: Text(
                p.fileName.isEmpty ? '照片 #${p.id}' : p.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5),
              ),
              onTap: () => Navigator.pop(ctx, true),
            ),
            ListTile(
              leading: const Icon(Icons.close, color: FnosColors.textSub),
              title: const Text('取消', style: TextStyle(fontSize: 15)),
              onTap: () => Navigator.pop(ctx, false),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;

    try {
      await c.setPersonCover(widget.person.id, p.id);
      _snack('已设为封面');
    } catch (e) {
      _snack('设置封面失败：$e');
    }
  }

  // ─────────────────────────── 构建 ───────────────────────────

  @override
  Widget build(BuildContext context) {
    return PhotoGridPage(
      title: widget.displayName,
      titleListenable: _title,
      emptyText: '这个人名下暂无照片',
      onLongPress: _setCover,
      actions: [
        IconButton(
          tooltip: '重命名',
          onPressed: _rename,
          icon: const Icon(Icons.drive_file_rename_outline),
        ),
      ],
      loader: (offset, limit) async {
        if (offset > 0) return (list: const <PhotoItem>[], hasNext: false);
        final list =
            await AppState.I.client?.personPhotos(widget.person.id, limit: 2000) ??
                const <PhotoItem>[];
        return (list: list, hasNext: false);
      },
    );
  }
}
