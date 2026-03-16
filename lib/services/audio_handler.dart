import 'dart:async';
import 'dart:io' show File;

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pb.dart' show DetailItem;
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/live/live_room_info_h5/data.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:path/path.dart' as path;

Future<VideoPlayerServiceHandler> initAudioService() {
  return AudioService.init(
    builder: VideoPlayerServiceHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.taoran.piliplus.audio',
      androidNotificationChannelName: 'Audio Service ${Constants.appName}',
      // 本项目的视频/听视频页并不依赖 Android 的媒体恢复入口。
      // 关闭 resume-on-click，避免服务销毁后 SystemUI 继续保留可恢复媒体卡片。
      androidResumeOnClick: false,
      // 采用 audio_service 推荐的暂停即退出前台策略，确保系统可以移除通知。
      androidStopForegroundOnPause: true,
      fastForwardInterval: Duration(seconds: 10),
      rewindInterval: Duration(seconds: 10),
      androidNotificationChannelDescription: 'Media notification channel',
      androidNotificationIcon: 'drawable/ic_notification_icon',
    ),
  );
}

class VideoPlayerServiceHandler extends BaseAudioHandler with SeekHandler {
  static const _backgroundPauseGracePeriod = Duration(minutes: 2);
  static final List<MediaItem> _item = [];
  static final Set<String> _activeOwners = <String>{};
  static final Set<String> _disposedOwners = <String>{};
  bool enableBackgroundPlay = Pref.enableBackgroundPlay;
  bool _lifecycleDebugLogEnabled = kDebugMode && Pref.enableLog;
  Future<void>? _clearFuture;
  Timer? _pauseReleaseTimer;

  Future<void>? Function()? onPlay;
  Future<void>? Function()? onPause;
  Future<void>? Function(Duration position)? onSeek;

  // 列表播放相关回调
  Function? onSkipToNext;
  Function? onSkipToPrevious;

  // 是否启用列表控制（上一个/下一个）
  bool _enableListControl = false;

  int get ownerCount => _activeOwners.length;

  /// 现场排障开关：可在运行时打开/关闭媒体卡片生命周期日志。
  /// 注：日志只在 debug 构建生效。
  void setLifecycleDebugLogEnabled(bool enabled) {
    _lifecycleDebugLogEnabled = enabled;
    _logLifecycle('lifecycle debug log => $enabled');
  }

  void _logLifecycle(String message) {
    if (_lifecycleDebugLogEnabled && kDebugMode) {
      debugPrint('[AudioServiceLifecycle] $message');
    }
  }

  /// 设置列表控制模式
  /// 注意：控件会在下次播放状态更新时自动刷新，不需要立即刷新
  void setListControlMode({
    bool enabled = false,
    Function? onNext,
    Function? onPrevious,
  }) {
    _enableListControl = enabled;
    onSkipToNext = onNext;
    onSkipToPrevious = onPrevious;
  }

  @override
  Future<void> skipToNext() async {
    if (_enableListControl && onSkipToNext != null) {
      onSkipToNext!.call();
    } else {
      // 默认快进10秒
      await fastForward();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_enableListControl && onSkipToPrevious != null) {
      onSkipToPrevious!.call();
    } else {
      // 默认快退10秒
      await rewind();
    }
  }

  @override
  Future<void> play() {
    _cancelPauseReleaseTimer();
    return onPlay?.call() ??
        PlPlayerController.playIfExists() ??
        Future.syncValue(null);
    // player.play();
  }

  @override
  Future<void> pause() {
    return onPause?.call() ?? PlPlayerController.pauseIfExists();
    // player.pause();
  }

