// NAS相册的冒烟测试：确认签名算法与数据模型在纯 Dart 环境下行为正确。
//
// 网络相关逻辑不在此测试（需要真实 NAS）。

import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_album/core/app_state.dart';
import 'package:nas_album/core/fnos_crypto.dart';
import 'package:nas_album/models/models.dart';
import 'package:nas_album/widgets/fnos_image.dart';

void main() {
  group('签名算法', () {
    test('构建期注入的签名参数格式正确', () {
      expect(kSignSalt.length, greaterThanOrEqualTo(16));
      expect(kPhotoApiKey, matches(RegExp(r'^[0-9A-F\-]{36}$')));
    });

    test('空参数的 a 分量为 md5("")', () {
      expect(paramContentForGet(null), 'd41d8cd98f00b204e9800998ecf8427e');
      expect(paramContentForGet({}), 'd41d8cd98f00b204e9800998ecf8427e');
      expect(paramContentForPost(null), 'd41d8cd98f00b204e9800998ecf8427e');
    });

    test('含空格的日期参数与实测服务端校验通过的值一致', () {
      final a = paramContentForGet({
        'limit': '1', 'offset': '0',
        'start_time': '2016:01:01 00:00:00',
        'end_time': '2026:12:31 23:59:59',
        'album_id': '0', 'is_collect': '0',
      });
      expect(a, 'c8c4f4e6ed4d77b89ddd1a29ae38b808');
    });

    test('完整 authx 与实测值一致', () {
      final authx = buildAuthx(
        method: 'GET',
        path: '/p/api/v1/user/info',
        nonce: '123456',
        timestamp: '1791536000000',
      );
      expect(authx,
          'nonce=123456&timestamp=1791536000000&'
          'sign=2808d980f6634f73b1676c8410d28150');
    });

    test('nonce 恒为 6 位数字', () {
      for (var i = 0; i < 200; i++) {
        final n = genNonce();
        expect(n.length, 6);
        expect(int.parse(n), inInclusiveRange(100000, 999999));
      }
    });
  });

  group('日期格式', () {
    test('输出 fnOS 冒号格式', () {
      expect(formatFnosDate(DateTime(2026, 10, 9, 12, 58, 48)),
          '2026:10:09 12:58:48');
    });

    test('解析 fnOS 冒号格式', () {
      final d = parseFnosDate('2026:10:09 12:58:48');
      expect(d, isNotNull);
      expect(d!.year, 2026);
      expect(d.month, 10);
      expect(d.day, 9);
      expect(d.hour, 12);
    });
  });

  group('数据模型', () {
    test('实况照片识别（isLive=2 是设备端的实际取值）', () {
      PhotoItem p(int live) => PhotoItem(
            id: 1, ownerId: 0, dateTime: '', photoDateTime: '',
            timeZoneOffset: 0, fileType: 'jpeg', isRaw: false,
            category: 'photo', specialType: 0, fileName: '', fileSize: 0,
            description: '', isCollect: 0, mp: '', filePath: '',
            height: 1, width: 1, flash: -1, isLive: live, rotation: 0,
            isCanPreview: 1, thumbnailStatus: 0,
            thumb: const ThumbUrls(), photoUUID: '',
          );
      expect(p(0).isLivePhoto, isFalse);
      expect(p(1).isLivePhoto, isTrue);
      expect(p(2).isLivePhoto, isTrue);
    });

    test('地点聚类解析（explore/geos 实测结构）', () {
      final g = GeoCluster.fromJson({
        'country': '中国', 'city': '菏泽市', 'itemCount': 526,
        'posterUrl': '/p/api/v1/stream/p/t/8264/s/uuid',
      });
      expect(g.city, '菏泽市');
      expect(g.itemCount, 526);
      expect(g.posterUrl.isNotEmpty, isTrue);
    });

    test('场景标签解析（容错字段名）', () {
      final t = SceneTag.fromJson({'name': '草地', 'itemCount': 12});
      expect(t.name, '草地');
      expect(t.itemCount, 12);
    });

    test('照片拍摄参数与位置解析（gallery/getList 实测字段）', () {
      final p = PhotoItem.fromJson({
        'id': 8408,
        'dateTime': '2026:10:09 10:00:36',
        'photoDateTime': '2026:10:09 10:00:36',
        'fileType': 'jpeg', 'category': 'photo',
        'fileName': 'MVIMG_20261009_100036.jpg',
        'fileSize': 5847776, 'mp': '9.4MP',
        'filePath': '/vol1/x/MVIMG.jpg',
        'height': 4096, 'width': 2304,
        'model': 'Xiaomi 13', 'make': 'Xiaomi',
        // 接口把光圈字段实测拼作 fumber
        'fumber': 'f/1.8', 'exposureTime': '1/100s',
        'isoSpeedRatings': 'ISO80', 'focalLength': '5.4mm',
        'exposureProgram': 'Program AE',
        'meteringMode': 'Center-weighted average',
        'geo': '中国,广西壮族自治区,南宁市,江南区,五一路,淡村商贸城',
        'isLive': 2,
      });
      expect(p.cameraModel, 'Xiaomi 13');
      expect(p.make, 'Xiaomi');
      expect(p.fNumber, 'f/1.8');
      expect(p.exposureTime, '1/100s');
      expect(p.isoSpeedRatings, 'ISO80');
      expect(p.focalLength, '5.4mm');
      expect(p.exposureProgram, 'Program AE');
      expect(p.geo, contains('南宁市'));
      expect(p.isLivePhoto, isTrue);
      expect(p.mediaDuration, 0);
    });

    test('视频时长解析（mediaDuration 实测字段）', () {
      final v = PhotoItem.fromJson({
        'id': 6225, 'fileType': 'mp4', 'category': 'video',
        'fileName': 'EV.mp4', 'fileSize': 46552665,
        'height': 1296, 'width': 2304, 'mediaDuration': 30,
      });
      expect(v.isVideo, isTrue);
      expect(v.mediaDuration, 30);
    });

    test('无 EXIF 的截图拍摄参数容错为空', () {
      final s = PhotoItem.fromJson({
        'id': 8401, 'fileType': 'jpeg', 'category': 'photo',
        'fileName': 'Screenshot.jpg', 'height': 2400, 'width': 1080,
      });
      expect(s.cameraModel, '');
      expect(s.fNumber, '');
      expect(s.exposureTime, '');
      expect(s.geo, '');
      expect(s.mediaDuration, 0);
    });
  });

  group('服务器地址归一化', () {
    test('局域网 IP + 用户填写的端口', () {
      final r = AppState.resolveAddress(
          address: '192.168.10.2', port: '8080', tls: false)!;
      expect(r.host, '192.168.10.2:8080');
      expect(r.tls, isFalse);
    });

    test('地址内已带端口时以地址为准', () {
      final r = AppState.resolveAddress(
          address: 'http://192.168.10.2:8081', port: '8080', tls: false)!;
      expect(r.host, '192.168.10.2:8081');
    });

    test('端口为空时不猜端口，返回 null 交由用户补输', () {
      final r = AppState.resolveAddress(
          address: '192.168.10.2', port: '', tls: true);
      expect(r, isNull);
      final r2 = AppState.resolveAddress(
          address: 'https://nas.example.com', port: '  ', tls: true);
      expect(r2, isNull);
    });

    test('裸 FN ID 自动补 fnos.net 并切到 HTTPS，端口以用户输入为准', () {
      final r = AppState.resolveAddress(
          address: 'abc123', port: '8080', tls: false)!;
      expect(r.host, 'abc123.fnos.net:8080');
      expect(r.tls, isTrue);
    });

    test('FN ID 带自定义端口时保留端口', () {
      final r = AppState.resolveAddress(
          address: 'abc123', port: '8443', tls: true)!;
      expect(r.host, 'abc123.fnos.net:8443');
    });

    test('域名不当作 FN ID', () {
      final r = AppState.resolveAddress(
          address: 'nas.example.com', port: '8080', tls: false)!;
      expect(r.host, 'nas.example.com:8080');
    });

    test('地址为空返回 null', () {
      expect(AppState.resolveAddress(address: '  ', port: '8080', tls: false),
          isNull);
    });
  });

  group('图片解码尺寸（比例不失真的关键）', () {
    /// 最小 PNG 头：只需要 IHDR 里的宽高
    Uint8List png(int w, int h) {
      final b = Uint8List(30);
      b.setAll(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      b.setAll(12, [0x49, 0x48, 0x44, 0x52]); // IHDR
      b[16] = (w >> 24) & 0xFF;
      b[17] = (w >> 16) & 0xFF;
      b[18] = (w >> 8) & 0xFF;
      b[19] = w & 0xFF;
      b[20] = (h >> 24) & 0xFF;
      b[21] = (h >> 16) & 0xFF;
      b[22] = (h >> 8) & 0xFF;
      b[23] = h & 0xFF;
      return b;
    }

    test('从 PNG 头部读出宽高', () {
      final s = imageSizeOf(png(4032, 3024));
      expect(s, isNotNull);
      expect(s!.w, 4032);
      expect(s.h, 3024);
    });

    test('无法识别时安全返回 null', () {
      expect(imageSizeOf(Uint8List.fromList([1, 2, 3, 4, 5])), isNull);
    });

    test('永远只给单轴 cache 尺寸（同时给两轴会把图片拉伸变形）', () {
      // 横屏 4:3 图片放进 9:16 竖屏容器
      final t = resolveDecodeTarget(
          BoxFit.contain, 1080, 1920, (w: 4032, h: 3024), 3);
      expect(t.w, isNotNull);
      expect(t.h, isNull); // 只给宽，引擎按原比例推高 → 不变形
    });

    test('竖屏 9:16 图片在竖屏容器里按高度解码（省内存）', () {
      final t = resolveDecodeTarget(
          BoxFit.contain, 1080, 1920, (w: 1080, h: 1920), 3);
      expect(t.w, isNull);
      expect(t.h, 5760);
    });

    test('cover 模式同样只给单轴', () {
      final t = resolveDecodeTarget(
          BoxFit.cover, 300, 300, (w: 4000, h: 3000), 2);
      expect(t.w == null || t.h == null, isTrue);
      expect(t.w ?? t.h, isNotNull);
    });

    test('没有固有尺寸信息时退化为按宽度解码', () {
      final t = resolveDecodeTarget(BoxFit.contain, 1080, 1920, null, 3);
      expect(t.w, 3240);
      expect(t.h, isNull);
    });
  });
}
