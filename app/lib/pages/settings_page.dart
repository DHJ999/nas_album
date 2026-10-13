import 'package:flutter/material.dart';

import '../core/app_info.dart';
import '../core/app_state.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../widgets/fnos_image.dart';
import 'agreement_page.dart';

/// 「更多」页风格的分组圆角白卡
class _CardGroup extends StatelessWidget {
  final List<Widget> children;
  const _CardGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(FnosRadius.card),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: _separated(children)),
    );
  }

  static List<Widget> _separated(List<Widget> list) => [
        for (var i = 0; i < list.length; i++) ...[
          if (i > 0)
            const Padding(
              padding: EdgeInsets.only(left: 56),
              child: Divider(),
            ),
          list[i],
        ],
      ];
}

class _GroupTitle extends StatelessWidget {
  final String text;
  const _GroupTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(text,
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: FnosColors.textSub)),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? _user;
  List<PhotoFolder> _folders = const [];
  bool _loading = true;

  bool _autoVideo = false;
  bool _autoAnim = true;
  String _downloadPath = AppPrefs.defaultDownloadRelativePath;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final c = AppState.I.client;
    final av = await AppPrefs.autoPlayVideo();
    final aa = await AppPrefs.autoPlayAnim();
    final dp = await AppPrefs.downloadRelativePath();
    if (!mounted) return;
    setState(() {
      _autoVideo = av;
      _autoAnim = aa;
      _downloadPath = dp;
    });
    if (c == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final u = await c.userInfo();
      final f = await c.folders();
      if (mounted) {
        setState(() {
          _user = u;
          _folders = f;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 统一样式的开关行（与fnOS App 的分组卡一致）
  Widget _switchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      secondary: Icon(icon, size: 22),
      activeThumbColor: FnosColors.primary,
      title: Text(title, style: const TextStyle(fontSize: 15)),
      subtitle: Text(subtitle,
          style: const TextStyle(fontSize: 12.5, color: FnosColors.textSub)),
    );
  }

  /// 编辑「下载到系统相册」的目标目录。
  /// 目录由「父目录（DCIM/Pictures/Movies）+ 文件夹名」拼成 MediaStore
  /// 的 RELATIVE_PATH，例如 DCIM/NAS相册下载。
  Future<void> _editDownloadPath() async {
    // 拆出当前父目录与文件夹名
    const parents = ['DCIM', 'Pictures', 'Movies'];
    var parts = _downloadPath.split('/');
    var parent = parents.contains(parts.first) ? parts.first : 'DCIM';
    var folder = parts.length > 1 ? parts.sublist(1).join('/') : 'NAS相册下载';
    final controller = TextEditingController(text: folder);

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('下载位置',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('保存到系统相册的位置',
                  style: TextStyle(fontSize: 13, color: FnosColors.textSub)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final p in parents)
                    ChoiceChip(
                      label: Text(p),
                      selected: parent == p,
                      onSelected: (_) => setLocal(() => parent = p),
                      selectedColor: const Color(0x142B7FFF),
                      labelStyle: TextStyle(
                        fontSize: 13,
                        color: parent == p
                            ? FnosColors.primary
                            : FnosColors.textMain,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: false,
                decoration: const InputDecoration(
                  labelText: '文件夹名',
                  hintText: 'NAS相册下载',
                ),
                onChanged: (v) => setLocal(() => folder = v),
              ),
              const SizedBox(height: 10),
              Text('将保存到 $parent/${folder.isEmpty ? 'NAS相册下载' : folder}',
                  style: const TextStyle(
                      fontSize: 12.5, color: FnosColors.textSub)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child:
                  const Text('取消', style: TextStyle(color: FnosColors.textSub)),
            ),
            FilledButton(
              onPressed: () async {
                final f = controller.text.trim().isEmpty
                    ? 'NAS相册下载'
                    : controller.text.trim();
                final path = '$parent/$f';
                await AppPrefs.setDownloadRelativePath(path);
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                if (mounted) setState(() => _downloadPath = path);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final s = AppState.I.session;
    final totalPhoto = _folders.fold<int>(0, (a, b) => a + b.photoCount);
    final totalVideo = _folders.fold<int>(0, (a, b) => a + b.videoCount);

    return Scaffold(
      appBar: FnosLargeTitle(text: '设置'),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const SizedBox(height: 12),
          // ── 用户信息卡 ──
          _CardGroup(children: [
            ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              leading: CircleAvatar(
                radius: 24,
                backgroundColor: const Color(0x142B7FFF),
                child: Text(
                  (s?.userName.isNotEmpty ?? false)
                      ? s!.userName.substring(0, 1).toUpperCase()
                      : '?',
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: FnosColors.primary),
                ),
              ),
              title: Text(s?.userName ?? '未登录',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: FnosColors.textMain)),
              subtitle: Text(_user?['isAdmin'] == true ? '管理员' : '普通用户',
                  style: const TextStyle(
                      fontSize: 12.5, color: FnosColors.textSub)),
            ),
          ]),

          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            const _GroupTitle('统计'),
            _CardGroup(children: [
              ListTile(
                leading: const Icon(Icons.photo_outlined, size: 22),
                title: const Text('照片总数', style: TextStyle(fontSize: 15)),
                trailing: Text('$totalPhoto',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: FnosColors.textSub)),
              ),
              ListTile(
                leading: const Icon(Icons.videocam_outlined, size: 22),
                title: const Text('视频总数', style: TextStyle(fontSize: 15)),
                trailing: Text('$totalVideo',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: FnosColors.textSub)),
              ),
            ]),
          ],

          const _GroupTitle('播放'),
          _CardGroup(children: [
            _switchTile(
              icon: Icons.play_circle_outline,
              title: '自动播放视频',
              subtitle: '大图查看时滑到视频就直接开始播放',
              value: _autoVideo,
              onChanged: (v) async {
                setState(() => _autoVideo = v);
                await AppPrefs.setAutoPlayVideo(v);
              },
            ),
            _switchTile(
              icon: Icons.motion_photos_on_outlined,
              title: '自动播放动图',
              subtitle: '打开实况照片 / 动图时自动播放一遍',
              value: _autoAnim,
              onChanged: (v) async {
                setState(() => _autoAnim = v);
                await AppPrefs.setAutoPlayAnim(v);
              },
            ),
          ]),

          const _GroupTitle('下载'),
          _CardGroup(children: [
            ListTile(
              leading: const Icon(Icons.download_for_offline_outlined, size: 22),
              title: const Text('下载位置', style: TextStyle(fontSize: 15)),
              subtitle: Text(_downloadPath,
                  style: const TextStyle(
                      fontSize: 12.5, color: FnosColors.textSub)),
              trailing: const Icon(Icons.chevron_right,
                  size: 20, color: FnosColors.textSub),
              onTap: _editDownloadPath,
            ),
          ]),

          const _GroupTitle('连接'),
          _CardGroup(children: [
            ListTile(
              leading: const Icon(Icons.dns_outlined, size: 22),
              title: const Text('服务器', style: TextStyle(fontSize: 15)),
              subtitle: Text(
                  s == null
                      ? '-'
                      : '${s.host}${s.useTls ? "  (HTTPS)" : ""}',
                  style: const TextStyle(
                      fontSize: 12.5, color: FnosColors.textSub)),
            ),
            ListTile(
              leading: Icon(Icons.logout,
                  size: 22, color: FnosColors.danger),
              title: Text('退出登录',
                  style: const TextStyle(
                      fontSize: 15, color: FnosColors.danger)),
              onTap: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    title: const Text('退出登录'),
                    content: const Text('确定要退出当前账号吗？'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消')),
                      FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: FnosColors.danger,
                            minimumSize: const Size(72, 40),
                            shape: const StadiumBorder(),
                          ),
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('退出')),
                    ],
                  ),
                );
                if (ok == true) {
                  clearImageCache();
                  await AppState.I.logout();
                }
              },
            ),
          ]),

          const _GroupTitle('关于'),
          _CardGroup(children: [
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined, size: 22),
              title: const Text('用户协议与隐私政策',
                  style: TextStyle(fontSize: 15)),
              trailing: const Icon(Icons.chevron_right,
                  size: 20, color: FnosColors.textSub),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => _LegalPage(),
              )),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline, size: 22),
              title: const Text('版本', style: TextStyle(fontSize: 15)),
              trailing: Text('v${AppInfo.version}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: FnosColors.textSub)),
            ),
          ]),

          const SizedBox(height: 28),
          Center(
            child: Text('${AppInfo.appName} v${AppInfo.version}\n基于 fnOS 相册接口实现',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12, color: FnosColors.textSub)),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// 协议与政策入口（复用首启门禁里的正文）
class _LegalPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('用户协议与隐私政策')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          const Text('更新日期：2026 年 10 月 13 日',
              style: TextStyle(fontSize: 12.5, color: FnosColors.textSub)),
          const SizedBox(height: 18),
          const Text('用户协议',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: FnosColors.textMain)),
          const SizedBox(height: 14),
          for (final s in kUserAgreement) ...[
            Text(s.$1,
                style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: FnosColors.textMain)),
            const SizedBox(height: 8),
            Text(s.$2,
                style: const TextStyle(
                    fontSize: 14, height: 1.75, color: FnosColors.textMain)),
            const SizedBox(height: 20),
          ],
          const SizedBox(height: 8),
          const Divider(),
          const SizedBox(height: 20),
          const Text('隐私政策',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: FnosColors.textMain)),
          const SizedBox(height: 14),
          for (final s in kPrivacyPolicy) ...[
            Text(s.$1,
                style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: FnosColors.textMain)),
            const SizedBox(height: 8),
            Text(s.$2,
                style: const TextStyle(
                    fontSize: 14, height: 1.75, color: FnosColors.textMain)),
            const SizedBox(height: 20),
          ],
        ],
      ),
    );
  }
}
