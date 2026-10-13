import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_info.dart';
import '../core/theme.dart';

/// 「查看已下载数据」：列出本应用保存到手机私有目录的文件。
///
/// 对应看图页右上角的「保存到本机」，文件落在
/// `<应用文档目录>/nas_album/` 下，这里读回来展示与清理。
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  bool _loading = true;
  Directory? _dir;
  List<FileSystemEntity> _files = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Directory> _targetDir() async {
    final base = await getApplicationDocumentsDirectory();
    return Directory('${base.path}/${AppInfo.downloadDirName}');
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final d = await _targetDir();
      if (!await d.exists()) {
        if (!mounted) return;
        setState(() {
          _dir = d;
          _files = const [];
          _loading = false;
        });
        return;
      }
      final list = d.listSync()..sort((a, b) {
          final am = a.statSync().modified;
          final bm = b.statSync().modified;
          return bm.compareTo(am);
        });
      final files =
          list.whereType<File>().map<FileSystemEntity>((e) => e).toList();
      if (!mounted) return;
      setState(() {
        _dir = d;
        _files = files;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _files = const [];
        _loading = false;
      });
    }
  }

  int get _totalBytes {
    var sum = 0;
    for (final f in _files) {
      try {
        sum += (f as File).lengthSync();
      } catch (_) {/* 忽略单个文件读取失败 */}
    }
    return sum;
  }

  String _fmt(int b) {
    if (b <= 0) return '0 B';
    const u = ['B', 'KB', 'MB', 'GB'];
    var v = b.toDouble();
    var i = 0;
    while (v >= 1024 && i < u.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${u[i]}';
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(s)));
  }

  Future<bool> _confirm(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        content: Text(body, style: const TextStyle(fontSize: 14, height: 1.6)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消',
                style: TextStyle(color: FnosColors.textSub)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: FnosColors.danger,
              minimumSize: const Size(72, 40),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  Future<void> _deleteOne(FileSystemEntity f) async {
    final name = f.path.split(Platform.pathSeparator).last;
    if (!await _confirm('删除文件', '将从本机删除「$name」，且不可恢复。')) return;
    try {
      await f.delete();
      await _load();
      _snack('已删除 $name');
    } catch (e) {
      _snack('删除失败：$e');
    }
  }

  Future<void> _clearAll() async {
    if (_files.isEmpty) return;
    if (!await _confirm('清空本机数据', '将删除应用保存的全部 ${_files.length} 个文件，且不可恢复。')) {
      return;
    }
    var fail = 0;
    for (final f in _files) {
      try {
        await f.delete();
      } catch (_) {
        fail++;
      }
    }
    await _load();
    _snack(fail == 0 ? '已清空' : '已清空，$fail 个文件删除失败');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('已下载数据'),
        actions: [
          if (_files.isNotEmpty)
            IconButton(
              tooltip: '清空',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _clearAll,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _header(),
                const Divider(height: 0.6),
                Expanded(
                  child: _files.isEmpty ? _empty() : _list(),
                ),
              ],
            ),
    );
  }

  Widget _header() => Container(
        width: double.infinity,
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        child: Row(
          children: [
            const Icon(Icons.folder_outlined,
                size: 20, color: FnosColors.textSub),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _dir == null ? '本机目录' : '${_dir!.path.split(Platform.pathSeparator).last}/',
                style: const TextStyle(fontSize: 13, color: FnosColors.textSub),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '${_files.length} 项 · ${_fmt(_totalBytes)}',
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: FnosColors.textMain),
            ),
          ],
        ),
      );

  Widget _empty() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined,
                size: 56, color: FnosColors.textSub.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            const Text('还没有保存过文件',
                style: TextStyle(fontSize: 15, color: FnosColors.textMain)),
            const SizedBox(height: 6),
            const Text('在看图页点右上角的「保存到本机」即可',
                style: TextStyle(fontSize: 13, color: FnosColors.textSub)),
          ],
        ),
      );

  Widget _list() => ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: _files.length,
        separatorBuilder: (_, __) => const Padding(
          padding: EdgeInsets.only(left: 68),
          child: Divider(height: 0.6),
        ),
        itemBuilder: (context, i) {
          final f = _files[i] as File;
          final name = f.path.split(Platform.pathSeparator).last;
          int size = 0;
          DateTime? mod;
          try {
            final st = f.statSync();
            size = st.size;
            mod = st.modified;
          } catch (_) {/* 忽略 */}
          final isVideo = RegExp(r'\.(mp4|mov|mkv|avi|webm|3gp)$',
                  caseSensitive: false)
              .hasMatch(name);
          return ListTile(
            tileColor: Colors.white,
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: FnosColors.field,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(
                  isVideo ? Icons.videocam_outlined : Icons.image_outlined,
                  size: 20,
                  color: FnosColors.textSub),
            ),
            title: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14.5)),
            subtitle: Text(
              [
                _fmt(size),
                if (mod != null)
                  '${mod.year}-${_2(mod.month)}-${_2(mod.day)} '
                      '${_2(mod.hour)}:${_2(mod.minute)}',
              ].join('  ·  '),
              style: const TextStyle(fontSize: 12, color: FnosColors.textSub),
            ),
            trailing: IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline,
                  size: 20, color: FnosColors.textSub),
              onPressed: () => _deleteOne(f),
            ),
          );
        },
      );

  static String _2(int n) => n.toString().padLeft(2, '0');
}
