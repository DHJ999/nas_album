/// fnOS 相册 API 客户端
///
/// 完整实现（全部经真机实测）：
///   1. 门禁  GET /access_code_verify   → 204 + Cookie os-access-code
///   2. 登录  ws://host/websocket  RPC  "user.login" → token
///   3. 请求  带 Cookie `fnos-token` + 头 `authx`(签名) + `x-access-source: app`
///
/// 已实测通过的接口见各方法注释。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/models.dart';
import 'fnos_crypto.dart';

class FnosException implements Exception {
  final int code;
  final String message;
  const FnosException(this.code, this.message);
  @override
  String toString() => 'FnosException($code): $message';
}

/// 把可能自带 query 的地址拆成 `(path, params)`。
///
/// 设备下发的部分 URL（缩略图 / 封面等）会带 query。签名基准必须与**实际发出
/// 的 query** 完全一致：如果直接把 `"/x/y?w=100"` 当 path 去算 `a` 分量，
/// 而实际请求的 query 是 `w=100`，两者口径不同 → 服务端校验失败 401。
/// 因此统一在这里拆开，让「签名」与「请求」共用同一份参数。
///
/// 已显式传入的 [params] 优先（调用方意图更明确）。
({String path, Map<String, dynamic>? params}) splitPathQuery(
    String path, Map<String, dynamic>? params) {
  final q = path.indexOf('?');
  if (q < 0) return (path: path, params: params);
  final merged = <String, dynamic>{};
  final raw = path.substring(q + 1);
  if (raw.isNotEmpty) {
    try {
      merged.addAll(Uri.splitQueryString(raw));
    } catch (_) {
      // query 不是合法 k=v 形式：不拆，按原样交给调用方（宁可签名口径怪，
      // 也不要因为解析失败直接把参数丢掉）
      return (path: path, params: params);
    }
  }
  if (params != null) merged.addAll(params);
  return (path: path.substring(0, q), params: merged);
}

/// 本地约定的错误码：NAS 开了「访问码门禁」但客户端还没拿到访问码。
/// 登录页据此弹出访问码输入框（而不是当成普通登录失败）。
const int kErrNeedAccessCode = 60201;

/// 访问码门禁探测结果
enum GateResult {
  /// 不需要门禁，或已带着正确访问码通过
  passed,

  /// 需要访问码，但客户端没有（或为空）
  needCode,

  /// 带着访问码，但服务端拒绝
  wrongCode,
}

/// 登录结果
class FnosSession {
  final String token, longToken, secret, machineId;
  final int uid;
  final bool admin;
  final String host; // host:port
  final bool useTls;
  final String accessCode;
  final String userName;

  /// 登录密码（仅本地保存，用于 token 失效后静默重登；可为空）
  final String password;

  const FnosSession({
    required this.token, required this.longToken, required this.secret,
    required this.machineId, required this.uid, required this.admin,
    required this.host, required this.useTls, required this.accessCode,
    required this.userName,
    this.password = '',
  });

  Map<String, dynamic> toJson() => {
        'token': token, 'longToken': longToken, 'secret': secret,
        'machineId': machineId, 'uid': uid, 'admin': admin,
        'host': host, 'useTls': useTls, 'accessCode': accessCode,
        'userName': userName,
        // 刻意不写 password：本机的密码只由「登录表单」那一份负责保存，
        // 同一个明文不再重复落盘。[fromJson] 仍读旧数据以兼容历史安装。
      };

  factory FnosSession.fromJson(Map<String, dynamic> j) => FnosSession(
        token: '${j['token'] ?? ''}', longToken: '${j['longToken'] ?? ''}',
        secret: '${j['secret'] ?? ''}', machineId: '${j['machineId'] ?? ''}',
        uid: j['uid'] is int ? j['uid'] : int.tryParse('${j['uid']}') ?? 0,
        admin: j['admin'] == true,
        host: '${j['host'] ?? ''}', useTls: j['useTls'] == true,
        accessCode: '${j['accessCode'] ?? ''}', userName: '${j['userName'] ?? ''}',
        password: '${j['password'] ?? ''}',
      );
}

