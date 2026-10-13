# nas_album（Flutter 应用）

NAS相册（兼容 fnOS）的 Flutter 工程。**项目总说明请看上一级目录的
[README.md](../README.md)**。实现说明与构建 / 交付手册存于
本地（未随仓库分发）。

## 在 Windows 上构建

⚠️ **工程路径必须是纯 ASCII**。含中文的路径会让 Dart AOT 编译器
把路径编码成乱码而失败（`Unable to read file: ...\app.dill`）。

一键脚本（推荐，产物自动按版本号拷到桌面）：

```powershell
E:\Code\nas_album\build_apk.bat
```

手动等价方式：

```powershell
# 环境（按本机实际路径调整）
$env:FLUTTER_ROOT     = "D:\flutter"
$env:JAVA_HOME        = "D:\Android\Android Studio\jbr"
$env:ANDROID_HOME     = "D:\Android\Sdk"
$env:ANDROID_SDK_ROOT = "D:\Android\Sdk"

# 构建期参数（不入库；从 tool\secrets.example.json 复制后填写）
cd E:\Code\nas_album\app
dart tool\gen_secrets.dart

# 构建
flutter pub get
flutter build apk --release
```

> 若 `flutter build apk` 报 `CreateFile failed 231`（Dart 无法创建子进程），
> 改用 Gradle 直连：`cd android && .\gradlew.bat assembleRelease`。
> 版本号以 `android/local.properties` 为准（与 `pubspec.yaml`、
> `lib/core/app_info.dart` 三处同步，详见构建指南）。

产物：`build/app/outputs/flutter-apk/app-release.apk`

## 自检

```bash
flutter test      # 单元测试（签名 / 日期 / 模型 / 地址归一化 / 图片解码，共 26 项）
flutter analyze   # 应无 error 级问题（受限环境下会因 Dart 子进程问题崩溃，属环境限制）
```

## 目录

```
lib/core/     签名、HTTP 客户端、全局状态、偏好、主题、局域网扫描、本机媒体
lib/models/   数据模型（照片 / 相簿 / 人物 / 地点 / 场景）
lib/widgets/  带鉴权的图片组件、视频组件、删除确认弹窗
lib/pages/    各功能页面
```
