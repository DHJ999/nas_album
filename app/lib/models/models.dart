/// NAS相册数据模型 —— 字段名全部来自真机实测响应。
library;

int? _i(dynamic v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));
String _s(dynamic v) => v == null ? '' : '$v';
bool _b(dynamic v) => v == true || v == 1 || v == '1' || v == 'true';

/// 解析 fnOS 的日期字符串 `YYYY:MM:DD HH:MM:SS`
DateTime? parseFnosDate(String? s) {
  if (s == null || s.isEmpty) return null;
  final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})')
      .firstMatch(s);
  if (m == null) return DateTime.tryParse(s.replaceAll(':', '-'));
  try {
    return DateTime(
      int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!),
      int.parse(m.group(4)!), int.parse(m.group(5)!), int.parse(m.group(6)!),
    );
  } catch (_) {
    return null;
  }
}

/// 转成接口要求的 `YYYY:MM:DD HH:MM:SS`
String formatFnosDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}:'
    '${d.month.toString().padLeft(2, '0')}:'
    '${d.day.toString().padLeft(2, '0')} '
    '${d.hour.toString().padLeft(2, '0')}:'
    '${d.minute.toString().padLeft(2, '0')}:'
    '${d.second.toString().padLeft(2, '0')}';

/// 缩略图各档尺寸
class ThumbUrls {
  final String xxs, xs, s, m, original, video;
  const ThumbUrls({
    this.xxs = '', this.xs = '', this.s = '',
    this.m = '', this.original = '', this.video = '',
  });

  factory ThumbUrls.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const ThumbUrls();
    return ThumbUrls(
      xxs: _s(j['xxsUrl']), xs: _s(j['xsUrl']), s: _s(j['sUrl']),
      m: _s(j['mUrl']), original: _s(j['originalUrl']), video: _s(j['videoUrl']),
    );
  }

  /// 注意：必须连 `xxs` / `xs` 一起判，否则只有极小缩略图的照片
  /// 会被误判为空，占位图 / 降级逻辑走错分支。
  bool get isEmpty =>
      xxs.isEmpty && xs.isEmpty && s.isEmpty && m.isEmpty && original.isEmpty;
}

/// 一张照片 / 一段视频
class PhotoItem {
  final int id;
  final int ownerId;
  final String dateTime;      // 原始 fnOS 格式
  final String photoDateTime;
  final int timeZoneOffset;
  final String fileType;      // jpeg / png / mp4 ...
  final bool isRaw;
  final String category;      // photo | video
  final int specialType;
  final String fileName;
  final int fileSize;
  final String description;
  final int isCollect;
  final String mp;            // 像素，如 "2.6MP"
  final String filePath;
  final int height, width;
  final int flash;
  final int isLive;           // 1 = 实况照片
  final int rotation;
  final int isCanPreview;
  final int thumbnailStatus;
  final ThumbUrls thumb;
  final String photoUUID;

  // ── 拍摄参数 / 位置（gallery/getList 实测顶层字段，仅相机拍摄的照片有，
  //    截图等无 EXIF 的条目这些字段缺失，统一容错为空串）──
  final String make;            // 厂商，如 "Xiaomi"
  final String cameraModel;     // 机型，如 "Xiaomi 13"（接口字段名就叫 model）
  final String fNumber;         // 光圈，如 "f/1.8"（接口字段名实测拼作 fumber）
  final String exposureTime;    // 快门，如 "1/100s"
  final String isoSpeedRatings; // 感光度，如 "ISO80"
  final String focalLength;     // 焦距，如 "5.4mm"
  final String exposureProgram; // 曝光程序，如 "Program AE"
  final String meteringMode;    // 测光模式，如 "Center-weighted average"
  final String geo;             // 拍摄位置（完整中文地址，逗号分隔），无 GPS 时为空

  /// 视频时长（秒）。接口字段 mediaDuration，照片为 0
  final int mediaDuration;

  const PhotoItem({
    required this.id, required this.ownerId, required this.dateTime,
    required this.photoDateTime, required this.timeZoneOffset,
    required this.fileType, required this.isRaw, required this.category,
    required this.specialType, required this.fileName, required this.fileSize,
    required this.description, required this.isCollect, required this.mp,
    required this.filePath, required this.height, required this.width,
    required this.flash, required this.isLive, required this.rotation,
    required this.isCanPreview, required this.thumbnailStatus,
    required this.thumb, required this.photoUUID,
    this.make = '', this.cameraModel = '', this.fNumber = '',
    this.exposureTime = '', this.isoSpeedRatings = '', this.focalLength = '',
    this.exposureProgram = '', this.meteringMode = '', this.geo = '',
    this.mediaDuration = 0,
  });

