/// 应用元信息 —— 版本号与联系方式统一放这里，避免各处硬编码不一致。
library;

class AppInfo {
  /// 与 pubspec.yaml 的 versionName 保持一致
  static const String version = '1.1.3';

  /// 隐私政策中公示的联系邮箱
  static const String contactEmail = 'hjd2002@yeah.net';

  static const String appName = 'NAS相册';

  /// 本机保存「从 NAS 下载到手机」的文件目录名（位于应用私有文档目录下）
  static const String downloadDirName = 'nas_album';
}
