# NAS相册

<p align="center">
  <a href="https://github.com/DHJ999/nas_album/releases/latest"><img src="https://img.shields.io/github/v/release/DHJ999/nas_album?style=flat-square&amp;label=release&amp;color=2ea44f" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-PolyForm%20NC-blue?style=flat-square" alt="License"></a>
  <img src="https://img.shields.io/badge/platform-Android%207.0%2B-3DDC84?style=flat-square&amp;logo=android&amp;logoColor=white" alt="Platform">
  <img src="https://img.shields.io/badge/Flutter-3.44.9-02569B?style=flat-square&amp;logo=flutter&amp;logoColor=white" alt="Flutter">
  <br>
  <img src="https://img.shields.io/github/downloads/DHJ999/nas_album/total?style=flat-square&amp;label=downloads&amp;color=orange" alt="Downloads">
  <img src="https://img.shields.io/github/stars/DHJ999/nas_album?style=flat-square&amp;label=stars&amp;color=yellow" alt="Stars">
  <img src="https://img.shields.io/github/last-commit/DHJ999/nas_album?style=flat-square&amp;label=last%20commit" alt="Last commit">
  <img src="https://img.shields.io/badge/data-stays%20local-success?style=flat-square" alt="Data stays local">
</p>

<p align="center">
  <b>中文</b> · <a href="README_EN.md">English</a>
</p>

> ⚠️ 非官方第三方作品，由个人开发者提供，与设备厂商无隶属、合作或授权关系；
> 仅用于连接你本人拥有或经授权管理的设备，使用须自行符合设备厂商的最终用户许可协议；
> fnOS 等产品名及商标均为其各自权利人的财产，本仓库不授予任何商标许可。

NAS相册是一款连接你自己 NAS 的 Android 相册客户端，兼容 fnOS 相册接口。照片与视频只在手机和你的 NAS 之间传输，不经过任何第三方服务器。

## ✨ 功能特色

### 🖼️ 全屏浏览

- **上下滑动翻页**：全屏看大图时，上下滑动即可切换上一张 / 下一张。
- **左滑查看图片信息**：从右侧跟手拉出信息卡片，展示拍摄时间、机型、光圈、快门、感光度、焦距、曝光程序、测光模式、拍摄位置、分辨率、文件大小与文件路径；右滑或点遮罩收起。
- **右滑返回**：从照片墙进入后，右滑即可退出，回到照片墙时会自动定位到最后看过的那一张。
- **双指缩放 / 双击缩放**：放大后可单指拖动查看细节；放大状态下自动让出翻页与侧滑手势，避免误触。
- **实况照片**：进入即自动播放一遍，可一键重播。
- **视频播放**：内联播放、进度拖动、暂停 / 继续、全屏播放；相邻视频会提前预热，翻过去即可开播。
- **清晰度切换**：默认使用中等清晰度以节省流量与 NAS 带宽，需要时一键切换「原图」。

### 🗂️ 图库与分类

- 时间轴 / 铺满两种显示样式，按天分组、自适应网格，支持下拉刷新与触底分页。
- 长按进入多选，可批量下载、批量删除；时间轴样式支持按天全选。
- **相册**：按 NAS 上已有的相簿分类浏览。
- **人物**：展示设备端人脸聚类结果，支持重命名人物、把某张照片设为封面。
- **地点**：按城市聚合 GPS 照片，点进去查看该地点全部内容。
- **视频 / 图片**：按媒体类型快速筛选。
- 人物 / 地点 / 视频 / 图片 为同级分类，左右滑动即可切换，卡片尺寸统一。

### 🧹 管理

- 删除默认移入 NAS 回收站，可在 NAS 网页端还原。
- 可选「同时删除手机上的本地副本」。
- 下载保存到系统相册，目录可自定义（默认 `DCIM/NAS相册下载`）。

### 🔒 连接与隐私

- 支持局域网 IP / 域名 + 自定义端口，App 不内置任何默认端口。
- 支持 HTTP 与 HTTPS；自签名证书可一键信任。
- 支持 NAS 访问码门禁，登录时按需弹出输入框并记住。
- 「发现局域网内设备」：扫描当前网段并自动填入地址。
- 记住密码、地址历史、登录令牌失效后自动静默重登。
- 不设自有服务器，不上传照片、视频或账号信息。
- 无广告、无内购、无行为统计 SDK。

## 📱 平台与兼容性

- Android（Flutter 构建），支持 Android 7.0+（API 24）。
- 横竖屏均可用，界面随系统自动旋转适配。
- 仅用于连接你本人拥有或经授权管理的 NAS 设备。
- 非官方第三方客户端，与设备厂商无隶属、合作或授权关系。

## 📦 安装

1. 在 [Releases](https://github.com/DHJ999/nas_album/releases/latest) 页面下载最新 APK。
2. 首次启动阅读并同意用户协议与隐私政策。
3. 填写 NAS 地址、端口、账号与密码；如 NAS 开启了访问码门禁，按提示输入访问码。

## 🛠️ 从源码构建

源码使用 Flutter 构建，环境要求与构建步骤见 [`app/README.md`](app/README.md)。为保证兼容性，部分接口参数在构建期注入，不随仓库分发。

## 📄 许可证

[PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0)（非商业许可），完整条款见 [LICENSE](LICENSE)，版权 © 2026 DHJ999。

> 本许可允许个人非商业使用、修改与分享；**任何商业用途须事先获得书面授权**。
> 本许可不授予商标许可，亦不附带任何担保。
