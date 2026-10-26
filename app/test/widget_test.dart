// NAS相册的冒烟测试：确认签名算法与数据模型在纯 Dart 环境下行为正确。
//
// 网络相关逻辑不在此测试（需要真实 NAS）。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_album/core/app_state.dart';
import 'package:nas_album/core/error_text.dart';
import 'package:nas_album/core/fnos_client.dart';
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

  // ── 以下为针对已修缺陷的回归测试 ──

  group('地址自带 query 时的签名口径', () {
    test('path 里的 query 经归一化后与显式 params 得到同一个 authx', () {
      // 回归：以前 `_request` / `_fetchOnce` 把 "/x?w=100" 整个当 path 去算 md5，
      // 而实际发出的 query 是 w=100，两者口径不一致 → 服务端 401。
      // 现在两边都先过 splitPathQuery，结果必须逐字节相同。
      final split = splitPathQuery('/p/api/v1/stream/p/t/8264/s/uuid?w=100', null);
      final viaPath = buildAuthx(
        method: 'GET',
        path: split.path,
        params: split.params,
        nonce: '123456',
        timestamp: '1791536000000',
      );
      final viaParams = buildAuthx(
        method: 'GET',
        path: '/p/api/v1/stream/p/t/8264/s/uuid',
        params: {'w': '100'},
        nonce: '123456',
        timestamp: '1791536000000',
      );
      expect(viaPath, viaParams);
    });

    test('未归一化时两者确实不同 —— 说明这层归一化是必要的', () {
      final raw = buildAuthx(
        method: 'GET',
        path: '/p/api/v1/stream/p/t/8264/s/uuid?w=100',
        nonce: '123456',
        timestamp: '1791536000000',
      );
      final normalized = buildAuthx(
        method: 'GET',
        path: '/p/api/v1/stream/p/t/8264/s/uuid',
        params: {'w': '100'},
        nonce: '123456',
        timestamp: '1791536000000',
      );
      expect(raw, isNot(normalized));
    });

    test('拆出 path 与 query 参数', () {
      final r = splitPathQuery('/x/y?w=100&h=50', null);
      expect(r.path, '/x/y');
      expect(r.params, {'w': '100', 'h': '50'});
    });

    test('显式 params 优先于地址里的 query', () {
      final r = splitPathQuery('/x/y?w=1', {'w': '2', 'z': '3'});
      expect(r.path, '/x/y');
      expect(r.params, {'w': '2', 'z': '3'});
    });

    test('没有 query 时原样返回，params 保持 null', () {
      final r = splitPathQuery('/p/api/v1/user/info', null);
      expect(r.path, '/p/api/v1/user/info');
      expect(r.params, isNull);
    });

    test('query 无法解码时保守回退，不丢参数', () {
      // %zz 不是合法百分号转义，解码会抛；此时宁可保持原样交给调用方
      final r = splitPathQuery('/x/y?a=%zz', null);
      expect(r.path, '/x/y?a=%zz');
      expect(r.params, isNull);
    });
  });

  group('地址 scheme 识别（HTTPS 开关联动）', () {
    test('https:// 提示用 TLS', () {
      expect(AppState.tlsHintFromAddress('https://nas.local'), isTrue);
      expect(AppState.tlsHintFromAddress('  HTTPS://nas.local  '), isTrue);
    });

    test('http:// 提示走明文', () {
      expect(AppState.tlsHintFromAddress('http://192.168.1.2'), isFalse);
    });

    test('没写 scheme 时返回 null，沿用界面开关', () {
      expect(AppState.tlsHintFromAddress('192.168.1.2'), isNull);
      expect(AppState.tlsHintFromAddress('nas.local:8080'), isNull);
    });
  });

  group('IPv6 地址不被误拆', () {
    test('裸 IPv6 不再把末尾段当成端口', () {
      // 回归：贪婪正则 ^(.+):(\d+)$ 会把 fe80::1 拆成 host="fe80:"、port="1"，
      // 静默改写用户输入。现在端口只认输入框里的值。
      final r = AppState.resolveAddress(
          address: 'fe80::1', port: '8080', tls: false)!;
      expect(r.host, 'fe80::1:8080');
    });

    test('带方括号的 IPv6 仍照常拆出端口', () {
      final r = AppState.resolveAddress(
          address: '[fe80::1]:9000', port: '', tls: false)!;
      expect(r.host, '[fe80::1]:9000');
    });

    test('普通 host:port 行为不变', () {
      final r = AppState.resolveAddress(
          address: '192.168.10.2:8081', port: '8080', tls: false)!;
      expect(r.host, '192.168.10.2:8081');
    });
  });

  group('容错布尔解析', () {
    test('接受大小写变体与 yes/on', () {
      expect(PhotoItem.fromJson({'isRaw': 'TRUE'}).isRaw, isTrue);
      expect(PhotoItem.fromJson({'isRaw': 'yes'}).isRaw, isTrue);
      expect(PhotoItem.fromJson({'isRaw': ' On '}).isRaw, isTrue);
      expect(PhotoItem.fromJson({'isRaw': 1}).isRaw, isTrue);
    });

    test('否定值与缺失值仍为 false', () {
      expect(PhotoItem.fromJson({'isRaw': 'no'}).isRaw, isFalse);
      expect(PhotoItem.fromJson({'isRaw': '0'}).isRaw, isFalse);
      expect(PhotoItem.fromJson({}).isRaw, isFalse);
    });
  });

  group('页面错误文案', () {
    test('FnosException 直接用它自带的中文说明', () {
      expect(friendlyError(const FnosException(-1, '无法连接 1.2.3.4:8080')), '无法连接 1.2.3.4:8080');
    });

    test('message 为空时退化为带 code 的描述', () {
      expect(friendlyError(const FnosException(4224, '  ')),
          'NAS 返回错误（code=4224）');
    });

    test('SocketException 翻译成人话，不再把英文原文摊给用户', () {
      final msg = friendlyError(const SocketException('Connection refused'));
      expect(msg, contains('连接不上 NAS'));
      expect(msg, isNot(contains('SocketException')));
    });

    test('StateError 直接使用它的 message', () {
      expect(friendlyError(StateError('尚未连接到 NAS')), '尚未连接到 NAS');
    });

    test('无法识别的异常保留原始文本，不吞掉信息', () {
      expect(friendlyError(ArgumentError('bad argument')), contains('bad argument'));
    });
  });
}