  factory PhotoItem.fromJson(Map<String, dynamic> j) {
    final add = j['additional'];
    final th = add is Map ? add['thumbnail'] : null;
    return PhotoItem(
      id: _i(j['id']) ?? 0,
      ownerId: _i(j['ownerId']) ?? 0,
      dateTime: _s(j['dateTime']),
      photoDateTime: _s(j['photoDateTime'] ?? j['dateTime']),
      timeZoneOffset: _i(j['timeZoneOffset']) ?? 0,
      fileType: _s(j['fileType']),
      isRaw: _b(j['isRaw']),
      category: _s(j['category']),
      specialType: _i(j['specialType']) ?? 0,
      fileName: _s(j['fileName']),
      fileSize: _i(j['fileSize']) ?? 0,
      description: _s(j['description']),
      isCollect: _i(j['isCollect']) ?? 0,
      mp: _s(j['mp']),
      filePath: _s(j['filePath']),
      height: _i(j['height']) ?? 0,
      width: _i(j['width']) ?? 0,
      flash: _i(j['flash']) ?? -1,
      isLive: _i(j['isLive']) ?? 0,
      rotation: _i(j['rotation']) ?? 0,
      isCanPreview: _i(j['isCanPreview']) ?? 1,
      thumbnailStatus: _i(j['thumbnailStatus']) ?? 0,
      thumb: ThumbUrls.fromJson(th is Map ? Map<String, dynamic>.from(th) : null),
      photoUUID: _s(j['photoUUID']),
      make: _s(j['make']),
      cameraModel: _s(j['model']),
      // 注意：接口把光圈字段拼作 "fumber"（真机实测，非笔误）
      fNumber: _s(j['fumber']),
      exposureTime: _s(j['exposureTime']),
      isoSpeedRatings: _s(j['isoSpeedRatings']),
      focalLength: _s(j['focalLength']),
      exposureProgram: _s(j['exposureProgram']),
      meteringMode: _s(j['meteringMode']),
      geo: _s(j['geo']),
      mediaDuration: _i(j['mediaDuration']) ?? 0,
    );
  }

  bool get isVideo => category == 'video' || fileType == 'mp4' ||
      fileType == 'mov' || fileType == 'mkv' || fileType == 'avi';

  /// 实况照片。设备端用 `isLive == 2` 表示动态照片
  /// （文件名通常形如 `MVIMG_xxx.jpg`），`1` 亦按实况处理。
  bool get isLivePhoto => isLive == 1 || isLive == 2;

  /// 视频/实况照片的动态部分流地址（实测返回 video/mp4，支持 Range）
  String get videoStreamPath => '/p/api/v1/stream/v/$id';

  /// 原图地址
  String get originalPath => thumb.original.isNotEmpty
      ? thumb.original
      : '/p/api/v1/download/original/$id';

  DateTime? get takenAt => parseFnosDate(photoDateTime);

  double get aspectRatio => (width > 0 && height > 0) ? width / height : 1.0;
}

/// 时间轴里的一天
class TimelineDay {
  final int year, month, day, itemCount;
  const TimelineDay({
    required this.year, required this.month,
    required this.day, required this.itemCount,
  });
  factory TimelineDay.fromJson(Map<String, dynamic> j) => TimelineDay(
        year: _i(j['year']) ?? 0, month: _i(j['month']) ?? 0,
        day: _i(j['day']) ?? 0, itemCount: _i(j['itemCount']) ?? 0,
      );
  DateTime get date => DateTime(year, month, day);
  String get label => '$year年$month月$day日';
}

/// 相簿
class Album {
  final int albumId;
  final String albumName;
  final String source;
  final int photoCount, videoCount;
  final String posterUrl, posterImgUrl;
  final String startDateTime, endDateTime;
  final int shared, ownerId;
  final int category, displayType;
  final int modTime;

  const Album({
    required this.albumId, required this.albumName, required this.source,
    required this.photoCount, required this.videoCount, required this.posterUrl,
    required this.posterImgUrl, required this.startDateTime,
    required this.endDateTime, required this.shared, required this.ownerId,
    required this.category, required this.displayType, required this.modTime,
  });

