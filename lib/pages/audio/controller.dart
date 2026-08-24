import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/common/widgets/dialog/simple_dialog_option.dart';
import 'package:PiliPlus/grpc/audio.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pb.dart'
    show
        DetailItem,
        PlaylistResp,
        PlayURLResp,
        PlayItem,
        PlaylistSource,
        PlayInfo,
        ThumbUpReq_ThumbType,
        ListOrder,
        DashItem,
        ResponseUrl;
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart'
    show FavMixin, IntroAction;
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
import 'package:PiliPlus/services/playback/completed_gate.dart';
import 'package:PiliPlus/services/playback/playback_foreground_service.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/connectivity_utils.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/loading_action_mixin.dart';
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
import 'package:flutter/scheduler.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as path;

class _CompletedPlaybackIdentity {
  const _CompletedPlaybackIdentity({
    required this.player,
    required this.oid,
    required this.subId,
    required this.index,
    required this.item,
    required this.switchGeneration,
  });

  final Player player;
  final int oid;
  final Int64? subId;
  final int? index;
  final DetailItem? item;
  final int switchGeneration;
}

class _AutoTailSkipCandidate {
  const _AutoTailSkipCandidate({
    required this.identity,
    required this.gateGeneration,
    required this.target,
    required this.duration,
    required this.remaining,
  });

  final _CompletedPlaybackIdentity identity;
  final int gateGeneration;
  final Duration target;
  final Duration duration;
  final Duration remaining;
}

