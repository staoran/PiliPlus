import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io' show Directory, File;

import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/http/download.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/download/bili_download_media_file_info.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart' as pgc;
import 'package:PiliPlus/models_new/pgc/pgc_info_model/result.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart' as ugc;
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/services/download/download_foreground_service.dart';
import 'package:PiliPlus/services/download/download_manager.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/danmaku_utils.dart';
import 'package:PiliPlus/utils/extension/file_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;
import 'package:synchronized/synchronized.dart';

// ref https://github.com/10miaomiao/bilimiao2/blob/master/bilimiao-download/src/main/java/cn/a10miaomiao/bilimiao/download/DownloadService.kt

class DownloadService extends GetxService {
  static const _entryFile = 'entry.json';
  static const _indexFile = 'index.json';
  static const _maxDanmakuConcurrency = 4;

  final _lock = Lock();

  final flagNotifier = SetNotifier();
  final waitDownloadQueue = RxList<BiliDownloadEntryInfo>();
  final downloadList = <BiliDownloadEntryInfo>[];
  final _activeTasks = <int, _ActiveDownloadTask>{};
  final _connectivity = Connectivity();

  int? _curCid;
  int? get curCid => _curCid;
  final curDownload = Rxn<BiliDownloadEntryInfo>();
  late final int _downloadTaskLimit;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  List<ConnectivityResult>? _connectivityResults;
  bool _schedulerPaused = false;

  List<BiliDownloadEntryInfo> get activeDownloads =>
      _activeTasks.values.map((task) => task.entry).toList(growable: false);

  int get activeCount => _activeTasks.length;

  bool isActive(BiliDownloadEntryInfo entry) =>
      _activeTasks.containsKey(entry.cid);

  bool isActiveCid(int cid) => _activeTasks.containsKey(cid);

  BiliDownloadEntryInfo? activeEntry(int cid) => _activeTasks[cid]?.entry;

  bool isEntryDownloading(BiliDownloadEntryInfo entry) =>
      _activeTasks[entry.cid]?.entry.status.isDownloading == true;

  late Future<void> waitForInitialization;

  @override
  void onInit() {
    super.onInit();
    _downloadTaskLimit = Pref.downloadTaskCount;
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(
      _onConnectivityChanged,
    );
    initDownloadList();
  }

  @override
  void onClose() {
    _connectivitySubscription?.cancel();
    super.onClose();
  }

  void initDownloadList() {
    waitForInitialization = _readDownloadList();
  }

  void _syncCurDownload() {
    final entry = _activeTasks.isEmpty ? null : _activeTasks.values.first.entry;
    _curCid = entry?.cid;
    if (curDownload.value?.cid == entry?.cid) {
      curDownload.refresh();
    } else {
      curDownload.value = entry;
    }
  }

  void _refreshDownloadState({bool refreshFlag = false}) {
    _syncCurDownload();
    waitDownloadQueue.refresh();
    if (refreshFlag) {
      flagNotifier.refresh();
    }
    _updateForegroundNotification();
  }

  void _updateEntryStatus(
    BiliDownloadEntryInfo entry,
    DownloadStatus status,
  ) {
    entry.status = status;
    _refreshDownloadState();
  }

  /// 启动前台服务
  Future<void> _startForegroundService() async {
    await DownloadForegroundService.start(
      title: '正在缓存 ${_activeTasks.length} 个任务',
      text: '准备中...',
    );
  }

  /// 更新前台服务通知
  void _updateForegroundNotification({bool force = false}) {
    if (_activeTasks.isEmpty) {
      unawaited(_stopForegroundService());
      return;
    }

    var totalBytes = 0;
    var downloadedBytes = 0;
    for (final task in _activeTasks.values) {
      totalBytes += task.entry.totalBytes;
      downloadedBytes += task.entry.downloadedBytes;
    }
    final progress = totalBytes > 0
        ? (downloadedBytes / totalBytes * 100).toStringAsFixed(1)
        : '0';

    unawaited(
      DownloadForegroundService.updateNotification(
        title: '正在缓存 ${_activeTasks.length} 个任务',
        text: '总进度: $progress%',
        force: force,
      ),
    );
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    _connectivityResults = results;
    if (_isNetworkAllowed(results)) {
      unawaited(_lock.synchronized(_scheduleDownloadsLocked));
    }
  }

