# NAS Album

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
  <a href="README.md">中文</a> · <b>English</b>
</p>

> ⚠️ Unofficial third-party project. Provided by an individual developer, with no affiliation,
> partnership, or authorization relationship with any device vendor. Use it only to connect to
> devices you own or are authorized to manage, and comply with the vendor's end-user license
> agreement. Product names and trademarks such as fnOS remain the property of their respective
> owners; this repository grants no trademark license.

NAS Album is an Android gallery client that connects to your own NAS and is compatible with the fnOS photo API. Photos and videos travel only between your phone and your NAS — never through any third-party server.

## ✨ Features

### 🖼️ Full-screen viewing

- **Swipe up/down to page**: when viewing an image full-screen, swipe vertically to move between photos.
- **Swipe left for details**: drag the info card in from the right edge to see capture time, camera model, aperture, shutter speed, ISO, focal length, exposure program, metering mode, location, resolution, file size, and file path. Swipe right or tap the scrim to dismiss.
- **Swipe right to go back**: swipe right to exit to the grid, which automatically repositions to the last photo you were viewing.
- **Pinch and double-tap to zoom**: drag with one finger to inspect details once zoomed. While zoomed, paging and edge-swipe gestures are intentionally released to avoid accidental triggers.
- **Live Photos**: plays once automatically on open, with one-tap replay.
- **Video playback**: inline playback, seek bar, pause/resume, and full screen. Adjacent videos are pre-warmed so playback starts instantly when you reach them.
- **Quality switching**: medium quality is used by default to save bandwidth on both the phone and the NAS; switch to the original file in one tap when needed.

### 🗂️ Library and categories

- Two layouts — timeline and edge-to-edge grid — grouped by day, with an adaptive grid, pull-to-refresh, and infinite scroll.
- Long-press to enter multi-select for batch download or batch delete; the timeline layout supports selecting a whole day.
- **Albums**: browse by the albums that already exist on your NAS.
- **People**: shows the on-device face clustering results; rename a person or set a photo as their cover.
- **Places**: GPS photos aggregated by city; tap through to see everything from that place.
- **Videos / Photos**: filter quickly by media type.
- People, Places, Videos, and Photos sit at the same level — swipe left/right to switch, with uniform card sizes.

### 🧹 Management

- Deletion moves items to the NAS recycle bin by default, restorable from the NAS web UI.
- Optionally delete the local copy on the phone at the same time.
- Downloads are saved to the system gallery, with a configurable directory (default `DCIM/NAS相册下载`).

### 🔒 Connection and privacy

- Supports LAN IP or domain name plus a custom port; the app ships with no default port.
- Supports both HTTP and HTTPS, with one-tap trust for self-signed certificates.
- Supports NAS access-code gating; the prompt appears only when required and the code is remembered afterwards.
- **Discover devices on LAN**: scans the current subnet and fills in the address automatically.
- Remembers passwords, address history, and silently re-authenticates when a token expires.
- No self-hosted server of any kind; photos, videos, and credentials are never uploaded anywhere.
- No ads, no in-app purchases, no behavioral analytics SDKs.

## 📱 Platform and compatibility

- Android (built with Flutter), supporting Android 7.0+ (API 24).
- Works in both portrait and landscape; the UI follows the system auto-rotate setting.
- Intended only for NAS devices you own or are authorized to manage.
- Unofficial third-party client with no affiliation, partnership, or authorization from any device vendor.

## 📦 Installation

1. Download the latest APK from the [Releases](https://github.com/DHJ999/nas_album/releases/latest) page.
2. On first launch, read and accept the user agreement and privacy policy.
3. Enter your NAS address, port, username, and password; if the NAS is protected by an access code, enter it when prompted.

## 🛠️ Building from source

The source is built with Flutter. Environment requirements and build steps are documented in [`app/README.md`](app/README.md). Some API parameters are injected at build time and are not distributed with the repository.

## 📄 License

[PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0), full terms in [LICENSE](LICENSE), copyright © 2026 DHJ999.

> This license permits personal, noncommercial use, modification, and sharing.
> **Any commercial use requires prior written permission.**
> It grants no trademark rights and comes with no warranty.

---

The official fnOS Photos standalone App is out, and I'm no longer maintaining this project.