class AudioController extends GetxController
    with
        GetTickerProviderStateMixin,
        LoadingActionMixin<IntroAction>,
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
  final Rx<Duration> position = Rx(Duration.zero);
  final Rx<Duration> duration = Rx(Duration.zero);

  late final AnimationController animController;

  List<StreamSubscription>? _subscriptions;

  int? index;
  List<DetailItem>? playlist;
  final Map<String, int> _partProgress = {};
  final Map<String, int> _initialPlaylistProgress = {};
  // lastProgress 先按稿件缓存；playInfo 解析出真实分P后再绑定到 cid。
  final Map<String, int> _playlistItemHistoryProgress = {};
  final Map<String, int> _playlistHistoryProgress = {};

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
  static const _switchProtectionWarmupThreshold = Duration(seconds: 6);
  int _switchGeneration = 0;
  int _switchProtectionToken = 0;
  bool _pendingSwitchProtection = false;
  bool _switchProtectionWarmupStarted = false;
  bool _audioSwitchOpenReady = false;
  int? _audioSwitchZeroPositionGuardGeneration;
  bool _isInBackground = false;
  bool _isSwitchingAudio = false;
  // Completed gate keeps raw media_kit completed/playing=false signals from
  // publishing completed or switching items before the visible tail finishes.
  final CompletedGateScheduler _completedGateScheduler =
      CompletedGateScheduler();
  Timer? _pendingNearTailPauseTimer;
  int _completedGateGeneration = 0;
  bool _pendingCompleted = false;
  _AutoTailSkipCandidate? _autoTailSkipCandidate;
  _CompletedPlaybackIdentity? _consumedCompletedIdentity;
  bool _manualPausePending = false;
  int _heartDuration = 0;
  bool _completedHeartBeatSynced = false;
  bool get _isAppInForeground =>
      SchedulerBinding.instance.lifecycleState == AppLifecycleState.resumed;

  bool get isSwitchingAudio => _isSwitchingAudio;

  bool get _hasVideoDetailController => _videoDetailController != null;

  bool get _shouldSyncVideoDetailMetadata => _hasVideoDetailController;

  bool get _shouldSyncVideoDetailSideEffects =>
      _hasVideoDetailController && _isAppInForeground;

  int get _currentSubId => (subId.firstOrNull ?? oid).toInt();

  String _progressKey(int aid, int subId) => '$aid:$subId';

  Duration get syncPosition {
    final currentPlayer = player;
    if (currentPlayer != null) {
      final rawPosition = _rawAudioPosition(currentPlayer);
      if (rawPosition > Duration.zero) {
        return rawPosition;
      }
    }
    if (_start case final start? when start > Duration.zero) {
      return start;
    }
    return position.value;
  }

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
    _initPlaylistProgressSnapshot(args['playlistProgress']);
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
    _cancelPendingCompleted(reason: 'play');
    return player?.play();
  }

  Future<void>? onPause() {
    _cancelPendingCompleted(reason: 'pause', clearConsumed: false);
    _manualPausePending = true;
    final currentPlayer = player;
    if (currentPlayer == null) {
      _manualPausePending = false;
      return null;
    }
    return currentPlayer.pause();
  }

  Future<void>? onSeek(Duration duration) {
    return _seekToAudio(duration);
  }

  Future<void>? _seekToAudio(
    Duration duration, {
    BlockSkipSource skipSource = BlockSkipSource.manual,
  }) {
    _audioSwitchZeroPositionGuardGeneration = null;
    _cancelPendingCompleted(reason: 'seek');
    _heartDuration = duration.inSeconds;
    _completedHeartBeatSynced = false;
    if (_pendingSwitchProtection && !_isSwitchingAudio) {
      unawaited(_finishSwitchProtection(success: false, reason: 'seek'));
    }
    if (skipSource == BlockSkipSource.automatic) {
      _recordAutoTailSkipCandidate(duration);
    }
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

  _CompletedPlaybackIdentity? _currentCompletedPlaybackIdentity([
    Player? currentPlayer,
  ]) {
    final resolvedPlayer = currentPlayer ?? player;
    if (resolvedPlayer == null) {
      return null;
    }
    return _CompletedPlaybackIdentity(
      player: resolvedPlayer,
      oid: oid.toInt(),
      subId: subId.firstOrNull,
      index: index,
      item: audioItem.value,
      switchGeneration: _switchGeneration,
    );
  }

  Map<String, dynamic> _identityExtra(_CompletedPlaybackIdentity identity) => {
    'oid': identity.oid,
    'subId': identity.subId?.toString(),
    'index': identity.index,
    'switchGeneration': identity.switchGeneration,
  };

  void _cancelCompletedGate({
    required String reason,
    bool advanceGeneration = true,
  }) {
    if (advanceGeneration) {
      _completedGateGeneration += 1;
    }
    _pendingCompleted = false;
    final hadPending = _completedGateScheduler.cancel();
    final hadPendingPause = _pendingNearTailPauseTimer != null;
    _pendingNearTailPauseTimer?.cancel();
    _pendingNearTailPauseTimer = null;
    if (hadPending ||
        hadPendingPause ||
        (reason != 'seek' && reason != 'playing')) {
      DebugLogService.log(
        'audio.completed',
        'cancel pending completed',
        extra: {
          'reason': reason,
          'advanceGeneration': advanceGeneration,
          'oid': oid.toString(),
          'subId': subId.firstOrNull?.toString(),
        },
      );
    }
  }

  void _cancelPendingCompleted({
    required String reason,
    bool clearConsumed = true,
  }) {
    _cancelCompletedGate(reason: reason);
    _clearAutoTailSkipCandidate(reason: reason);
    if (clearConsumed) {
      _clearConsumedCompletedIdentity(reason: reason);
    }
  }

  void _clearAutoTailSkipCandidate({required String reason}) {
    final candidate = _autoTailSkipCandidate;
    if (candidate == null) {
      return;
    }
    _autoTailSkipCandidate = null;
    DebugLogService.log(
      'audio.completed',
      'clear auto tail skip candidate',
      extra: {
        'reason': reason,
        ..._identityExtra(candidate.identity),
        'targetMs': candidate.target.inMilliseconds,
        'remainingMs': candidate.remaining.inMilliseconds,
      },
    );
  }

  void _clearConsumedCompletedIdentity({required String reason}) {
    final identity = _consumedCompletedIdentity;
    if (identity == null) {
      return;
    }
    _consumedCompletedIdentity = null;
    DebugLogService.log(
      'audio.completed',
      'clear consumed completed marker',
      extra: {
        'reason': reason,
        ..._identityExtra(identity),
      },
    );
  }

  void _markCompletedConsumed(
    _CompletedPlaybackIdentity identity, {
    required String source,
  }) {
    _consumedCompletedIdentity = identity;
    DebugLogService.log(
      'audio.completed',
      'mark completed consumed',
      extra: {
        'source': source,
        ..._identityExtra(identity),
      },
    );
  }

  bool _isSamePlaybackIdentity({
    required Player currentPlayer,
    required _CompletedPlaybackIdentity identity,
  }) {
    return !isClosed &&
        !_isSwitchingAudio &&
        identity.switchGeneration == _switchGeneration &&
        identical(player, currentPlayer) &&
        identical(identity.player, currentPlayer) &&
        oid.toInt() == identity.oid &&
        subId.firstOrNull == identity.subId &&
        index == identity.index &&
        identical(audioItem.value, identity.item);
  }

  bool _isSameCompletedPlayback({
    required Player currentPlayer,
    required _CompletedPlaybackIdentity identity,
  }) {
    return _isSamePlaybackIdentity(
          currentPlayer: currentPlayer,
          identity: identity,
        ) &&
        currentPlayer.state.completed;
  }

  bool _isConsumedCompletedPlayback(Player currentPlayer) {
    final identity = _consumedCompletedIdentity;
    return identity != null &&
        _isSamePlaybackIdentity(
          currentPlayer: currentPlayer,
          identity: identity,
        );
  }

  bool _isSameAutoTailSkipCandidate({
    required _AutoTailSkipCandidate candidate,
    required Player currentPlayer,
  }) {
    return _isSamePlaybackIdentity(
      currentPlayer: currentPlayer,
      identity: candidate.identity,
    );
  }

  void _recordAutoTailSkipCandidate(Duration target) {
    final currentPlayer = player;
    final identity = _currentCompletedPlaybackIdentity(currentPlayer);
    if (currentPlayer == null || identity == null) {
      return;
    }

    final total = _rawAudioDuration(currentPlayer);
    final remaining = CompletedGate.remaining(total: total, position: target);
    if (remaining == null) {
      DebugLogService.log(
        'audio.completed',
        'skip auto tail candidate',
        extra: {
          ..._identityExtra(identity),
          'targetMs': target.inMilliseconds,
          'durationMs': total.inMilliseconds,
        },
      );
      return;
    }

    _autoTailSkipCandidate = _AutoTailSkipCandidate(
      identity: identity,
      gateGeneration: _completedGateGeneration,
      target: target,
      duration: total,
      remaining: remaining,
    );
    DebugLogService.log(
      'audio.completed',
      'record auto tail skip candidate',
      extra: {
        ..._identityExtra(identity),
        'gateGeneration': _completedGateGeneration,
        'targetMs': target.inMilliseconds,
        'durationMs': total.inMilliseconds,
        'remainingMs': remaining.inMilliseconds,
      },
    );
  }

  bool _isValidAutoTailSkipCandidate({
    required _AutoTailSkipCandidate candidate,
    required Player currentPlayer,
  }) {
    return candidate.gateGeneration == _completedGateGeneration &&
        _isSameAutoTailSkipCandidate(
          candidate: candidate,
          currentPlayer: currentPlayer,
        ) &&
        _completedRemaining(currentPlayer) != null;
  }

  Duration _rawAudioPosition(Player currentPlayer) {
    final statePosition = currentPlayer.state.position;
    return statePosition > Duration.zero ? statePosition : position.value;
  }

  Duration _rawAudioDuration(Player currentPlayer) {
    final stateDuration = currentPlayer.state.duration;
    return stateDuration > Duration.zero ? stateDuration : duration.value;
  }

  Duration? _completedRemaining(Player currentPlayer) {
    final stateDuration = _rawAudioDuration(currentPlayer);
    final stateRemaining = CompletedGate.remaining(
      total: stateDuration,
      position: currentPlayer.state.position,
    );
    final visibleRemaining = CompletedGate.remaining(
      total: stateDuration,
      position: position.value,
      // Audio UI only publishes position when the displayed second changes.
      // Allow that sub-second display lag to make the gate conservative.
      maxAllowed: CompletedGate.maxRemaining + const Duration(seconds: 1),
    );
    return CompletedGate.longer(stateRemaining, visibleRemaining);
  }

  void _publishPlaybackStatus(PlayerStatus status) {
    if (status.isPlaying) {
      animController.forward();
    } else {
      animController.reverse();
    }
    videoPlayerServiceHandler?.onStatusChange(status, false, false);
  }

  bool get _enableHeartBeat => Accounts.heartbeat.isLogin && !Pref.historyPause;

  bool _canReportHeartBeat(int reportItemType) =>
      reportItemType == 1 && _enableHeartBeat;

  void _unawaitedHeartBeat(Future<void>? future) {
    if (future != null) {
      unawaited(future);
    }
  }

  Future<void>? _sendHeartBeat({
    required int aid,
    required int cid,
    required int reportItemType,
    required int progress,
  }) {
    if (!_canReportHeartBeat(reportItemType) || progress == 0) {
      return null;
    }

    // Keep the same request surface as the normal video player heartbeat.
    return VideoHttp.heartBeat(
      bvid: IdUtils.av2bv(aid),
      cid: cid,
      progress: progress,
      videoType: VideoType.ugc,
    );
  }

  void _resetHeartBeatProgress() {
    _heartDuration = 0;
    _completedHeartBeatSynced = false;
  }

  Future<void>? _reportPlayingHeartBeat(Duration currentPosition) {
    final currentPlayer = player;
    if (_isSwitchingAudio ||
        _pendingCompleted ||
        currentPlayer?.state.playing != true) {
      return null;
    }

    final progress = currentPosition.inSeconds;
    if (progress <= 0 || progress - _heartDuration < 5) {
      return null;
    }
    _heartDuration = progress;
    return _sendHeartBeat(
      aid: oid.toInt(),
      cid: _currentSubId,
      reportItemType: itemType,
      progress: progress,
    );
  }

  Future<void>? _reportStatusHeartBeat({
    bool allowPendingCompleted = false,
    bool force = false,
  }) {
    if (_isSwitchingAudio || (!allowPendingCompleted && _pendingCompleted)) {
      return null;
    }

    final currentPlayer = player;
    if (currentPlayer == null) {
      return null;
    }
    final currentPosition = _rawAudioPosition(currentPlayer);
    final progress = currentPosition.inSeconds;
    if (progress <= 0 || (!force && progress - _heartDuration < 2)) {
      return null;
    }
    _heartDuration = progress;
    return _sendHeartBeat(
      aid: oid.toInt(),
      cid: _currentSubId,
      reportItemType: itemType,
      progress: progress,
    );
  }

  Future<void>? _reportCompletedHeartBeat() {
    if (_completedHeartBeatSynced) {
      return null;
    }
    _completedHeartBeatSynced = true;
    return _sendHeartBeat(
      aid: oid.toInt(),
      cid: _currentSubId,
      reportItemType: itemType,
      progress: -1,
    );
  }

  void _syncCompletedPlaybackPosition(Player currentPlayer) {
    final completedDuration = _rawAudioDuration(currentPlayer);
    if (completedDuration <= Duration.zero) {
      return;
    }

    // Publish the final position before completed so downstream switch logic
    // observes a playback that has reached its real duration.
    duration.value = completedDuration;
    position.value = completedDuration;
    if (_shouldSyncVideoDetailMetadata) {
      _videoDetailController?.playedTime = completedDuration;
    }
    videoPlayerServiceHandler?.onPositionChange(completedDuration);
  }

  void _scheduleAutoTailSkipCompleted({
    required _AutoTailSkipCandidate candidate,
    required Duration remaining,
  }) {
    final identity = candidate.identity;
    _pendingNearTailPauseTimer?.cancel();
    _pendingNearTailPauseTimer = null;
    _pendingCompleted = true;
    final completedGateGeneration = ++_completedGateGeneration;
    _autoTailSkipCandidate = _AutoTailSkipCandidate(
      identity: identity,
      gateGeneration: completedGateGeneration,
      target: candidate.target,
      duration: candidate.duration,
      remaining: candidate.remaining,
    );
    final tailDelay = CompletedGate.isReady(remaining)
        ? Duration.zero
        : CompletedGate.tailPlaybackWait(remaining, playbackRate: speed);
    if (_isInBackground && _hasNextSwitchTarget) {
      unawaited(
        _ensureSwitchProtection(
          reason: 'completed_gate',
          text: '正在准备下一条音频…',
        ),
      );
    }
    DebugLogService.log(
      'audio.completed',
      'schedule auto tail skip completed gate',
      extra: {
        ..._identityExtra(identity),
        'delayMs': tailDelay.inMilliseconds,
        'remainingMs': remaining.inMilliseconds,
        'candidateRemainingMs': candidate.remaining.inMilliseconds,
        'targetMs': candidate.target.inMilliseconds,
        'durationMs': candidate.duration.inMilliseconds,
        'gateGeneration': completedGateGeneration,
      },
    );

    bool isSamePlayback(Player? currentPlayer) =>
        completedGateGeneration == _completedGateGeneration &&
        currentPlayer != null &&
        _isSamePlaybackIdentity(
          currentPlayer: currentPlayer,
          identity: identity,
        ) &&
        _completedRemaining(currentPlayer) != null;

    _completedGateScheduler.schedule(tailDelay, () {
      final currentPlayer = player;
      if (!isSamePlayback(currentPlayer)) {
        return;
      }

      _syncCompletedPlaybackPosition(currentPlayer!);
      DebugLogService.log(
        'audio.completed',
        'settle auto tail skip completed position',
        extra: {
          ..._identityExtra(identity),
          'gateGeneration': completedGateGeneration,
        },
      );
      _completedGateScheduler.schedule(CompletedGate.buffer, () {
        final currentPlayer = player;
        if (!isSamePlayback(currentPlayer)) {
          return;
        }

        _pendingCompleted = false;
        _clearAutoTailSkipCandidate(reason: 'auto_tail_skip_consumed');
        _markCompletedConsumed(identity, source: 'auto_tail_skip');
        _consumePlaybackCompleted();
      });
    });
  }

  void _handlePlayingChanged(bool playing) {
    if (playing) {
      _manualPausePending = false;
      _cancelCompletedGate(reason: 'playing', advanceGeneration: false);
      _publishPlaybackStatus(PlayerStatus.playing);
      _unawaitedHeartBeat(_reportStatusHeartBeat());
      if (_pendingSwitchProtection) {
        unawaited(
          _finishSwitchProtection(
            success: true,
            reason: 'playback_started',
          ),
        );
      }
      return;
    }

    final isManualPause = _manualPausePending;
    _manualPausePending = false;
    final currentPlayer = player;
    final remaining = currentPlayer == null
        ? null
        : _completedRemaining(currentPlayer);
    final candidate = _autoTailSkipCandidate;
    if (candidate != null) {
      if (currentPlayer == null ||
          !_isSameAutoTailSkipCandidate(
            candidate: candidate,
            currentPlayer: currentPlayer,
          )) {
        _clearAutoTailSkipCandidate(reason: 'auto_tail_candidate_invalid');
      } else if (!isManualPause && !_isSwitchingAudio && remaining != null) {
        if (_isValidAutoTailSkipCandidate(
          candidate: candidate,
          currentPlayer: currentPlayer,
        )) {
          _scheduleAutoTailSkipCompleted(
            candidate: candidate,
            remaining: remaining,
          );
          return;
        }
        _clearAutoTailSkipCandidate(reason: 'auto_tail_candidate_stale');
      } else if (!isManualPause && !_isSwitchingAudio) {
        DebugLogService.log(
          'audio.completed',
          'keep auto tail skip candidate',
          extra: {
            'reason': 'playing_false_not_near_tail',
            ..._identityExtra(candidate.identity),
            'targetMs': candidate.target.inMilliseconds,
            'remainingMs': candidate.remaining.inMilliseconds,
            'positionMs': currentPlayer.state.position.inMilliseconds,
            'durationMs': _rawAudioDuration(currentPlayer).inMilliseconds,
            'gateGeneration': _completedGateGeneration,
            'candidateGateGeneration': candidate.gateGeneration,
          },
        );
      }
    }
    if (!isManualPause && !_isSwitchingAudio && remaining != null) {
      // Near the tail media_kit can flip playing=false before the final second
      // is visible. Hold the paused status unless completed is canceled.
      final generation = _completedGateGeneration;
      _pendingNearTailPauseTimer?.cancel();
      _pendingNearTailPauseTimer = Timer(
        CompletedGate.tailWait(remaining, playbackRate: speed),
        () {
          if (generation != _completedGateGeneration || _pendingCompleted) {
            return;
          }
          _publishPlaybackStatus(PlayerStatus.paused);
          _unawaitedHeartBeat(_reportStatusHeartBeat());
        },
      );
      DebugLogService.log(
        'audio.completed',
        'hold near-tail pause',
        extra: {
          'oid': oid.toString(),
          'subId': subId.firstOrNull?.toString(),
          'remainingMs': remaining.inMilliseconds,
        },
      );
      return;
    }

    _publishPlaybackStatus(PlayerStatus.paused);
    _unawaitedHeartBeat(_reportStatusHeartBeat());
  }

  int _beginSwitch() {
    _cancelPendingCompleted(reason: 'switch');
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

  void _armAudioSwitchZeroPositionGuard(int generation) {
    _audioSwitchZeroPositionGuardGeneration = generation;
    Future.delayed(const Duration(milliseconds: 500), () {
      if (_audioSwitchZeroPositionGuardGeneration == generation) {
        _audioSwitchZeroPositionGuardGeneration = null;
      }
    });
  }

  bool _shouldIgnoreAudioSwitchZeroPosition(Duration position) {
    return position == Duration.zero &&
        this.position.value > Duration.zero &&
        _audioSwitchZeroPositionGuardGeneration == _switchGeneration;
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
    _audioSwitchZeroPositionGuardGeneration = null;
    _resetHeartBeatProgress();
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
    final protectionToken = ++_switchProtectionToken;
    _pendingSwitchProtection = true;
    await PlaybackForegroundService.start(
      title: 'PiliPlus 后台播放',
      text: text ?? '正在准备下一条音频…',
    );
    if (protectionToken != _switchProtectionToken) {
      if (!_pendingSwitchProtection && PlaybackForegroundService.isRunning) {
        await PlaybackForegroundService.stop();
      }
      return;
    }
    if (!_pendingSwitchProtection || !_isInBackground) {
      _pendingSwitchProtection = false;
      _switchProtectionWarmupStarted = false;
      if (PlaybackForegroundService.isRunning) {
        await PlaybackForegroundService.stop();
      }
      return;
    }
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
    _switchProtectionToken += 1;
    _pendingSwitchProtection = false;
    _switchProtectionWarmupStarted = false;
    if (PlaybackForegroundService.isRunning) {
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

  String _playlistHistoryKey(int itemType, int aid, int cid) =>
      '$itemType:$aid:$cid';

  String _playlistItemHistoryKey(int itemType, int aid) => '$itemType:$aid';

  int? _readInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return null;
  }

  void _initPlaylistProgressSnapshot(dynamic raw) {
    if (raw is! Iterable) {
      return;
    }

    for (final item in raw) {
      if (item is! Map) {
        continue;
      }
      final aid = _readInt(item['aid']);
      final cid = _readInt(item['cid']);
      final progress = _readInt(item['progress']);
      if (aid == null ||
          aid <= 0 ||
          cid == null ||
          cid <= 0 ||
          progress == null ||
          progress <= 0) {
        continue;
      }
      _initialPlaylistProgress[_progressKey(aid, cid)] = progress;
    }

    if (_initialPlaylistProgress.isNotEmpty) {
      DebugLogService.log(
        'audio.progress',
        'init playlist progress snapshot',
        extra: {
          'count': _initialPlaylistProgress.length,
        },
      );
    }
  }

  List<int> _detailItemSubIds(DetailItem item) {
    final result = <int>[];
    for (final subId in item.item.subId) {
      final value = subId.toInt();
      if (value > 0 && !result.contains(value)) {
        result.add(value);
      }
    }
    for (final part in item.parts) {
      final value = part.subId.toInt();
      if (value > 0 && !result.contains(value)) {
        result.add(value);
      }
    }
    return result;
  }

  bool _detailItemContainsSubId(DetailItem item, int cid) =>
      _detailItemSubIds(item).contains(cid);

  // 跨稿件列表跳转要恢复历史分P；同稿件切P仍由 _playNextPartInternal 明确指定目标。
  bool _shouldRestoreHistoryPartForPlaylistSwitch({
    required Int64 previousOid,
    required DetailItem targetItem,
    required List<Int64>? requestedSubId,
  }) =>
      requestedSubId == null &&
      isUgc &&
      targetItem.item.oid != previousOid &&
      targetItem.parts.length > 1;

  List<int> _playItemSubIds(PlayItem item, List<DetailItem> list) {
    final result = <int>[];
    for (final subId in item.subId) {
      final value = subId.toInt();
      if (value > 0 && !result.contains(value)) {
        result.add(value);
      }
    }
    if (result.isNotEmpty) {
      return result;
    }

    final matched = list.firstWhereOrNull(
      (e) =>
          e.item.oid == item.oid &&
          (!item.hasItemType() || e.item.itemType == item.itemType),
    );
    if (matched == null) {
      return result;
    }
    if (matched.lastPart > 0) {
      return [matched.lastPart.toInt()];
    }
    final matchedSubIds = _detailItemSubIds(matched);
    return matchedSubIds.length == 1 ? matchedSubIds : result;
  }

  // playInfo 只返回历史 cid，进度仍来自播放列表的 lastProgress/DetailItem。
  void _cacheDetailProgressForResolvedHistoryPart(
    DetailItem item,
    int aid,
    int cid,
  ) {
    final itemHistoryProgress =
        _playlistItemHistoryProgress[_playlistItemHistoryKey(
          item.item.itemType,
          aid,
        )];
    final durationSeconds = _detailItemDurationSeconds(item, cid);
    final detailProgress = _normalizeProgressSeconds(
      item.progress.toInt(),
      durationSeconds: durationSeconds,
    );
    final fallbackProgress = detailProgress > 0
        ? detailProgress
        : _normalizeProgressSeconds(
            item.lastPlayTime.toInt(),
            durationSeconds: durationSeconds,
          );
    final progress = itemHistoryProgress != null && itemHistoryProgress > 0
        ? itemHistoryProgress
        : fallbackProgress;
    if (progress <= 0) {
      return;
    }
    _playlistHistoryProgress[_playlistHistoryKey(
          item.item.itemType,
          aid,
          cid,
        )] =
        progress;
  }

  Future<Int64?> _resolvePlayInfoHistorySubId(
    DetailItem audioItem,
    PlayItem item,
    Int64 fallbackSubId, {
    required bool Function() isCurrent,
  }) async {
    final aid = item.oid.toInt();
    final fallbackCid = fallbackSubId.toInt();
    if (aid <= 0 ||
        fallbackCid <= 0 ||
        !_detailItemContainsSubId(audioItem, fallbackCid)) {
      return null;
    }

    try {
      final res = await VideoHttp.playInfo(
        bvid: IdUtils.av2bv(aid),
        cid: fallbackCid,
      );
      if (!isCurrent()) {
        return null;
      }
      if (res case Success(:final response)) {
        final lastPlayCid = response.lastPlayCid;
        if (lastPlayCid != null &&
            lastPlayCid > 0 &&
            _detailItemContainsSubId(audioItem, lastPlayCid)) {
          _cacheDetailProgressForResolvedHistoryPart(
            audioItem,
            aid,
            lastPlayCid,
          );
          return Int64(lastPlayCid);
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('resolve audio history cid failed: $e');
      }
    }
    return null;
  }

  Future<List<Int64>> _defaultSubIdsForPlaylistItem(
    DetailItem audioItem,
    PlayItem item,
    List<Int64>? requestedSubId, {
    required bool preferHistoryPart,
    required bool Function() isCurrent,
  }) async {
    // 调用方显式指定分 P 时优先使用，避免历史分 P 覆盖上一首/下一首等确定性跳转。
    if (requestedSubId != null) {
      return requestedSubId;
    }

    final parts = audioItem.parts;
    final fallbackSubId = item.subId.firstOrNull ?? parts.first.subId;
    // 显式进入条目和跨稿件列表跳转恢复历史分P；同稿件切P不走这里的历史覆盖。
    if (preferHistoryPart && isUgc && parts.length > 1) {
      final playInfoSubId = await _resolvePlayInfoHistorySubId(
        audioItem,
        item,
        fallbackSubId,
        isCurrent: isCurrent,
      );
      if (playInfoSubId != null) {
        return [playInfoSubId];
      }

      final lastPart = audioItem.lastPart;
      if (lastPart > 0 && parts.any((part) => part.subId == lastPart)) {
        return [lastPart];
      }
    }

    return item.subId.isNotEmpty ? item.subId : [fallbackSubId];
  }

  int _normalizeProgressSeconds(
    int progress, {
    required int durationSeconds,
  }) {
    if (progress <= 0) {
      return 0;
    }
    if (durationSeconds > 0 &&
        progress > durationSeconds + 30 &&
        progress ~/ 1000 <= durationSeconds + 30) {
      return progress ~/ 1000;
    }
    if (durationSeconds <= 0 && progress > 12 * 60 * 60) {
      return progress ~/ 1000;
    }
    return progress;
  }

  int _detailItemDurationSeconds(DetailItem item, int cid) {
    final part = item.parts.firstWhereOrNull((e) => e.subId.toInt() == cid);
    if (part != null && part.duration > 0) {
      return part.duration.toInt();
    }
    return item.arc.duration.toInt();
  }

  int _detailProgressSeconds(DetailItem item, int cid) {
    if (!_isSinglePart(item) && item.lastPart.toInt() != cid) {
      return 0;
    }

    final durationSeconds = _detailItemDurationSeconds(item, cid);
    final progress = _normalizeProgressSeconds(
      item.progress.toInt(),
      durationSeconds: durationSeconds,
    );
    if (progress > 0) {
      return progress;
    }
    return _normalizeProgressSeconds(
      item.lastPlayTime.toInt(),
      durationSeconds: durationSeconds,
    );
  }

  void _recordPlaylistHistoryProgress(PlaylistResp response) {
    if (!response.hasLastPlay() || !response.hasLastProgress()) {
      return;
    }

    final lastPlay = response.lastPlay;
    final aid = lastPlay.oid.toInt();
    if (aid <= 0) {
      return;
    }

    final itemType = lastPlay.hasItemType() ? lastPlay.itemType : this.itemType;
    final matchedItem = response.list.firstWhereOrNull(
      (e) =>
          e.item.oid == lastPlay.oid &&
          (!lastPlay.hasItemType() || e.item.itemType == lastPlay.itemType),
    );
    final itemProgress = _normalizeProgressSeconds(
      response.lastProgress.toInt(),
      durationSeconds: matchedItem?.arc.duration.toInt() ?? 0,
    );
    if (itemProgress > 0) {
      _playlistItemHistoryProgress[_playlistItemHistoryKey(itemType, aid)] =
          itemProgress;
    }

    final subIds = _playItemSubIds(lastPlay, response.list);
    if (subIds.isEmpty) {
      return;
    }

    for (final cid in subIds) {
      final matched = response.list.firstWhereOrNull(
        (e) => e.item.oid == lastPlay.oid && _detailItemSubIds(e).contains(cid),
      );
      final durationSeconds = matched == null
          ? 0
          : _detailItemDurationSeconds(matched, cid);
      final progress = _normalizeProgressSeconds(
        response.lastProgress.toInt(),
        durationSeconds: durationSeconds,
      );
      if (progress <= 0) {
        continue;
      }
      _playlistHistoryProgress[_playlistHistoryKey(itemType, aid, cid)] =
          progress;
      DebugLogService.log(
        'audio.progress',
        'record playlist history progress',
        extra: {
          'oid': aid,
          'subId': cid,
          'itemType': itemType,
          'progress': progress,
        },
      );
    }
  }

  ({int seconds, String source}) _resolvePlaylistItemProgress(
    DetailItem audioItem,
    int aid,
    int cid,
  ) {
    final progressKey = _progressKey(aid, cid);
    final savedPartProgress = _partProgress[progressKey];
    if (_partProgress.containsKey(progressKey)) {
      return savedPartProgress != null && savedPartProgress > 0
          ? (seconds: savedPartProgress, source: 'partProgress')
          : (seconds: 0, source: 'completed');
    }

    final mediaListProgress = _getProgressFromMediaList(aid, cid);
    if (mediaListProgress > 0) {
      return (seconds: mediaListProgress, source: 'mediaList');
    }

    final initialPlaylistProgress = _initialPlaylistProgress[progressKey];
    if (_initialPlaylistProgress.containsKey(progressKey) &&
        initialPlaylistProgress != null &&
        initialPlaylistProgress <= 0) {
      return (seconds: 0, source: 'completed');
    }
    if (initialPlaylistProgress != null && initialPlaylistProgress > 0) {
      return (seconds: initialPlaylistProgress, source: 'playlistSnapshot');
    }

    final detailProgress = _detailProgressSeconds(audioItem, cid);
    if (detailProgress > 0) {
      return (seconds: detailProgress, source: 'detail');
    }

    final playlistHistoryProgress =
        _playlistHistoryProgress[_playlistHistoryKey(
          audioItem.item.itemType,
          aid,
          cid,
        )];
    if (playlistHistoryProgress != null && playlistHistoryProgress > 0) {
      return (seconds: playlistHistoryProgress, source: 'playlistHistory');
    }

    return (seconds: 0, source: 'none');
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
      _recordPlaylistHistoryProgress(response);
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
      onNext: hasMultiItems ? () => playNext(nextPart: true) : null,
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
        _audioSwitchOpenReady = true;
        final currentPlayer = player!;
        final statePosition = _rawAudioPosition(currentPlayer);
        final stateDuration = _rawAudioDuration(currentPlayer);
        if (stateDuration > Duration.zero) {
          duration.value = stateDuration;
        }
        if (_start case final start? when start > Duration.zero) {
          position.value = start;
          _armAudioSwitchZeroPositionGuard(openGeneration);
        } else if (statePosition > Duration.zero) {
          position.value = statePosition;
          _armAudioSwitchZeroPositionGuard(openGeneration);
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
        if (_shouldIgnoreAudioSwitchZeroPosition(position)) return;
        if (position > Duration.zero) {
          _audioSwitchZeroPositionGuardGeneration = null;
        }
        final shouldUpdatePosition =
            position.inSeconds != this.position.value.inSeconds ||
            (this.position.value == Duration.zero && position > Duration.zero);
        if (shouldUpdatePosition) {
          this.position.value = position;
          if (_shouldSyncVideoDetailMetadata) {
            _videoDetailController?.playedTime = position;
          }
          videoPlayerServiceHandler?.onPositionChange(position);
          _unawaitedHeartBeat(_reportPlayingHeartBeat(position));
        }
        _settleAudioSwitchingOnValidState(position: position);
        _maybeStartSwitchProtectionWarmup(position);
      }),
      stream.duration.listen((duration) {
        if (_isSwitchingAudio && !_audioSwitchOpenReady) return;
        this.duration.value = duration;
        _settleAudioSwitchingOnValidState(duration: duration);
      }),
      stream.playing.listen(_handlePlayingChanged),
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
    final currentPlayer = player;
    if (currentPlayer == null) {
      return;
    }
    if (_isConsumedCompletedPlayback(currentPlayer)) {
      DebugLogService.log(
        'audio.completed',
        'drop consumed completed signal',
        extra: {
          'oid': oid.toString(),
          'subId': subId.firstOrNull?.toString(),
        },
      );
      return;
    }

    final stateDuration = _rawAudioDuration(currentPlayer);
    final stateRemaining = CompletedGate.remaining(
      total: stateDuration,
      position: currentPlayer.state.position,
    );
    final visibleRemaining = CompletedGate.remaining(
      total: stateDuration,
      position: position.value,
      maxAllowed: CompletedGate.maxRemaining + const Duration(seconds: 1),
    );
    final remaining = CompletedGate.longer(stateRemaining, visibleRemaining);
    if (remaining == null) {
      DebugLogService.log(
        'audio.completed',
        'drop completed candidate',
        extra: {
          'oid': oid.toString(),
          'subId': subId.firstOrNull?.toString(),
          'statePosition': currentPlayer.state.position.inMilliseconds,
          'visiblePosition': position.value.inMilliseconds,
          'duration': stateDuration.inMilliseconds,
        },
      );
      return;
    }

    final completedIdentity = _currentCompletedPlaybackIdentity(currentPlayer);
    if (completedIdentity == null) {
      return;
    }
    _clearAutoTailSkipCandidate(reason: 'completed_signal');

    // 即使 remaining 为 0，也统一进入调度器，确保回调前还能校验播放身份和切换代次。
    _pendingNearTailPauseTimer?.cancel();
    _pendingNearTailPauseTimer = null;
    _pendingCompleted = true;
    final completedGateGeneration = ++_completedGateGeneration;
    final tailDelay = CompletedGate.isReady(remaining)
        ? Duration.zero
        : CompletedGate.tailPlaybackWait(remaining, playbackRate: speed);
    if (_isInBackground && _hasNextSwitchTarget) {
      unawaited(
        _ensureSwitchProtection(
          reason: 'completed_gate',
          text: '正在准备下一条音频…',
        ),
      );
    }
    DebugLogService.log(
      'audio.completed',
      'schedule completed gate',
      extra: {
        'oid': oid.toString(),
        'subId': subId.firstOrNull?.toString(),
        'delayMs': tailDelay.inMilliseconds,
        'remainingMs': remaining.inMilliseconds,
        'stateRemainingMs': stateRemaining?.inMilliseconds,
        'visibleRemainingMs': visibleRemaining?.inMilliseconds,
        'gateGeneration': completedGateGeneration,
        'switchGeneration': completedIdentity.switchGeneration,
        'playMode': playMode.value.name,
      },
    );

    bool isSameCompletedPlayback(Player? currentPlayer) =>
        // The delayed callback must still belong to the same audio item and
        // the same completed signal; otherwise a seek or switch already won.
        completedGateGeneration == _completedGateGeneration &&
        currentPlayer != null &&
        _isSameCompletedPlayback(
          currentPlayer: currentPlayer,
          identity: completedIdentity,
        ) &&
        _completedRemaining(currentPlayer) != null;

    _completedGateScheduler.schedule(tailDelay, () {
      final currentPlayer = player;
      if (!isSameCompletedPlayback(currentPlayer)) {
        return;
      }

      _syncCompletedPlaybackPosition(currentPlayer!);
      DebugLogService.log(
        'audio.completed',
        'settle completed position',
        extra: {
          'oid': oid.toString(),
          'subId': subId.firstOrNull?.toString(),
          'gateGeneration': completedGateGeneration,
        },
      );
      _completedGateScheduler.schedule(CompletedGate.buffer, () {
        final currentPlayer = player;
        if (!isSameCompletedPlayback(currentPlayer)) {
          return;
        }

        _pendingCompleted = false;
        _markCompletedConsumed(completedIdentity, source: 'completed_signal');
        _consumePlaybackCompleted();
      });
    });
  }

  bool _persistCompletedProgressIfNeeded({required String reason}) {
    final currentPlayer = player;
    final completedDuration = currentPlayer == null
        ? Duration.zero
        : _rawAudioDuration(currentPlayer);
    final remaining = currentPlayer == null
        ? null
        : CompletedGate.remaining(
            total: completedDuration,
            position: currentPlayer.state.position,
          );
    if (_isSwitchingAudio ||
        currentPlayer == null ||
        !currentPlayer.state.completed ||
        remaining == null ||
        !CompletedGate.isReady(remaining)) {
      return false;
    }

    _syncCompletedProgress();
    _unawaitedHeartBeat(_reportCompletedHeartBeat());
    if (_shouldSyncVideoDetailMetadata && completedDuration > Duration.zero) {
      _videoDetailController?.playedTime = completedDuration;
    }
    DebugLogService.log(
      'audio.completed',
      'persist completed progress before close',
      extra: {
        'reason': reason,
        'oid': oid.toString(),
        'subId': subId.firstOrNull?.toString(),
      },
    );
    return true;
  }

  void _consumePlaybackCompleted() {
    DebugLogService.log(
      'audio.completed',
      'handle playback completed',
      extra: {
        'oid': oid.toString(),
        'subId': subId.firstOrNull?.toString(),
        'playMode': playMode.value.name,
      },
    );
    _syncCompletedProgress();
    _unawaitedHeartBeat(_reportCompletedHeartBeat());
    if (_shouldSyncVideoDetailMetadata) {
      _videoDetailController?.playedTime = duration.value;
    }
    _publishPlaybackStatus(PlayerStatus.completed);
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
          playNext(nextPart: true, skipSaveProgress: true);
          break;
        case PlayRepeat.singleCycle:
          _enqueueSwitch(() async {
            if (player case final currentPlayer?) {
              final seekFuture = onSeek(Duration.zero);
              if (seekFuture != null) {
                await seekFuture;
              }
              await currentPlayer.play();
            }
          });
          break;
        case PlayRepeat.listCycle:
          if (playNext(nextPart: true, skipSaveProgress: true)) {
          } else if (index != null && index != 0 && playlist != null) {
            playIndex(0, skipSaveProgress: true);
          } else {
            _enqueueSwitch(() async {
              if (player case final currentPlayer?) {
                final seekFuture = onSeek(Duration.zero);
                if (seekFuture != null) {
                  await seekFuture;
                }
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
    await runWithActionLoading(IntroAction.like, () async {
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
    });
  }

  @override
  Future<void> actionTriple() async {
    await runWithActionLoading(IntroAction.triple, () async {
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
    });
  }

  @override
  int get copyright => audioItem.value?.arc.copyright ?? 1;

  @override
  Future<void> onPayCoin(int coin, bool coinWithLike) async {
    await runWithActionLoading(IntroAction.coin, () async {
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
    });
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
      builder: (_) => SimpleDialog(
        clipBehavior: Clip.hardEdge,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          DialogOption(
            child: const Text('复制链接', style: TextStyle(fontSize: 14)),
            onPressed: () {
              Get.back();
              Utils.copyText(audioUrl);
            },
          ),
          DialogOption(
            child: const Text('其它app打开', style: TextStyle(fontSize: 14)),
            onPressed: () {
              Get.back();
              PageUtils.launchURL(audioUrl);
            },
          ),
          if (PlatformUtils.isMobile)
            DialogOption(
              child: const Text('分享视频', style: TextStyle(fontSize: 14)),
              onPressed: () {
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
          if (isLogin)
            DialogOption(
              child: const Text('分享至动态', style: TextStyle(fontSize: 14)),
              onPressed: () {
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
          if (isUgc && isLogin)
            DialogOption(
              child: const Text('分享至消息', style: TextStyle(fontSize: 14)),
              onPressed: () {
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
    );
  }

  void playOrPause() {
    if (player case final player?) {
      if ((duration.value - position.value).inMilliseconds < 50) {
        onSeek(Duration.zero)?.whenComplete(player.play);
      } else if (player.state.playing) {
        onPause();
      } else {
        onPlay();
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
          // 上一条是顺序跳转，不应被该条目的历史分 P 重定向。
          await _playIndexInternal(
            prev,
            skipSaveProgress: false,
            preferHistoryPart: false,
          );
        });
        return true;
      }
    }
    return false;
  }

  bool playNext({bool nextPart = false, bool skipSaveProgress = false}) {
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
              await _playNextPartInternal(
                nextIndex,
                skipSaveProgress: skipSaveProgress,
              );
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
          // 下一条是顺序跳转，不应被该条目的历史分 P 重定向。
          await _playIndexInternal(
            next,
            skipSaveProgress: skipSaveProgress,
            preferHistoryPart: false,
          );
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
    bool preferHistoryPart = true,
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
          preferHistoryPart: preferHistoryPart,
        );
      },
    );
  }

  Future<void> _playNextPartInternal(
    int nextPartIndex, {
    bool skipSaveProgress = false,
  }) async {
    final currentItem = audioItem.value;
    if (currentItem == null) {
      return;
    }
    final parts = currentItem.parts;
    if (nextPartIndex < 0 || nextPartIndex >= parts.length) {
      return;
    }

    if (!skipSaveProgress) {
      _saveCurrentProgress();
      _unawaitedHeartBeat(_reportStatusHeartBeat());
    }
    final prevHeartDuration = _heartDuration;
    final prevCompletedHeartBeatSynced = _completedHeartBeatSynced;
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
    final resolvedProgress = _resolvePlaylistItemProgress(
      currentItem,
      oid.toInt(),
      _currentSubId,
    );
    _start = resolvedProgress.seconds > 0
        ? Duration(seconds: resolvedProgress.seconds)
        : null;
    DebugLogService.log(
      'audio.switch',
      'switch to next part progress',
      extra: {
        'generation': generation,
        'oid': oid.toString(),
        'subId': subId.firstOrNull?.toString(),
        'progress': resolvedProgress.seconds,
        'progressSource': resolvedProgress.source,
      },
    );
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
        _heartDuration = prevHeartDuration;
        _completedHeartBeatSynced = prevCompletedHeartBeatSynced;
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
    bool preferHistoryPart = true,
  }) async {
    if (index == this.index && subId == null) return;
    // 切换前保存当前视频进度（如果没有在调用方保存过）
    if (!skipSaveProgress) {
      _saveCurrentProgress();
      _unawaitedHeartBeat(_reportStatusHeartBeat());
    }
    final prevHeartDuration = _heartDuration;
    final prevCompletedHeartBeatSynced = _completedHeartBeatSynced;
    final prevIndex = this.index;
    final prevOid = oid;
    final prevSubId = this.subId;
    final prevItemType = itemType;
    final audioItem = playlist![index];
    final item = audioItem.item;
    final shouldRestoreHistoryPart =
        preferHistoryPart ||
        _shouldRestoreHistoryPartForPlaylistSwitch(
          previousOid: prevOid,
          targetItem: audioItem,
          requestedSubId: subId,
        );

    final generation = _beginSwitch();
    _markAudioSwitching();
    final resolvedSubIds = await _defaultSubIdsForPlaylistItem(
      audioItem,
      item,
      subId,
      preferHistoryPart: shouldRestoreHistoryPart,
      isCurrent: () => !_isStaleSwitch(generation),
    );
    if (_isStaleSwitch(generation)) {
      return;
    }

    this.index = index;
    _isLocalPlayback = false;
    oid = item.oid;
    this.subId = resolvedSubIds;
    itemType = item.itemType;
    _resetPlaybackProgressForSwitch();
    final currentAid = item.oid.toInt();
    final currentSubId = _currentSubId;
    // 后续进度解析必须使用最终选定的 subId，保证历史分 P 和显式分 P 进度一致。
    final resolvedProgress = _resolvePlaylistItemProgress(
      audioItem,
      currentAid,
      currentSubId,
    );
    final progress = resolvedProgress.seconds;
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
        'progressSource': resolvedProgress.source,
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
        _heartDuration = prevHeartDuration;
        _completedHeartBeatSynced = prevCompletedHeartBeatSynced;
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
        (e) {
          if (e.aid != aid) return false;
          final pages = e.pages;
          if (pages != null && pages.isNotEmpty) {
            return pages.length == 1 && pages.first.id == cid;
          }
          return e.cid == cid;
        },
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
      _initialPlaylistProgress[_progressKey(currentOid, currentCid)] =
          progressSeconds;

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
      _initialPlaylistProgress[_progressKey(currentOid, currentCid)] = -1;

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
  int get currPosInMilliseconds => player?.state.position.inMilliseconds ?? 0;

  @override
  int? get timeLength => player?.state.duration.inMilliseconds ?? 0;

  @override
  Future<void>? seekTo(
    Duration duration, {
    required bool isSeek,
    BlockSkipSource skipSource = BlockSkipSource.manual,
  }) => _seekToAudio(duration, skipSource: skipSource);

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
    // 退出听视频时保存最后的进度
    final persistedCompleted = _persistCompletedProgressIfNeeded(
      reason: 'controller_closed',
    );
    if (!persistedCompleted && !_isSwitchingAudio) {
      _unawaitedHeartBeat(
        _reportStatusHeartBeat(
          allowPendingCompleted: true,
          force: _pendingCompleted,
        ),
      );
      _saveCurrentProgress();
    } else if (!persistedCompleted) {
      DebugLogService.log(
        'audio.progress',
        'skip save progress on close while switching',
        extra: {
          'oid': oid.toString(),
          'subId': subId.firstOrNull?.toString(),
        },
      );
    }

    _cancelPendingCompleted(reason: 'controller_closed');

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
