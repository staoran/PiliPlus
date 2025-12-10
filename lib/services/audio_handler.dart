import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pb.dart' show DetailItem;
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/live/live_room_info_h5/data.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get_utils/get_utils.dart';

Future<VideoPlayerServiceHandler> initAudioService() {
  return AudioService.init(
    builder: VideoPlayerServiceHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.taoran.piliplus.audio',
      androidNotificationChannelName: 'Audio Service ${Constants.appName}',
      // 暂停时停止前台服务，这样退出页面时媒体卡片会自动消失
      // 后台播放场景下用户不会退出页面，所以不受影响
      androidStopForegroundOnPause: true,
      fastForwardInterval: Duration(seconds: 10),
      rewindInterval: Duration(seconds: 10),
      androidNotificationChannelDescription: 'Media notification channel',
      androidNotificationIcon: 'drawable/ic_notification_icon',
    ),
  );
}

class VideoPlayerServiceHandler extends BaseAudioHandler with SeekHandler {
  static final List<MediaItem> _item = [];
  bool enableBackgroundPlay = Pref.enableBackgroundPlay;

  Function? onPlay;
  Function? onPause;
  Function(Duration position)? onSeek;

  // 列表播放相关回调
  Function? onSkipToNext;
  Function? onSkipToPrevious;

  // 是否启用列表控制（上一个/下一个）
  bool _enableListControl = false;

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
  Future<void> play() async {
    onPlay?.call() ?? PlPlayerController.playIfExists();
    // player.play();
  }

  @override
  Future<void> pause() async {
    await (onPause?.call() ?? PlPlayerController.pauseIfExists());
    // player.pause();
  }

  @override
  Future<void> stop() async {
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
  Future<void> seek(Duration position) async {
    playbackState.add(
      playbackState.value.copyWith(
        updatePosition: position,
      ),
    );
    await (onSeek?.call(position) ??
        PlPlayerController.seekToIfExists(position, isSeek: false));
    // await player.seekTo(position);
  }

  Future<void> setMediaItem(MediaItem newMediaItem) async {
    if (!enableBackgroundPlay) return;
    // if (kDebugMode) {
    //   debugPrint("此时调用栈为：");
    //   debugPrint(newMediaItem);
    //   debugPrint(newMediaItem.title);
    //   debugPrint(StackTrace.current.toString());
    // }
    if (!mediaItem.isClosed) mediaItem.add(newMediaItem);
  }

  Future<void> setPlaybackState(
    PlayerStatus status,
    bool isBuffering,
    bool isLive,
  ) async {
    if (!enableBackgroundPlay ||
        _item.isEmpty ||
        !PlPlayerController.instanceExists()) {
      return;
    }

    final AudioProcessingState processingState;
    final playing = status == PlayerStatus.playing;
    if (status == PlayerStatus.completed) {
      processingState = AudioProcessingState.completed;
    } else if (isBuffering) {
      processingState = AudioProcessingState.buffering;
    } else {
      processingState = AudioProcessingState.ready;
    }

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
    setPlaybackState(status, isBuffering, isLive);
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

    late final id = '$cid$herotag';
    MediaItem? mediaItem;
    if (data is VideoDetailData) {
      if ((data.pages?.length ?? 0) > 1) {
        final current = data.pages?.firstWhereOrNull(
          (element) => element.cid == cid,
        );
        mediaItem = MediaItem(
          id: id,
          title: current?.part ?? '',
          artist: data.owner?.name,
          duration: Duration(seconds: current?.duration ?? 0),
          artUri: Uri.parse(data.pic ?? ''),
        );
      } else {
        mediaItem = MediaItem(
          id: id,
          title: data.title ?? '',
          artist: data.owner?.name,
          duration: Duration(seconds: data.duration ?? 0),
          artUri: Uri.parse(data.pic ?? ''),
        );
      }
    } else if (data is EpisodeItem) {
      mediaItem = MediaItem(
        id: id,
        title: data.showTitle ?? data.longTitle ?? data.title ?? '',
        artist: artist,
        duration: data.from == 'pugv'
            ? Duration(seconds: data.duration ?? 0)
            : Duration(milliseconds: data.duration ?? 0),
        artUri: Uri.parse(data.cover ?? ''),
      );
    } else if (data is RoomInfoH5Data) {
      mediaItem = MediaItem(
        id: id,
        title: data.roomInfo?.title ?? '',
        artist: data.anchorInfo?.baseInfo?.uname,
        artUri: Uri.parse(data.roomInfo?.cover ?? ''),
        isLive: true,
      );
    } else if (data is Part) {
      mediaItem = MediaItem(
        id: id,
        title: data.part ?? '',
        artist: artist,
        duration: Duration(seconds: data.duration ?? 0),
        artUri: Uri.parse(cover ?? ''),
      );
    } else if (data is DetailItem) {
      mediaItem = MediaItem(
        id: id,
        title: data.arc.title,
        artist: data.owner.name,
        duration: Duration(seconds: data.arc.duration.toInt()),
        artUri: Uri.parse(data.arc.cover),
      );
    } else if (data is BiliDownloadEntryInfo) {
      mediaItem = MediaItem(
        id: id,
        title: data.showTitle,
        artist: data.ownerName,
        duration: Duration(milliseconds: data.totalTimeMilli),
        artUri: Uri.parse(data.cover),
      );
    }
    if (mediaItem == null) return;
    if (!PlPlayerController.instanceExists()) return;
    _item.add(mediaItem);
    if (kDebugMode) {
      debugPrint('[AudioService] mediaItem added: ${mediaItem.title}');
      debugPrint('[AudioService] _item.length: ${_item.length}');
    }
    setMediaItem(mediaItem);
  }

  void onVideoDetailDispose(String herotag) {
    if (!enableBackgroundPlay) return;

    if (_item.isNotEmpty) {
      _item.removeWhere((item) => item.id.endsWith(herotag));
    }

    if (_item.isNotEmpty) {
      // 还有其他视频在播放，切换到上一个
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.idle,
          playing: false,
        ),
      );
      setMediaItem(_item.last);
      stop();
    } else {
      // 没有其他视频了，但不在这里停止服务
      // 由页面 dispose 中的 clear(force: true) 负责停止
      // 这里只需确保状态是 idle，以便后续 clear() 能正确工作
    }
  }

  /// 清理媒体通知，停止前台服务
  /// [force] 强制清理，忽略 enableBackgroundPlay 设置
  Future<void> clear({bool force = false}) async {
    if (!force && !enableBackgroundPlay) return;

    _item.clear();

    // 清除 mediaItem
    if (!mediaItem.isClosed) {
      mediaItem.add(null);
    }

    // 重置列表控制模式
    _enableListControl = false;
    onSkipToNext = null;
    onSkipToPrevious = null;

    // 调用 stop() 来停止服务
    // stop() 会设置 processingState 为 idle 并触发 audio_service 停止前台服务
    await stop();
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
