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
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/triple_mixin.dart';
import 'package:PiliPlus/pages/video/pay_coins/view.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
        BlockMixin {
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

  late double speed = 1.0;

  late final Rx<PlayRepeat> playMode = Pref.audioPlayMode.obs;

  late final isLogin = Accounts.main.isLogin;

  Duration? _start;
  VideoDetailController? _videoDetailController;

  String? _prev;
  String? _next;
  bool get reachStart => _prev == null;

  ListOrder order = ListOrder.ORDER_NORMAL;

  Timer? _pendingCompletionTimer;
  bool _isLocalPlayback = false;
  // 保存当前使用的本地缓存条目（用于从其他页面返回时恢复本地播放）
  BiliDownloadEntryInfo? currentLocalEntry;

  @override
  void onInit() {
    super.onInit();
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
    Utils.isWiFi.then((isWiFi) async {
      cacheAudioQa = isWiFi ? Pref.defaultAudioQa : Pref.defaultAudioQaCellular;

      final String? audioUrl = args['audioUrl'];
      final hasAudioUrl = audioUrl != null;

      if (hasAudioUrl) {
        // 即使传入了audioUrl，也先尝试使用本地离线资源
        final triedLocal = await _tryPlayLocalIfAvailable();
        if (!triedLocal) {
          // 没有离线资源才使用传入的在线地址
          _onOpenMedia(
            audioUrl,
            ua: BrowserUa.pc,
            referer: HttpString.baseUrl,
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
    videoPlayerServiceHandler?.onVideoDetailChange(
      item,
      (subId.firstOrNull ?? oid).toInt(),
      hashCode.toString(),
    );
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
    if (_isLocalPlayback) return true;

    // 切换视频时，立即清空旧的空降助手数据，防止 UI 残留
    resetBlock();

    // 尝试使用本地已缓存的离线音频
    final triedLocal = await _tryPlayLocalIfAvailable();
    if (triedLocal) {
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
      _onPlay(response);
      return true;
    } else {
      res.toast();
      return false;
    }
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
    duration.value = Duration(milliseconds: local.totalTimeMilli);
    _onOpenMedia(audioPath, ua: '', referer: null);
    return true;
  }

  void _onPlay(PlayURLResp data) {
    final PlayInfo? playInfo = data.playerInfo.values.firstOrNull;
    if (playInfo != null) {
      if (playInfo.hasPlayDash()) {
        final playDash = playInfo.playDash;
        final audios = playDash.audio;
        if (audios.isEmpty) {
          return;
        }
        position.value = Duration.zero;
        final audio = audios.findClosestTarget(
          (e) => e.id <= cacheAudioQa,
          (a, b) => a.id > b.id ? a : b,
        );
        _onOpenMedia(VideoUtils.getCdnUrl(audio.playUrls));
      } else if (playInfo.hasPlayUrl()) {
        final playUrl = playInfo.playUrl;
        final durls = playUrl.durl;
        if (durls.isEmpty) {
          return;
        }
        final durl = durls.first;
        position.value = Duration.zero;
        _onOpenMedia(VideoUtils.getCdnUrl(durl.playUrls));
      }
    }
  }

  Future<void> _onOpenMedia(
    String url, {
    String ua = Constants.userAgentApp,
    String? referer,
  }) async {
    _cancelPendingCompletionTimer();
    position.value = Duration.zero;
    // 切换媒资时重置本地播放标记
    if (!_isLocalPlayback) {
      // 非本地播放路径，确保标记清空
      _isLocalPlayback = false;
    }
    await _initPlayerIfNeeded();
    player!.setMediaHeader(
      userAgent: ua,
      // mpv cannot clear referer option
      headers: {'Referer': ?referer},
    );
    player!.open(
      Media(
        url,
        start: _start,
      ),
    );
    await player!.play();
    player!.setRate(speed);
    _start = null;
    initSkip();
  }

  Future<void> _initPlayerIfNeeded() async {
    if (_hasInit) return;
    _hasInit = true;
    assert(player == null, _subscriptions = null);
    player = await Player.create();
    if (isClosed) {
      player!.dispose();
      player = null;
      return;
    }
    final stream = player!.stream;
    _subscriptions = [
      stream.position.listen((position) {
        if (isDragging) return;
        if (position.inSeconds != this.position.value.inSeconds) {
          this.position.value = position;
          _videoDetailController?.playedTime = position;
          videoPlayerServiceHandler?.onPositionChange(position);
        }
      }),
      stream.duration.listen(duration.call),
      stream.playing.listen((playing) {
        if (playing) {
          _cancelPendingCompletionTimer();
        }
        final PlayerStatus playerStatus;
        if (playing) {
          animController.forward();
          playerStatus = PlayerStatus.playing;
        } else {
          animController.reverse();
          playerStatus = PlayerStatus.paused;
        }
        videoPlayerServiceHandler?.onStatusChange(playerStatus, false, false);
      }),
      stream.completed.listen((completed) {
        if (!completed) {
          _cancelPendingCompletionTimer();
          return;
        }

        final remaining = _completionRemaining;
        if (remaining > const Duration(milliseconds: 800)) {
          _schedulePendingCompletion(remaining);
          return;
        }

        _handlePlaybackCompleted();
      }),
    ];
  }

  Duration get _completionRemaining {
    final remaining = duration.value - position.value;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void _cancelPendingCompletionTimer() {
    _pendingCompletionTimer?.cancel();
    _pendingCompletionTimer = null;
  }

  void _schedulePendingCompletion(Duration remaining) {
    final waitDuration = remaining > const Duration(seconds: 2)
        ? const Duration(seconds: 2)
        : remaining;
    final expectedOid = oid;
    final expectedSubId = subId.firstOrNull;

    _cancelPendingCompletionTimer();
    if (kDebugMode) {
      debugPrint(
        'AudioController: completed 触发过早，延迟 ${waitDuration.inMilliseconds}ms 再切换，remaining=${remaining.inMilliseconds}ms',
      );
    }

    _pendingCompletionTimer = Timer(waitDuration, () {
      _pendingCompletionTimer = null;
      if (isClosed ||
          oid != expectedOid ||
          subId.firstOrNull != expectedSubId) {
        return;
      }
      _handlePlaybackCompleted();
    });
  }

  void _handlePlaybackCompleted() {
    _cancelPendingCompletionTimer();
    _videoDetailController?.playedTime = duration.value;
    videoPlayerServiceHandler?.onStatusChange(
      PlayerStatus.completed,
      false,
      false,
    );
    var willAutoContinue = false;
    if (kDebugMode) {
      debugPrint('AudioController: 播放完成，准备切换下一个');
    }
    if (shutdownTimerService.isWaiting) {
      willAutoContinue = true;
      shutdownTimerService.handleWaiting();
    } else {
      switch (playMode.value) {
        case PlayRepeat.pause:
          break;
        case PlayRepeat.listOrder:
          willAutoContinue = playNext(nextPart: true);
          break;
        case PlayRepeat.singleCycle:
          willAutoContinue = true;
          onPlay();
          break;
        case PlayRepeat.listCycle:
          if (playNext(nextPart: true)) {
            willAutoContinue = true;
          } else if (index != null && index != 0 && playlist != null) {
            willAutoContinue = true;
            playIndex(0);
          } else {
            willAutoContinue = true;
            onPlay();
          }
          break;
        case PlayRepeat.autoPlayRelated:
          break;
      }
    }

    // 统一由 handler 处理“播放完成是否清理卡片”的最终策略。
    if (PlatformUtils.isMobile) {
      videoPlayerServiceHandler?.onPlaybackCompleted(
        willAutoContinue: willAutoContinue,
        source: 'audio',
      );
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

  void actionCoinVideo() {
    final audioItem = this.audioItem.value;
    if (audioItem == null) {
      return;
    }

    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }

    final int copyright = audioItem.arc.copyright;
    if ((copyright != 1 && coinNum.value >= 1) || coinNum.value >= 2) {
      SmartDialog.showToast('达到投币上限啦~');
      return;
    }

    if (GlobalData().coins != null && GlobalData().coins! < 1) {
      SmartDialog.showToast('硬币不足');
      // return;
    }

    PayCoinsPage.toPayCoinsPage(
      onPayCoin: _onPayCoin,
      hasCoin: coinNum.value == 1,
      copyright: copyright,
    );
  }

  Future<void> _onPayCoin(int coin, bool coinWithLike) async {
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
                    Utils.shareText(
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
        // 切换前保存当前视频进度
        _saveCurrentProgress();
        playIndex(prev, skipSaveProgress: true);
        return true;
      }
    }
    return false;
  }

  bool playNext({bool nextPart = false}) {
    _cancelPendingCompletionTimer();
    if (nextPart) {
      if (audioItem.value case DetailItem(:final parts)) {
        if (parts.length > 1) {
          final subId = this.subId.firstOrNull;
          final nextIndex = parts.indexWhere((e) => e.subId == subId) + 1;
          if (nextIndex != 0 && nextIndex < parts.length) {
            // 切换前保存当前视频进度（在更新 oid/subId 之前）
            _saveCurrentProgress();

            final nextPart = parts[nextIndex];
            oid = nextPart.oid;
            this.subId = [nextPart.subId];
            _queryPlayUrl().then((res) {
              if (res) {
                // 保持与 VideoDetailController 的连接，不再设置为 null
                // _videoDetailController = null;
              }
            });
            return true;
          }
        }
      }
    }
    if (index != null && playlist != null && player != null) {
      final next = index! + 1;
      if (next < playlist!.length) {
        if (next == playlist!.length - 1 && _next != null) {
          _queryPlayList(isLoadNext: true);
        }
        // 切换前保存当前视频进度
        _saveCurrentProgress();
        playIndex(next, skipSaveProgress: true);
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
    if (index == this.index && subId == null) return;
    // 切换前保存当前视频进度（如果没有在调用方保存过）
    if (!skipSaveProgress) {
      _saveCurrentProgress();
    }
    this.index = index;
    _isLocalPlayback = false;
    final audioItem = playlist![index];
    final item = audioItem.item;
    oid = item.oid;
    this.subId =
        subId ??
        (item.subId.isNotEmpty ? item.subId : [audioItem.parts.first.subId]);
    itemType = item.itemType;
    // 使用列表中的进度信息设置起始播放位置
    // 优先使用 playlist 中的进度（由 _saveCurrentProgress 更新）
    // 如果为 0，尝试从 VideoDetailController 的 mediaList 中获取本地进度
    int progress = audioItem.progress.toInt();
    if (progress <= 0) {
      progress = _getProgressFromMediaList(item.oid.toInt());
    }
    if (kDebugMode) {
      debugPrint(
        '🎵 playIndex: index=$index, oid=${item.oid}, progress=$progress seconds',
      );
    }
    _start = progress > 0 ? Duration(seconds: progress) : null;
    _queryPlayUrl().then((res) {
      if (res) {
        // 保持与 VideoDetailController 的连接，不再设置为 null
        // _videoDetailController = null;
        _updateCurrItem(audioItem);
      }
    });
  }

  /// 从 VideoDetailController 的 mediaList 中获取视频的本地进度（秒）
  int _getProgressFromMediaList(int aid) {
    if (_videoDetailController == null) return 0;
    try {
      final mediaList = _videoDetailController!.mediaList;
      final item = mediaList.firstWhereOrNull((e) => e.aid == aid);
      if (item != null &&
          item.progressPercent != null &&
          item.duration != null &&
          item.progressPercent! > 0) {
        // progressPercent 可能是 0-1 格式（服务器返回）或 0-100 格式（内部更新）
        // 如果值 <= 1，认为是 0-1 格式；否则是 0-100 格式
        final percent = item.progressPercent! <= 1
            ? item.progressPercent!
            : item.progressPercent! / 100;
        return (percent * item.duration!).round();
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

    try {
      final currentPosition = position.value;
      if (currentPosition == Duration.zero) return;

      // 获取听视频当前播放的视频信息
      final currentOid = oid.toInt();
      final currentCid = (subId.firstOrNull ?? oid).toInt();
      final currentBvid = IdUtils.av2bv(currentOid);
      final currentDuration = duration.value.inSeconds;
      final progressSeconds = currentPosition.inSeconds;

      if (kDebugMode) {
        debugPrint(
          '🎵 AudioController: 保存进度 bvid=$currentBvid, cid=$currentCid, position=${progressSeconds}s',
        );
      }

      // 同步更新 playlist 中当前项的进度，以便在列表中切换时使用最新进度
      if (index != null && playlist != null && index! < playlist!.length) {
        playlist![index!].progress = Int64(progressSeconds);
      }

      // 使用新的公开方法更新指定视频的进度
      _videoDetailController!.updateProgressForVideo(
        videoAid: currentOid,
        videoBvid: currentBvid,
        videoCid: currentCid,
        progressSeconds: progressSeconds,
        videoDuration: currentDuration,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AudioController: 保存进度失败: $e');
      }
    }
  }

  void setSpeed(double speed) {
    if (player case final player?) {
      this.speed = speed;
      player.setRate(speed);
      unawaited(
        _videoDetailController?.plPlayerController.setPlaybackSpeed(speed),
      );
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
  void onClose() {
    _cancelPendingCompletionTimer();

    // 退出听视频时保存最后的进度
    _saveCurrentProgress();

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
    videoPlayerServiceHandler?.onVideoDetailDispose(hashCode.toString());
    _subscriptions?.forEach((e) => e.cancel());
    _subscriptions?.clear();
    _subscriptions = null;
    player?.dispose();
    player = null;
    animController.dispose();
    // 方案对比说明：
    // - 旧方案：这里根据 shouldPreserveVideoNotification 条件 clear。
    // - 新方案：统一通过 onVideoDetailDispose 由 handler 判定“是否已无 owner”。
    // 这样不用在页面层复制“是否该清理”的策略，降低多页面维护成本。
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