  factory Album.fromJson(Map<String, dynamic> j) => Album(
        albumId: _i(j['albumId']) ?? 0,
        albumName: _s(j['albumName']),
        source: _s(j['source']),
        photoCount: _i(j['photoCount']) ?? 0,
        videoCount: _i(j['videoCount']) ?? 0,
        posterUrl: _s(j['posterUrl']),
        posterImgUrl: _s(j['posterImgUrl']),
        startDateTime: _s(j['startDateTime']),
        endDateTime: _s(j['endDateTime']),
        shared: _i(j['shared']) ?? 0,
        ownerId: _i(j['ownerId']) ?? 0,
        category: _i(j['category']) ?? 0,
        displayType: _i(j['displayType']) ?? 0,
        modTime: _i(j['modTime']) ?? 0,
      );

  int get total => photoCount + videoCount;
}

/// 人物（人脸识别）
class PersonItem {
  final int id;
  final String name;
  final String faceId;
  final int itemCount;
  final String birthday;
  final int isHide;
  final int updatedAt;
  const PersonItem({
    required this.id, required this.name, required this.faceId,
    required this.itemCount, required this.birthday,
    required this.isHide, required this.updatedAt,
  });
  factory PersonItem.fromJson(Map<String, dynamic> j) => PersonItem(
        id: _i(j['id']) ?? 0, name: _s(j['name']), faceId: _s(j['faceId']),
        itemCount: _i(j['itemCount']) ?? 0, birthday: _s(j['birthday']),
        isHide: _i(j['isHide']) ?? 0, updatedAt: _i(j['updatedAt']) ?? 0,
      );
  String get displayName => name.isEmpty ? '未命名' : name;
}

/// 相册文件夹
class PhotoFolder {
  final int folderId;
  final String folderPath;
  final int photoCount, videoCount, status, isDefault;
  final bool hasWriteAccess;
  const PhotoFolder({
    required this.folderId, required this.folderPath,
    required this.photoCount, required this.videoCount, required this.status,
    required this.isDefault, required this.hasWriteAccess,
  });
  factory PhotoFolder.fromJson(Map<String, dynamic> j) {
    final w = j['hasWriteAccess'];
    return PhotoFolder(
      folderId: _i(j['folderId']) ?? 0,
      folderPath: _s(j['folderPath']),
      photoCount: _i(j['photoCount']) ?? 0,
      videoCount: _i(j['videoCount']) ?? 0,
      status: _i(j['status']) ?? 0,
      isDefault: _i(j['isDefault']) ?? 0,
      hasWriteAccess: w is Map ? _b(w['hasWriteAccess']) : _b(w),
    );
  }
}

/// 回收站条目
class RecycleItem {
  final int id;
  final String ownerName, dateTime, fileType, category, fileName, photoUUID, filePath, city;
  final int fileSize, height, width, isCollect;
  const RecycleItem({
    required this.id, required this.ownerName, required this.dateTime,
    required this.fileType, required this.category, required this.fileName,
    required this.fileSize, required this.isCollect, required this.photoUUID,
    required this.filePath, required this.height, required this.width,
    required this.city,
  });
  factory RecycleItem.fromJson(Map<String, dynamic> j) => RecycleItem(
        id: _i(j['id']) ?? 0, ownerName: _s(j['ownerName']),
        dateTime: _s(j['dateTime']), fileType: _s(j['fileType']),
        category: _s(j['category']), fileName: _s(j['fileName']),
        fileSize: _i(j['fileSize']) ?? 0, isCollect: _i(j['isCollect']) ?? 0,
        photoUUID: _s(j['photoUUID']), filePath: _s(j['filePath']),
        height: _i(j['height']) ?? 0, width: _i(j['width']) ?? 0,
        city: _s(j['city']),
      );
  bool get isVideo => category == 'video';
}

// ─────────────────────────── 探索（搜索页） ───────────────────────────

/// 地点聚类（explore/geos 实测：{country, city, itemCount, posterUrl}）
class GeoCluster {
  final String country, city, posterUrl;
  final int itemCount;
  const GeoCluster({
    required this.country, required this.city,
    required this.itemCount, required this.posterUrl,
  });
  factory GeoCluster.fromJson(Map<String, dynamic> j) => GeoCluster(
        country: _s(j['country']), city: _s(j['city']),
        itemCount: _i(j['itemCount']) ?? 0, posterUrl: _s(j['posterUrl']),
      );
}

/// 场景标签（explore/tags；字段名未实证，容错解析）
class SceneTag {
  final String name, posterUrl;
  final int itemCount;
  const SceneTag({required this.name, required this.posterUrl, required this.itemCount});
  factory SceneTag.fromJson(Map<String, dynamic> j) => SceneTag(
        name: _s(j['name'] ?? j['tagName'] ?? j['tag']),
        posterUrl: _s(j['posterUrl'] ?? j['coverUrl']),
        itemCount: _i(j['itemCount'] ?? j['count']) ?? 0,
      );
}
