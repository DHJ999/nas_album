import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_info.dart';
import '../core/theme.dart';
import 'agreement_page.dart';

/// 「关于」页：版本信息、协议正文入口、开发者联系方式。
///
/// 登录页右上角齿轮进入。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SizedBox(height: 28),
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Image.asset('assets/logo.jpg',
                  width: 84, height: 84, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 14),
          const Center(
            child: Text(AppInfo.appName,
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: FnosColors.textMain)),
          ),
          const SizedBox(height: 6),
          const Center(
            child: Text('版本 ${AppInfo.version}',
                style: TextStyle(fontSize: 13, color: FnosColors.textSub)),
          ),
          const SizedBox(height: 6),
          const Center(
            child: Text('非官方第三方客户端 · 与设备厂商无隶属关系 · 仅限自有或授权管理的设备使用',
                style: TextStyle(fontSize: 12, color: FnosColors.textSub)),
          ),
          const SizedBox(height: 26),
          _group([
            _tile(
              context,
              icon: Icons.description_outlined,
              title: '用户协议',
              onTap: () => AgreementDetailPage.open(context,
                  title: '用户协议', sections: kUserAgreement),
            ),
            _tile(
              context,
              icon: Icons.privacy_tip_outlined,
              title: '隐私政策',
              onTap: () => AgreementDetailPage.open(context,
                  title: '隐私政策', sections: kPrivacyPolicy),
            ),
          ]),
          const SizedBox(height: 14),
          _group([
            _tile(
              context,
              icon: Icons.mail_outline,
              title: '联系开发者',
              subtitle: AppInfo.contactEmail,
              trailing: IconButton(
                tooltip: '复制邮箱',
                icon: const Icon(Icons.copy_rounded,
                    size: 18, color: FnosColors.textSub),
                onPressed: () async {
                  await Clipboard.setData(
                      const ClipboardData(text: AppInfo.contactEmail));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('邮箱已复制')),
                  );
                },
              ),
              onTap: () async {
                await Clipboard.setData(
                    const ClipboardData(text: AppInfo.contactEmail));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('邮箱已复制')),
                );
              },
            ),
          ]),
          const SizedBox(height: 22),
          const Center(
            child: Text('本应用不联网上传任何数据\n所有信息仅保存在你的手机与你的 NAS 上',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12, height: 1.7, color: FnosColors.textSub)),
          ),
        ],
      ),
    );
  }

  static Widget _group(List<Widget> children) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(FnosRadius.card),
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      );

  static Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
    required VoidCallback onTap,
  }) =>
      ListTile(
        onTap: onTap,
        leading: Icon(icon, size: 21, color: FnosColors.textMain),
        title: Text(title,
            style: const TextStyle(fontSize: 15, color: FnosColors.textMain)),
        subtitle: subtitle == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(subtitle,
                    style: const TextStyle(
                        fontSize: 12.5, color: FnosColors.textSub)),
              ),
        trailing: trailing ??
            const Icon(Icons.chevron_right,
                size: 20, color: FnosColors.textSub),
      );
}
