import 'dart:convert';

/// 窗口类型定义
abstract class WindowArguments {
  const WindowArguments();

  static const String businessIdMain = 'main';
  static const String businessIdPlayer = 'player';

  factory WindowArguments.fromArguments(String arguments) {
    if (arguments.isEmpty) {
      return const MainWindowArguments();
    }
    final json = jsonDecode(arguments) as Map<String, dynamic>;
    final businessId = json['businessId'] as String? ?? '';

    // Check if it contains player-related fields (video or live)
    final hasVideoFields = json.containsKey('aid') || json.containsKey('bvid');
    final hasLiveFields = json.containsKey('roomId');

    if (businessId == businessIdPlayer || hasVideoFields || hasLiveFields) {
      return PlayerWindowArguments.fromJson(json);
    }
    return const MainWindowArguments();
  }

  Map<String, dynamic> toJson();

  String get businessId;

  String toArguments() => jsonEncode({"businessId": businessId, ...toJson()});

  @override
  String toString() {
    return 'WindowArguments(businessId: $businessId, data: ${toJson()})';
  }
}

/// 主窗口参数
class MainWindowArguments extends WindowArguments {
  const MainWindowArguments();

  @override
  Map<String, dynamic> toJson() {
    return {};
  }

  @override
  String get businessId => WindowArguments.businessIdMain;
}

/// 播放器窗口参数（支持视频和直播）
class PlayerWindowArguments extends WindowArguments {
  const PlayerWindowArguments({
    this.aid,
    this.bvid,
    this.cid,
    this.seasonId,
    this.epId,
    this.pgcType,
    this.cover,
    this.title,
    this.progress,
    this.progressAid,
    this.progressBvid,
    this.progressCid,
    this.videoType = 'ugc',
    this.roomId,
    this.extraArguments,
    // Settings passed from main window
    this.settings,
  });

  factory PlayerWindowArguments.fromJson(Map<String, dynamic> json) {
    // Handle videoType being either a String or VideoType enum
    final rawVideoType = json['videoType'];
    String videoTypeStr;
    if (rawVideoType is String) {
      videoTypeStr = rawVideoType;
    } else if (rawVideoType != null) {
      // Assume it's a VideoType enum, extract its name
      videoTypeStr = rawVideoType.toString().split('.').last;
    } else {
      videoTypeStr = 'ugc';
    }

    // Helper to convert Map<Object?, Object?> to Map<String, dynamic>
    Map<String, dynamic>? convertMap(dynamic raw) {
      if (raw == null) return null;
      if (raw is Map<String, dynamic>) return raw;
      if (raw is Map) {
        return Map<String, dynamic>.from(
          raw.map(
            (key, value) => MapEntry(key.toString(), value),
          ),
        );
      }
      return null;
    }

    int? readInt(String key) {
      final value = json[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value);
      return null;
    }

    String? readString(String key) {
      final value = json[key];
      return value?.toString();
    }

    return PlayerWindowArguments(
      aid: readInt('aid'),
      bvid: readString('bvid'),
      cid: readInt('cid'),
      seasonId: readInt('seasonId'),
      epId: readInt('epId'),
      pgcType: readInt('pgcType'),
      cover: (json['cover'] ?? json['pic'])?.toString(),
      title: readString('title'),
      progress: readInt('progress'),
      progressAid: readInt('progressAid'),
      progressBvid: readString('progressBvid'),
      progressCid: readInt('progressCid'),
      videoType: videoTypeStr,
      roomId: readInt('roomId'),
      extraArguments: convertMap(json['extraArguments']),
      settings: convertMap(json['settings']),
    );
  }

  final int? aid;
  final String? bvid;
  final int? cid;
  final int? seasonId;
  final int? epId;
  final int? pgcType;
  final String? cover;
  final String? title;
  final int? progress;
  final int? progressAid;
  final String? progressBvid;
  final int? progressCid;
  final String videoType;
  final int? roomId;
  final Map<String, dynamic>? extraArguments;

  /// Settings snapshot from main window
  final Map<String, dynamic>? settings;

  @override
  Map<String, dynamic> toJson() {
    return {
      if (aid != null) 'aid': aid,
      if (bvid != null) 'bvid': bvid,
      if (cid != null) 'cid': cid,
      if (seasonId != null) 'seasonId': seasonId,
      if (epId != null) 'epId': epId,
      if (pgcType != null) 'pgcType': pgcType,
      if (cover != null) 'cover': cover,
      if (title != null) 'title': title,
      if (progress != null) 'progress': progress,
      if (progressAid != null) 'progressAid': progressAid,
      if (progressBvid != null) 'progressBvid': progressBvid,
      if (progressCid != null) 'progressCid': progressCid,
      'videoType': videoType,
      if (roomId != null) 'roomId': roomId,
      if (extraArguments != null) 'extraArguments': extraArguments,
      if (settings != null) 'settings': settings,
    };
  }

  @override
  String get businessId => WindowArguments.businessIdPlayer;
}