  bool _isNetworkAllowed(List<ConnectivityResult> results) {
    if (!Pref.disableMobileDownload) {
      return true;
    }
    if (results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet)) {
      return true;
    }
    return !results.contains(ConnectivityResult.mobile) &&
        !results.contains(ConnectivityResult.none);
  }

  Future<bool> _canStartNewDownload({required bool isManual}) async {
    if (!Pref.disableMobileDownload) {
      return true;
    }
    final results =
        _connectivityResults ?? await _connectivity.checkConnectivity();
    _connectivityResults = results;
    final allowed = _isNetworkAllowed(results);
    if (!allowed && isManual) {
      SmartDialog.showToast('已禁止移动流量下载');
    }
    return allowed;
  }

  BiliDownloadEntryInfo? _nextWaitingEntry() {
    for (final entry in waitDownloadQueue) {
      if (!_activeTasks.containsKey(entry.cid) &&
          entry.status == DownloadStatus.wait) {
        return entry;
      }
    }
    return null;
  }

  Future<void> _scheduleDownloadsLocked() async {
    if (_schedulerPaused) {
      _refreshDownloadState();
      return;
    }

    while (_activeTasks.length < _downloadTaskLimit) {
      final entry = _nextWaitingEntry();
      if (entry == null) {
        break;
      }
      final started = await _startEntryLocked(entry, isManual: false);
      if (!started) {
        break;
      }
    }

    _refreshDownloadState();
  }

  bool get _isDownloadTaskLimitReached =>
      _activeTasks.length >= _downloadTaskLimit;

  bool _isFailedStatus(DownloadStatus status) => switch (status) {
    DownloadStatus.failDownload ||
    DownloadStatus.failDownloadAudio ||
    DownloadStatus.failDanmaku ||
    DownloadStatus.failPlayUrl => true,
    _ => false,
  };

  bool _shouldQueueBeforeStart(BiliDownloadEntryInfo entry) =>
      entry.status == DownloadStatus.pause || _isFailedStatus(entry.status);

  void _ensureInWaitQueue(BiliDownloadEntryInfo entry) {
    if (!waitDownloadQueue.contains(entry)) {
      waitDownloadQueue.add(entry);
    }
  }

  Future<void> _markEntryWaitingLocked(BiliDownloadEntryInfo entry) async {
    _ensureInWaitQueue(entry);
    if (entry.status != DownloadStatus.wait) {
      entry.status = DownloadStatus.wait;
      await _updateBiliDownloadEntryJson(entry);
    }
    _refreshDownloadState();
  }

  Future<bool> _startEntryLocked(
    BiliDownloadEntryInfo entry, {
    required bool isManual,
  }) async {
    if (_activeTasks.containsKey(entry.cid)) {
      return true;
    }
    if (!await _canStartNewDownload(isManual: isManual)) {
      return false;
    }

    entry.status = DownloadStatus.wait;
    final task = _ActiveDownloadTask(entry: entry, isManual: isManual);
    _activeTasks[entry.cid] = task;
    _refreshDownloadState();
    await _startForegroundService();
    _updateForegroundNotification(force: true);
    unawaited(_startDownload(task));
    return true;
  }

  Future<void> _releaseTaskLocked(
    _ActiveDownloadTask task, {
    required bool scheduleNext,
  }) async {
    _activeTasks.remove(task.entry.cid);
    _refreshDownloadState();
    if (scheduleNext) {
      await _scheduleDownloadsLocked();
    }
  }

  Future<void> _failTask(
    _ActiveDownloadTask task,
    DownloadStatus status,
  ) async {
    await _lock.synchronized(() async {
      if (!_activeTasks.containsKey(task.entry.cid)) {
        return;
      }
      task.entry.status = status;
      await _updateBiliDownloadEntryJson(task.entry);
      await _releaseTaskLocked(task, scheduleNext: true);
    });
  }

  Future<void> _pauseTaskLocked(
    _ActiveDownloadTask task, {
    required bool isDelete,
    DownloadStatus status = DownloadStatus.pause,
  }) async {
    if (!isDelete) {
      task.interruptedStatus = status;
    }
    _activeTasks.remove(task.entry.cid);
    await task.cancel(isDelete: isDelete);
    if (!isDelete) {
      task.entry.status = status;
      await _updateBiliDownloadEntryJson(task.entry);
    }
    _refreshDownloadState();
  }

  Future<void> _startDownloadByUserLocked(BiliDownloadEntryInfo entry) async {
    _schedulerPaused = false;
    if (_activeTasks.containsKey(entry.cid)) {
      return;
    }

    if (_isDownloadTaskLimitReached) {
      final task = _findYieldableActiveTask();
      if (task == null) {
        SmartDialog.showToast('当前缓存任务已满');
        return;
      }
      await _pauseTaskLocked(
        task,
        isDelete: false,
        status: DownloadStatus.wait,
      );
    }

    _ensureInWaitQueue(entry);
    final started = await _startEntryLocked(entry, isManual: true);
    if (started) {
      await _scheduleDownloadsLocked();
    }
  }

  Future<bool> _restoreInterruptedTaskStatus(
    _ActiveDownloadTask task,
  ) async {
    final activeTask = _activeTasks[task.entry.cid];
    if (identical(activeTask, task)) {
      return false;
    }
    if (activeTask != null) {
      return true;
    }
    final status = task.interruptedStatus;
    if (status != null && task.entry.status != status) {
      task.entry.status = status;
      await _updateBiliDownloadEntryJson(task.entry);
      _refreshDownloadState();
    }
    return true;
  }

  _ActiveDownloadTask? _findYieldableActiveTask() {
    for (final task in _activeTasks.values) {
      if (!task.isManual) {
        return task;
      }
    }
    if (_activeTasks.isEmpty) {
      return null;
    }
    return _activeTasks.values.first;
  }

  /// 停止前台服务
  Future<void> _stopForegroundService() async {
    await DownloadForegroundService.stop();
  }

  Future<void> _readDownloadList() async {
    downloadList.clear();
    final downloadDir = Directory(await _getDownloadPath());
    await for (final dir in downloadDir.list()) {
      if (dir is Directory) {
        downloadList.addAll(await _readDownloadDirectory(dir));
      }
    }
    downloadList.sort((a, b) => b.timeUpdateStamp.compareTo(a.timeUpdateStamp));
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<List<BiliDownloadEntryInfo>> _readDownloadDirectory(
    Directory pageDir,
  ) async {
    final result = <BiliDownloadEntryInfo>[];

    if (!pageDir.existsSync()) {
      return result;
    }

    await for (final entryDir in pageDir.list()) {
      if (entryDir is Directory) {
        final entryFile = File(path.join(entryDir.path, _entryFile));
        if (entryFile.existsSync()) {
          try {
            final entryJson = await entryFile.readAsString();
            final entry = BiliDownloadEntryInfo.fromJson(jsonDecode(entryJson))
              ..pageDirPath = pageDir.path
              ..entryDirPath = entryDir.path;
            if (entry.isCompleted) {
              result.add(entry);
            } else {
              waitDownloadQueue.add(entry..status = DownloadStatus.wait);
            }
          } catch (_) {}
        }
      }
    }

    return result;
  }

  void downloadVideo(
    Part page,
    VideoDetailData? videoDetail,
    ugc.EpisodeItem? videoArc,
    VideoQuality videoQuality,
  ) {
    final cid = page.cid!;
    if (downloadList.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    if (waitDownloadQueue.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    final pageData = PageInfo(
      cid: cid,
      page: page.page!,
      from: page.from,
      part: page.part,
      vid: page.vid,
      hasAlias: false,
      tid: 0,
      width: 0,
      height: 0,
      rotate: 0,
      downloadTitle: '视频已缓存完成',
      downloadSubtitle: videoDetail?.title ?? videoArc!.title,
    );
    final currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final entry = BiliDownloadEntryInfo(
      mediaType: 2,
      hasDashAudio: false,
      isCompleted: false,
      totalBytes: 0,
      downloadedBytes: 0,
      title: videoDetail?.title ?? videoArc!.title!,
      typeTag: videoQuality.code.toString(),
      cover: (videoDetail?.pic ?? videoArc!.cover!).http2https,
      preferedVideoQuality: videoQuality.code,
      qualityPithyDescription: videoQuality.desc,
      guessedTotalBytes: 0,
      totalTimeMilli: (page.duration ?? 0) * 1000,
      danmakuCount:
          videoDetail?.stat?.danmaku ?? videoArc?.arc?.stat?.danmaku ?? 0,
      timeUpdateStamp: currentTime,
      timeCreateStamp: currentTime,
      canPlayInAdvance: true,
      interruptTransformTempFile: false,
      avid: videoDetail?.aid ?? videoArc!.aid!,
      spid: 0,
      seasonId: null,
      ep: null,
      source: null,
      bvid: videoDetail?.bvid ?? videoArc!.bvid!,
      ownerId: videoDetail?.owner?.mid ?? videoArc?.arc?.author?.mid,
      ownerName: videoDetail?.owner?.name ?? videoArc?.arc?.author?.name,
      pageData: pageData,
    );
    _createDownload(entry);
  }

  void downloadBangumi(
    int index,
    PgcInfoModel pgcItem,
    pgc.EpisodeItem episode,
    VideoQuality quality,
  ) {
    final cid = episode.cid!;
    if (downloadList.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    if (waitDownloadQueue.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    final currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final source = SourceInfo(
      avId: episode.aid!,
      cid: cid,
    );
    final ep = EpInfo(
      avId: source.avId,
      page: index,
      danmaku: source.cid,
      cover: episode.cover!,
      episodeId: episode.id!,
      index: episode.title!,
      indexTitle: episode.longTitle ?? '',
      showTitle: episode.showTitle,
      from: episode.from ?? 'bangumi',
      seasonType: pgcItem.type ?? (episode.from == 'pugv' ? -1 : 0),
      width: 0,
      height: 0,
      rotate: 0,
      link: episode.link ?? '',
      bvid: episode.bvid ?? IdUtils.av2bv(source.avId),
      sortIndex: index,
    );
    final entry = BiliDownloadEntryInfo(
      mediaType: 2,
      hasDashAudio: false,
      isCompleted: false,
      totalBytes: 0,
      downloadedBytes: 0,
      title: pgcItem.seasonTitle ?? pgcItem.title ?? '',
      typeTag: quality.code.toString(),
      cover: episode.cover!,
      preferedVideoQuality: quality.code,
      qualityPithyDescription: quality.desc,
      guessedTotalBytes: 0,
      totalTimeMilli:
          (episode.duration ?? 0) *
          (episode.from == 'pugv' ? 1000 : 1), // pgc millisec,, pugv sec
      danmakuCount: pgcItem.stat?.danmaku ?? 0,
      timeUpdateStamp: currentTime,
      timeCreateStamp: currentTime,
      canPlayInAdvance: true,
      interruptTransformTempFile: false,
      spid: 0,
      seasonId: pgcItem.seasonId!.toString(),
      bvid: episode.bvid ?? IdUtils.av2bv(source.avId),
      avid: source.avId,
      ep: ep,
      source: source,
      ownerId: pgcItem.upInfo?.mid,
      ownerName: pgcItem.upInfo?.uname,
      pageData: null,
    );
    _createDownload(entry);
  }

  /// 直接通过已知标识（cid/aid/bvid/title/cover）创建并入列下载项，适用于动态/稍后再看等场景
  Future<void> downloadByIdentifiers({
    required int cid,
    required String bvid,
    required int totalTimeMilli,
    int? aid,
    String? title,
    String? cover,
    int? ownerId,
    String? ownerName,
    VideoQuality? quality,
  }) async {
    if (downloadList.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    final currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final preferQ = quality ?? VideoQuality.fromCode(Pref.defaultVideoQa);
    final entry = BiliDownloadEntryInfo(
      mediaType: 2,
      hasDashAudio: true,
      isCompleted: false,
      totalBytes: 0,
      downloadedBytes: 0,
      title: title ?? bvid,
      typeTag: preferQ.code.toString(),
      cover: cover ?? '',
      preferedVideoQuality: preferQ.code,
      qualityPithyDescription: preferQ.desc,
      guessedTotalBytes: 0,
      totalTimeMilli: totalTimeMilli,
      danmakuCount: 0,
      timeUpdateStamp: currentTime,
      timeCreateStamp: currentTime,
      canPlayInAdvance: true,
      interruptTransformTempFile: false,
      avid: aid ?? 0,
      spid: 0,
      seasonId: null,
      ep: null,
      source: null,
      bvid: bvid,
      ownerId: ownerId,
      ownerName: ownerName,
      pageData: PageInfo(
        cid: cid,
        page: 1,
        from: null,
        part: null,
        vid: null,
        hasAlias: false,
        tid: 0,
        width: 0,
        height: 0,
        rotate: 0,
        downloadTitle: '视频已缓存完成',
        downloadSubtitle: title,
      ),
    );
    await _createDownload(entry);
  }

  Future<void> _createDownload(BiliDownloadEntryInfo entry) async {
    final entryDir = await _getDownloadEntryDir(entry);
    entry
      ..pageDirPath = entryDir.parent.path
      ..entryDirPath = entryDir.path
      ..status = DownloadStatus.wait;
    final entryJsonFile = File(path.join(entryDir.path, _entryFile));
    await entryJsonFile.writeAsString(jsonEncode(entry.toJson()));
    waitDownloadQueue.add(entry);
    await _lock.synchronized(_scheduleDownloadsLocked);
  }

  Future<Directory> _getDownloadEntryDir(BiliDownloadEntryInfo entry) async {
    late final String dirName;
    late final String pageDirName;
    if (entry.ep case final ep?) {
      dirName = 's_${entry.seasonId}';
      pageDirName = ep.episodeId.toString();
    } else if (entry.pageData case final page?) {
      dirName = entry.avid.toString();
      pageDirName = 'c_${page.cid}';
    }
    final pageDir = Directory(
      path.join(await _getDownloadPath(), dirName, pageDirName),
    );
    if (!pageDir.existsSync()) {
      await pageDir.create(recursive: true);
    }
    return pageDir;
  }

  static Future<String> _getDownloadPath() async {
    final dir = Directory(downloadPath);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  Future<void> startDownload(BiliDownloadEntryInfo entry) {
    return _lock.synchronized(() => _startDownloadByUserLocked(entry));
  }

  Future<void> toggleDownload(BiliDownloadEntryInfo entry) {
    return _lock.synchronized(() async {
      final task = _activeTasks[entry.cid];
      if (task != null) {
        await _pauseTaskLocked(task, isDelete: false);
        await _scheduleDownloadsLocked();
        return;
      }

      if (_shouldQueueBeforeStart(entry) && _isDownloadTaskLimitReached) {
        await _markEntryWaitingLocked(entry);
        return;
      }

      await _startDownloadByUserLocked(entry);
    });
  }

  Future<void> startAllDownloads() {
    return _lock.synchronized(() async {
      _schedulerPaused = false;
      var hasWaitingEntry = false;
      for (final entry in waitDownloadQueue) {
        if (_activeTasks.containsKey(entry.cid) || entry.isCompleted) {
          continue;
        }
        if (entry.status == DownloadStatus.wait) {
          hasWaitingEntry = true;
          continue;
        }
        if (_shouldQueueBeforeStart(entry)) {
          entry.status = DownloadStatus.wait;
          await _updateBiliDownloadEntryJson(entry);
          hasWaitingEntry = true;
        }
      }
      if (hasWaitingEntry) {
        await _scheduleDownloadsLocked();
      } else {
        _refreshDownloadState();
      }
    });
  }

  Future<void> pauseAllDownloads() {
    return _lock.synchronized(() async {
      _schedulerPaused = true;
      final tasks = _activeTasks.values.toList();
      for (final task in tasks) {
        await _pauseTaskLocked(task, isDelete: false);
      }
      for (final entry in waitDownloadQueue) {
        if (entry.isCompleted ||
            _activeTasks.containsKey(entry.cid) ||
            entry.status != DownloadStatus.wait) {
          continue;
        }
        entry.status = DownloadStatus.pause;
        await _updateBiliDownloadEntryJson(entry);
      }
      _refreshDownloadState();
    });
  }

  Future<bool> downloadDanmaku({
    required BiliDownloadEntryInfo entry,
    bool isUpdate = false,
  }) async {
    final cid = entry.pageData?.cid ?? entry.source?.cid;
    if (cid == null || entry.totalTimeMilli == 0) {
      return false;
    }
    final danmakuFile = File(
      path.join(entry.entryDirPath, PathUtils.danmakuName),
    );
    if (isUpdate || !danmakuFile.existsSync()) {
      try {
        if (!isUpdate) {
          _updateEntryStatus(entry, DownloadStatus.getDanmaku);
        }
        final seg = (entry.totalTimeMilli / DmUtils.segLength).ceil();
        if (seg <= 0) {
          throw StateError('Invalid danmaku segment count: $seg');
        }

        final danmaku = (await DmGrpc.dmSegMobile(
          cid: cid,
          segmentIndex: 1,
        )).data;
        for (var start = 2; start <= seg; start += _maxDanmakuConcurrency) {
          final end = start + _maxDanmakuConcurrency - 1;
          final responses = await Future.wait([
            for (var index = start; index <= seg && index <= end; index++)
              DmGrpc.dmSegMobile(cid: cid, segmentIndex: index),
          ]);
          for (final response in responses) {
            danmaku.elems.addAll(response.data.elems);
          }
          responses.clear();
        }
        await danmakuFile.writeAsBytes(danmaku.writeToBuffer());

        return true;
      } catch (e) {
        if (!isUpdate) {
          _updateEntryStatus(entry, DownloadStatus.failDanmaku);
        }
        if (kDebugMode) SmartDialog.showToast(e.toString());
        return false;
      }
    }
    return true;
  }

  Future<bool> _downloadCover({
    required BiliDownloadEntryInfo entry,
  }) async {
    try {
      final filePath = path.join(entry.entryDirPath, PathUtils.coverName);
      if (File(filePath).existsSync()) {
        return true;
      }
      final file = (await CacheManager.manager.getFileFromCache(
        entry.cover,
      ))?.file;
      if (file != null) {
        await file.copy(filePath);
      } else {
        await Request.dio.download(entry.cover, filePath);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _startDownload(_ActiveDownloadTask task) async {
    final entry = task.entry;
    try {
      if (!await downloadDanmaku(entry: entry)) {
        if (await _restoreInterruptedTaskStatus(task)) {
          return;
        }
        await _failTask(task, DownloadStatus.failDanmaku);
        return;
      }
      if (await _restoreInterruptedTaskStatus(task)) {
        return;
      }

      _updateEntryStatus(entry, DownloadStatus.getPlayUrl);

      final mediaFileInfo = await DownloadHttp.getVideoUrl(
        entry: entry,
        ep: entry.ep,
        source: entry.source,
        pageData: entry.pageData,
      );
      if (await _restoreInterruptedTaskStatus(task)) {
        return;
      }

      final videoDir = Directory(path.join(entry.entryDirPath, entry.typeTag));
      if (!videoDir.existsSync()) {
        await videoDir.create(recursive: true);
      }

      final mediaJsonFile = File(path.join(videoDir.path, _indexFile));
      await Future.wait([
        mediaJsonFile.writeAsString(jsonEncode(mediaFileInfo.toJson())),
        _downloadCover(entry: entry),
      ]);

      if (await _restoreInterruptedTaskStatus(task)) {
        return;
      }

      switch (mediaFileInfo) {
        case Type1 mediaFileInfo:
          final first = mediaFileInfo.segmentList.first;
          task.videoManager = DownloadManager(
            url: first.url,
            path: path.join(videoDir.path, PathUtils.videoNameType1),
            onReceiveProgress: (progress, total) =>
                _onReceive(task, progress, total),
            onDone: ([error]) => _onDone(task, error),
          );
          break;
        case Type2 mediaFileInfo:
          task.videoManager = DownloadManager(
            url: mediaFileInfo.video.first.baseUrl,
            path: path.join(videoDir.path, PathUtils.videoNameType2),
            onReceiveProgress: (progress, total) =>
                _onReceive(task, progress, total),
            onDone: ([error]) => _onDone(task, error),
          );
          final audio = mediaFileInfo.audio;
          if (audio != null && audio.isNotEmpty) {
            task.audioManager = DownloadManager(
              url: audio.first.baseUrl,
              path: path.join(videoDir.path, PathUtils.audioNameType2),
              onReceiveProgress: null,
              onDone: ([error]) => _onAudioDone(task, error),
            );
          }
          late final first = mediaFileInfo.video.first;
          entry.pageData
            ?..width = first.width
            ..height = first.height;
          entry.ep
            ?..width = first.width
            ..height = first.height;
          _updateBiliDownloadEntryJson(entry);
          break;
        default:
          break;
      }
    } catch (e) {
      if (await _restoreInterruptedTaskStatus(task)) {
        return;
      }
      await _failTask(task, DownloadStatus.failPlayUrl);
      if (kDebugMode) {
        debugPrint('get download url error: $e');
      }
    }
  }

  Future<void> _updateBiliDownloadEntryJson(BiliDownloadEntryInfo entry) {
    final entryJsonFile = File(path.join(entry.entryDirPath, _entryFile));
    return entryJsonFile.writeAsString(jsonEncode(entry.toJson()));
  }

  void _onReceive(_ActiveDownloadTask task, int progress, int total) {
    if (!identical(_activeTasks[task.entry.cid], task)) {
      return;
    }
    final entry = task.entry;
    if (progress == 0 && total != 0) {
      unawaited(_updateBiliDownloadEntryJson(entry..totalBytes = total));
    }
    entry
      ..downloadedBytes = progress
      ..status = DownloadStatus.downloading;
    _refreshDownloadState();
  }

  void _onDone(_ActiveDownloadTask task, [Object? error]) {
    unawaited(_handleVideoDone(task, error));
  }

  void _onAudioDone(_ActiveDownloadTask task, [Object? error]) {
    unawaited(_handleAudioDone(task, error));
  }

  Future<void> _handleVideoDone(_ActiveDownloadTask task, Object? error) async {
    await _lock.synchronized(() async {
      if (!identical(_activeTasks[task.entry.cid], task)) {
        return;
      }

      if (error != null) {
        final status = task.videoManager?.status ?? DownloadStatus.pause;
        task.entry.status = status;
        if (status == DownloadStatus.failDownload) {
          await task.audioManager?.cancel(isDelete: false);
          await _updateBiliDownloadEntryJson(task.entry);
          await _releaseTaskLocked(task, scheduleNext: true);
        } else {
          _refreshDownloadState();
        }
        return;
      }

      final status = switch (task.audioManager?.status) {
        DownloadStatus.downloading => DownloadStatus.audioDownloading,
        DownloadStatus.failDownload => DownloadStatus.failDownloadAudio,
        _ => task.videoManager?.status ?? DownloadStatus.pause,
      };
      task.entry
        ..status = status
        ..downloadedBytes = task.entry.totalBytes;

      if (status == DownloadStatus.completed) {
        await _completeDownloadLocked(task);
      } else if (status == DownloadStatus.failDownload ||
          status == DownloadStatus.failDownloadAudio) {
        await _updateBiliDownloadEntryJson(task.entry);
        await _releaseTaskLocked(task, scheduleNext: true);
      } else {
        await _updateBiliDownloadEntryJson(task.entry);
        _refreshDownloadState();
      }
    });
  }

  Future<void> _handleAudioDone(_ActiveDownloadTask task, Object? error) async {
    await _lock.synchronized(() async {
      if (!identical(_activeTasks[task.entry.cid], task) ||
          task.videoManager?.status != DownloadStatus.completed) {
        return;
      }
      if (error == null) {
        await _completeDownloadLocked(task);
      } else {
        final status = task.audioManager?.status ?? DownloadStatus.pause;
        task.entry.status = status == DownloadStatus.failDownload
            ? DownloadStatus.failDownloadAudio
            : status;
        if (task.entry.status == DownloadStatus.failDownloadAudio) {
          await _updateBiliDownloadEntryJson(task.entry);
          await _releaseTaskLocked(task, scheduleNext: true);
        } else {
          _refreshDownloadState();
        }
      }
    });
  }

  Future<void> _completeDownloadLocked(_ActiveDownloadTask task) async {
    final entry = task.entry;
    entry
      ..downloadedBytes = entry.totalBytes
      ..isCompleted = true;
    await _updateBiliDownloadEntryJson(entry);
    waitDownloadQueue.remove(entry);
    downloadList.insert(0, entry);
    await _releaseTaskLocked(
      task,
      scheduleNext: true,
    );
    flagNotifier.refresh();
  }

  void nextDownload() {
    unawaited(_lock.synchronized(_scheduleDownloadsLocked));
  }

  Future<void> deleteDownload({
    required BiliDownloadEntryInfo entry,
    bool removeList = false,
    bool removeQueue = false,
    bool refresh = true,
    bool downloadNext = true,
  }) async {
    if (removeList) {
      downloadList.remove(entry);
    }
    if (removeQueue) {
      waitDownloadQueue.remove(entry);
    }
    if (_activeTasks.containsKey(entry.cid)) {
      await cancelDownload(
        entry: entry,
        isDelete: true,
        downloadNext: downloadNext,
      );
    }
    final downloadDir = Directory(entry.pageDirPath);
    if (downloadDir.existsSync()) {
      if (!await downloadDir.lengthGte(2)) {
        await downloadDir.tryDel(recursive: true);
      } else {
        final entryDir = Directory(entry.entryDirPath);
        if (entryDir.existsSync()) {
          await entryDir.tryDel(recursive: true);
        }
      }
    }
    if (refresh) {
      flagNotifier.refresh();
    }
  }

  Future<void> deletePage({
    required String pageDirPath,
    bool refresh = true,
  }) async {
    await Directory(pageDirPath).tryDel(recursive: true);
    downloadList.removeWhere((e) => e.pageDirPath == pageDirPath);
    if (refresh) {
      flagNotifier.refresh();
    }
  }

  Future<void> cancelDownload({
    BiliDownloadEntryInfo? entry,
    required bool isDelete,
    bool downloadNext = true,
  }) async {
    await _lock.synchronized(() async {
      if (entry == null) {
        _schedulerPaused = !isDelete;
        final tasks = _activeTasks.values.toList();
        for (final task in tasks) {
          await _pauseTaskLocked(task, isDelete: isDelete);
        }
        if (downloadNext) {
          await _scheduleDownloadsLocked();
        } else {
          _refreshDownloadState();
        }
        return;
      }

      final target = entry;
      final task = _activeTasks[target.cid];
      if (task == null) {
        return;
      }
      await _pauseTaskLocked(task, isDelete: isDelete);
      if (isDelete) {
        waitDownloadQueue.remove(target);
      }
      if (downloadNext) {
        await _scheduleDownloadsLocked();
      } else {
        _refreshDownloadState();
      }
    });
  }
}

class _ActiveDownloadTask {
  _ActiveDownloadTask({
    required this.entry,
    required this.isManual,
  });

  final BiliDownloadEntryInfo entry;
  final bool isManual;
  DownloadManager? videoManager;
  DownloadManager? audioManager;
  DownloadStatus? interruptedStatus;

  Future<void> cancel({required bool isDelete}) async {
    await videoManager?.cancel(isDelete: isDelete);
    await audioManager?.cancel(isDelete: isDelete);
    videoManager = null;
    audioManager = null;
  }
}

typedef SetNotifier = Set<VoidCallback>;

extension SetNotifierExt on SetNotifier {
  void refresh() {
    for (final i in this) {
      i();
    }
  }
}
