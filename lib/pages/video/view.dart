import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/custom_icon.dart';
import 'package:PiliPlus/common/widgets/flutter/pop_scope.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/keep_alive_wrapper.dart';
import 'package:PiliPlus/common/widgets/route_aware_mixin.dart';
import 'package:PiliPlus/common/widgets/scroll_physics.dart';
import 'package:PiliPlus/models/common/episode_panel_type.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart'
    as pgc;
import 'package:PiliPlus/models_new/pgc/pgc_info_model/result.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart' as ugc;
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/models_new/video/video_detail/ugc_season.dart';
import 'package:PiliPlus/models_new/video/video_tag/data.dart';
import 'package:PiliPlus/pages/audio/controller.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/danmaku/view.dart';
import 'package:PiliPlus/pages/episode_panel/view.dart';
import 'package:PiliPlus/pages/video/ai_conclusion/view.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/local/controller.dart';
import 'package:PiliPlus/pages/video/introduction/local/view.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/view.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/widgets/intro_detail.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/view.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/page.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/season.dart';
import 'package:PiliPlus/pages/video/member/controller.dart';
import 'package:PiliPlus/pages/video/member/view.dart';
import 'package:PiliPlus/pages/video/related/view.dart';
import 'package:PiliPlus/pages/video/reply/controller.dart';
import 'package:PiliPlus/pages/video/reply/view.dart';
import 'package:PiliPlus/pages/video/view_point/view.dart';
import 'package:PiliPlus/pages/video/widgets/header_control.dart';
import 'package:PiliPlus/pages/video/widgets/player_focus.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/plugin/pl_player/view/view.dart';
import 'package:PiliPlus/services/battery_debug_service.dart';
import 'package:PiliPlus/services/debug_log_service.dart';
import 'package:PiliPlus/services/multi_window/player_window_service.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart'
    show shutdownTimerService;
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/max_screen_size.dart';
import 'package:PiliPlus/utils/mobile_observer.dart';
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';

class VideoDetailPageV extends StatefulWidget {
  const VideoDetailPageV({super.key});

  @override
  State<VideoDetailPageV> createState() => _VideoDetailPageVState();
}

