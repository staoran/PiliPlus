import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/audio.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pb.dart'
    show
        DetailItem,
        PlayURLResp,
        PlaylistSource,
        PlayInfo,
        ThumbUpReq_ThumbType,
        ListOrder,
        DashItem,
        ResponseUrl;
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart'
    show FavMixin;
import 'package:PiliPlus/pages/dynamics_repost/view.dart';
import 'package:PiliPlus/pages/main_reply/view.dart';
import 'package:PiliPlus/pages/setting/models/play_settings.dart'
    show kMaxVolume;
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/triple_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/debug_log_service.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/playback/playback_foreground_service.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/connectivity_utils.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/share_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:collection/collection.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as path;

class AudioController extends GetxController
    with
        GetTickerProviderStateMixin,
        TripleMixin,
        FavMixin,
        BlockConfigMixin,
        BlockMixin,
        WidgetsBindingObserver {
  late final Map args;
  late Int64 id;
  late Int64 oid;
  late List<Int64> subId;
  late int itemType;
  Int64? extraId;
  late final PlaylistSource from;
  @override
  late final bool isUgc = itemType == 1;

  final audioItem = Rxn<DetailItem>();

  bool _hasInit = false;
  @override
  Player? player;
  late int cacheAudioQa;

  late bool isDragging = false;
  final Rx<Duration> position = Duration.zero.obs;
  final Rx<Duration> duration = Duration.zero.obs;

  late final AnimationController animController;

  List<StreamSubscription>? _subscriptions;

  int? index;
  List<DetailItem>? playlist;
  final Map<String, int> _partProgress = {};

  late double speed = 1.0;

  late final Rx<PlayRepeat> playMode = Pref.audioPlayMode.obs;

  @override
  late final isLogin = Accounts.main.isLogin;

  Duration? _start;
  VideoDetailController? _videoDetailController;

  String? _prev;
  String? _next;
  bool get reachStart => _prev == null;

  ListOrder order = ListOrder.ORDER_NORMAL;
  Future<void> _switchQueue = Future<void>.value();
  bool _isLocalPlayback = false;
  // 保存当前使用的本地缓存条目（用于从其他页面返回时恢复本地播放）
  BiliDownloadEntryInfo? currentLocalEntry;
  // 听音频 completed gate 参数：
  // completed 信号可能早到，且 position.value 只按秒更新；因此 gate 用 raw
  // player state 做亚秒尾段判断，并在 fallback 最大等待内持续确认。
  // fallback 只允许提交时已经在尾段的 pending gate 使用，不能让非尾段
  // completed 延迟后仍触发自动切换。
  static const _completedGateTailThreshold = Duration(milliseconds: 1200);
  static const _completedGateCheckInterval = Duration(milliseconds: 120);
  static const _completedGateFallbackGrace = Duration(milliseconds: 200);
  static const _switchProtectionWarmupThreshold = Duration(seconds: 6);
  int _switchGeneration = 0;
  int _completedGateToken = 0;
  bool _pendingSwitchProtection = false;
  bool _switchProtectionWarmupStarted = false;
  bool _audioSwitchOpenReady = false;
  bool _isInBackground = false;
  bool _isSwitchingAudio = false;
  _CompletedAudioSwitchMarker? _completedSwitchMarker;
  bool get _isAppInForeground =>
      SchedulerBinding.instance.lifecycleState == AppLifecycleState.resumed;

  bool get isSwitchingAudio => _isSwitchingAudio;

  bool get _hasVideoDetailController => _videoDetailController != null;

  bool get _shouldSyncVideoDetailMetadata => _hasVideoDetailController;

  bool get _shouldSyncVideoDetailSideEffects =>
      _hasVideoDetailController && _isAppInForeground;

  int get _currentSubId => (subId.firstOrNull ?? oid).toInt();

  String _progressKey(int aid, int subId) => '$aid:$subId';

  bool _isSinglePart(DetailItem item) => item.parts.length <= 1;

  double? _lastVolume;
  late final RxDouble desktopVolume = RxDouble(Pref.desktopVolume);

  void toggleVolume() {
    if (_lastVolume == null) {
      _lastVolume = desktopVolume.value;
      setVolume(0, clearLastVolme: false);
    } else {
      setVolume(_lastVolume!);
    }
  }

  void setVolume(double volume, {bool clearLastVolme = true}) {
    if (clearLastVolme) {
      _lastVolume = null;
    }
    desktopVolume.value = volume;
    player?.setVolume(volume * 100);
  }

  void syncVolume([_]) {
    final volume = desktopVolume.value;
    PlPlayerController.instance
      ?..volume.value = volume
      ..videoPlayerController?.setVolume(volume * 100);
    GStorage.setting.put(SettingBoxKey.desktopVolume, volume.toPrecision(3));
  }

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    args = Get.arguments;
    oid = Int64(args['oid']);
    final id = args['id'];
    this.id = id != null ? Int64(id) : oid;
    subId = (args['subId'] as List<int>?)?.map(Int64.new).toList() ?? [oid];
    itemType = args['itemType'];
    from = args['from'];
    _start = args['start'];
    final int? extraId = args['extraId'];
    if (extraId != null) {
      this.extraId = Int64(extraId);
    }
    if (args['heroTag'] case String heroTag) {
      try {
        _videoDetailController = Get.find<VideoDetailController>(tag: heroTag);
      } catch (_) {}
    }
    speed = (args['speed'] as num?)?.toDouble() ?? 1.0;

    _queryPlayList(isInit: true);

    // 先确定音频质量配置，再检查离线资源和播放
    ConnectivityUtils.isWiFi.then((isWiFi) async {
      cacheAudioQa = isWiFi ? Pref.defaultAudioQa : Pref.defaultAudioQaCellular;

      final String? audioUrl = args['audioUrl'];
      final hasAudioUrl = audioUrl != null;

      if (hasAudioUrl) {
        // 即使传入了audioUrl，也先尝试使用本地离线资源
        final triedLocal = await _tryPlayLocalIfAvailable();
        if (!triedLocal) {
          // 离线资源不可用（不存在或打开失败）才使用传入的在线地址
          unawaited(
            _onOpenMedia(
              audioUrl,
              ua: BrowserUa.pc,
              referer: HttpString.baseUrl,
            ),
          );
        }
        // 有 audioUrl 时也需要查询空降助手
        _querySponsorBlock();
      } else {
        _queryPlayUrl();
      }
    });
    videoPlayerServiceHandler
      ?..onPlay = onPlay
      ..onPause = onPause
      ..onSeek = onSeek;

    animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );

    if (shutdownTimerService.isActive) {
      shutdownTimerService
        ..onPause = onPause
        ..isPlaying = isPlaying;
    }
  }

  bool isPlaying() {
    return player?.state.playing ?? false;
  }

  Future<void>? onPlay() {
    return player?.play();
  }

  Future<void>? onPause() {
    return player?.pause();
  }

  Future<void>? onSeek(Duration duration) {
    return player?.seek(duration);
  }

  void _updateCurrItem(DetailItem item) {
    audioItem.value = item;
    hasLike.value = item.stat.hasLike_7;
    coinNum.value = item.stat.hasCoin_8 ? 2 : 0;
    hasFav.value = item.stat.hasFav;
    if (isClosed) {
      return;
    }
    final expectedOid = oid;
    final expectedSubId = subId.firstOrNull;
    final expectedCid = (expectedSubId ?? expectedOid).toInt();
    if (_shouldSyncVideoDetailSideEffects) {
      videoPlayerServiceHandler?.onVideoDetailChange(
        item,
        expectedCid,
        hashCode.toString(),
      );
    } else if (_shouldSyncVideoDetailMetadata) {
      unawaited(
        videoPlayerServiceHandler?.onAudioDetailChangeInBackground(
              item,
              expectedCid,
              hashCode.toString(),
              isCurrent: () =>
                  !isClosed &&
                  oid == expectedOid &&
                  subId.firstOrNull == expectedSubId,
            ) ??
            Future<void>.value(),
      );
    } else {
      DebugLogService.log(
        'audio.item',
        'skip onVideoDetailChange in background',
        extra: {
          'oid': oid.toString(),
          'subId': subId.firstOrNull?.toString(),
          'foreground': _isAppInForeground,
        },
      );
    }
    DebugLogService.log(
      'audio.item',
      'update current item',
      extra: {
        'oid': oid.toString(),
        'subId': subId.firstOrNull?.toString(),
        'title': item.arc.title,
      },
    );
  }

  DetailItem? _findCurrentDetailItem() {
    final currentOid = oid;
    final currentSubId = subId.firstOrNull;

    final currentList = playlist;
    if (currentList == null) {
      return null;
    }

    for (final item in currentList) {
      if (item.item.oid != currentOid) {
        continue;
      }
      if (currentSubId == null) {
        return item;
      }
      final itemSubIds = item.item.subId;
      if (itemSubIds.contains(currentSubId) ||
          item.parts.any((part) => part.subId == currentSubId)) {
        return item;
      }
    }
    return currentList.firstWhereOrNull((item) => item.item.oid == currentOid);
  }

  void _updateCurrentItemFromState() {
    final currentItem = _findCurrentDetailItem();
    if (currentItem != null) {
      _updateCurrItem(currentItem);
    }
  }

  int _beginSwitch() {
    final generation = ++_switchGeneration;
    DebugLogService.log(
      'audio.switch',
      'begin switch',
      extra: {
        'generation': generation,
        'oid': oid.toString(),
        'subId': subId.firstOrNull?.toString(),
      },
    );
    return generation;
  }

  bool _isStaleSwitch(int generation) =>
      isClosed || generation != _switchGeneration;

  Duration _rawAudioPosition(Player currentPlayer) {
    final statePosition = currentPlayer.state.position;
    return statePosition > Duration.zero ? statePosition : position.value;
  }

  Duration _rawAudioDuration(Player currentPlayer) {
    final stateDuration = currentPlayer.state.duration;
    return stateDuration > Duration.zero ? stateDuration : duration.value;
  }

  Duration _completedGateFallbackWait(Duration remaining) {
    final wait = remaining + _completedGateFallbackGrace;
    return wait < _completedGateTailThreshold
        ? wait
        : _completedGateTailThreshold;
  }

  // playlist item 本身也作为身份的一部分：gate 窗口内如果列表刷新、
  // 用户手动切换或换源，旧 completed 的 pending token 必须失效。
  Object? _currentAudioItemIdentity() {
    final currentIndex = index;
    final currentPlaylist = playlist;
    if (currentIndex != null &&
        currentPlaylist != null &&
        currentIndex >= 0 &&
        currentIndex < currentPlaylist.length) {
      return currentPlaylist[currentIndex];
    }
    return audioItem.value;
  }

  // token 保证每个媒体最多只有一个 completed gate 可以消费；player、
  // switchGeneration、oid/subId/index/item 一起防止晚到 completed 落到新媒体上。
  bool _isAudioCompletedGateCurrent(_AudioCompletedGateSnapshot snapshot) {
    return snapshot.token == _completedGateToken &&
        !isClosed &&
        identical(player, snapshot.player) &&
        !_isSwitchingAudio &&
        _switchGeneration == snapshot.switchGeneration &&
        oid == snapshot.oid &&
        _currentSubId == snapshot.subId &&
        index == snapshot.index &&
        identical(_currentAudioItemIdentity(), snapshot.itemIdentity);
  }

  void _markCompletedSwitchForCurrentAudio() {
    // gate confirmed 后会先把当前条写成完成。紧随其后的自动切换会
    // 进入 _saveCurrentProgress()，这里打一次性标记来跳过那一次保存，
    // 避免把完成态 -1 降级成普通秒数。
    _completedSwitchMarker = _CompletedAudioSwitchMarker(
      oid: oid,
      subId: _currentSubId,
      switchGeneration: _switchGeneration,
    );
  }

  bool _consumeCompletedSwitchProgressSkip() {
    final marker = _completedSwitchMarker;
    if (marker == null) return false;
    final matches =
        marker.oid == oid &&
        marker.subId == _currentSubId &&
        marker.switchGeneration == _switchGeneration;
    if (matches) {
      _completedSwitchMarker = null;
      DebugLogService.log(
        'audio.progress',
        'skip save progress after completed switch',
        extra: {
          'oid': oid.toString(),
          'subId': subId.firstOrNull?.toString(),
          'generation': _switchGeneration,
        },
      );
      return true;
    }
    return false;
  }

  Future<void> _runAudioCompletedGate() async {
    final currentPlayer = player;
    if (currentPlayer == null) return;

    final token = ++_completedGateToken;
    final submitPosition = _rawAudioPosition(currentPlayer);
    final submitDuration = _rawAudioDuration(currentPlayer);
    final submitRemaining = submitDuration - submitPosition;
    final snapshot = _AudioCompletedGateSnapshot(
      token: token,
      player: currentPlayer,
      oid: oid,
      subId: _currentSubId,
      index: index,
      itemIdentity: _currentAudioItemIdentity(),
      switchGeneration: _switchGeneration,
      submitPosition: submitPosition,
      submitDuration: submitDuration,
    );
    final isTailCompleted =
        submitDuration > Duration.zero &&
        submitPosition >= Duration.zero &&
        submitRemaining >= Duration.zero &&
        submitRemaining <= _completedGateTailThreshold;

    // 非尾段 completed 不进入 pending/fallback。否则旧媒体 completed 在
    // 新媒体 position=0 或缓冲停住时晚到，也可能把新媒体错误切走。
    if (!isTailCompleted) {
      DebugLogService.log(
        'audio.completed',
        'discard_non_tail_completed',
        extra: {
          'oid': oid.toString(),
          'subId': subId.firstOrNull?.toString(),
          'position': submitPosition.inMilliseconds,
          'duration': submitDuration.inMilliseconds,
          'remaining': submitRemaining.inMilliseconds,
          'generation': _switchGeneration,
          'switching': _isSwitchingAudio,
        },
      );
      return;
    }

    DebugLogService.log(
      'audio.completed',
      'submit completed gate',
      extra: {
        'oid': oid.toString(),
        'subId': subId.firstOrNull?.toString(),
        'position': submitPosition.inMilliseconds,
        'duration': submitDuration.inMilliseconds,
        'remaining': submitRemaining.inMilliseconds,
        'playMode': playMode.value.name,
        'generation': _switchGeneration,
      },
    );

    final fallbackWait = _completedGateFallbackWait(submitRemaining);
    final startedAt = DateTime.now();
    var fallback = false;

    while (DateTime.now().difference(startedAt) < fallbackWait) {
      await Future<void>.delayed(_completedGateCheckInterval);
      if (!_isAudioCompletedGateCurrent(snapshot)) {
        DebugLogService.log(
          'audio.completed',
          'cancel completed gate identity mismatch',
          extra: snapshot.debugExtra(this),
        );
        return;
      }

      final currentPosition = _rawAudioPosition(currentPlayer);
      final currentDuration = _rawAudioDuration(currentPlayer);
      final currentRemaining = currentDuration - currentPosition;
      // 进入最后 200ms 后才消费 completed，确保“提前约 1 秒”的信号
      // 不会立即触发 _syncCompletedProgress() 和 playNext()。
      if (currentDuration > Duration.zero &&
          currentRemaining >= Duration.zero &&
          currentRemaining <= _completedGateFallbackGrace) {
        DebugLogService.log(
          'audio.completed',
          'confirm completed gate',
          extra: {
            ...snapshot.debugExtra(this),
            'position': currentPosition.inMilliseconds,
            'duration': currentDuration.inMilliseconds,
            'remaining': currentRemaining.inMilliseconds,
            'playMode': playMode.value.name,
          },
        );
        _handleConfirmedPlaybackCompleted();
        return;
      }

      if (DateTime.now().difference(startedAt) >= fallbackWait) {
        fallback = true;
        break;
      }
    }

    if (!_isAudioCompletedGateCurrent(snapshot)) {
      DebugLogService.log(
        'audio.completed',
        'cancel completed gate identity mismatch',
        extra: snapshot.debugExtra(this),
      );
      return;
    }

    // fallback 只允许提交时已经在尾段的 pending gate 使用。它防止真实
    // completed 后 position 停住导致卡死，但不会把非尾段 completed 变成延时切歌。
    if (fallback || DateTime.now().difference(startedAt) >= fallbackWait) {
      DebugLogService.log(
        'audio.completed',
        'fallback completed gate',
        extra: {
          ...snapshot.debugExtra(this),
          'wait': fallbackWait.inMilliseconds,
          'playMode': playMode.value.name,
        },
      );
      _handleConfirmedPlaybackCompleted();
    }
  }

  void _markAudioSwitching() {
    if (_isSwitchingAudio) return;
    _isSwitchingAudio = true;
    DebugLogService.log(
      'audio.switch',
      'mark audio switching',
      extra: {
        'oid': oid.toString(),
        'subId': subId.firstOrNull?.toString(),
      },
    );
  }

  void _clearAudioSwitching({required String reason}) {
    if (!_isSwitchingAudio) return;
    _isSwitchingAudio = false;
    _audioSwitchOpenReady = false;
    DebugLogService.log(
      'audio.switch',
      'clear audio switching',
      extra: {
        'reason': reason,
        'oid': oid.toString(),
        'subId': subId.firstOrNull?.toString(),
      },
    );
  }

  void _scheduleClearAudioSwitching(int generation) {
    Future.delayed(const Duration(milliseconds: 500), () {
      if (generation != _switchGeneration) return;
      _clearAudioSwitching(reason: 'media_opened');
    });
  }

  void _settleAudioSwitchingOnValidState({
    Duration? position,
    Duration? duration,
  }) {
    if (!_isSwitchingAudio) return;
    final hasValidPosition = position != null && position > Duration.zero;
    final hasValidDuration = duration != null && duration > Duration.zero;
    if (!hasValidPosition && !hasValidDuration) return;
    _clearAudioSwitching(
      reason: hasValidPosition
          ? 'first_valid_position'
          : 'first_valid_duration',
    );
  }

  void _resetPlaybackProgressForSwitch() {
    position.value = Duration.zero;
    duration.value = Duration.zero;
    _start = null;
    _audioSwitchOpenReady = false;
    videoPlayerServiceHandler?.onPositionChange(Duration.zero);
    DebugLogService.log(
      'audio.switch',
      'reset playback progress for switch',
      extra: {
        'oid': oid.toString(),
        'subId': subId.firstOrNull?.toString(),
      },
    );
  }

  bool get _hasNextSwitchTarget {
    if (playMode.value == PlayRepeat.pause ||
        playMode.value == PlayRepeat.singleCycle ||
        playMode.value == PlayRepeat.autoPlayRelated) {
      return false;
    }

    if (audioItem.value case final currentItem?) {
      final parts = currentItem.parts;
      if (parts.length > 1) {
        final currentSubId = subId.firstOrNull;
        final partIndex = parts.indexWhere((e) => e.subId == currentSubId);
        if (partIndex != -1 && partIndex + 1 < parts.length) {
          return true;
        }
      }
    }

    final currentIndex = index;
    final currentPlaylist = playlist;
    if (currentIndex == null || currentPlaylist == null) {
      return false;
    }
    if (currentIndex + 1 < currentPlaylist.length) {
      return true;
    }
    return playMode.value == PlayRepeat.listCycle && currentIndex != 0;
  }

  void _maybeStartSwitchProtectionWarmup(Duration currentPosition) {
    if (!_isInBackground) return;
    if (_switchProtectionWarmupStarted || _pendingSwitchProtection) return;
    final total = duration.value;
    if (total <= Duration.zero || !_hasNextSwitchTarget) return;
    final remaining = total - currentPosition;
    if (remaining > _switchProtectionWarmupThreshold) return;

    _switchProtectionWarmupStarted = true;
    DebugLogService.log(
      'audio.switch',
      'pre-end warmup switch protection',
      extra: {
        'remainingMs': remaining.inMilliseconds,
        'position': currentPosition.inMilliseconds,
        'duration': total.inMilliseconds,
        'playMode': playMode.value.name,
      },
    );
    unawaited(
      _ensureSwitchProtection(
        reason: 'pre_end_warmup',
        text: '正在准备下一条音频…',
      ),
    );
  }

  Future<void> _ensureSwitchProtection({
    required String reason,
    String? text,
  }) async {
    if (!_isInBackground) {
      return;
    }
    _pendingSwitchProtection = true;
    await PlaybackForegroundService.start(
      title: 'PiliPlus 后台播放',
      text: text ?? '正在准备下一条音频…',
    );
    DebugLogService.log(
      'audio.switch',
      'ensure switch protection',
      extra: {
        'reason': reason,
        'foreground': _isAppInForeground,
      },
    );
  }

  Future<void> _finishSwitchProtection({
    required bool success,
    required String reason,
  }) async {
    _pendingSwitchProtection = false;
    _switchProtectionWarmupStarted = false;
    if (!_isAppInForeground && PlaybackForegroundService.isRunning) {
      await PlaybackForegroundService.update(
        title: 'PiliPlus 后台播放',
        text: success ? '切换完成' : '切换失败',
        force: true,
      );
      await PlaybackForegroundService.stop();
    }
    DebugLogService.log(
      'audio.switch',
      'finish switch protection',
      extra: {
        'success': success,
        'reason': reason,
        'foreground': _isAppInForeground,
      },
    );
  }

  void _enqueueSwitch(Future<void> Function() action) {
    _switchQueue = _switchQueue.then((_) => action());
  }

  Future<void> _queryPlayList({
    bool isInit = false,
    bool isLoadPrev = false,
    bool isLoadNext = false,
  }) async {
    final res = await AudioGrpc.audioPlayList(
      id: id,
      oid: isInit ? oid : null,
      subId: isInit ? subId : null,
      itemType: isInit ? itemType : null,
      from: isInit ? from : null,
      next: isLoadPrev
          ? _prev
          : isLoadNext
          ? _next
          : null,
      extraId: extraId,
      order: order,
    );
    if (res case Success(:final response)) {
      if (isInit) {
        late final paginationReply = response.paginationReply;
        _prev = response.reachStart ? null : paginationReply.prev;
        _next = response.reachEnd ? null : paginationReply.next;
        final index = response.list.indexWhere((e) => e.item.oid == oid);
        if (index != -1) {
          this.index = index;
          _updateCurrItem(response.list[index]);
          playlist = response.list;
          // 更新媒体通知列表控制模式
          _updateListControlMode();
        }
      } else if (isLoadPrev) {
        _prev = response.reachStart ? null : response.paginationReply.prev;
        if (response.list.isNotEmpty) {
          index += response.list.length;
          playlist?.insertAll(0, response.list);
        }
      } else if (isLoadNext) {
        _next = response.reachEnd ? null : response.paginationReply.next;
        if (response.list.isNotEmpty) {
          playlist?.addAll(response.list);
        }
      }
    } else {
      res.toast();
    }
  }

  /// 更新媒体通知列表控制模式
  void _updateListControlMode() {
    final hasMultiItems = (playlist?.length ?? 0) > 1;

    videoPlayerServiceHandler?.setListControlMode(
      enabled: hasMultiItems,
      onNext: hasMultiItems ? playNext : null,
      onPrevious: hasMultiItems ? playPrev : null,
    );
  }

  Future<bool> _queryPlayUrl() async {
    DebugLogService.log(
      'audio.playurl',
      'query play url start',
      extra: {
        'oid': oid.toString(),
        'subId': subId.map((e) => e.toString()).toList(),
        'itemType': itemType,
        'isLocalPlayback': _isLocalPlayback,
      },
    );
    if (_isLocalPlayback) return true;

    // 切换视频时，立即清空旧的空降助手数据，防止 UI 残留
    resetBlock();

    // 尝试使用本地已缓存的离线音频
    final triedLocal = await _tryPlayLocalIfAvailable();
    if (triedLocal) {
      DebugLogService.log(
        'audio.playurl',
        'use local cache instead of remote url',
        extra: {
          'oid': oid.toString(),
          'subId': subId.firstOrNull?.toString(),
          'localEntry': currentLocalEntry?.entryDirPath,
        },
      );
      // 本地播放也需要查询空降助手（如果有网络）
      _querySponsorBlock();
      return true;
    }

    // 查询空降助手
    _querySponsorBlock();

    final res = await AudioGrpc.audioPlayUrl(
      itemType: itemType,
      oid: oid,
      subId: subId,
    );
    if (res case Success(:final response)) {
      DebugLogService.log(
        'audio.playurl',
        'query play url success',
        extra: {
          'oid': oid.toString(),
          'subId': subId.firstOrNull?.toString(),
        },
      );
      return _onPlay(response);
    } else {
      DebugLogService.log(
        'audio.playurl',
        'query play url failed',
        extra: {
          'oid': oid.toString(),
          'subId': subId.firstOrNull?.toString(),
          'error': res.toString(),
        },
      );
      res.toast();
      return false;
    }
  }

  Future<bool> _queryPlayUrlForSwitch(int generation) async {
    final result = await _queryPlayUrl();
    if (_isStaleSwitch(generation)) {
      return false;
    }
    return result;
  }

  Future<bool> _tryPlayLocalIfAvailable() async {
    // 与视频页保持一致：允许通过参数强制本地播放，或全局开关 Pref.enableLocalPlayInOnlineList
    final bool forceLocalPlay = args['forceLocalPlay'] == true;
    final bool shouldTryLocal =
        forceLocalPlay || Pref.enableLocalPlayInOnlineList;
    if (!shouldTryLocal) return false;

    final int? targetCid = subId.firstOrNull?.toInt();
    if (targetCid == null) return false;

    BiliDownloadEntryInfo? local;
    final passed = args['entry'];
    if (passed is BiliDownloadEntryInfo &&
        passed.isCompleted &&
        passed.cid == targetCid &&
        passed.entryDirPath.isNotEmpty &&
        passed.typeTag?.isNotEmpty == true) {
      local = passed;
    } else {
      local = await _findLocalCompletedEntryByCid(targetCid);
    }

    if (local == null) return false;

    final audioPath = path.join(
      local.entryDirPath,
      local.typeTag!,
      PathUtils.audioNameType2,
    );
    if (!File(audioPath).existsSync()) {
      return false;
    }

    _isLocalPlayback = true;
    // 保存找到的本地缓存条目
    currentLocalEntry = local;
    DebugLogService.log(
      'audio.local',
      'local cache hit',
      extra: {
        'oid': oid.toString(),
        'cid': targetCid,
        'entryDirPath': local.entryDirPath,
      },
    );
    duration.value = Duration(milliseconds: local.totalTimeMilli);
    return _onOpenMedia(audioPath, ua: '', referer: null);
  }

  Future<bool> _onPlay(PlayURLResp data) {
    final PlayInfo? playInfo = data.playerInfo.values.firstOrNull;
    if (playInfo != null) {
      if (playInfo.hasPlayDash()) {
        final playDash = playInfo.playDash;
        final audios = playDash.audio;
        if (audios.isEmpty) {
          return Future.value(false);
        }
        position.value = Duration.zero;
        final audio = audios.findClosestTarget(
          (e) => e.id <= cacheAudioQa,
          (a, b) => a.id > b.id ? a : b,
        );
        return _onOpenMedia(
          VideoUtils.getCdnUrl(audio.playUrls, isAudio: true),
        );
      } else if (playInfo.hasPlayUrl()) {
        final playUrl = playInfo.playUrl;
        final durls = playUrl.durl;
        if (durls.isEmpty) {
          return Future.value(false);
        }
        final durl = durls.first;
        position.value = Duration.zero;
        return _onOpenMedia(VideoUtils.getCdnUrl(durl.playUrls, isAudio: true));
      }
    }
    return Future.value(false);
  }

  Future<bool> _onOpenMedia(
    String url, {
    String ua = Constants.userAgentApp,
    String? referer,
  }) async {
    final openGeneration = _switchGeneration;
    DebugLogService.log(
      'audio.media',
      'open media',
      extra: {
        'oid': oid.toString(),
        'subId': subId.firstOrNull?.toString(),
        'url': url,
        'start': _start?.inMilliseconds,
        'isLocalPlayback': _isLocalPlayback,
      },
    );
    if (openGeneration == _switchGeneration) {
      _audioSwitchOpenReady = true;
      position.value = Duration.zero;
    }
    try {
      await _initPlayerIfNeeded();
      if (player == null) {
        _clearAudioSwitching(reason: 'player_unavailable');
        return false;
      }
      player!.setMediaHeader(
        userAgent: ua,
        // mpv cannot clear referer option
        headers: {'Referer': ?referer},
      );
      await player!.open(
        Media(
          url,
          start: _start,
        ),
        play: false,
      );
      await player!.play();
      player!.setRate(speed);
      if (openGeneration == _switchGeneration) {
        final currentPlayer = player!;
        final statePosition = _rawAudioPosition(currentPlayer);
        final stateDuration = _rawAudioDuration(currentPlayer);
        if (stateDuration > Duration.zero) {
          duration.value = stateDuration;
        }
        if (_start case final start? when start > Duration.zero) {
          position.value = start;
        } else if (statePosition > Duration.zero) {
          position.value = statePosition;
        }
        _start = null;
        _scheduleClearAudioSwitching(openGeneration);
        initSkip();
        return true;
      } else {
        DebugLogService.log(
          'audio.media',
          'ignore stale media open completion',
          extra: {
            'openGeneration': openGeneration,
            'currentGeneration': _switchGeneration,
            'oid': oid.toString(),
            'subId': subId.firstOrNull?.toString(),
          },
        );
        return false;
      }
    } catch (e) {
      DebugLogService.log(
        'audio.media',
        'open media failed',
        extra: {
          'oid': oid.toString(),
          'subId': subId.firstOrNull?.toString(),
          'error': e.toString(),
        },
      );
      if (openGeneration == _switchGeneration) {
        _clearAudioSwitching(reason: 'media_open_failed');
      }
      if (openGeneration == _switchGeneration && _pendingSwitchProtection) {
        unawaited(
          _finishSwitchProtection(
            success: false,
            reason: 'media_open_failed',
          ),
        );
      }
      return false;
    }
  }

  Future<void> _initPlayerIfNeeded() async {
    if (_hasInit) return;
    _hasInit = true;
    assert(player == null, _subscriptions = null);
    player = await Player.create(
      configuration: PlayerConfiguration(
        options: {
          'volume': PlatformUtils.isDesktop
              ? (desktopVolume.value * 100).toString()
              : Pref.playerVolume.toString(),
          'volume-max': kMaxVolume.toString(),
          ...Pref.initBuffer(),
        },
      ),
    );
    if (isClosed) {
      player!.dispose();
      player = null;
      return;
    }
    final stream = player!.stream;
    _subscriptions = [
      stream.position.listen((position) {
        if (isDragging) return;
        if (_isSwitchingAudio && !_audioSwitchOpenReady) return;
        final shouldUpdatePosition =
            position.inSeconds != this.position.value.inSeconds ||
            (this.position.value == Duration.zero && position > Duration.zero);
        if (shouldUpdatePosition) {
          this.position.value = position;
          if (_shouldSyncVideoDetailMetadata) {
            _videoDetailController?.playedTime = position;
          }
          videoPlayerServiceHandler?.onPositionChange(position);
        }
        _settleAudioSwitchingOnValidState(position: position);
        _maybeStartSwitchProtectionWarmup(position);
      }),
      stream.duration.listen((duration) {
        if (_isSwitchingAudio && !_audioSwitchOpenReady) return;
        this.duration.value = duration;
        _settleAudioSwitchingOnValidState(duration: duration);
      }),
      stream.playing.listen((playing) {
        final PlayerStatus playerStatus;
        if (playing) {
          animController.forward();
          playerStatus = PlayerStatus.playing;
          if (_pendingSwitchProtection) {
            unawaited(
              _finishSwitchProtection(
                success: true,
                reason: 'playback_started',
              ),
            );
          }
        } else {
          animController.reverse();
          playerStatus = PlayerStatus.paused;
        }
        videoPlayerServiceHandler?.onStatusChange(playerStatus, false, false);
      }),
      stream.completed.listen((completed) {
        if (!completed) {
          return;
        }
        DebugLogService.log(
          'audio.completed',
          'completed signal received',
          extra: {
            'oid': oid.toString(),
            'subId': subId.firstOrNull?.toString(),
            'position': position.value.inMilliseconds,
            'duration': duration.value.inMilliseconds,
          },
        );
        _handlePlaybackCompleted();
      }),
    ];
  }

  void _handlePlaybackCompleted() {
    if (_isSwitchingAudio) {
      DebugLogService.log(
        'audio.completed',
        'ignore completed while switching',
        extra: {
          'oid': oid.toString(),
          'subId': subId.firstOrNull?.toString(),
        },
      );
      return;
    }
    DebugLogService.log(
      'audio.completed',
      'handle playback completed candidate',
      extra: {
        'oid': oid.toString(),
        'subId': subId.firstOrNull?.toString(),
        'playMode': playMode.value.name,
      },
    );
    unawaited(_runAudioCompletedGate());
  }

  void _handleConfirmedPlaybackCompleted() {
    _syncCompletedProgress();
    if (_shouldSyncVideoDetailMetadata) {
      _videoDetailController?.playedTime = duration.value;
    }
    videoPlayerServiceHandler?.onStatusChange(
      PlayerStatus.completed,
      false,
      false,
    );
    if (kDebugMode) {
      debugPrint('AudioController: 播放完成，准备切换下一个');
    }
    if (shutdownTimerService.isWaiting) {
      shutdownTimerService.handleWaiting();
    } else {
      switch (playMode.value) {
        case PlayRepeat.pause:
          break;
        case PlayRepeat.listOrder:
          _markCompletedSwitchForCurrentAudio();
          if (!playNext(nextPart: true)) {
            _completedSwitchMarker = null;
          }
          break;
        case PlayRepeat.singleCycle:
          _enqueueSwitch(() async {
            if (player case final currentPlayer?) {
              await currentPlayer.seek(Duration.zero);
              await currentPlayer.play();
            }
          });
          break;
        case PlayRepeat.listCycle:
          _markCompletedSwitchForCurrentAudio();
          if (playNext(nextPart: true)) {
          } else if (index != null && index != 0 && playlist != null) {
            playIndex(0);
          } else {
            _completedSwitchMarker = null;
            _enqueueSwitch(() async {
              if (player case final currentPlayer?) {
                await currentPlayer.seek(Duration.zero);
                await currentPlayer.play();
              }
            });
          }
          break;
        case PlayRepeat.autoPlayRelated:
          break;
      }
    }
  }

  @pragma('vm:notify-debugger-on-exception')
  void _querySponsorBlock() {
    if (isUgc && blockConfig.enableSponsorBlock) {
      try {
        querySponsorBlock(
          bvid: IdUtils.av2bv(oid.toInt()),
          cid: (subId.firstOrNull ?? oid).toInt(),
        );
      } catch (_) {}
    }
  }

  @override
  Future<void> actionLikeVideo() async {
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final newVal = !hasLike.value;
    final res = await AudioGrpc.audioThumbUp(
      oid: oid,
      subId: subId,
      itemType: itemType,
      type: newVal
          ? ThumbUpReq_ThumbType.LIKE
          : ThumbUpReq_ThumbType.CANCEL_LIKE,
    );
    if (res case Success(:final response)) {
      hasLike.value = newVal;
      try {
        audioItem.value!.stat
          ..hasLike_7 = newVal
          ..like += newVal ? 1 : -1;
        audioItem.refresh();
      } catch (_) {}
      SmartDialog.showToast(response.message);
    } else {
      res.toast();
    }
  }

  @override
  Future<void> actionTriple() async {
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final res = await AudioGrpc.audioTripleLike(
      oid: oid,
      subId: subId,
      itemType: itemType,
    );
    if (res case Success(:final response)) {
      hasLike.value = true;
      if (response.coinOk && !hasCoin) {
        coinNum.value = 2;
        GlobalData().afterCoin(2);
        try {
          audioItem.value!.stat
            ..hasCoin_8 = true
            ..coin += 2;
          audioItem.refresh();
        } catch (_) {}
      }
      hasFav.value = true;
      if (!hasCoin) {
        SmartDialog.showToast('投币失败');
      } else {
        SmartDialog.showToast('三连成功');
      }
    } else {
      res.toast();
    }
  }

  @override
  int get copyright => audioItem.value?.arc.copyright ?? 1;

  @override
  Future<void> onPayCoin(int coin, bool coinWithLike) async {
    final res = await AudioGrpc.audioCoinAdd(
      oid: oid,
      subId: subId,
      itemType: itemType,
      num: coin,
      thumbUp: coinWithLike,
    );
    if (res.isSuccess) {
      final updateLike = !hasLike.value && coinWithLike;
      if (updateLike) {
        hasLike.value = true;
      }
      coinNum.value += coin;
      try {
        final stat = audioItem.value!.stat
          ..hasCoin_8 = true
          ..coin += coin;
        if (updateLike) {
          stat
            ..hasLike_7 = true
            ..like += 1;
        }
        audioItem.refresh();
      } catch (_) {}
      GlobalData().afterCoin(coin);
    } else {
      res.toast();
    }
  }

  @override
  void showFavBottomSheet(BuildContext context, {bool isLongPress = false}) {
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    if (enableQuickFav) {
      if (!isLongPress) {
        actionFavVideo(isQuick: true);
      } else {
        PageUtils.showFavBottomSheet(context: context, ctr: this);
      }
    } else if (!isLongPress) {
      PageUtils.showFavBottomSheet(context: context, ctr: this);
    }
  }

  void showReply() {
    MainReplyPage.toMainReplyPage(
      oid: oid.toInt(),
      replyType: isUgc ? 1 : 14,
    );
  }

  void actionShareVideo(BuildContext context) {
    final audioUrl = isUgc
        ? '${HttpString.baseUrl}/video/${IdUtils.av2bv(oid.toInt())}'
        : '${HttpString.baseUrl}/audio/au$oid';
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        clipBehavior: Clip.hardEdge,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              title: const Text(
                '复制链接',
                style: TextStyle(fontSize: 14),
              ),
              onTap: () {
                Get.back();
                Utils.copyText(audioUrl);
              },
            ),
            ListTile(
              dense: true,
              title: const Text(
                '其它app打开',
                style: TextStyle(fontSize: 14),
              ),
              onTap: () {
                Get.back();
                PageUtils.launchURL(audioUrl);
              },
            ),
            if (PlatformUtils.isMobile)
              ListTile(
                dense: true,
                title: const Text(
                  '分享视频',
                  style: TextStyle(fontSize: 14),
                ),
                onTap: () {
                  Get.back();
                  if (audioItem.value case DetailItem(
                    :final arc,
                    :final owner,
                  )) {
                    ShareUtils.shareText(
                      '${arc.title} '
                      'UP主: ${owner.name}'
                      ' - $audioUrl',
                    );
                  }
                },
              ),
            ListTile(
              dense: true,
              title: const Text(
                '分享至动态',
                style: TextStyle(fontSize: 14),
              ),
              onTap: () {
                Get.back();
                if (audioItem.value case DetailItem(
                  :final arc,
                  :final owner,
                )) {
                  showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    builder: (context) => RepostPanel(
                      rid: oid.toInt(),
                      dynType: isUgc ? 8 : 256,
                      pic: arc.cover,
                      title: arc.title,
                      uname: owner.name,
                    ),
                  );
                }
              },
            ),
            if (isUgc)
              ListTile(
                dense: true,
                title: const Text(
                  '分享至消息',
                  style: TextStyle(fontSize: 14),
                ),
                onTap: () {
                  Get.back();
                  if (audioItem.value case DetailItem(
                    :final arc,
                    :final owner,
                  )) {
                    try {
                      PageUtils.pmShare(
                        context,
                        content: {
                          "id": oid.toString(),
                          "title": arc.title,
                          "headline": arc.title,
                          "source": 5,
                          "thumb": arc.cover,
                          "author": owner.name,
                          "author_id": owner.mid.toString(),
                        },
                      );
                    } catch (e) {
                      SmartDialog.showToast(e.toString());
                    }
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  void playOrPause() {
    if (player case final player?) {
      if ((duration.value - position.value).inMilliseconds < 50) {
        player.seek(Duration.zero).whenComplete(player.play);
      } else {
        player.playOrPause();
      }
    }
  }

  bool playPrev() {
    if (index != null && playlist != null && player != null) {
      final prev = index! - 1;
      if (prev >= 0) {
        _enqueueSwitch(() async {
          await _ensureSwitchProtection(
            reason: 'play_prev',
            text: '正在切换上一条音频…',
          );
          await _playIndexInternal(prev, skipSaveProgress: false);
        });
        return true;
      }
    }
    return false;
  }

  bool playNext({bool nextPart = false}) {
    if (nextPart) {
      if (audioItem.value case final currentItem?) {
        final parts = currentItem.parts;
        if (parts.length > 1) {
          final subId = this.subId.firstOrNull;
          final nextIndex = parts.indexWhere((e) => e.subId == subId) + 1;
          if (nextIndex != 0 && nextIndex < parts.length) {
            _enqueueSwitch(() async {
              await _ensureSwitchProtection(
                reason: 'play_next_part',
                text: '正在切换下一段音频…',
              );
              await _playNextPartInternal(nextIndex);
            });
            return true;
          }
        }
      }
    }
    if (index != null && playlist != null && player != null) {
      final next = index! + 1;
      if (next < playlist!.length) {
        _enqueueSwitch(() async {
          await _ensureSwitchProtection(
            reason: 'play_next',
            text: '正在切换下一条音频…',
          );
          await _playIndexInternal(next, skipSaveProgress: false);
        });
        return true;
      }
    }
    return false;
  }

  void playIndex(
    int index, {
    List<Int64>? subId,
    bool skipSaveProgress = false,
  }) {
    _enqueueSwitch(
      () async {
        await _ensureSwitchProtection(
          reason: 'play_index',
          text: '正在切换指定音频…',
        );
        await _playIndexInternal(
          index,
          subId: subId,
          skipSaveProgress: skipSaveProgress,
        );
      },
    );
  }

  Future<void> _playNextPartInternal(int nextPartIndex) async {
    final currentItem = audioItem.value;
    if (currentItem == null) {
      return;
    }
    final parts = currentItem.parts;
    if (nextPartIndex < 0 || nextPartIndex >= parts.length) {
      return;
    }

    _saveCurrentProgress();
    final generation = _beginSwitch();
    final nextPart = parts[nextPartIndex];
    DebugLogService.log(
      'audio.switch',
      'switch to next part',
      extra: {
        'generation': generation,
        'currentOid': oid.toString(),
        'nextOid': nextPart.oid.toString(),
        'nextSubId': nextPart.subId.toString(),
        'nextPartIndex': nextPartIndex,
      },
    );
    _markAudioSwitching();
    _isLocalPlayback = false;
    final prevOid = oid;
    final prevSubId = subId;
    oid = nextPart.oid;
    subId = [nextPart.subId];
    _resetPlaybackProgressForSwitch();
    final res = await _queryPlayUrlForSwitch(generation);
    if (res) {
      DebugLogService.log(
        'audio.switch',
        'switch to next part success',
        extra: {
          'generation': generation,
          'oid': oid.toString(),
          'subId': subId.firstOrNull?.toString(),
        },
      );
      _updateCurrentItemFromState();
    } else {
      if (!_isStaleSwitch(generation)) {
        oid = prevOid;
        subId = prevSubId;
        _clearAudioSwitching(reason: 'next_part_failed');
        _updateCurrentItemFromState();
      }
      DebugLogService.log(
        'audio.switch',
        'switch to next part failed',
        extra: {
          'generation': generation,
          'oid': oid.toString(),
          'subId': subId.firstOrNull?.toString(),
        },
      );
      await _finishSwitchProtection(success: false, reason: 'next_part');
    }
  }

  Future<void> _playIndexInternal(
    int index, {
    List<Int64>? subId,
    bool skipSaveProgress = false,
  }) async {
    if (index == this.index && subId == null) return;
    // 切换前保存当前视频进度（如果没有在调用方保存过）
    if (!skipSaveProgress) {
      _saveCurrentProgress();
    }
    final generation = _beginSwitch();
    _markAudioSwitching();
    final prevIndex = this.index;
    final prevOid = oid;
    final prevSubId = this.subId;
    final prevItemType = itemType;
    this.index = index;
    _isLocalPlayback = false;
    final audioItem = playlist![index];
    final item = audioItem.item;
    oid = item.oid;
    this.subId =
        subId ??
        (item.subId.isNotEmpty ? item.subId : [audioItem.parts.first.subId]);
    itemType = item.itemType;
    _resetPlaybackProgressForSwitch();
    final currentAid = item.oid.toInt();
    final currentSubId = _currentSubId;
    final progressKey = _progressKey(currentAid, currentSubId);
    final savedPartProgress = _partProgress[progressKey];
    int progress = savedPartProgress ?? 0;
    if (progress <= 0) {
      progress = _getProgressFromMediaList(currentAid, currentSubId);
    }
    if (progress <= 0 && audioItem.progress > 0) {
      progress = audioItem.progress.toInt();
    }
    if (kDebugMode) {
      debugPrint(
        '🎵 playIndex: index=$index, oid=${item.oid}, progress=$progress seconds',
      );
    }
    DebugLogService.log(
      'audio.switch',
      'switch to playlist index',
      extra: {
        'generation': generation,
        'index': index,
        'oid': item.oid.toString(),
        'subId': this.subId.firstOrNull?.toString(),
        'progress': progress,
      },
    );
    // 先由 _resetPlaybackProgressForSwitch 清理旧 seek，再按新列表项进度设置目标 seek。
    _start = progress > 0 ? Duration(seconds: progress) : null;
    final res = await _queryPlayUrlForSwitch(generation);
    if (res) {
      DebugLogService.log(
        'audio.switch',
        'switch to playlist index success',
        extra: {
          'generation': generation,
          'index': index,
          'oid': oid.toString(),
          'subId': this.subId.firstOrNull?.toString(),
        },
      );
      _updateCurrentItemFromState();
    } else {
      if (!_isStaleSwitch(generation)) {
        this.index = prevIndex;
        oid = prevOid;
        this.subId = prevSubId;
        itemType = prevItemType;
        _clearAudioSwitching(reason: 'playlist_index_failed');
        _updateCurrentItemFromState();
      }
      DebugLogService.log(
        'audio.switch',
        'switch to playlist index failed',
        extra: {
          'generation': generation,
          'index': index,
          'oid': oid.toString(),
          'subId': this.subId.firstOrNull?.toString(),
        },
      );
      await _finishSwitchProtection(success: false, reason: 'playlist_index');
    }
  }

  /// 从 VideoDetailController 的 mediaList 中获取视频的本地进度（秒）
  int _getProgressFromMediaList(int aid, int cid) {
    if (_videoDetailController == null) return 0;
    try {
      final mediaList = _videoDetailController!.mediaList;
      final item = mediaList.firstWhereOrNull(
        (e) =>
            e.aid == aid &&
            (e.pages?.any((page) => page.id == cid) ?? e.cid == cid),
      );
      if (item != null && item.progress != null && item.progress! > 0) {
        return item.progress!;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('获取 mediaList 进度失败: $e');
      }
    }
    return 0;
  }

  /// 保存当前视频的播放进度到 VideoDetailController
  /// 使用听视频当前播放的视频信息，而不是 VideoDetailController 的视频信息
  void _saveCurrentProgress() {
    // completed gate 确认后已经把当前音频写成完成态。紧随其后的自动
    // 切换会再次调用 _saveCurrentProgress()，因此这里消费一次性标记，
    // 只跳过这一次保存，避免完成态被降级成普通进度。
    if (_consumeCompletedSwitchProgressSkip()) return;
    if (_videoDetailController == null) return;
    if (_isSwitchingAudio) {
      DebugLogService.log(
        'audio.progress',
        'skip save progress while switching',
        extra: {
          'oid': oid.toString(),
          'subId': subId.firstOrNull?.toString(),
        },
      );
      return;
    }

    final currentPlayer = player;
    if (currentPlayer == null) return;

    try {
      final currentPosition = _rawAudioPosition(currentPlayer);
      if (currentPosition == Duration.zero) return;

      // 获取听视频当前播放的视频信息
      final currentOid = oid.toInt();
      final currentCid = _currentSubId;
      final currentBvid = IdUtils.av2bv(currentOid);
      final currentDuration = _rawAudioDuration(currentPlayer).inSeconds;
      final progressSeconds = currentPosition.inSeconds;

      if (kDebugMode) {
        debugPrint(
          '🎵 AudioController: 保存进度 bvid=$currentBvid, cid=$currentCid, position=${progressSeconds}s',
        );
      }

      _partProgress[_progressKey(currentOid, currentCid)] = progressSeconds;

      // 单 P 列表项可继续同步 item-level 进度；多 P 由 per-subId map 隔离。
      if (index != null && playlist != null && index! < playlist!.length) {
        final currentItem = playlist![index!];
        if (_isSinglePart(currentItem)) {
          currentItem.progress = Int64(progressSeconds);
        }
      }

      // 使用新的公开方法更新指定视频的进度
      if (_shouldSyncVideoDetailMetadata) {
        _videoDetailController!.updateProgressForVideo(
          videoAid: currentOid,
          videoBvid: currentBvid,
          videoCid: currentCid,
          progressSeconds: progressSeconds,
          videoDuration: currentDuration,
        );
      } else {
        DebugLogService.log(
          'audio.progress',
          'skip updateProgressForVideo in background',
          extra: {
            'videoAid': currentOid,
            'videoCid': currentCid,
            'progressSeconds': progressSeconds,
            'foreground': _isAppInForeground,
          },
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AudioController: 保存进度失败: $e');
      }
    }
  }

  void _syncCompletedProgress() {
    if (_videoDetailController == null) return;

    try {
      final currentPlayer = player;
      if (currentPlayer == null) return;
      final currentOid = oid.toInt();
      final currentCid = _currentSubId;
      final currentBvid = IdUtils.av2bv(currentOid);
      final currentDuration = _rawAudioDuration(currentPlayer).inSeconds;

      if (currentDuration <= 0) {
        return;
      }

      _partProgress[_progressKey(currentOid, currentCid)] = -1;

      if (index != null && playlist != null && index! < playlist!.length) {
        final currentItem = playlist![index!];
        if (_isSinglePart(currentItem)) {
          currentItem.progress = Int64(currentDuration);
        }
      }

      _videoDetailController!.updateProgressForVideo(
        videoAid: currentOid,
        videoBvid: currentBvid,
        videoCid: currentCid,
        progressSeconds: -1,
        videoDuration: currentDuration,
      );

      DebugLogService.log(
        'audio.progress',
        'sync completed progress',
        extra: {
          'videoAid': currentOid,
          'videoCid': currentCid,
          'videoDuration': currentDuration,
          'foreground': _isAppInForeground,
        },
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AudioController: 同步完成进度失败: $e');
      }
    }
  }

  void setSpeed(double speed) {
    if (player case final player?) {
      this.speed = speed;
      player.setRate(speed);
      if (_shouldSyncVideoDetailSideEffects) {
        unawaited(
          _videoDetailController?.plPlayerController.setPlaybackSpeed(speed),
        );
      }
    }
  }

  @override
  (Object, int) get getFavRidType => (oid, isUgc ? 2 : 12);

  @override
  void updateFavCount(int count) {
    try {
      audioItem.value!.stat
        ..hasFav = count > 0
        ..favourite += count;
      audioItem.refresh();
    } catch (_) {}
  }

  Future<void> loadPrev(BuildContext context) async {
    if (_prev == null) return;
    final length = playlist!.length;
    await _queryPlayList(isLoadPrev: true);
    if (length != playlist!.length && context.mounted) {
      (context as Element).markNeedsBuild();
    }
  }

  Future<void> loadNext(BuildContext context) async {
    if (_next == null) return;
    final length = playlist!.length;
    await _queryPlayList(isLoadNext: true);
    if (length != playlist!.length && context.mounted) {
      (context as Element).markNeedsBuild();
    }
  }

  void onChangeOrder(ListOrder value) {
    if (order != value) {
      order = value;
      _queryPlayList(isInit: true);
    }
  }

  @override
  BlockConfigMixin get blockConfig => this;

  @override
  int get currPosInMilliseconds => position.value.inMilliseconds;

  @override
  Future<void>? seekTo(Duration duration, {required bool isSeek}) =>
      onSeek(duration);

  @override
  int? get timeLength => duration.value.inMilliseconds;

  @override
  bool get autoPlay => true;

  @override
  bool get preInitPlayer => true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _isInBackground = true;
    } else if (state == AppLifecycleState.resumed) {
      _isInBackground = false;
    }
  }

  @override
  void onClose() {
    _completedGateToken++;
    _completedSwitchMarker = null;
    // 退出听视频时保存最后的进度
    if (!_isSwitchingAudio) {
      _saveCurrentProgress();
    } else {
      DebugLogService.log(
        'audio.progress',
        'skip save progress on close while switching',
        extra: {
          'oid': oid.toString(),
          'subId': subId.firstOrNull?.toString(),
        },
      );
    }

    if (_pendingSwitchProtection) {
      unawaited(
        _finishSwitchProtection(
          success: false,
          reason: 'controller_closed',
        ),
      );
    }

    // _cancelTimer();
    shutdownTimerService
      ..onPause = null
      ..isPlaying = null
      ..reset();
    videoPlayerServiceHandler
      ?..onPlay = null
      ..onPause = null
      ..onSeek = null;
    // 不要在这里重置 setListControlMode，因为播放器页有自己的状态管理
    // 从听视频页返回时，播放器页的 didPopNext 会恢复正确的列表控制模式
    if (_shouldSyncVideoDetailSideEffects) {
      videoPlayerServiceHandler?.onVideoDetailDispose(hashCode.toString());
    } else {
      DebugLogService.log(
        'audio.handler',
        'skip onVideoDetailDispose while background',
        extra: {'foreground': _isAppInForeground},
      );
    }
    _subscriptions?.forEach((e) => e.cancel());
    _subscriptions?.clear();
    _subscriptions = null;
    player?.dispose();
    player = null;
    animController.dispose();
    // 方案对比说明：
    // - 旧方案：这里根据 shouldPreserveVideoNotification 条件 clear。
    // - 新方案：统一通过 onVideoDetailDispose 由 handler 判定”是否已无 owner”。
    // 这样不用在页面层复制”是否该清理”的策略，降低多页面维护成本。
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }

  Future<BiliDownloadEntryInfo?> _findLocalCompletedEntryByCid(int cid) async {
    try {
      if (!Get.isRegistered<DownloadService>()) {
        return null;
      }
      final ds = Get.find<DownloadService>();
      await ds.waitForInitialization;
      for (final entry in ds.downloadList) {
        if (entry.isCompleted &&
            entry.cid == cid &&
            entry.entryDirPath.isNotEmpty &&
            entry.typeTag?.isNotEmpty == true) {
          return entry;
        }
      }
    } catch (_) {}
    return null;
  }
}

class _AudioCompletedGateSnapshot {
  const _AudioCompletedGateSnapshot({
    required this.token,
    required this.player,
    required this.oid,
    required this.subId,
    required this.index,
    required this.itemIdentity,
    required this.switchGeneration,
    required this.submitPosition,
    required this.submitDuration,
  });

  final int token;
  final Player player;
  final Int64 oid;
  final int subId;
  final int? index;
  final Object? itemIdentity;
  final int switchGeneration;
  final Duration submitPosition;
  final Duration submitDuration;

  Map<String, dynamic> debugExtra(AudioController controller) => {
    'token': token,
    'oid': oid.toString(),
    'subId': subId,
    'index': index,
    'generation': switchGeneration,
    'currentGeneration': controller._switchGeneration,
    'currentOid': controller.oid.toString(),
    'currentSubId': controller._currentSubId,
    'submitPosition': submitPosition.inMilliseconds,
    'submitDuration': submitDuration.inMilliseconds,
    'submitRemaining': (submitDuration - submitPosition).inMilliseconds,
    'switching': controller._isSwitchingAudio,
  };
}

class _CompletedAudioSwitchMarker {
  const _CompletedAudioSwitchMarker({
    required this.oid,
    required this.subId,
    required this.switchGeneration,
  });

  final Int64 oid;
  final int subId;
  final int switchGeneration;
}

extension on DashItem {
  Iterable<String> get playUrls sync* {
    yield baseUrl;
    yield* backupUrl;
  }
}

extension on ResponseUrl {
  Iterable<String> get playUrls sync* {
    yield url;
    yield* backupUrl;
  }
}