  @override
  Future<void> stop() async {
    _cancelPauseReleaseTimer();
    // 检查当前状态，如果已经是 idle，需要先设置为非 idle
    // 这样才能触发 audio_service Android 端的 stop() 逻辑
    // 根据 AudioService.java 源码：
    // if (oldProcessingState != AudioProcessingState.idle && processingState == AudioProcessingState.idle) {
    //     stop();
    // }
    final currentState = playbackState.value.processingState;
    if (currentState == AudioProcessingState.idle) {
      // 先设置为 ready，然后 super.stop() 会设置回 idle，从而触发停止
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.ready,
          playing: false,
        ),
      );
    }
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    // 用户在任务管理器划掉应用时，停止媒体服务并移除通知卡片。
    await clear(force: true);
  }

  bool get _isAppInForeground =>
      SchedulerBinding.instance.lifecycleState == AppLifecycleState.resumed;

  void _cancelPauseReleaseTimer() {
    _pauseReleaseTimer?.cancel();
    _pauseReleaseTimer = null;
  }

  void _schedulePauseRelease() {
    _cancelPauseReleaseTimer();
    final delay = _isAppInForeground
        ? Duration.zero
        : _backgroundPauseGracePeriod;
    if (kDebugMode) {
      debugPrint(
        '[AudioService] pause release scheduled in ${delay.inSeconds}s',
      );
    }
    _pauseReleaseTimer = Timer(delay, () {
      _pauseReleaseTimer = null;
      final state = playbackState.value;
      final shouldRelease =
          !state.playing &&
          state.processingState != AudioProcessingState.buffering &&
          state.processingState != AudioProcessingState.completed;
      if (!shouldRelease || _item.isEmpty) {
        return;
      }
      if (kDebugMode) {
        debugPrint('[AudioService] pause grace expired, stopping service');
      }
      _logLifecycle(
        'pause grace expired; owners=$ownerCount, items=${_item.length}',
      );
      unawaited(stop());
    });
  }

  @override
  Future<void> seek(Duration position) {
    playbackState.add(
      playbackState.value.copyWith(
        updatePosition: position,
      ),
    );
    return (onSeek?.call(position) ??
        PlPlayerController.seekToIfExists(position, isSeek: false));
    // await player.seekTo(position);
  }

  void setMediaItem(MediaItem newMediaItem) {
    if (!enableBackgroundPlay) return;
    // if (kDebugMode) {
    //   debugPrint("此时调用栈为：");
    //   debugPrint(newMediaItem);
    //   debugPrint(newMediaItem.title);
    //   debugPrint(StackTrace.current.toString());
    // }
    if (!mediaItem.isClosed) mediaItem.add(newMediaItem);
  }

  void setPlaybackState(
    PlayerStatus status,
    bool isBuffering,
    bool isLive,
  ) {
    if (!enableBackgroundPlay ||
        _item.isEmpty ||
        !PlPlayerController.instanceExists()) {
      return;
    }

    final AudioProcessingState processingState;
    if (status.isCompleted) {
      processingState = AudioProcessingState.completed;
    } else if (isBuffering) {
      processingState = AudioProcessingState.buffering;
    } else {
      processingState = AudioProcessingState.ready;
    }

    final playing = status.isPlaying;
    playbackState.add(
      playbackState.value.copyWith(
        processingState: isBuffering
            ? AudioProcessingState.buffering
            : processingState,
        controls: _buildMediaControls(playing, isLive),
        playing: playing,
        systemActions: const {
          MediaAction.seek,
        },
      ),
    );
  }

  /// 构建媒体控制按钮列表
  List<MediaControl> _buildMediaControls(bool playing, bool isLive) {
    if (_enableListControl) {
      // 列表播放模式：显示上一个/下一个
      return [
        if (!isLive && onSkipToPrevious != null)
          MediaControl.skipToPrevious.copyWith(
            androidIcon: 'drawable/ic_baseline_skip_previous_24',
          ),
        if (playing) MediaControl.pause else MediaControl.play,
        if (!isLive && onSkipToNext != null)
          MediaControl.skipToNext.copyWith(
            androidIcon: 'drawable/ic_baseline_skip_next_24',
          ),
      ];
    } else {
      // 普通模式：显示快退/快进
      return [
        if (!isLive)
          MediaControl.rewind.copyWith(
            androidIcon: 'drawable/ic_baseline_replay_10_24',
          ),
        if (playing) MediaControl.pause else MediaControl.play,
        if (!isLive)
          MediaControl.fastForward.copyWith(
            androidIcon: 'drawable/ic_baseline_forward_10_24',
          ),
      ];
    }
  }

  void onStatusChange(PlayerStatus status, bool isBuffering, isLive) {
    if (!enableBackgroundPlay) return;

    if (_item.isEmpty) return;
    _logLifecycle(
      'status=${status.name}, buffering=$isBuffering, owners=$ownerCount, items=${_item.length}',
    );
    setPlaybackState(status, isBuffering, isLive);
    if (status.isPlaying || isBuffering || status.isCompleted) {
      _cancelPauseReleaseTimer();
    } else if (status.isPaused) {
      _schedulePauseRelease();
    }
  }

  /// 统一处理“播放完成”后的通知卡片策略。
  ///
  /// 方案对比说明：
  /// - 旧方案：页面自行判断是否 clear(force: true)。
  /// - 新方案：页面只上报“是否会继续播放”，由 handler 统一决定清理。
  ///   这样可减少页面分叉逻辑，便于排查残留问题。
  void onPlaybackCompleted({
    required bool willAutoContinue,
    String source = 'unknown',
  }) {
    _logLifecycle(
      'completed from=$source, willAutoContinue=$willAutoContinue, owners=$ownerCount, items=${_item.length}',
    );
    if (willAutoContinue) {
      _cancelPauseReleaseTimer();
      return;
    }
    unawaited(clear(force: true));
  }

  void onVideoDetailChange(
    dynamic data,
    int cid,
    String herotag, {
    String? artist,
    String? cover,
  }) {
    if (kDebugMode) {
      debugPrint('[AudioService] onVideoDetailChange called');
      debugPrint('[AudioService] enableBackgroundPlay: $enableBackgroundPlay');
    }
    if (!enableBackgroundPlay) return;
    if (!PlPlayerController.instanceExists()) return;
    if (data == null) return;

    // 方案说明（用于后续冲突对比）：
    // - 旧方案默认接受所有晚到的 onVideoDetailChange。
    // - 新方案会拒绝已释放 owner 的晚到回调，避免页面退出后异步请求把媒体卡片重新挂回系统。
    if (_disposedOwners.contains(herotag)) {
      _logLifecycle('ignore stale owner attach: $herotag');
      return;
    }

    _activeOwners.add(herotag);
    _logLifecycle('owner attached: $herotag, owners=$ownerCount');

    Uri getUri(String? cover) => Uri.parse(ImageUtils.safeThumbnailUrl(cover));

    late final id = '$cid$herotag';
    final MediaItem mediaItem;
    switch (data) {
      case VideoDetailData(:final pages):
        if (pages != null && pages.length > 1) {
          final current = pages.firstWhereOrNull((e) => e.cid == cid);
          mediaItem = MediaItem(
            id: id,
            title: current?.part ?? '',
            artist: data.owner?.name,
            duration: Duration(seconds: current?.duration ?? 0),
            artUri: getUri(data.pic),
          );
        } else {
          mediaItem = MediaItem(
            id: id,
            title: data.title ?? '',
            artist: data.owner?.name,
            duration: Duration(seconds: data.duration ?? 0),
            artUri: getUri(data.pic),
          );
        }
      case EpisodeItem():
        mediaItem = MediaItem(
          id: id,
          title: data.showTitle ?? data.longTitle ?? data.title ?? '',
          artist: artist,
          duration: data.from == 'pugv'
              ? Duration(seconds: data.duration ?? 0)
              : Duration(milliseconds: data.duration ?? 0),
          artUri: getUri(data.cover),
        );
      case RoomInfoH5Data():
        mediaItem = MediaItem(
          id: id,
          title: data.roomInfo?.title ?? '',
          artist: data.anchorInfo?.baseInfo?.uname,
          artUri: getUri(data.roomInfo?.cover),
          isLive: true,
        );
      case Part():
        mediaItem = MediaItem(
          id: id,
          title: data.part ?? '',
          artist: artist,
          duration: Duration(seconds: data.duration ?? 0),
          artUri: getUri(cover),
        );
      case DetailItem(:final arc):
        mediaItem = MediaItem(
          id: id,
          title: arc.title,
          artist: data.owner.name,
          duration: Duration(seconds: arc.duration.toInt()),
          artUri: getUri(arc.cover),
        );
      case BiliDownloadEntryInfo():
        final coverFile = File(
          path.join(data.entryDirPath, PathUtils.coverName),
        );
        final uri = coverFile.existsSync()
            ? coverFile.absolute.uri
            : getUri(data.cover);
        mediaItem = MediaItem(
          id: id,
          title: data.showTitle,
          artist: data.ownerName,
          duration: Duration(milliseconds: data.totalTimeMilli),
          artUri: uri,
        );
      default:
        return;
    }
    if (!PlPlayerController.instanceExists()) return;
    _item.add(mediaItem);
    if (kDebugMode) {
      debugPrint('[AudioService] mediaItem added: ${mediaItem.title}');
      debugPrint('[AudioService] _item.length: ${_item.length}');
    }
    setMediaItem(mediaItem);
  }

  void onVideoDetailDispose(String herotag) {
    // 方案说明（用于后续冲突对比）：
    // - 旧方案：页面层在多个生命周期里手动 clear(force: true)。
    // - 新方案：统一由 handler 在“owner 释放”时决定是否 clear。
    // 这样可以避免页面层与 handler 层同时清理导致的竞态和通知残留。
    if (!enableBackgroundPlay) return;

    _disposedOwners.add(herotag);
    _activeOwners.remove(herotag);
    _logLifecycle('owner disposed: $herotag, owners=$ownerCount');

    if (_item.isNotEmpty) {
      _item.removeWhere((item) => item.id.endsWith(herotag));
    }

    if (_item.isEmpty) {
      // 最后一个 owner 释放时，由 handler 统一关闭通知。
      // 不再依赖页面层分散 clear，避免“有时清掉/有时残留”的不稳定行为。
      _logLifecycle('last owner disposed -> clear notification');
      unawaited(clear(force: true));
      return;
    }

    // 仍有其他 owner 时，只更新通知展示目标，不主动 stop。
    // stop 会导致仍在用的会话被提前降级，表现为控制项闪烁或状态错乱。
    setMediaItem(_item.last);
  }


  /// 清理媒体通知，停止前台服务
  /// [force] 强制清理，忽略 enableBackgroundPlay 设置
  Future<void> clear({bool force = false}) async {
    if (!force && !enableBackgroundPlay) return;

    if (_clearFuture != null) {
      return _clearFuture!;
    }

    _clearFuture = () async {
      _cancelPauseReleaseTimer();
      _item.clear();
      _activeOwners.clear();
      _disposedOwners.clear();
      _logLifecycle('clear called(force=$force), owners=0, items=0');

      // 立即重置播放状态，避免通知卡片在 stop 完成前残留旧进度和按钮
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.idle,
          playing: false,
          controls: const [],
          systemActions: const {},
          updatePosition: Duration.zero,
        ),
      );

      // 重置列表控制模式
      _enableListControl = false;
      onSkipToNext = null;
      onSkipToPrevious = null;

      await stop();
    }();

    try {
      await _clearFuture;
    } finally {
      _clearFuture = null;
    }
  }

  void onPositionChange(Duration position) {
    if (!enableBackgroundPlay ||
        _item.isEmpty ||
        !PlPlayerController.instanceExists()) {
      return;
    }

    playbackState.add(
      playbackState.value.copyWith(
        updatePosition: position,
      ),
    );
  }
}
