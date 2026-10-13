# NAS相册

[![License](https://img.shields.io/badge/License-PolyForm%20NC-blue.svg)](LICENSE)

兼容 fnOS 私有云的第三方相册客户端（Android）。

> ⚠️ 非官方第三方作品，由个人开发者提供，与设备厂商无隶属、合作或授权关系；
> 仅用于连接你本人拥有或经授权管理的设备，使用须自行符合设备厂商的最终用户许可协议；
> fnOS 等产品名及商标均为其各自权利人的财产，本仓库不授予任何商标许可。

## 技术栈

- 语言 / 框架：Dart · Flutter 3.44+，仅 Android
- 依赖与实现见 `app/pubspec.yaml` 与 `app/lib/`；接口参数构建期注入，不随仓库分发
- 应用包名：`com.github.dhj999.nasalbum`

## 目录结构

```
app/
├── tool/        构建期参数生成脚本（secrets.json 不入库）
├── lib/core/    网络客户端、签名、全局状态、偏好、主题、本机媒体
├── lib/models/  数据模型
├── lib/widgets/ 通用组件
└── lib/pages/   功能页面
```

## 构建

```bash
cd app
dart tool/gen_secrets.dart    # 需先准备 tool/secrets.json（参考 secrets.example.json）
flutter pub get
flutter build apk --release
```

产物：`build/app/outputs/flutter-apk/app-release.apk`。
构建环境要求与常见问题见 [app/README.md](app/README.md)。

## 许可证

[PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0)（非商业许可），完整条款见 [LICENSE](LICENSE)，版权 © 2026 DHJ999。
