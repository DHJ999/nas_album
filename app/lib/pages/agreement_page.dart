import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';

/// 首次启动的合规门禁：同意《用户协议》与《隐私政策》后才能使用。
class AgreementPage extends StatefulWidget {
  final VoidCallback onAccepted;

  const AgreementPage({super.key, required this.onAccepted});

  @override
  State<AgreementPage> createState() => _AgreementPageState();
}

class _AgreementPageState extends State<AgreementPage> {
  bool _checked = false;

  void _open(String title, List<(String, String)> sections) {
    AgreementDetailPage.open(context, title: title, sections: sections);
  }

  @override
  Widget build(BuildContext context) {
    final bg = DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0, 0.42, 1],
          colors: [Color(0xFFDCEBFF), Color(0xFFF0F4FB), FnosColors.bg],
        ),
      ),
      child: SizedBox.expand(child: Container()),
    );

    return Scaffold(
      body: Stack(
        children: [
          bg,
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 26),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(22),
                          child: Image.asset('assets/logo.jpg',
                              width: 84, height: 84, fit: BoxFit.cover),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text('欢迎使用NAS相册',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: FnosColors.textMain)),
                      const SizedBox(height: 8),
                      const Text('开始之前，请阅读并同意以下条款',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 14, color: FnosColors.textSub)),
                      const SizedBox(height: 26),
                      Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(FnosRadius.card),
                        child: Column(children: [
                          _row(
                            icon: Icons.description_outlined,
                            title: '《用户协议》',
                            onTap: _openUser,
                          ),
                          const Padding(
                            padding: EdgeInsets.only(left: 56),
                            child: Divider(height: 0.6),
                          ),
                          _row(
                            icon: Icons.privacy_tip_outlined,
                            title: '《隐私政策》',
                            onTap: _openPrivacy,
                          ),
                        ]),
                      ),
                      const SizedBox(height: 18),
                      InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => setState(() => _checked = !_checked),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 30,
                                height: 30,
                                child: Checkbox(
                                  value: _checked,
                                  visualDensity: VisualDensity.compact,
                                  onChanged: (v) =>
                                      setState(() => _checked = v ?? false),
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Expanded(
                                child: Padding(
                                  padding: EdgeInsets.only(top: 4),
                                  child: Text(
                                    '我已阅读并同意《用户协议》和《隐私政策》',
                                    style: TextStyle(
                                        fontSize: 13.5,
                                        height: 1.5,
                                        color: FnosColors.textMain),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        height: 50,
                        child: FilledButton(
                          onPressed:
                              _checked ? () => widget.onAccepted() : null,
                          child: const Text('同意并继续'),
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextButton(
                        onPressed: _exit,
                        child: const Text('不同意',
                            style: TextStyle(
                                color: FnosColors.textSub, fontSize: 13.5)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) =>
      ListTile(
        onTap: onTap,
        leading: Icon(icon, color: FnosColors.textMain, size: 22),
        title: Text(title,
            style: const TextStyle(fontSize: 15, color: FnosColors.textMain)),
        trailing: const Icon(Icons.chevron_right,
            size: 20, color: FnosColors.textSub),
      );

  void _exit() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('无法继续使用',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        content: const Text('需要同意《用户协议》和《隐私政策》才能使用NAS相册。',
            style: TextStyle(fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('返回'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: FnosColors.danger,
              minimumSize: const Size(72, 40),
              shape: const StadiumBorder(),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              SystemNavigator.pop();
            },
            child: const Text('退出应用'),
          ),
        ],
      ),
    );
  }

  void _openUser() => _open('用户协议', kUserAgreement);
  void _openPrivacy() => _open('隐私政策', kPrivacyPolicy);
}

/// 协议正文页。被首启门禁与「设置 → 关于」共用。
class AgreementDetailPage extends StatelessWidget {
  final String title;
  final List<(String, String)> sections;

  const AgreementDetailPage(
      {super.key, required this.title, required this.sections});

  /// 便捷入口
  static Future<void> open(
    BuildContext context, {
    required String title,
    required List<(String, String)> sections,
  }) =>
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AgreementDetailPage(title: title, sections: sections),
      ));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          const Text('更新日期：2026 年 10 月 13 日',
              style: TextStyle(fontSize: 12.5, color: FnosColors.textSub)),
          const SizedBox(height: 18),
          for (final s in sections) ...[
            Text(s.$1,
                style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: FnosColors.textMain)),
            const SizedBox(height: 8),
            Text(s.$2,
                style: const TextStyle(
                    fontSize: 14,
                    height: 1.75,
                    color: FnosColors.textMain)),
            const SizedBox(height: 20),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────── 正文 ───────────────────────────

const List<(String, String)> kUserAgreement = [
  (
    '一、关于本应用',
    'NAS相册（以下简称「本应用」）是由个人开发者提供的非官方第三方客户端，'
        '用于连接并浏览你自己拥有的、运行 fnOS 的私有云 NAS 上的照片与视频。'
        '本应用与设备厂商无隶属或合作关系，也未获得任何授权，不提供任何云端存储服务。'
        '使用本应用即表示你声明：仅将其用于连接你本人拥有或经授权管理的设备，'
        '并且你对设备及其系统的使用符合设备厂商的最终用户许可协议。',
  ),
  (
    '二、账号与服务器',
    '你需要在登录页填写自己的 NAS 地址与端口、用户名与密码。'
        '这些信息仅用于向你的 NAS 发起登录请求，其中密码是否在本机保存，'
        '由你在登录页的「记住密码」开关自行决定。',
  ),
  (
    '三、使用规范',
    '你应确保对所连接的 NAS 设备及其中内容拥有合法访问权限，'
        '不得利用本应用访问、传播他人隐私或违反法律法规的内容。'
        '因账号出借、设备共享造成的损失由你自行承担。',
  ),
  (
    '四、数据与备份',
    '本应用仅作为浏览与管理的工具，不对你的数据做云端备份。'
        '涉及删除的操作（移入回收站、删除本机副本）请在操作前确认，'
        '建议重要数据保留独立的备份方案。',
  ),
  (
    '五、免责声明',
    '本应用按「现状」提供。因网络环境、NAS 固件版本变更、接口调整'
        '导致的功能异常，开发者不承担由此产生的间接损失。'
        '我们会尽力修复问题，但不承诺零缺陷。',
  ),
  (
    '六、免费与协议变更',
    '本应用完全免费，无广告、无内购、无任何形式的收费功能。'
        '本协议可能会随功能调整而更新，更新后将在本页面展示。'
        '继续使用即视为接受更新后的条款。',
  ),
];

const List<(String, String)> kPrivacyPolicy = [
  (
    '一、我们收集什么',
    '本应用不设自有服务器，不会把你的任何信息上传给第三方，'
        '也不包含广告 SDK 与用户行为统计 SDK。',
  ),
  (
    '二、信息如何存储',
    '① NAS 地址、端口、用户名、访问码：保存在本机应用的私有存储中，'
        '用于下次免输。\n'
        '② 密码：仅在你勾选「记住密码」时才会写入本机私有存储；'
        '未勾选时密码只存在于本次运行的进程内存中，应用退出即丢弃。\n'
        '③ 登录令牌（token）：保存在本机私有存储中，用于免登录。',
  ),
  (
    '三、手机相册权限',
    '为了让「删除 NAS 照片时同步删除手机上的同名副本」这一功能可用，'
        '本应用会申请读取（并在你确认删除时写入）本机照片与视频的权限。\n'
        '该权限仅用于按文件名匹配你明确选择要删除的那些文件，'
        '不会扫描上传你的相册内容，也不会读取照片的地理位置信息。\n'
        '你可以随时在系统设置中关闭该权限，'
        '关闭后仅「同步删除本机副本」功能不可用，其他功能不受影响。',
  ),
  (
    '四、网络访问',
    '本应用只与你填写的 NAS 地址通信。'
        '当图片、视频通过局域网传输时，'
        '数据在你自己控制的链路中传输，我们不中转、不记录。',
  ),
  (
    '五、删除与退出',
    '在「设置 → 退出登录」后，本机会清除保存的令牌与（若勾选过的）密码。'
        '卸载应用即删除本应用在本机的全部数据。',
  ),
  (
    '六、未成年人保护',
    '若你是未成年人，请在监护人陪同下阅读本政策并使用本应用。',
  ),
  (
    '七、联系我们',
    '如对本政策有疑问，可通过邮箱联系开发者：hjd2002@yeah.net。\n'
        '我们会在收到邮件后尽快回复。',
  ),
];