class FnosClient {
  final String host; // "host:port"
  final bool useTls;

  /// 是否放行**不受信任的证书**（自签名 / 自建 CA）。
  ///
  /// fnOS 的 HTTPS 用的是它自签的证书，不在任何公网 CA 信任链里，
  /// Dart 默认校验会直接抛
  /// `HandshakeException: CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate`
  /// （2026-10-09 用户实测 60001 端口开 HTTPS 后必现）。
  /// 因此凡是用户选择信任的目标（局域网地址、或用户手动勾选），都要放行。
  ///
  /// ⚠️ 这个开关同时作用于 **REST（HttpClient）与 WebSocket 双通道** ——
  /// `WebSocket.connect` 内部自建 HttpClient、不吃外部回调，所以 TLS 场景下
  /// 必须改用我们自己的 `_http` 手动完成 Upgrade 握手（见 [_openWebSocket]）。
  final bool allowBadCertificate;

  String accessCode;
  String apiKey;

  String token = '';
  String longToken = '';
  String secret = '';
  String machineId = '';
  int uid = 0;
  bool admin = false;

  /// 鉴权失效时的自动重登回调（由 AppState 注入）。
  /// 返回 true 表示重登成功，调用方可安全重试原请求。
  Future<bool> Function()? relogin;

  final HttpClient _http;

  final Map<String, String> _cookies = {};