class _VideoDetailPageVState extends State<VideoDetailPageV>
    with RouteAware, RouteAwareMixin, WidgetsBindingObserver {
  final heroTag = Get.arguments['heroTag'];

  late final VideoDetailController videoDetailController;
  late final VideoReplyController _videoReplyController;
  PlPlayerController? plPlayerController;

  // 页面级 completed gate 参数：
  // completed 信号有机会早到或在切换窗口后晚到，因此页面层不能一收到
  // completed 就直接 nextPlay/repeat。这里先要求提交时已经处于尾段，
  // 再在 fallback 最大等待内持续确认当前位置；fallback 只服务于
  // “已在尾段但 position 不再推进”的场景，不能把非尾段 completed 变成延迟切换。
  static const Duration _completedGateTailThreshold = Duration(
    milliseconds: 1200,
  );
  static const Duration _completedGateCheckInterval = Duration(
    milliseconds: 120,
  );
  static const Duration _completedGateFallbackGrace = Duration(
    milliseconds: 200,
  );
  int _completedGateToken = 0;

  // intro ctr
  late final CommonIntroController introController =
      videoDetailController.isFileSource
      ? localIntroController
      : videoDetailController.isUgc
      ? ugcIntroController
      : pgcIntroController;
  late final UgcIntroController ugcIntroController;
  late final PgcIntroController pgcIntroController;
  late final LocalIntroController localIntroController;

  bool get autoExitFullscreen =>
      videoDetailController.plPlayerController.autoExitFullscreen;

  bool get autoPlayEnable =>
      videoDetailController.plPlayerController.autoPlayEnable;

  bool get enableVerticalExpand =>
      videoDetailController.plPlayerController.enableVerticalExpand;

  bool get pipNoDanmaku =>
      videoDetailController.plPlayerController.pipNoDanmaku;

  bool isShowing = true;
  Duration? _pendingAudioSyncPosition;

  Duration _audioPagePosition(AudioController audioController) {
    final rawPosition = audioController.player?.state.position;
    if (rawPosition != null && rawPosition > Duration.zero) {
      return rawPosition;
    }
    return audioController.position.value;
  }

  bool get isFullScreen =>
      videoDetailController.plPlayerController.isFullScreen.value;

  bool get _shouldShowSeasonPanel {
    if (videoDetailController.isFileSource ||
        isPortrait ||
        !videoDetailController.isUgc) {
      return false;
    }
    late final videoDetail = ugcIntroController.videoDetail.value;
    return videoDetailController.plPlayerController.horizontalSeasonPanel &&
        (videoDetail.ugcSeason != null ||
            ((videoDetail.pages?.length ?? 0) > 1));
  }

  final videoReplyPanelKey = GlobalKey();
  final videoRelatedKey = GlobalKey();
  final videoIntroKey = GlobalKey();

  @override
  void initState() {
    super.initState();

    PlPlayerController.setPlayCallBack(playCallBack);
    videoDetailController = Get.put(VideoDetailController(), tag: heroTag);

    if (videoDetailController.removeSafeArea) {
      hideSystemBar();
    }

    if (videoDetailController.showReply) {
      _videoReplyController = Get.put(
        VideoReplyController(
          aid: videoDetailController.aid,
          videoType: videoDetailController.videoType,
          heroTag: heroTag,
        ),
        tag: heroTag,
      );
    }

    if (videoDetailController.isFileSource) {
      localIntroController = Get.put(LocalIntroController(), tag: heroTag);
    } else if (videoDetailController.isUgc) {
      ugcIntroController = Get.put(UgcIntroController(), tag: heroTag);
    } else {
      pgcIntroController = Get.put(PgcIntroController(), tag: heroTag);
    }

    videoSourceInit();

    addObserverMobile(this);
  }

  // 获取视频资源，初始化播放器
  void videoSourceInit() {
    // 先让当前页子树完成 unmount，再销毁 tagged controllers，
    // 避免 Obx/TabBar 还在订阅或绘制时流已经被关闭。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      videoDetailController.queryVideoUrl(autoFullScreenFlag: true);
      if (videoDetailController.autoPlay) {
        plPlayerController = videoDetailController.plPlayerController;
        plPlayerController!
          ..addStatusLister(playerListener)
          ..addPositionListener(positionListener);
      }
    });
  }

  void _handleWindowBack() {
    if (PlayerWindowService.isPlayerWindow) {
      if (Get.key.currentState?.canPop() ?? false) {
        Get.back();
      } else {
        SmartDialog.showToast('已经是第一个视频了');
      }
      return;
    }
    Get.back();
  }

  void _handleWindowHome() {
    if (PlayerWindowService.isPlayerWindow) {
      PlayerWindowService.showMainWindow();
      return;
    }
    videoDetailController.plPlayerController.onCloseAll();
  }

  void positionListener(Duration position) {
    if (videoDetailController.isSwitchingVideo) {
      return;
    }
    videoDetailController.playedTime = position;
  }

  Duration _rawVideoPosition(PlPlayerController controller) =>
      controller.videoPlayerController?.state.position ?? controller.position;

  Duration _rawVideoDuration(PlPlayerController controller) {
    final stateDuration = controller.videoPlayerController?.state.duration;
    return stateDuration != null && stateDuration > Duration.zero
        ? stateDuration
        : controller.duration.value;
  }

  Duration _completedGateFallbackWait(Duration remaining) {
    final wait = remaining + _completedGateFallbackGrace;
    return wait < _completedGateTailThreshold
        ? wait
        : _completedGateTailThreshold;
  }

  // token + 播放器实例 + 媒体身份共同决定 pending gate 是否仍属于当前媒体。
  // 只看 aid/cid 不够：同一视频重开源、切清晰度、页面离开再回来时，旧
  // completed 的异步等待仍可能晚到。
  bool _isVideoCompletedGateCurrent(
    int token,
    PlPlayerController controller,
    Object? playerInstance,
    int aid,
    String bvid,
    int cid,
    int? epId,
    int? seasonId,
    int? pgcType,
    Object videoType,
    Object sourceType,
  ) {
    return token == _completedGateToken &&
        mounted &&
        isShowing &&
        identical(plPlayerController, controller) &&
        identical(controller.videoPlayerController, playerInstance) &&
        !videoDetailController.isSwitchingVideo &&
        videoDetailController.aid == aid &&
        videoDetailController.bvid == bvid &&
        videoDetailController.cid.value == cid &&
        videoDetailController.epId == epId &&
        videoDetailController.seasonId == seasonId &&
        videoDetailController.pgcType == pgcType &&
        videoDetailController.videoType == videoType &&
        videoDetailController.sourceType == sourceType;
  }

  Future<void> _runVideoCompletedGate({
    required bool skipCompletedRefresh,
  }) async {
    final controller = plPlayerController;
    if (controller == null) return;

    final token = ++_completedGateToken;
    final playerInstance = controller.videoPlayerController;
    final aid = videoDetailController.aid;
    final bvid = videoDetailController.bvid;
    final cid = videoDetailController.cid.value;
    final epId = videoDetailController.epId;
    final seasonId = videoDetailController.seasonId;
    final pgcType = videoDetailController.pgcType;
    final videoType = videoDetailController.videoType;
    final sourceType = videoDetailController.sourceType;
    final submitPosition = _rawVideoPosition(controller);
    final submitDuration = _rawVideoDuration(controller);
    final submitRemaining = submitDuration - submitPosition;
    // 非尾段 completed 直接丢弃，不创建 pending token。这样旧媒体的
    // completed 即使在 500ms switching 窗口后晚到，也不会靠 fallback 切掉新媒体。
    final isTailCompleted =
        submitDuration > Duration.zero &&
        submitPosition >= Duration.zero &&
        submitRemaining >= Duration.zero &&
        submitRemaining <= _completedGateTailThreshold;

    if (!isTailCompleted) {
      DebugLogService.log(
        'video.completed',
        'discard_non_tail_completed',
        extra: {
          'position': submitPosition.inMilliseconds,
          'duration': submitDuration.inMilliseconds,
          'remaining': submitRemaining.inMilliseconds,
          'aid': aid,
          'bvid': bvid,
          'cid': cid,
          'playMode': controller.playRepeat.name,
          'switching': videoDetailController.isSwitchingVideo,
        },
      );
      return;
    }

    DebugLogService.log(
      'video.completed',
      'submit completed gate',
      extra: {
        'position': submitPosition.inMilliseconds,
        'duration': submitDuration.inMilliseconds,
        'remaining': submitRemaining.inMilliseconds,
        'aid': aid,
        'bvid': bvid,
        'cid': cid,
        'playMode': controller.playRepeat.name,
      },
    );

    final fallbackWait = _completedGateFallbackWait(submitRemaining);
    final startedAt = DateTime.now();
    var fallback = false;

    while (DateTime.now().difference(startedAt) < fallbackWait) {
      await Future<void>.delayed(_completedGateCheckInterval);
      if (!_isVideoCompletedGateCurrent(
        token,
        controller,
        playerInstance,
        aid,
        bvid,
        cid,
        epId,
        seasonId,
        pgcType,
        videoType,
        sourceType,
      )) {
        DebugLogService.log(
          'video.completed',
          'cancel completed gate identity mismatch',
          extra: {
            'aid': aid,
            'bvid': bvid,
            'cid': cid,
            'token': token,
            'switching': videoDetailController.isSwitchingVideo,
          },
        );
        return;
      }

      final currentPosition = _rawVideoPosition(controller);
      final currentDuration = _rawVideoDuration(controller);
      final currentRemaining = currentDuration - currentPosition;
      // 进入最后 200ms 视为“页面层可以消费 completed”。此处只延后
      // next/repeat/尾处理，不改变 PlPlayerController 内部 completed heartbeat。
      if (currentDuration > Duration.zero &&
          currentRemaining >= Duration.zero &&
          currentRemaining <= _completedGateFallbackGrace) {
        DebugLogService.log(
          'video.completed',
          'confirm completed gate',
          extra: {
            'position': currentPosition.inMilliseconds,
            'duration': currentDuration.inMilliseconds,
            'remaining': currentRemaining.inMilliseconds,
            'aid': aid,
            'bvid': bvid,
            'cid': cid,
            'playMode': controller.playRepeat.name,
          },
        );
        await _handleConfirmedVideoCompleted(skipCompletedRefresh);
        return;
      }

      if (DateTime.now().difference(startedAt) >= fallbackWait) {
        fallback = true;
        break;
      }
    }

    if (!_isVideoCompletedGateCurrent(
      token,
      controller,
      playerInstance,
      aid,
      bvid,
      cid,
      epId,
      seasonId,
      pgcType,
      videoType,
      sourceType,
    )) {
      DebugLogService.log(
        'video.completed',
        'cancel completed gate identity mismatch',
        extra: {
          'aid': aid,
          'bvid': bvid,
          'cid': cid,
          'token': token,
          'switching': videoDetailController.isSwitchingVideo,
        },
      );
      return;
    }

    // fallback 只允许提交时已经在尾段的 pending gate 使用。它的目的
    // 是防止真实 completed 后 position 停住导致卡死，而不是普通延时切歌。
    if (fallback || DateTime.now().difference(startedAt) >= fallbackWait) {
      DebugLogService.log(
        'video.completed',
        'fallback completed gate',
        extra: {
          'submitRemaining': submitRemaining.inMilliseconds,
          'wait': fallbackWait.inMilliseconds,
          'aid': aid,
          'bvid': bvid,
          'cid': cid,
          'playMode': controller.playRepeat.name,
        },
      );
      await _handleConfirmedVideoCompleted(skipCompletedRefresh);
    }
  }

  Future<void> _handleConfirmedVideoCompleted(
    bool skipCompletedRefresh,
  ) async {
    bool exitFlag = true;

    /// 顺序播放 列表循环
    if (shutdownTimerService.isWaiting) {
      shutdownTimerService.handleWaiting();
    } else {
      switch (plPlayerController!.playRepeat) {
        case PlayRepeat.singleCycle:
          exitFlag = false;
          plPlayerController!.play(repeat: true);
        case PlayRepeat.listOrder:
        case PlayRepeat.listCycle:
        case PlayRepeat.autoPlayRelated:
          exitFlag = !introController.nextPlay();
        case PlayRepeat.pause:
      }
    }

    if (skipCompletedRefresh && exitFlag) {
      videoDetailController.refreshPage();
    }

    if (exitFlag) {
      if (autoExitFullscreen) {
        plPlayerController!.triggerFullScreen(status: false);
        if (plPlayerController!.controlsLock.value) {
          plPlayerController!.onLockControl(false);
        }
      } else {
        if (plPlayerController!.controlsLock.value &&
            (!Platform.isAndroid || !AndroidHelper.isPipMode)) {
          plPlayerController!.onLockControl(false);
        }
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isResume = state == .resumed;
    final ctr = videoDetailController.plPlayerController..visible = isResume;
    batteryDebug.trackBackgroundTask(
      'VideoPage_lifecycle_$state',
      start: state == AppLifecycleState.paused,
    );
    if (isResume) {
      if (!ctr.showDanmaku) {
        introController.startTimer();
        ctr.showDanmaku = true;
      }
    } else if (state == .paused) {
      introController.cancelTimer();
      ctr.showDanmaku = false;
      // 输出当前电池调试状态
      batteryDebug.logStatus();
    }
  }

  Future<void>? playCallBack() {
    if (!isShowing) {
      plPlayerController
        ?..addStatusLister(playerListener)
        ..addPositionListener(positionListener);
    }
    return PlPlayerController.instance?.play();
  }

  // 播放器状态监听
  Future<void> playerListener(PlayerStatus status) async {
    final isPlaying = status.isPlaying;
    final isCompleted = status.isCompleted;
    final skipCompletedRefresh =
        isCompleted && PlayerWindowService.isPlayerWindow;
    try {
      if (videoDetailController.scrollCtr.hasClients) {
        if (isPlaying) {
          if (!videoDetailController.isExpanding &&
              videoDetailController.scrollCtr.offset != 0 &&
              !videoDetailController.animationController.isAnimating) {
            videoDetailController.isExpanding = true;
            videoDetailController.animationController.forward(
              from:
                  1 -
                  videoDetailController.scrollCtr.offset /
                      videoDetailController.videoHeight,
            );
          } else if (!skipCompletedRefresh) {
            videoDetailController.refreshPage();
          }
        } else if (!skipCompletedRefresh) {
          videoDetailController.refreshPage();
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('handle player status: $e');
    }

    if (isCompleted) {
      try {
        if (videoDetailController
                .steinEdgeInfo
                ?.edges
                ?.questions
                ?.firstOrNull
                ?.choices
                ?.isNotEmpty ==
            true) {
          videoDetailController.showSteinEdgeInfo.value = true;
          return;
        }
      } catch (_) {}

      // Gate completed before running next/repeat/fullscreen side effects.
      // This guards page-level auto-next against early or stale completed
      // signals; Stein remains immediate because it is not an auto-next path.
      await _runVideoCompletedGate(skipCompletedRefresh: skipCompletedRefresh);
    }
  }

  // 继续播放或重新播放
  void continuePlay() {
    plPlayerController!.play();
  }

  /// 未开启自动播放时触发播放
  Future<void>? handlePlay() {
    if (!videoDetailController.isFileSource) {
      if (videoDetailController.isQuerying) {
        if (kDebugMode) debugPrint('handlePlay: querying');
        return null;
      }
      if (videoDetailController.videoUrl == null ||
          videoDetailController.audioUrl == null) {
        if (kDebugMode) {
          debugPrint('handlePlay: videoUrl/audioUrl not initialized');
        }
        videoDetailController.queryVideoUrl();
        return null;
      }
    }
    final plPlayerController = this.plPlayerController =
        videoDetailController.plPlayerController;
    videoDetailController.autoPlay = true;
    plPlayerController
      ..addStatusLister(playerListener)
      ..addPositionListener(positionListener);
    if (plPlayerController.preInitPlayer) {
      if (plPlayerController.autoEnterFullScreen) {
        plPlayerController.triggerFullScreen();
      }
      return plPlayerController.play();
    } else {
      return videoDetailController.playerInit(
        autoplay: true,
        autoFullScreenFlag: true,
      );
    }
  }

  @override
  void dispose() {
    _completedGateToken++;
    final currentHeroTag = heroTag;
    final currentVideoDetailController = videoDetailController;
    final currentHorizontalMemberController =
        Get.isRegistered<HorizontalMemberPageController>(tag: currentHeroTag)
        ? Get.find<HorizontalMemberPageController>(tag: currentHeroTag)
        : null;
    final currentVideoReplyController =
        videoDetailController.showReply &&
            Get.isRegistered<VideoReplyController>(tag: currentHeroTag)
        ? Get.find<VideoReplyController>(tag: currentHeroTag)
        : null;
    final currentUgcIntroController =
        !videoDetailController.isFileSource &&
            videoDetailController.isUgc &&
            Get.isRegistered<UgcIntroController>(tag: currentHeroTag)
        ? Get.find<UgcIntroController>(tag: currentHeroTag)
        : null;
    final currentPgcIntroController =
        !videoDetailController.isFileSource &&
            !videoDetailController.isUgc &&
            Get.isRegistered<PgcIntroController>(tag: currentHeroTag)
        ? Get.find<PgcIntroController>(tag: currentHeroTag)
        : null;
    final currentLocalIntroController =
        videoDetailController.isFileSource &&
            Get.isRegistered<LocalIntroController>(tag: currentHeroTag)
        ? Get.find<LocalIntroController>(tag: currentHeroTag)
        : null;

    plPlayerController
      ?..removeStatusLister(playerListener)
      ..removePositionListener(positionListener);

    if (!videoDetailController.removeSafeArea) {
      showSystemBar();
    }

    if (!videoDetailController.plPlayerController.isCloseAll) {
      videoPlayerServiceHandler?.onVideoDetailDispose(heroTag);
      videoPlayerServiceHandler?.clear(force: true);
      if (plPlayerController != null) {
        videoDetailController.makeHeartBeat();
        PlPlayerController.updatePlayCount();
      } else {
        PlPlayerController.updatePlayCount();
      }
    }
    removeObserverMobile(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _deleteControllerIfSame<HorizontalMemberPageController>(
        currentHeroTag,
        currentHorizontalMemberController,
      );
      if (currentVideoReplyController != null) {
        _deleteControllerIfSame<VideoReplyController>(
          currentHeroTag,
          currentVideoReplyController,
        );
      }
      if (currentUgcIntroController != null) {
        currentUgcIntroController.cancelTimer();
        currentUgcIntroController.videoDetail.close();
        _deleteControllerIfSame<UgcIntroController>(
          currentHeroTag,
          currentUgcIntroController,
        );
      } else if (currentPgcIntroController != null) {
        currentPgcIntroController.cancelTimer();
        _deleteControllerIfSame<PgcIntroController>(
          currentHeroTag,
          currentPgcIntroController,
        );
      } else if (currentLocalIntroController != null) {
        _deleteControllerIfSame<LocalIntroController>(
          currentHeroTag,
          currentLocalIntroController,
        );
      }
      _deleteControllerIfSame<VideoDetailController>(
        currentHeroTag,
        currentVideoDetailController,
      );
    });

    super.dispose();
  }

  void _deleteControllerIfSame<T extends Object>(String tag, T? controller) {
    if (controller == null) return;
    try {
      if (!Get.isRegistered<T>(tag: tag)) return;
      final current = Get.find<T>(tag: tag);
      if (identical(current, controller)) {
        Get.delete<T>(tag: tag, force: true);
      }
    } catch (_) {}
  }

  @override
  // 离开当前页面时
  void didPushNext() {
    super.didPushNext();
    isShowing = false;
    _completedGateToken++;

    removeObserverMobile(this);

    if (Platform.isAndroid && !videoDetailController.setSystemBrightness) {
      ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
    }

    introController.cancelTimer();

    final playerStatusBeforeNavigation = PlayerWindowService.isPlayerWindow
        ? PageUtils.takePlayerWindowStatusBeforeNavigation(heroTag)
        : null;
    videoDetailController
      ..videoState.value = false
      ..cancelBlockListener()
      ..playerStatus =
          playerStatusBeforeNavigation ?? plPlayerController?.playerStatus.value
      ..brightness = plPlayerController?.brightness.value;
    if (plPlayerController != null) {
      videoDetailController.makeHeartBeat();
      plPlayerController!
        ..pause()
        ..removeStatusLister(playerListener)
        ..removePositionListener(positionListener);
      // 状态上报统一由 PlPlayerController 的流监听完成。
      // 这里不再手动 onStatusChange，避免与底层流回调重复写状态。
    }
  }

  @override
  // 返回当前页面时
  void didPopNext() {
    super.didPopNext();

    if (videoDetailController.plPlayerController.isCloseAll) {
      return;
    }

    isShowing = true;

    addObserverMobile(this);

    plPlayerController?.isLive = false;
    if (videoDetailController.plPlayerController.playerStatus.isPlaying &&
        videoDetailController.playerStatus != PlayerStatus.playing) {
      videoDetailController.plPlayerController.pause();
    }

    PlPlayerController.setPlayCallBack(playCallBack);

    introController
      ..startTimer()
      // 恢复媒体通知列表控制模式（从听视频页返回时需要）
      ..restoreListControlMode();

    // 同步听视频返回时的状态
    _syncAudioPageState();

    if (mounted &&
        Platform.isAndroid &&
        !videoDetailController.setSystemBrightness) {
      if (videoDetailController.brightness != null) {
        plPlayerController?.brightness.value =
            videoDetailController.brightness!;
        if (videoDetailController.brightness != -1.0) {
          ScreenBrightnessPlatform.instance.setApplicationScreenBrightness(
            videoDetailController.brightness!,
          );
        } else {
          ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
        }
      } else {
        ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
      }
    }

    () async {
      final syncedPosition = _pendingAudioSyncPosition;
      _pendingAudioSyncPosition = null;
      if (videoDetailController.autoPlay) {
        await videoDetailController.playerInit(
          autoplay: videoDetailController.playerStatus?.isPlaying ?? false,
          localEntry: videoDetailController.currentLocalEntry,
          seekToTime: syncedPosition,
        );
      } else if (videoDetailController.plPlayerController.preInitPlayer &&
          !videoDetailController.isQuerying &&
          videoDetailController.videoState.value is! Error) {
        await videoDetailController.playerInit(
          localEntry: videoDetailController.currentLocalEntry,
          seekToTime: syncedPosition,
        );
      }
      if (!mounted || !isShowing) return;
      plPlayerController
        ?..addStatusLister(playerListener)
        ..addPositionListener(positionListener);
    }();

    super.didPopNext();
  }

  /// 同步听视频页面的状态
  void _syncAudioPageState() {
    try {
      // 检查是否有 AudioController 实例
      if (!Get.isRegistered<AudioController>(tag: heroTag)) {
        return;
      }

      final audioController = Get.find<AudioController>(tag: heroTag);
      final audioSpeed = audioController.speed;
      unawaited(
        videoDetailController.plPlayerController.setPlaybackSpeed(audioSpeed),
      );

      if (audioController.isSwitchingAudio) {
        if (kDebugMode) {
          debugPrint('从听视频返回时音频仍在切换中，跳过视频身份和进度同步');
        }
        return;
      }

      // 如果听视频切换了视频，需要同步到视频页
      final audioOid = audioController.oid;
      final audioCid = audioController.subId.firstOrNull?.toInt();
      final currentBvid = IdUtils.av2bv(audioOid.toInt());
      final audioPosition = _audioPagePosition(audioController);
      final currentCid = videoDetailController.cid.value;
      final hasSwitchedBvid = currentBvid != videoDetailController.bvid;
      final hasSwitchedPart =
          videoDetailController.isUgc &&
          audioCid != null &&
          audioCid != currentCid;
      final shouldSwitchEpisode = hasSwitchedBvid || hasSwitchedPart;
      _pendingAudioSyncPosition = audioPosition > Duration.zero
          ? audioPosition
          : null;

      if (shouldSwitchEpisode) {
        if (kDebugMode) {
          if (hasSwitchedBvid) {
            debugPrint(
              '🔄 从听视频返回，检测到视频切换: $currentBvid (当前: ${videoDetailController.bvid})',
            );
          } else {
            debugPrint(
              '🔄 从听视频返回，检测到分P切换: cid=$audioCid (当前: $currentCid)',
            );
          }
        }

        // 触发视频切换
        if (videoDetailController.isUgc) {
          ugc.BaseEpisodeItem? targetItem;
          final audioAid = audioOid.toInt();
          bool matchesAudioState(ugc.BaseEpisodeItem item) =>
              item.cid == audioCid ||
              (hasSwitchedBvid &&
                  (item.aid == audioAid || item.bvid == currentBvid));

          final videoDetail = ugcIntroController.videoDetail.value;
          final currentPages = videoDetail.pages;
          if (currentPages != null && currentPages.isNotEmpty) {
            for (final item in currentPages) {
              if (matchesAudioState(item)) {
                targetItem = item;
                break;
              }
            }
          }

          final sections = videoDetail.ugcSeason?.sections;
          if (targetItem == null && sections != null) {
            for (final section in sections) {
              final episodes = section.episodes;
              if (episodes == null) continue;
              for (final item in episodes) {
                if (matchesAudioState(item)) {
                  targetItem = item;
                  break;
                }
              }
              if (targetItem != null) {
                break;
              }
            }
          }

          if (targetItem == null) {
            for (final item in videoDetailController.mediaList) {
              if (matchesAudioState(item)) {
                targetItem = item;
                break;
              }
            }
          }

          if (targetItem != null) {
            ugcIntroController.onChangeEpisode(
              targetItem,
              fromAudioPage: true,
              audioPosition: audioPosition,
            );
          }
        } else {
          pgc.EpisodeItem? targetItem;
          final audioAid = audioOid.toInt();

          bool matchesAudioState(pgc.EpisodeItem item) =>
              item.cid == audioCid ||
              item.aid == audioAid ||
              item.bvid == currentBvid;

          final episodes = pgcIntroController.pgcItem.episodes;
          if (episodes != null && episodes.isNotEmpty) {
            for (final item in episodes) {
              if (matchesAudioState(item)) {
                targetItem = item;
                break;
              }
            }
          }

          if (targetItem != null) {
            pgcIntroController.onChangeEpisode(
              targetItem,
              fromAudioPage: true,
              audioPosition: audioPosition,
            );
          }
        }
      } else {
        // 同一个视频，只需同步进度
        if (audioPosition > Duration.zero) {
          videoDetailController.playedTime = audioPosition;
          videoDetailController.defaultST = audioPosition;

          if (kDebugMode) {
            debugPrint(
              '🔄 从听视频返回，同步进度: ${audioPosition.inSeconds}s, 倍速: ${audioSpeed}x',
            );
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('同步听视频状态失败: $e');
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (videoDetailController.removeSafeArea) {
      padding = .zero;
    } else {
      padding = MediaQuery.viewPaddingOf(context);
    }

    final size = MediaQuery.sizeOf(context);
    maxWidth = size.width;
    maxHeight = size.height;
    isWindowMode = MaxScreenSize.isWindowMode(
      width: maxWidth * videoDetailController.uiScale,
      height: maxHeight * videoDetailController.uiScale,
    );
    videoDetailController.plPlayerController.screenRatio = maxHeight / maxWidth;

    final shortestSide = size.shortestSide;
    final minVideoHeight = shortestSide / Style.aspectRatio16x9;
    final maxVideoHeight = max(size.longestSide * 0.65, shortestSide);
    videoDetailController
      ..isPortrait = isPortrait = maxHeight >= maxWidth
      ..minVideoHeight = minVideoHeight
      ..maxVideoHeight = maxVideoHeight
      ..videoHeight = videoDetailController.isVertical.value
          ? maxVideoHeight
          : minVideoHeight;

    themeData = videoDetailController.plPlayerController.darkVideoPage
        ? ThemeUtils.darkTheme
        : Theme.of(context);
  }

  bool removeAppBar(bool isFullScreen) =>
      videoDetailController.removeSafeArea ||
      (isWindowMode && isFullScreen && !isPortrait);

  Widget get childWhenDisabled {
    return Obx(
      () {
        final isFullScreen = this.isFullScreen;
        return Scaffold(
          resizeToAvoidBottomInset: false,
          appBar: removeAppBar(isFullScreen)
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(0),
                  child: Obx(
                    () {
                      final scrollRatio =
                          videoDetailController.scrollRatio.value;
                      final flag =
                          isPortrait &&
                          videoDetailController.scrollCtr.offset != 0;
                      return AppBar(
                        backgroundColor: flag && scrollRatio > 0
                            ? Color.lerp(
                                Colors.black,
                                themeData.colorScheme.surface,
                                scrollRatio,
                              )
                            : Colors.black,
                        toolbarHeight: 0,
                        systemOverlayStyle: Platform.isAndroid
                            ? SystemUiOverlayStyle(
                                statusBarIconBrightness:
                                    flag && scrollRatio >= 0.5
                                    ? themeData.brightness.reverse
                                    : Brightness.light,
                                systemNavigationBarIconBrightness:
                                    themeData.brightness.reverse,
                              )
                            : null,
                      );
                    },
                  ),
                ),
          body: ExtendedNestedScrollView(
            key: videoDetailController.scrollKey,
            controller: videoDetailController.scrollCtr,
            onlyOneScrollInBody: true,
            pinnedHeaderSliverHeightBuilder: () {
              double pinnedHeight = this.isFullScreen || !isPortrait
                  ? maxHeight - (isWindowMode && !isPortrait ? 0 : padding.top)
                  : videoDetailController.isExpanding ||
                        videoDetailController.isCollapsing
                  ? videoDetailController.animHeight
                  : videoDetailController.isCollapsing ||
                        (plPlayerController?.playerStatus.isPlaying ?? false)
                  ? videoDetailController.minVideoHeight
                  : kToolbarHeight;
              if (videoDetailController.isExpanding &&
                  videoDetailController.animationController.value == 1) {
                videoDetailController.isExpanding = false;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  videoDetailController.scrollRatio.value = 0;
                  videoDetailController.refreshPage();
                });
              } else if (videoDetailController.isCollapsing &&
                  videoDetailController.animationController.value == 1) {
                videoDetailController.isCollapsing = false;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  videoDetailController.refreshPage();
                });
              }
              return pinnedHeight;
            },
            headerSliverBuilder: (context, innerBoxIsScrolled) {
              final height = isFullScreen || !isPortrait
                  ? maxHeight - (isWindowMode && !isPortrait ? 0 : padding.top)
                  : videoDetailController.isExpanding ||
                        videoDetailController.isCollapsing
                  ? videoDetailController.animHeight
                  : videoDetailController.videoHeight;
              return [
                SliverAppBar(
                  elevation: 0,
                  scrolledUnderElevation: 0,
                  primary: false,
                  automaticallyImplyLeading: false,
                  pinned: true,
                  expandedHeight: height,
                  flexibleSpace: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      SizedBox(
                        width: maxWidth,
                        height: height,
                        child: videoPlayer(
                          width: maxWidth,
                          height: height,
                        ),
                      ),
                      Obx(
                        () {
                          Widget toolbar() => Opacity(
                            opacity: videoDetailController.scrollRatio.value,
                            child: Container(
                              color: themeData.colorScheme.surface,
                              alignment: Alignment.topCenter,
                              child: SizedBox(
                                height: kToolbarHeight,
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          SizedBox(
                                            width: 42,
                                            height: 34,
                                            child: IconButton(
                                              tooltip: '返回',
                                              icon: Icon(
                                                FontAwesomeIcons.arrowLeft,
                                                size: 15,
                                                color: themeData
                                                    .colorScheme
                                                    .onSurface,
                                              ),
                                              onPressed: _handleWindowBack,
                                            ),
                                          ),
                                          SizedBox(
                                            width: 42,
                                            height: 34,
                                            child: IconButton(
                                              tooltip: '返回主页',
                                              icon: Icon(
                                                FontAwesomeIcons.house,
                                                size: 15,
                                                color: themeData
                                                    .colorScheme
                                                    .onSurface,
                                              ),
                                              onPressed: _handleWindowHome,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Center(
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.play_arrow_rounded,
                                            color:
                                                themeData.colorScheme.primary,
                                          ),
                                          Text(
                                            '${videoDetailController.playedTime == null
                                                ? '立即'
                                                : plPlayerController!.playerStatus.isCompleted
                                                ? '重新'
                                                : '继续'}播放',
                                            style: TextStyle(
                                              color:
                                                  themeData.colorScheme.primary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child:
                                          videoDetailController.playedTime ==
                                              null
                                          ? _moreBtn(
                                              themeData.colorScheme.onSurface,
                                            )
                                          : SizedBox(
                                              width: 42,
                                              height: 34,
                                              child: IconButton(
                                                tooltip: "更多设置",
                                                style: const ButtonStyle(
                                                  padding:
                                                      WidgetStatePropertyAll(
                                                        EdgeInsets.zero,
                                                      ),
                                                ),
                                                onPressed: () =>
                                                    (videoDetailController
                                                                .headerCtrKey
                                                                .currentState
                                                            as HeaderControlState?)
                                                        ?.showSettingSheet(),
                                                icon: Icon(
                                                  Icons.more_vert_outlined,
                                                  size: 19,
                                                  color: themeData
                                                      .colorScheme
                                                      .onSurface,
                                                ),
                                              ),
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                          return videoDetailController.scrollRatio.value == 0 ||
                                  videoDetailController.scrollCtr.offset == 0 ||
                                  !isPortrait
                              ? const SizedBox.shrink()
                              : Positioned.fill(
                                  bottom: -2,
                                  child: GestureDetector(
                                    onTap: () async {
                                      if (!videoDetailController.isFileSource) {
                                        if (videoDetailController.isQuerying) {
                                          if (kDebugMode) {
                                            debugPrint(
                                              'handlePlay: querying',
                                            );
                                          }
                                          return;
                                        }
                                        if (videoDetailController.videoUrl ==
                                                null ||
                                            videoDetailController.audioUrl ==
                                                null) {
                                          if (kDebugMode) {
                                            debugPrint(
                                              'handlePlay: videoUrl/audioUrl not initialized',
                                            );
                                          }
                                          videoDetailController.queryVideoUrl();
                                          return;
                                        }
                                      }
                                      videoDetailController.scrollRatio.value =
                                          0;
                                      if (plPlayerController == null ||
                                          videoDetailController.playedTime ==
                                              null) {
                                        handlePlay();
                                      } else {
                                        if (plPlayerController!
                                            .videoPlayerController!
                                            .state
                                            .completed) {
                                          await plPlayerController!
                                              .videoPlayerController!
                                              .seek(Duration.zero);
                                          plPlayerController!
                                              .videoPlayerController!
                                              .play();
                                        } else {
                                          plPlayerController!
                                              .videoPlayerController!
                                              .playOrPause();
                                        }
                                      }
                                    },
                                    behavior: HitTestBehavior.opaque,
                                    child: toolbar(),
                                  ),
                                );
                        },
                      ),
                    ],
                  ),
                ),
              ];
            },
            body: Scaffold(
              key: videoDetailController.childKey,
              resizeToAvoidBottomInset: false,
              backgroundColor: Colors.transparent,
              body: Column(
                children: [
                  buildTabBar(onTap: videoDetailController.animToTop),
                  Expanded(
                    child: tabBarView(
                      controller: videoDetailController.tabCtr,
                      children: [
                        videoIntro(
                          isHorizontal: false,
                          needCtr: false,
                          isNested: true,
                        ),
                        if (videoDetailController.showReply)
                          videoReplyPanel(isNested: true),
                        if (_shouldShowSeasonPanel) seasonPanel,
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // 统一的Tab内容区域组件
  Widget buildTabContentArea({
    required double width,
    required double height,
    VoidCallback? onTap,
    bool showIntro = true,
    String? introText,
    Widget? introWidget,
  }) {
    return Scaffold(
      key: videoDetailController.childKey,
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.transparent,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          buildTabBar(
            onTap: onTap,
            showIntro: showIntro,
            introText: introText,
          ),
          Expanded(
            child: tabBarView(
              controller: videoDetailController.tabCtr,
              children: [
                if (showIntro)
                  introWidget ??
                      videoIntro(
                        width: width,
                        height: height,
                      ),
                if (videoDetailController.showReply) videoReplyPanel(),
                if (_shouldShowSeasonPanel) seasonPanel,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget get childWhenDisabledLandscape => Obx(
    () {
      final isFullScreen = this.isFullScreen;
      return Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: removeAppBar(isFullScreen)
            ? null
            : AppBar(backgroundColor: Colors.black, toolbarHeight: 0),
        body: Padding(
          padding: isFullScreen
              ? EdgeInsets.zero
              : padding.copyWith(top: 0, bottom: 0),
          child: childWhenDisabledLandscapeInner(isFullScreen, padding),
        ),
      );
    },
  );

  Widget childSplit(double ratio) {
    final double videoHeight = isFullScreen && isWindowMode && !isPortrait
        ? maxHeight
        : maxHeight - padding.top;
    final double width = videoHeight * ratio;
    final videoWidth = isFullScreen ? maxWidth : width;
    final introWidth = maxWidth - width - padding.horizontal;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 左侧：播放器（占满垂直空间）
        SizedBox(
          width: videoWidth,
          height: videoHeight,
          child: videoPlayer(
            width: videoWidth,
            height: videoHeight,
          ),
        ),
        // 右侧：Tab内容区域
        Offstage(
          offstage: isFullScreen,
          child: SizedBox(
            width: introWidth,
            height: videoHeight,
            child: buildTabContentArea(
              width: introWidth,
              height: videoHeight,
            ),
          ),
        ),
      ],
    );
  }

  Widget childWhenDisabledLandscapeInner(
    bool isFullScreen,
    EdgeInsets padding,
  ) => Obx(() {
    // 竖屏视频横屏展示
    if (videoDetailController.isVertical.value &&
        enableVerticalExpand &&
        !isPortrait) {
      final double videoHeight = isFullScreen && isWindowMode && !isPortrait
          ? maxHeight
          : maxHeight - padding.top;
      final double width = videoHeight * 9 / 16;
      final videoWidth = isFullScreen ? maxWidth : width;
      final introWidth = maxWidth - padding.horizontal - width;
      final introHeight = maxHeight - padding.top;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧：播放器（占满垂直空间）
          SizedBox(
            width: videoWidth,
            height: videoHeight,
            child: videoPlayer(
              width: videoWidth,
              height: videoHeight,
            ),
          ),
          // 右侧：Tab内容区域
          Offstage(
            offstage: isFullScreen,
            child: SizedBox(
              width: introWidth,
              height: introHeight,
              child: buildTabContentArea(
                width: introWidth,
                height: introHeight,
                showIntro: false,
              ),
            ),
          ),
        ],
      );
    }

    double width =
        clampDouble(maxHeight / maxWidth * 1.08, 0.5, 0.7) * maxWidth;
    if (maxWidth >= 560) {
      width = maxWidth - clampDouble(maxWidth - width, 280, 425);
    }
    final videoWidth = isFullScreen ? maxWidth : width;
    final videoHeight = isFullScreen && isWindowMode && !isPortrait
        ? maxHeight
        : maxHeight - padding.top;

    // 检查宽度是否合理，如果视频区域太窄则使用childSplit
    final double minVideoWidth = videoHeight * 9 / 16;
    if (videoWidth < minVideoWidth) {
      return childSplit(16 / 9);
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 左侧：播放器（占满垂直空间）
        SizedBox(
          width: videoWidth,
          height: videoHeight,
          child: videoPlayer(
            width: videoWidth,
            height: videoHeight,
          ),
        ),
        // 右侧：Tab内容区域
        Offstage(
          offstage: isFullScreen,
          child: SizedBox(
            width: maxWidth - width - padding.horizontal,
            height: maxHeight - padding.top,
            child: buildTabContentArea(
              width: maxWidth - width - padding.horizontal,
              height: maxHeight - padding.top,
            ),
          ),
        ),
      ],
    );
  });

  Widget get childWhenDisabledAlmostSquare => Obx(() {
    final isFullScreen = this.isFullScreen;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: removeAppBar(isFullScreen)
          ? null
          : AppBar(backgroundColor: Colors.black, toolbarHeight: 0),
      body: Padding(
        padding: isFullScreen
            ? EdgeInsets.zero
            : padding.copyWith(top: 0, bottom: 0),
        child: childWhenDisabledAlmostSquareInner(isFullScreen, padding),
      ),
    );
  });

  Widget childWhenDisabledAlmostSquareInner(
    bool isFullScreen,
    EdgeInsets padding,
  ) => Obx(
    () {
      final isFullScreen = this.isFullScreen;
      // 竖屏视频横屏展示
      if (videoDetailController.isVertical.value &&
          enableVerticalExpand &&
          !isPortrait) {
        return childSplit(9 / 16);
      }

      // 接近正方形屏幕：上下布局
      final double height = maxHeight / 2.5;
      final videoHeight = isFullScreen
          ? maxHeight - (isWindowMode && !isPortrait ? 0 : padding.top)
          : height;
      final bottomHeight = maxHeight - height - padding.top;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: maxWidth,
            height: videoHeight,
            child: videoPlayer(
              width: maxWidth,
              height: videoHeight,
            ),
          ),
          Offstage(
            offstage: isFullScreen,
            child: SizedBox(
              width: maxWidth - padding.horizontal,
              height: bottomHeight,
              child: buildTabContentArea(
                width: maxWidth - padding.horizontal,
                height: bottomHeight,
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget get manualPlayerWidget => Obx(() {
    if (!videoDetailController.autoPlay) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AppBar(
              primary: false,
              elevation: 0,
              scrolledUnderElevation: 0,
              foregroundColor: Colors.white,
              backgroundColor: Colors.transparent,
              automaticallyImplyLeading: false,
              title: Row(
                children: [
                  SizedBox(
                    width: 42,
                    height: 34,
                    child: IconButton(
                      tooltip: '返回',
                      icon: const Icon(
                        FontAwesomeIcons.arrowLeft,
                        size: 15,
                        color: Colors.white,
                        shadows: [
                          Shadow(
                            blurRadius: 1.5,
                            color: Colors.black,
                          ),
                        ],
                      ),
                      onPressed: _handleWindowBack,
                    ),
                  ),
                  SizedBox(
                    width: 42,
                    height: 34,
                    child: IconButton(
                      tooltip: '返回主页',
                      icon: const Icon(
                        FontAwesomeIcons.house,
                        size: 15,
                        color: Colors.white,
                        shadows: [
                          Shadow(
                            blurRadius: 1.5,
                            color: Colors.black,
                          ),
                        ],
                      ),
                      onPressed: _handleWindowHome,
                    ),
                  ),
                ],
              ),
              actions: [
                _moreBtn(
                  Colors.white,
                  shadows: const [
                    Shadow(
                      blurRadius: 1.5,
                      color: Colors.black,
                    ),
                  ],
                ),
              ],
            ),
          ),
          Positioned(
            right: 12,
            bottom: 10,
            child: IconButton(
              tooltip: '播放',
              onPressed: handlePlay,
              icon: Image.asset(
                Assets.play,
                width: 60,
                height: 60,
                cacheHeight: 60.cacheSize(context),
              ),
            ),
          ),
        ],
      );
    }
    return const SizedBox.shrink();
  });

  Widget _moreBtn(Color color, {List<Shadow>? shadows}) => PopupMenuButton(
    icon: Icon(
      size: 22,
      Icons.more_vert,
      color: color,
      shadows: shadows,
    ),
    itemBuilder: (BuildContext context) => <PopupMenuEntry>[
      PopupMenuItem(
        onTap: introController.viewLater,
        child: const Text('稍后再看'),
      ),
      if (videoDetailController.epId == null)
        PopupMenuItem(
          onTap: () => videoDetailController.showNoteList(context),
          child: const Text('查看笔记'),
        ),
      if (!videoDetailController.isFileSource)
        PopupMenuItem(
          onTap: () => videoDetailController.onDownload(this.context),
          child: const Text('缓存视频'),
        ),
      if (videoDetailController.cover.value.isNotEmpty)
        PopupMenuItem(
          onTap: () =>
              ImageUtils.downloadImg([videoDetailController.cover.value]),
          child: const Text('保存封面'),
        ),
      if (!videoDetailController.isFileSource && videoDetailController.isUgc)
        PopupMenuItem(
          onTap: videoDetailController.toAudioPage,
          child: const Text('听音频'),
        ),
      PopupMenuItem(
        onTap: () {
          if (!Accounts.main.isLogin) {
            SmartDialog.showToast('账号未登录');
          } else {
            PageUtils.reportVideo(videoDetailController.aid);
          }
        },
        child: const Text('举报'),
      ),
    ],
  );

  Widget plPlayer({
    required double width,
    required double height,
    bool isPipMode = false,
  }) => popScope(
    key: videoDetailController.videoPlayerKey,
    canPop:
        !isFullScreen &&
        !videoDetailController.plPlayerController.isDesktopPip &&
        (videoDetailController.horizontalScreen || isPortrait),
    onPopInvokedWithResult:
        videoDetailController.plPlayerController.onPopInvokedWithResult,
    child: Obx(
      () =>
          !videoDetailController.videoState.value ||
              !videoDetailController.autoPlay ||
              plPlayerController?.videoController == null
          ? const SizedBox.shrink()
          : PLVideoPlayer(
              maxWidth: width,
              maxHeight: height,
              plPlayerController: plPlayerController!,
              videoDetailController: videoDetailController,
              introController: introController,
              headerControl: HeaderControl(
                key: videoDetailController.headerCtrKey,
                isPortrait: isPortrait,
                controller: videoDetailController.plPlayerController,
                videoDetailCtr: videoDetailController,
                heroTag: heroTag,
              ),
              danmuWidget: isPipMode && pipNoDanmaku
                  ? null
                  : Obx(
                      () => PlDanmaku(
                        key: ValueKey(videoDetailController.cid.value),
                        isPipMode: isPipMode,
                        cid: videoDetailController.cid.value,
                        playerController: plPlayerController!,
                        isFullScreen: plPlayerController!.isFullScreen.value,
                        isFileSource: videoDetailController.isFileSource,
                        size: Size(width, height),
                      ),
                    ),
              showEpisodes: showEpisodes,
              showViewPoints: showViewPoints,
            ),
    ),
  );

  late ThemeData themeData;
  late bool isPortrait;
  late double maxWidth;
  late double maxHeight;
  bool isWindowMode = false;
  late EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (videoDetailController.plPlayerController.isPipMode) {
      child = plPlayer(width: maxWidth, height: maxHeight, isPipMode: true);
    } else if (!videoDetailController.horizontalScreen) {
      child = childWhenDisabled;
    } else if (maxWidth / maxHeight >= kScreenRatio) {
      child = childWhenDisabledLandscape;
    } else if (maxWidth / Style.aspectRatio16x9 < 0.4 * maxHeight) {
      child = childWhenDisabled;
    } else {
      child = childWhenDisabledAlmostSquare;
    }
    if (videoDetailController.plPlayerController.keyboardControl) {
      child = PlayerFocus(
        plPlayerController: videoDetailController.plPlayerController,
        introController: introController,
        onSendDanmaku: videoDetailController.showShootDanmakuSheet,
        canPlay: () {
          if (videoDetailController.autoPlay) {
            return true;
          }
          handlePlay();
          return false;
        },
        onSkipSegment: videoDetailController.onSkipSegment,
        child: child,
      );
    }
    return videoDetailController.plPlayerController.darkVideoPage
        ? Theme(data: themeData, child: child)
        : child;
  }

  Widget buildTabBar({
    bool needIndicator = true,
    String? introText,
    bool showIntro = true,
    VoidCallback? onTap,
  }) {
    List<String> tabs = [
      if (showIntro)
        videoDetailController.isFileSource ? '离线视频' : introText ?? '简介',
      if (videoDetailController.showReply) '评论',
      if (_shouldShowSeasonPanel) '播放列表',
    ];
    if (videoDetailController.tabCtr.length != tabs.length) {
      final oldTabCtr = videoDetailController.tabCtr;
      final nextIndex = tabs.isEmpty
          ? 0
          : oldTabCtr.index.clamp(0, tabs.length - 1);
      videoDetailController.tabCtr = TabController(
        vsync: videoDetailController,
        length: tabs.length,
        initialIndex: nextIndex,
      );
      // 延后一帧释放旧 controller，避免 TabBar 还在 paint 时动画控制器已销毁。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldTabCtr.dispose();
      });
    }

    final flag = !needIndicator || tabs.length == 1;
    final tabController = videoDetailController.tabCtr;
    Widget tabBar() => TabBar(
      labelColor: flag ? themeData.colorScheme.onSurface : null,
      indicator: flag ? const BoxDecoration() : null,
      padding: EdgeInsets.zero,
      controller: tabController,
      labelStyle:
          TabBarTheme.of(context).labelStyle?.copyWith(fontSize: 13) ??
          const TextStyle(fontSize: 13),
      labelPadding: const EdgeInsets.symmetric(horizontal: 10.0),
      dividerColor: Colors.transparent,
      dividerHeight: 0,
      onTap: (value) {
        void animToTop() {
          if (onTap != null) {
            onTap();
            return;
          }
          String text = tabs[value];
          if (videoDetailController.isFileSource ||
              text == '简介' ||
              text == '相关视频') {
            videoDetailController.introScrollCtr?.animToTop();
          } else if (text.startsWith('评论')) {
            _videoReplyController.animateToTop();
          }
        }

        if (flag) {
          animToTop();
        } else if (!tabController.indexIsChanging) {
          animToTop();
        }
      },
      tabs: tabs.map((text) {
        if (text == '评论') {
          return Obx(() {
            final count = _videoReplyController.count.value;
            return Tab(
              text: '评论${count == -1 ? '' : ' ${NumUtils.numFormat(count)}'}',
            );
          });
        } else {
          return Tab(text: text);
        }
      }).toList(),
    );

    final tabbarWidget = DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: themeData.dividerColor.withValues(alpha: 0.1),
          ),
        ),
      ),
      child: SizedBox(
        height: 45,
        child: Row(
          children: [
            if (tabs.isEmpty)
              const Spacer()
            else
              Flexible(
                flex: tabs.length == 3 ? 2 : 1,
                child: tabBar(),
              ),
            Flexible(
              flex: 1,
              child: Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (!videoDetailController.isFileSource)
                      SizedBox(
                        height: 32,
                        child: TextButton(
                          style: const ButtonStyle(
                            padding: WidgetStatePropertyAll(EdgeInsets.zero),
                          ),
                          onPressed:
                              videoDetailController.showShootDanmakuSheet,
                          child: Text(
                            '发弹幕',
                            style: TextStyle(
                              fontSize: 12,
                              color: themeData.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    SizedBox(
                      width: 38,
                      height: 38,
                      child: Obx(
                        () {
                          final ctr = videoDetailController.plPlayerController;
                          final enableShowDanmaku = ctr.enableShowDanmaku.value;
                          return IconButton(
                            onPressed: () {
                              final newVal = !enableShowDanmaku;
                              ctr.enableShowDanmaku.value = newVal;
                              if (!ctr.tempPlayerConf) {
                                GStorage.setting.put(
                                  SettingBoxKey.enableShowDanmaku,
                                  newVal,
                                );
                              }
                            },
                            icon: Icon(
                              size: 22,
                              enableShowDanmaku
                                  ? CustomIcons.dm_on
                                  : CustomIcons.dm_off,
                              color: enableShowDanmaku
                                  ? themeData.colorScheme.secondary
                                  : themeData.colorScheme.outline,
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 14),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return tabbarWidget;
  }

  Widget videoPlayer({required double width, required double height}) {
    final isFullScreen = this.isFullScreen;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Positioned.fill(child: ColoredBox(color: Colors.black)),

        plPlayer(width: width, height: height),

        Obx(() {
          if (!videoDetailController.autoPlay) {
            return Positioned.fill(
              bottom: -1,
              child: GestureDetector(
                onTap: handlePlay,
                behavior: .opaque,
                child: Obx(
                  () => NetworkImgLayer(
                    type: .emote,
                    quality: 60,
                    src: videoDetailController.cover.value,
                    width: width,
                    height: height,
                    cacheWidth: true,
                    getPlaceHolder: () => Center(
                      child: Image.asset(Assets.loading),
                    ),
                  ),
                ),
              ),
            );
          }
          return const SizedBox.shrink();
        }),
        manualPlayerWidget,

        if (videoDetailController.plPlayerController.enableBlock ||
            videoDetailController.continuePlayingPart)
          Positioned(
            left: 16,
            bottom: isFullScreen ? max(75, maxHeight * 0.25) : 75,
            width: MediaQuery.textScalerOf(context).scale(120),
            child: ExcludeSemantics(
              child: AnimatedList(
                padding: EdgeInsets.zero,
                key: videoDetailController.listKey,
                reverse: true,
                shrinkWrap: true,
                initialItemCount: videoDetailController.listData.length,
                itemBuilder: (context, index, animation) {
                  return videoDetailController.buildItem(
                    videoDetailController.listData[index],
                    animation,
                  );
                },
              ),
            ),
          ),

        // for debug
        // Positioned(
        //   right: 16,
        //   bottom: 75,
        //   child: FilledButton.tonal(
        //     onPressed: () {
        //       videoDetailController.onAddItem(
        //         SegmentModel(
        //           UUID: '',
        //           segmentType:
        //               SegmentType.values[Utils.random.nextInt(
        //                 SegmentType.values.length,
        //               )],
        //           segment: Pair(first: 0, second: 0),
        //           skipType: SkipType.alwaysSkip,
        //         ),
        //       );
        //     },
        //     child: const Text('skip'),
        //   ),
        // ),
        // Positioned(
        //   right: 16,
        //   bottom: 120,
        //   child: FilledButton.tonal(
        //     onPressed: () {
        //       videoDetailController.onAddItem(2);
        //     },
        //     child: const Text('index'),
        //   ),
        // ),
        Obx(
          () {
            if (videoDetailController.showSteinEdgeInfo.value) {
              try {
                return Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      bottom: plPlayerController?.showControls.value == true
                          ? 75
                          : 16,
                    ),
                    child: Wrap(
                      spacing: 25,
                      runSpacing: 10,
                      children: videoDetailController
                          .steinEdgeInfo!
                          .edges!
                          .questions!
                          .first
                          .choices!
                          .map((item) {
                            return FilledButton.tonal(
                              style: FilledButton.styleFrom(
                                shape: const RoundedRectangleBorder(
                                  borderRadius: .all(.circular(6)),
                                ),
                                backgroundColor: themeData
                                    .colorScheme
                                    .secondaryContainer
                                    .withValues(alpha: 0.8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 15,
                                  vertical: 10,
                                ),
                                visualDensity: VisualDensity.compact,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () {
                                ugcIntroController.onChangeEpisode(
                                  item,
                                  isStein: true,
                                );
                                videoDetailController.getSteinEdgeInfo(item.id);
                              },
                              child: Text(item.option!),
                            );
                          })
                          .toList(),
                    ),
                  ),
                );
              } catch (e) {
                if (kDebugMode) debugPrint('build stein edges: $e');
                return const SizedBox.shrink();
              }
            }
            return const SizedBox.shrink();
          },
        ),
      ],
    );
  }

  Widget localIntroPanel({
    bool needCtr = true,
  }) {
    return CustomScrollView(
      controller: needCtr
          ? videoDetailController.effectiveIntroScrollCtr
          : null,
      physics: !needCtr
          ? const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics())
          : null,
      key: const PageStorageKey(CommonIntroController),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.only(top: 7, bottom: padding.bottom + 100),
          sliver: LocalIntroPanel(
            key: videoRelatedKey,
            heroTag: heroTag,
          ),
        ),
      ],
    );
  }

  Widget videoIntro({
    double? width,
    double? height,
    bool? isHorizontal,
    bool needRelated = true,
    bool needCtr = true,
    bool isNested = false,
  }) {
    if (videoDetailController.isFileSource) {
      return localIntroPanel(needCtr: needCtr);
    }
    Widget introPanel() {
      Widget child = CustomScrollView(
        key: const PageStorageKey(CommonIntroController),
        controller: needCtr
            ? videoDetailController.effectiveIntroScrollCtr
            : null,
        physics: !needCtr
            ? const AlwaysScrollableScrollPhysics(
                parent: ClampingScrollPhysics(),
              )
            : null,
        slivers: [
          if (videoDetailController.isUgc) ...[
            UgcIntroPanel(
              key: videoIntroKey,
              heroTag: heroTag,
              showAiBottomSheet: showAiBottomSheet,
              showEpisodes: showEpisodes,
              onShowMemberPage: onShowMemberPage,
              isPortrait: isPortrait,
              isHorizontal: isHorizontal ?? width! / height! >= kScreenRatio,
            ),
            if (needRelated && videoDetailController.showRelatedVideo) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(
                    top: Style.safeSpace,
                  ),
                  child: Divider(
                    height: 1,
                    indent: 12,
                    endIndent: 12,
                    color: themeData.colorScheme.outline.withValues(
                      alpha: 0.08,
                    ),
                  ),
                ),
              ),
              RelatedVideoPanel(key: videoRelatedKey, heroTag: heroTag),
            ],
          ] else
            PgcIntroPage(
              key: videoIntroKey,
              heroTag: heroTag,
              cid: videoDetailController.cid.value,
              showEpisodes: showEpisodes,
              showIntroDetail: showIntroDetail,
              maxWidth: width ?? maxWidth,
              isLandscape: !isPortrait,
            ),
          SliverToBoxAdapter(
            child: SizedBox(
              height:
                  (videoDetailController.isPlayAll && !isPortrait
                      ? 80
                      : Style.safeSpace) +
                  padding.bottom,
            ),
          ),
        ],
      );
      if (isNested) {
        child = ExtendedVisibilityDetector(
          uniqueKey: const Key('intro-panel'),
          child: child,
        );
      }
      return KeepAliveWrapper(child: child);
    }

    if (videoDetailController.isPlayAll) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          introPanel(),
          Positioned(
            left: 12,
            right: 12,
            bottom: 12 + padding.bottom,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () => videoDetailController.showMediaListPanel(context),
                borderRadius: const BorderRadius.all(Radius.circular(14)),
                child: Container(
                  height: 54,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: themeData.colorScheme.secondaryContainer.withValues(
                      alpha: 0.95,
                    ),
                    borderRadius: const BorderRadius.all(Radius.circular(14)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.playlist_play, size: 24),
                      const SizedBox(width: 10),
                      Text(
                        videoDetailController.watchLaterTitle,
                        style: TextStyle(
                          color: themeData.colorScheme.onSecondaryContainer,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const Spacer(),
                      const Icon(Icons.keyboard_arrow_up_rounded, size: 26),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return introPanel();
  }

  int _safeSeasonIndex(int index, int sectionLength) {
    if (sectionLength <= 0) {
      return 0;
    }
    return max(0, min(index, sectionLength - 1));
  }

  Widget get seasonPanel {
    final videoDetail = ugcIntroController.videoDetail.value;
    return KeepAliveWrapper(
      child: Column(
        children: [
          if ((videoDetail.pages?.length ?? 0) > 1)
            if (videoDetail.ugcSeason != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: PagesPanel(
                  heroTag: heroTag,
                  ugcIntroController: ugcIntroController,
                  bvid: ugcIntroController.bvid,
                  showEpisodes: showEpisodes,
                ),
              )
            else
              Expanded(
                child: Obx(
                  () => EpisodePanel(
                    heroTag: heroTag,
                    enableSlide: false,
                    ugcIntroController: videoDetailController.isUgc
                        ? ugcIntroController
                        : null,
                    type: EpisodeType.part,
                    list: [videoDetail.pages!],
                    cover: videoDetailController.cover.value,
                    bvid: videoDetailController.bvid,
                    aid: videoDetailController.aid,
                    cid: videoDetailController.cid.value,
                    isReversed: videoDetail.isPageReversed,
                    onChangeEpisode: videoDetailController.isUgc
                        ? ugcIntroController.onChangeEpisode
                        : pgcIntroController.onChangeEpisode,
                    showTitle: false,
                    isSupportReverse: videoDetailController.isUgc,
                    onReverse: () => onReversePlay(isSeason: false),
                  ),
                ),
              ),
          if (videoDetail.ugcSeason != null) ...[
            if ((videoDetail.pages?.length ?? 0) > 1) ...[
              const SizedBox(height: 8),
              Divider(
                height: 1,
                color: themeData.colorScheme.outline.withValues(alpha: 0.1),
              ),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Obx(
                () => SeasonPanel(
                  key: ValueKey(introController.videoDetail.value),
                  heroTag: heroTag,
                  canTap: false,
                  showEpisodes: showEpisodes,
                  ugcIntroController: ugcIntroController,
                ),
              ),
            ),
            Expanded(
              child: Obx(
                () {
                  final sections = videoDetail.ugcSeason!.sections;
                  if (sections == null || sections.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  final safeSeasonIndex = _safeSeasonIndex(
                    videoDetailController.seasonIndex.value,
                    sections.length,
                  );
                  return EpisodePanel(
                    key: ValueKey(
                      'season-${videoDetailController.bvid}-'
                      '${videoDetail.ugcSeason!.id}-'
                      '${sections.map((item) => item.id).join(',')}',
                    ),
                    heroTag: heroTag,
                    enableSlide: false,
                    ugcIntroController: videoDetailController.isUgc
                        ? ugcIntroController
                        : null,
                    type: EpisodeType.season,
                    initialTabIndex: safeSeasonIndex,
                    cover: videoDetailController.cover.value,
                    seasonId: videoDetail.ugcSeason!.id,
                    list: sections,
                    bvid: videoDetailController.bvid,
                    aid: videoDetailController.aid,
                    cid: videoDetailController.seasonCid ?? 0,
                    isReversed: sections[safeSeasonIndex].isReversed,
                    onChangeEpisode: videoDetailController.isUgc
                        ? ugcIntroController.onChangeEpisode
                        : pgcIntroController.onChangeEpisode,
                    showTitle: false,
                    isSupportReverse: videoDetailController.isUgc,
                    onReverse: () => onReversePlay(isSeason: true),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget videoReplyPanel({bool isNested = false}) => VideoReplyPanel(
    key: videoReplyPanelKey,
    isNested: isNested,
    heroTag: heroTag,
  );

  // ai总结
  void showAiBottomSheet() {
    videoDetailController.childKey.currentState?.showBottomSheet(
      backgroundColor: Colors.transparent,
      constraints: const BoxConstraints(),
      (context) =>
          AiConclusionPanel(item: ugcIntroController.aiConclusionResult!),
    );
  }

  void showIntroDetail(
    PgcInfoModel videoDetail,
    List<VideoTagItem>? videoTags,
  ) {
    videoDetailController.childKey.currentState?.showBottomSheet(
      backgroundColor: Colors.transparent,
      constraints: const BoxConstraints(),
      (context) => PgcIntroPanel(
        item: videoDetail,
        videoTags: videoTags,
      ),
    );
  }

  void showEpisodes([
    int? index,
    UgcSeason? season,
    List<ugc.BaseEpisodeItem>? episodes,
    String? bvid,
    int? aid,
    int? cid,
  ]) {
    assert((cid == null) == (bvid == null));
    final isFullScreen = this.isFullScreen;
    if (cid == null) {
      videoDetailController.showMediaListPanel(context);
      return;
    }
    Widget listSheetContent({bool enableSlide = true}) {
      final sections = season?.sections;
      if (season != null && (sections == null || sections.isEmpty)) {
        return const SizedBox.shrink();
      }
      final safeSeasonIndex = season == null
          ? index ?? 0
          : _safeSeasonIndex(index ?? 0, sections!.length);
      return EpisodePanel(
        key: season == null
            ? null
            : ValueKey(
                'season-sheet-$bvid-${season.id}-'
                '${sections!.map((item) => item.id).join(',')}',
              ),
        heroTag: heroTag,
        ugcIntroController: videoDetailController.isUgc
            ? ugcIntroController
            : null,
        type: season != null
            ? EpisodeType.season
            : episodes is List<Part>
            ? EpisodeType.part
            : EpisodeType.pgc,
        cover: videoDetailController.cover.value,
        enableSlide: enableSlide,
        initialTabIndex: safeSeasonIndex,
        bvid: bvid!,
        aid: aid,
        cid: cid,
        seasonId: season?.id,
        list: season != null ? sections! : [episodes],
        isReversed: !videoDetailController.isUgc
            ? null
            : season != null
            ? sections![safeSeasonIndex].isReversed
            : ugcIntroController.videoDetail.value.isPageReversed,
        isSupportReverse: videoDetailController.isUgc,
        onChangeEpisode: videoDetailController.isUgc
            ? ugcIntroController.onChangeEpisode
            : pgcIntroController.onChangeEpisode,
        onClose: Get.back,
        onReverse: () {
          Get.back();
          onReversePlay(isSeason: season != null);
        },
      );
    }

    if (isFullScreen || videoDetailController.showVideoSheet) {
      final child = listSheetContent(enableSlide: false);
      PageUtils.showVideoBottomSheet(
        context,
        child: videoDetailController.plPlayerController.darkVideoPage
            ? Theme(data: themeData, child: child)
            : child,
      );
    } else {
      videoDetailController.childKey.currentState?.showBottomSheet(
        backgroundColor: Colors.transparent,
        constraints: const BoxConstraints(),
        (context) => listSheetContent(),
      );
    }
  }

  void onReversePlay({required bool isSeason}) {
    if (isSeason && videoDetailController.isPlayAll) {
      SmartDialog.showToast('当前为播放全部，合集不支持倒序');
      return;
    }

    final videoDetail = ugcIntroController.videoDetail.value;
    if (isSeason) {
      final sections = videoDetail.ugcSeason?.sections;
      if (sections == null || sections.isEmpty) {
        return;
      }
      final safeSeasonIndex = _safeSeasonIndex(
        videoDetailController.seasonIndex.value,
        sections.length,
      );
      if (videoDetailController.seasonIndex.value != safeSeasonIndex) {
        videoDetailController.seasonIndex.value = safeSeasonIndex;
      }
      // reverse season
      final item = sections[safeSeasonIndex];
      final itemEpisodes = item.episodes;
      if (itemEpisodes == null || itemEpisodes.isEmpty) {
        return;
      }
      item
        ..isReversed = !item.isReversed
        ..episodes = itemEpisodes.reversed.toList();

      if (!videoDetailController.plPlayerController.reverseFromFirst) {
        // keep current episode
        videoDetailController
          ..seasonIndex.refresh()
          ..cid.refresh();
      } else {
        // switch to first episode
        final episode = item.episodes!.first;
        if (episode.cid != videoDetailController.cid.value) {
          ugcIntroController.onChangeEpisode(episode);
          videoDetailController.seasonCid = episode.cid;
        } else {
          videoDetailController
            ..seasonIndex.refresh()
            ..cid.refresh();
        }
      }
    } else {
      // reverse part
      videoDetail
        ..isPageReversed = !videoDetail.isPageReversed
        ..pages = videoDetail.pages!.reversed.toList();
      if (!videoDetailController.plPlayerController.reverseFromFirst) {
        // keep current episode
        videoDetailController.cid.refresh();
      } else {
        // switch to first episode
        final episode = videoDetail.pages!.first;
        if (episode.cid != videoDetailController.cid.value) {
          ugcIntroController.onChangeEpisode(episode);
        } else {
          videoDetailController.cid.refresh();
        }
      }
    }
  }

  void showViewPoints() {
    if (isFullScreen || videoDetailController.showVideoSheet) {
      final child = ViewPointsPage(
        enableSlide: false,
        videoDetailController: videoDetailController,
        plPlayerController: plPlayerController,
      );
      PageUtils.showVideoBottomSheet(
        context,
        child: videoDetailController.plPlayerController.darkVideoPage
            ? Theme(data: themeData, child: child)
            : child,
      );
    } else {
      videoDetailController.childKey.currentState?.showBottomSheet(
        backgroundColor: Colors.transparent,
        constraints: const BoxConstraints(),
        (context) => ViewPointsPage(
          videoDetailController: videoDetailController,
          plPlayerController: plPlayerController,
        ),
      );
    }
  }

  void onShowMemberPage(int? mid) {
    videoDetailController.childKey.currentState?.showBottomSheet(
      shape: const RoundedRectangleBorder(),
      constraints: const BoxConstraints(),
      (context) {
        return HorizontalMemberPage(
          mid: mid,
          videoDetailController: videoDetailController,
          ugcIntroController: ugcIntroController,
        );
      },
    );
  }
}