  FnosClient({
    required this.host,
    this.accessCode = '',
    this.useTls = false,
    this.allowBadCertificate = false,
    this.apiKey = kPhotoApiKey,
  }) : _http = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15)
          ..idleTimeout = const Duration(seconds: 30) {
    if (allowBadCertificate) {
      _http.badCertificateCallback = (cert, h, p) => true;
    }
  }

  String get baseUrl => '${useTls ? 'https' : 'http'}://$host';

  // ─────────────────────────── 门禁 ───────────────────────────

  /// 探测访问码门禁。
  ///
  /// 实测行为（fnnas 相册网关）：
  ///   · 未带 `x-access-code` 且 NAS 开了门禁 → 401
  ///   · 带错误访问码                        → 401
  ///   · 带正确访问码 / 未开门禁             → 204（或 200）
  ///
  /// 通过后会把 `os-access-code` Cookie 吸收进 cookie jar ——
  /// 后续所有 JSON 与图片/视频流请求都靠它，缺了会 401（缩略图全挂的根因）。
  Future<GateResult> checkGate() async {
    if (accessCode.isEmpty && _cookies['os-access-code'] != null) {
      return GateResult.passed;
    }
    try {
      final req = await _http.getUrl(Uri.parse('$baseUrl/access_code_verify'));
      if (accessCode.isNotEmpty) {
        req.headers.set('x-access-code', base64Encode(utf8.encode(accessCode)));
      }
      req.headers.set('x-access-source', 'app');
      req.headers.set('User-Agent', 'okhttp/4.12.0');
      final resp = await req.close();
      await resp.drain<void>();
      _absorbCookies(resp);
      final ok = resp.statusCode == 204 || resp.statusCode == 200;
      if (ok) return GateResult.passed;
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        return accessCode.isEmpty ? GateResult.needCode : GateResult.wrongCode;
      }
      // 404/405 之类说明该网关没有门禁路由，按「无需门禁」放行
      return GateResult.passed;
    } on SocketException catch (e) {
      throw FnosException(-1, '无法连接 $host：${e.message}');
    } on HandshakeException catch (e) {
      // 自签证书导致 TLS 握手失败 —— 必须翻译成人话，原始异常只有英文堆栈
      throw FnosException(-3, _handshakeErrorText(e));
    }
  }

  /// 兼容旧调用：过门禁，返回是否通过。需要访问码时抛 [kErrNeedAccessCode]。
  Future<bool> passGate() async {
    final r = await checkGate();
    if (r == GateResult.passed) return true;
    if (r == GateResult.needCode) {
      throw const FnosException(kErrNeedAccessCode, '需要访问码');
    }
    throw const FnosException(401, '访问码错误');
  }

  void _absorbCookies(HttpClientResponse resp) {
    for (final c in resp.cookies) {
      _cookies[c.name] = c.value;
    }
  }

  String get _cookieHeader =>
      _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  /// 完整 Cookie jar（含门禁 os-access-code、fnos-token 等）。
  /// 图片流请求必须用它 —— 之前只拼 fnos-token，
  /// 开启「访问码门禁」的 NAS 会拒绝所有图片请求（JSON 正常、图片全挂的根因）。
  String get cookieHeader => _cookieHeader;

  // ─────────────────────────── 登录 ───────────────────────────
  //
  // 核心 RPC 走 WebSocket：ws://host/websocket
  //   发送 {"reqid":"1","req":"user.login","user":..,"password":..,"stay":2,
  //         "deviceType":"web","deviceName":"..","did":".."}
  //   接收 {"result":"succ","token":..,"longToken":..,"secret":..,"uid":..,
  //         "machineId":..,"admin":..}
  // 登录后把 token 写入 Cookie `fnos-token`，REST 请求即通过鉴权。

  Future<FnosSession> login({
    required String user,
    required String password,
    String deviceName = 'fnos-album-android',
    String deviceType = 'android',
  }) async {
    if (_cookies['os-access-code'] == null || accessCode.isNotEmpty) {
      final g = await checkGate();
      if (g == GateResult.needCode) {
        throw const FnosException(kErrNeedAccessCode, '需要访问码');
      }
      if (g == GateResult.wrongCode) throw const FnosException(401, '访问码错误');
    }

    final scheme = useTls ? 'wss' : 'ws';
    final uri = Uri.parse('$scheme://$host/websocket');

    WebSocket ws;
    try {
      ws = await _openWebSocket(uri).timeout(const Duration(seconds: 20));
    } on TimeoutException {
      // 不翻译的话会一路冒到界面，用户看到的是
      // "连接失败：TimeoutException after 0:00:20.000000: Future not completed"
      throw FnosException(-1,
          '连接 $host 超时：请确认端口填的是 NAS 网关端口，且地址与当前的 HTTP/HTTPS 开关匹配。');
    } on SocketException catch (e) {
      throw FnosException(-1, '无法连接 $host：${e.message}');
    } on HandshakeException catch (e) {
      throw FnosException(-3, _handshakeErrorText(e));
    } on WebSocketException catch (e) {
      final m = e.message;
      throw FnosException(
          -1,
          m.contains('not upgraded')
              ? '服务器拒绝了 WebSocket 连接：请确认端口填的是 NAS 网关端口，'
                  '且地址与端口匹配了当前的 HTTP/HTTPS 开关。'
              : 'WebSocket 连接失败：$m');
    }

    final completer = Completer<Map<String, dynamic>>();
    final sub = ws.listen(
      (data) {
        try {
          final obj = jsonDecode(data as String) as Map<String, dynamic>;
          if (obj['res'] == 'pong') return;
          if (!completer.isCompleted) completer.complete(obj);
        } catch (_) {/* 忽略事件推送 */}
      },
      onError: (e) {
        if (!completer.isCompleted) {
          completer.completeError(FnosException(-1, 'WebSocket 错误: $e'));
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(const FnosException(-1, '连接被服务端关闭'));
        }
      },
      cancelOnError: true,
    );

    ws.add(jsonEncode({
      'reqid': '1',
      'req': 'user.login',
      'user': user,
      'password': password,
      'stay': 2,
      'deviceType': deviceType,
      'deviceName': deviceName,
      'did': 'fnos-album-${DateTime.now().millisecondsSinceEpoch}',
    }));

    try {
      Map<String, dynamic> r;
      try {
        r = await completer.future.timeout(const Duration(seconds: 25));
      } on TimeoutException {
        throw const FnosException(-1, '登录请求超时：NAS 没有响应，请检查网络后重试。');
      }
      final result = r['result'];
      if (result != 'succ') {
        final errno = r['errno'];
        throw FnosException(
          errno is int ? errno : -1,
          _loginErrorText(errno),
        );
      }
      token = '${r['token'] ?? ''}';
      longToken = '${r['longToken'] ?? ''}';
      secret = '${r['secret'] ?? ''}';
      machineId = '${r['machineId'] ?? ''}';
      uid = r['uid'] is int ? r['uid'] : 0;
      admin = r['admin'] == true;
      _cookies['fnos-token'] = token;
      if (longToken.isNotEmpty) _cookies['fnos-long-token'] = longToken;

      return FnosSession(
        token: token, longToken: longToken, secret: secret,
        machineId: machineId, uid: uid, admin: admin,
        host: host, useTls: useTls, accessCode: accessCode, userName: user,
        password: password,
      );
    } finally {
      await sub.cancel();
      await ws.close();
    }
  }

  /// 建立 WebSocket 连接（`<ws|wss>://host/websocket`）。
  ///
  /// 关键点是 **`customClient`**：
  ///   · `WebSocket.connect` 默认用 Dart 内部一个静态 HttpClient，它不认
  ///     [allowBadCertificate]，设备自签证书下 `wss://` 必然抛
  ///     `CERTIFICATE_VERIFY_FAILED`（用户实测「开 HTTPS 后进不去」的根源）；
  ///   · 把我们自己的 `_http`（已挂 `badCertificateCallback`）传进去，
  ///     证书策略就与 REST 通道完全一致；
  ///   · 顺带复用同一份 Cookie（门禁 `os-access-code` 也随头带上）。
  ///
  /// 该参数自 Dart 3.4 起提供，本项目 SDK 约束为 ^3.12.2，可用。
  Future<WebSocket> _openWebSocket(Uri uri) => WebSocket.connect(
        uri.toString(),
        headers: {
          if (_cookieHeader.isNotEmpty) 'Cookie': _cookieHeader,
          'Origin': baseUrl,
        },
        customClient: _http,
      );

  /// 把 TLS 握手异常翻译成用户能照着做的中文提示。
  String _handshakeErrorText(HandshakeException e) {
    final s = '${e.message} ${e.osError?.message ?? ''}';
    if (s.contains('CERTIFICATE_VERIFY_FAILED') || s.contains('certificate')) {
      return 'HTTPS 证书校验失败：该 NAS 使用的是自签名证书。'
          '请打开下方「信任自签名证书」开关后重试。';
    }
    return 'HTTPS 握手失败：${e.message}';
  }

  String _loginErrorText(dynamic errno) {
    switch (errno) {
      case 131072: return '用户名或密码错误';
      case 8192: return '请求参数错误';
      case 135168: return '两步验证码错误';
      case 131089: return '当前 IP 已被封禁';
      default: return '登录失败（errno=$errno）';
    }
  }

  /// 用已保存的会话恢复
  void restore(FnosSession s) {
    token = s.token; longToken = s.longToken; secret = s.secret;
    machineId = s.machineId; uid = s.uid; admin = s.admin;
    accessCode = s.accessCode;
    _cookies['fnos-token'] = token;
    if (longToken.isNotEmpty) _cookies['fnos-long-token'] = longToken;
  }

  // ─────────────────────────── HTTP ───────────────────────────

  /// 鉴权失效错误码：
  ///   401   网关层未鉴权（nginx 401）
  ///   4224  RPC 未登录（E_NOT_LOGIN）
  ///   65534 RPC 会话无效
  static bool _isAuthError(FnosException e) =>
      e.code == 401 || e.code == 4224 || e.code == 65534 || e.code == 65536;

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? params,
    Object? body,
    bool raw = false,
    bool retried = false,
  }) async {
    // 见 [splitPathQuery]：签名基准与实际请求必须共用同一份 query。
    final split = splitPathQuery(path, params);
    final realPath = split.path;
    final realParams = split.params;

    final uri = Uri.parse('$baseUrl$realPath').replace(
      queryParameters: realParams?.map((k, v) => MapEntry(k, '$v')),
    );
    final req = await _http.openUrl(method, uri);
    req.headers.set('x-access-source', 'app');
    req.headers.set('Accept', raw ? '*/*' : 'application/json');
    req.headers.set('User-Agent', 'okhttp/4.12.0');
    req.headers.set('authx',
        buildAuthx(method: method, path: realPath, params: realParams,
            body: body, apiKey: apiKey));
    if (_cookieHeader.isNotEmpty) req.headers.set('Cookie', _cookieHeader);
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      req.headers.set('Content-Type', 'application/json');
      req.headers.contentLength = bytes.length;
      req.add(bytes);
    }

    final resp = await req.close();
    _absorbCookies(resp);

    if (raw) {
      if (resp.statusCode == 401 && !retried) {
        await resp.drain<void>();
        // 必须先静默重登换掉过期 token 再重试。以前这一步没有调 relogin，
        // 等于用同一个旧 token 再打一次，最后把 401 的响应体当图片字节返回。
        if (relogin != null && await relogin!()) {
          return _request(method, path,
              params: params, body: body, raw: raw, retried: true);
        }
        throw const FnosException(401, '鉴权已失效，请重新登录');
      }
      final bytes = <int>[];
      await for (final chunk in resp) {
        bytes.addAll(chunk);
      }
      return bytes;
    }

    final text = await resp.transform(utf8.decoder).join();
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      // token 过期时网关直接回 401 HTML 页面 —— 静默重登后重试一次
      if (resp.statusCode == 401 && !retried) {
        if (relogin != null && await relogin!()) {
          return _request(method, path,
              params: params, body: body, raw: raw, retried: true);
        }
      }
      throw FnosException(resp.statusCode, '响应不是 JSON：${text.substring(0, text.length.clamp(0, 200))}');
    }
    final code = decoded is Map ? decoded['code'] : null;
    if (code != null && code != 0) {
      final e = FnosException(code is int ? code : int.tryParse('$code') ?? -1,
          '${decoded['msg'] ?? ''}');
      if (_isAuthError(e) && !retried) {
        if (relogin != null && await relogin!()) {
          return _request(method, path,
              params: params, body: body, raw: raw, retried: true);
        }
      }
      throw e;
    }
    return decoded is Map ? decoded['data'] : decoded;
  }

  /// 取原始字节（图片 / 视频流）
  Future<List<int>> fetchBytes(String path, {Map<String, dynamic>? params}) async {
    final r = await _request('GET', path, params: params, raw: true);
    return r as List<int>;
  }

  // ─────────────────────────── 相册接口 ───────────────────────────

  /// 当前用户信息
  Future<Map<String, dynamic>> userInfo() async =>
      (await _request('GET', '/p/api/v1/user/info')) as Map<String, dynamic>;

  /// 按天分组的时间轴骨架（实测返回 599 天）
  Future<List<TimelineDay>> timeline({int? albumId, int? isCollect}) async {
    final data = await _request('GET', '/p/api/v1/gallery/timeline', params: {
      if (albumId != null) 'album_id': '$albumId',
      if (isCollect != null) 'is_collect': '$isCollect',
    });
    final list = (data is Map ? data['list'] : null) as List? ?? const [];
    return list
        .map((e) => TimelineDay.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// 照片分页列表。
  ///
  /// ⚠️ **`albumId` 参数服务端会忽略**（2026-10-09 实测）：
  /// 无论传 0 还是真实相册 id，`gallery/getList` 都返回全量照片 ——
  /// 这正是「点进任何相册看到的都是全部照片」的根因。
  /// 要按相册过滤请用 [albumPhotos]。
  ///
  /// 注意：`start_time`/`end_time` 必须用 fnOS 的日期格式
  /// `YYYY:MM:DD HH:MM:SS`（日期部分用冒号），否则服务端返回 400。
  Future<({List<PhotoItem> list, bool hasNext})> getPhotos({
    int limit = 100,
    int offset = 0,
    DateTime? start,
    DateTime? end,
    int albumId = 0,
    int isCollect = 0,
  }) async {
    final now = DateTime.now();
    final s = start ?? DateTime(2000, 1, 1);
    final e = end ?? DateTime(now.year + 1, 12, 31, 23, 59, 59);
    final data = await _request('GET', '/p/api/v1/gallery/getList', params: {
      'limit': '$limit',
      'offset': '$offset',
      'start_time': formatFnosDate(s),
      'end_time': formatFnosDate(e),
      'album_id': '$albumId',
      'is_collect': '$isCollect',
    });
    final map = data is Map ? data : const {};
    final list = (map['list'] as List? ?? const [])
        .map((e) => PhotoItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    // hasNext 判据（已按安全语义收敛）：
    // 1. 服务端显式下发 hasNext 布尔值时直接采信；
    // 2. 否则以「本页是否取满」为准 —— 不满一页必然到底；
    //    满页则假设可能还有（若总数恰为 limit 整数倍，会多发一次空页请求，无害）。
    // 注意：不采信 `count` 字段，其实机语义（本页条数 or 命中总数）未经证实，
    // 误用会漏页或死循环。
    final hn = map['hasNext'];
    final hasNext = hn is bool ? hn : list.length >= limit;
    return (list: list, hasNext: hasNext);
  }

  /// 相簿列表（实测 18 个：截屏录屏 / Camera / WeiXin / 行车记录仪 / DJI …）
  Future<List<Album>> albums() async {
    final data = await _request('GET', '/p/api/v1/album/list');
    final list = (data is Map ? data['list'] : null) as List? ?? const [];
    return list
        .map((e) => Album.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// **相册内的照片**（按相册真实归类）。
  ///
  /// 实测结论（2026-10-09，逐个相册与 `album/list` 声明的数量比对）：
  ///   · `GET /p/api/v1/album/photos?album_id=<id>&limit=&offset=`
  ///     → 逐条命中，数量与相册声明完全一致；
  ///   · 参数名必须是**下划线** `album_id`，写成驼峰 `albumId` 会 400 invalid params；
  ///   · 同参数下 `gallery/getList` 会忽略相册过滤返回全量，**不可用**；
  ///   · `hasNext` / `count` 恒为 null，翻页判据只能用「本页是否取满」。
  Future<({List<PhotoItem> list, bool hasNext})> albumPhotos({
    required int albumId,
    int limit = 200,
    int offset = 0,
  }) async {
    final data = await _request('GET', '/p/api/v1/album/photos', params: {
      'album_id': '$albumId',
      'limit': '$limit',
      'offset': '$offset',
    });
    final map = data is Map ? data : const {};
    final list = (map['list'] as List? ?? const [])
        .map((e) => PhotoItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final hn = map['hasNext'];
    final hasNext = hn is bool ? hn : list.length >= limit;
    return (list: list, hasNext: hasNext);
  }

  /// 相册内的按天时间轴骨架（用于相册详情里的日期分组）
  Future<List<TimelineDay>> albumTimeline(int albumId) async {
    final data = await _request('GET', '/p/api/v1/album/normal/timeline',
        params: {'albumId': '$albumId'});
    final list = (data is Map ? data['list'] : null) as List? ?? const [];
    return list
        .map((e) => TimelineDay.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// 相册文件夹（含读写权限）
  Future<List<PhotoFolder>> folders() async {
    final data = await _request('GET', '/p/api/v1/photo/folder/list');
    final list = (data is Map ? data['list'] : null) as List? ?? const [];
    return list
        .map((e) => PhotoFolder.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// 人物（设备端人脸识别结果，实测 15 人）
  Future<List<PersonItem>> people() async {
    final data = await _request('GET', '/p/api/v1/ai-person/list');
    final list = (data is Map ? data['list'] : null) as List? ?? const [];
    return list
        .map((e) => PersonItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// 把照片/视频移入 NAS 回收站（经实测确认的相册接口：
  /// `addToRecycleBin` → POST /api/v1/recycle-bin/add body {ids}）。
  ///
  /// 注意别用 `gallery/delete` —— 那是 Web 端「彻底删除」链路之外的另一个
  /// 模块接口；`recycle-bin/add` 才是「删除 → 可在回收站还原」的语义，
  /// 误用会导致照片不可恢复。
  Future<void> deleteToRecycleBin(List<int> ids) async {
    if (ids.isEmpty) return;
    await _request('POST', '/p/api/v1/recycle-bin/add', body: {'ids': ids});
  }

  /// 目录浏览：文件
  Future<({List<PhotoItem> list, int total})> browseFiles(
    String folderPath, {int limit = 100, int offset = 0}) async {
    final data = await _request('GET', '/p/api/v1/folder_view/getFileList',
        params: {'folderPath': folderPath, 'limit': '$limit', 'offset': '$offset'});
    final map = data is Map ? data : const {};
    final list = (map['list'] as List? ?? const [])
        .map((e) => PhotoItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    return (list: list, total: (map['total'] as int?) ?? 0);
  }

  /// 目录浏览：子目录
  Future<List<({String name, String path})>> browseFolders(String folderPath) async {
    final data = await _request('GET', '/p/api/v1/folder_view/getFolderList',
        params: {'folderPath': folderPath});
    final list = (data is Map ? data['list'] : null) as List? ?? const [];
    return list
        .map((e) => (
              name: '${(e as Map)['name'] ?? ''}',
              path: '${e['path'] ?? ''}',
            ))
        .toList();
  }

  /// 媒体类型聚合（`media_category/list`）。
  ///
  /// 实测返回：`{"list":[{"id":8729,"category":1,"uuid":"...","count":3448}, ...]}`
  /// —— 这是「全部 / 视频 / 图片 / …」这类**媒体类型**，不是相册。
  /// `category` 字段的取值：1 = 照片、3 = 视频（其余取值本机未实测）。
  ///
  /// ⚠️ 想按类型过滤照片列表**不能**靠 `gallery/getList?category=` ——
  /// 实测服务端会忽略该参数、仍返回全量（见 API 逆向报告 C.3）。
  /// 正确做法：本方法只用来取「类型 + 条数」，真正的列表由
  /// [MediaFilter] 在客户端按 [PhotoItem.category] 过滤。
  Future<List<MediaCategory>> mediaCategories() async {
    final data = await _request('GET', '/p/api/v1/media_category/list');
    final list = (data is Map ? data['list'] : null) as List? ?? const [];
    return list
        .map((e) => MediaCategory.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// 原图下载地址（需带鉴权头，配合 [fetchBytes] 使用）
  String originalPath(int photoId) => '/p/api/v1/download/original/$photoId';

  /// 视频 / 实况照片动态部分的流地址
  /// 实测返回 `video/mp4` 且支持 HTTP Range（可拖动进度）
  String videoPath(int photoId) => '/p/api/v1/stream/v/$photoId';

  // ─────────────────────────── 探索 / 搜索 ───────────────────────────

  /// 地点聚类（设备扫描的 GPS 城市聚合，实测：菏泽/南宁/呼伦贝尔…）
  /// 实测条目：{country, city, itemCount, posterUrl}
  ///
  /// 无参数时服务端默认只返回 8 条，因此必须显式分页直到拿全。
  Future<List<GeoCluster>> exploreGeos() async {
    const pageSize = 100;
    final all = <GeoCluster>[];
    for (int offset = 0;; offset += pageSize) {
      final data = await _request('GET', '/p/api/v1/explore/geos',
          params: {'limit': '$pageSize', 'offset': '$offset'});
      final list = (data is Map ? data['list'] : null) as List? ?? const [];
      if (list.isEmpty) break;
      all.addAll(list.map((e) =>
          GeoCluster.fromJson(Map<String, dynamic>.from(e as Map))));
      if (list.length < pageSize) break;
    }
    return all;
  }

  /// 场景标签（事物场景，如 天空云彩/公园/草地；未扫描时为空列表）
  Future<List<SceneTag>> exploreTags() async {
    final data = await _request('GET', '/p/api/v1/explore/tags');
    final list = (data is Map ? data['list'] : null) as List? ?? const [];
    return list
        .map((e) => SceneTag.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// 关键词搜索（POST /search/results）
  ///
  /// 实测结论：
  ///  - `filters` 结构对本机 fnOS 版本不生效（一律返回空），**keyword 全文匹配可用**；
  ///  - 分页参数 limit/offset 被服务端忽略（恒返回全量），客户端本地分页；
  ///  - 条目结构与 gallery/getList 完全一致，可直接复用 [PhotoItem]。
  Future<List<PhotoItem>> searchResults(String keyword) async {
    final data = await _request('POST', '/p/api/v1/search/results', body: {
      'keyword': keyword,
      'antiFilters': [],
      'showFilterBar': false,
      'viewMode': '',
    });
    final list = (data is Map ? data['list'] : null) as List? ?? const [];
    return list
        .map((e) => PhotoItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// 人物照片库（点击某个人物看 TA 的所有照片）
  ///
  /// 实测：`personId` 必须搭配 `startTime/endTime`（fnOS 冒号日期格式），
  /// 缺时间参数会 400 invalid params。
  Future<List<PhotoItem>> personPhotos(int personId,
      {int limit = 500, int offset = 0}) async {
    final now = DateTime.now();
    final data = await _request('GET', '/p/api/v1/ai-person/photoLibrary/list',
        params: {
          'personId': '$personId', 'limit': '$limit', 'offset': '$offset',
          'startTime': formatFnosDate(DateTime(2000, 1, 1)),
          'endTime': formatFnosDate(
              DateTime(now.year + 2, 12, 31, 23, 59, 59)),
        });
    final list = (data is Map ? data['list'] : null) as List? ?? const [];
    return list
        .map((e) => PhotoItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// 人脸识别状态
  Future<Map<String, dynamic>> aiFaceStatus() async =>
      (await _request('GET', '/p/api/v1/ai-face/status')) as Map<String, dynamic>;

  /// 重命名人物。
  ///
  /// 端点与请求体字段以实测为准（`PersonRenameRequest{id, name}`，
  /// 见 `_analysis/API_SPEC.md` §9.2）：
  /// `POST /p/api/v1/ai-person/rename`  body `{"id": <personId>, "name": "..."}`
  Future<void> renamePerson(int personId, String name) async {
    await _request('POST', '/p/api/v1/ai-person/rename',
        body: {'id': personId, 'name': name});
  }

  /// 把某张照片设为人物封面。
  ///
  /// `POST /p/api/v1/ai-person/posterFromPhoto`
  /// body `{"id": <personId>, "userPhotoId": <照片 id>}`
  /// —— 注意参数名是 **`userPhotoId`**，对应 [PhotoItem.id]。
  Future<void> setPersonCover(int personId, int userPhotoId) async {
    await _request('POST', '/p/api/v1/ai-person/posterFromPhoto',
        body: {'id': personId, 'userPhotoId': userPhotoId});
  }

  void close() => _http.close(force: true);
}
