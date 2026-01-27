import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/common/widgets/pair.dart';
import 'package:PiliPlus/common/widgets/progress_bar/segment_progress_bar.dart';
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
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/sponsor_block.dart';
import 'package:PiliPlus/http/ua_type.dart';
import 'package:PiliPlus/models/common/sponsor_block/segment_model.dart';
import 'package:PiliPlus/models/common/sponsor_block/segment_type.dart';
import 'package:PiliPlus/models/common/sponsor_block/skip_type.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/sponsor_block/segment_item.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart'
    show FavMixin;
import 'package:PiliPlus/pages/dynamics_repost/view.dart';
import 'package:PiliPlus/pages/main_reply/view.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/triple_mixin.dart';
import 'package:PiliPlus/pages/video/pay_coins/view.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/playback/playback_foreground_service.dart';
import 'package:PiliPlus/services/service_locator.dart';
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
    with GetTickerProviderStateMixin, TripleMixin, FavMixin {
  late final Map args;
  late Int64 id;
  late Int64 oid;
  late List<Int64> subId;
  late int itemType;
  Int64? extraId;
  late final PlaylistSource from;
  late final isVideo = itemType == 1;

  final Rx<DetailItem?> audioItem = Rx<DetailItem?>(null);

  Player? player;
  late int cacheAudioQa;

  late bool isDragging = false;
  final Rx<Duration> position = Duration.zero.obs;
  final Rx<Duration> duration = Duration.zero.obs;

  late final AnimationController animController;

  Set<StreamSubscription>? _subscriptions;

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

  // 空降助手相关
  late final bool enableSponsorBlock = Pref.enableSponsorBlock;
  final List<SegmentModel> segmentList = [];
  final RxList<Segment> segmentProgressList = <Segment>[].obs;
  late final List<Color> blockColor = Pref.blockColor;
  StreamSubscription<Duration>? _sponsorBlockSubscription;
  int _lastPos = -1;
  bool _fgStartedForCurrent = false;
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
            ua: UaType.pc.ua,
            referer: HttpString.baseUrl,
          );
        }
        // 有 audioUrl 时也需要查询空降助手
        if (enableSponsorBlock && isVideo) {
          _querySponsorBlock();
        }
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
  }

  Future<void> onPlay() async {
    await player?.play();
  }

  Future<void> onPause() async {
    await player?.pause();
  }

  Future<void> onSeek(Duration duration) async {
    await player?.seek(duration);
  }

  void _updateCurrItem(DetailItem item) {
    audioItem.value = item;
    hasLike.value = item.stat.hasLike_7;
    coinNum.value = item.stat.hasCoin_8 ? 2 : 0;
    hasFav.value = item.stat.hasFav;
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

    // 尝试使用本地已缓存的离线音频
    final triedLocal = await _tryPlayLocalIfAvailable();
    if (triedLocal) {
      return true;
    }

    // 查询空降助手
    if (enableSponsorBlock && isVideo) {
      _querySponsorBlock();
    }

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

  void _onOpenMedia(
    String url, {
    String? referer,
    String ua = Constants.userAgentApp,
  }) {
    // 切换媒资时重置本地播放标记
    if (!_isLocalPlayback) {
      // 非本地播放路径，确保标记清空
      _isLocalPlayback = false;
    }
    // 重置前台服务标记，但不要立即停止服务
    // 等到新媒体开始播放时再停止，避免切换时的保护窗口期
    _fgStartedForCurrent = false;
    if (kDebugMode) {
      debugPrint(
        'AudioController: _onOpenMedia called, url=${url.substring(0, url.length > 50 ? 50 : url.length)}...',
      );
    }
    _initPlayerIfNeeded();
    player!.open(
      Media(
        url,
        start: _start,
        httpHeaders: {
          'user-agent': ua,
          'referer': ?referer,
        },
      ),
    );
    _start = null;
    // player 已准备好，初始化空降助手跳过监听
    if (enableSponsorBlock && segmentList.isNotEmpty) {
      if (kDebugMode) {
        debugPrint('AudioController: _onOpenMedia 中初始化空降助手');
      }
      _initSponsorBlockSkip();
    }
  }

  void _initPlayerIfNeeded() {
    player ??= Player();
    _subscriptions ??= {
      player!.stream.position.listen((position) {
        if (isDragging) return;
        if (position.inSeconds != this.position.value.inSeconds) {
          this.position.value = position;
          _videoDetailController?.playedTime = position;
          videoPlayerServiceHandler?.onPositionChange(position);
          _maybeStartPlaybackForeground();
        }
      }),
      player!.stream.duration.listen((duration) {
        this.duration.value = duration;
        // 当 duration 更新且有空降助手片段时，更新进度条片段
        _updateSegmentProgressList();
      }),
      player!.stream.playing.listen((playing) {
        PlayerStatus playerStatus;
        if (playing) {
          // 新媒体开始播放时，安全地停止前台服务
          // 此时播放器已经初始化完成，可以安全停止
          if (PlaybackForegroundService.isRunning && !_fgStartedForCurrent) {
            if (kDebugMode) {
              debugPrint('AudioController: 新媒体开始播放，停止前台服务');
            }
            PlaybackForegroundService.stop();
          }
          animController.forward();
          playerStatus = PlayerStatus.playing;
        } else {
          animController.reverse();
          playerStatus = PlayerStatus.paused;
        }
        videoPlayerServiceHandler?.onStatusChange(playerStatus, false, false);
      }),
      player!.stream.completed.listen((completed) {
        _videoDetailController?.playedTime = duration.value;
        videoPlayerServiceHandler?.onStatusChange(
          PlayerStatus.completed,
          false,
          false,
        );
        if (completed) {
          if (kDebugMode) {
            debugPrint('AudioController: 播放完成，准备切换下一个');
          }
          _fgStartedForCurrent = false;
          // 不要在这里停止前台服务，让它保护到新媒体开始播放
          // PlaybackForegroundService.stop();
          switch (playMode.value) {
            case PlayRepeat.pause:
              break;
            case PlayRepeat.listOrder:
              playNext(nextPart: true);
              break;
            case PlayRepeat.singleCycle:
              _replay();
              break;
            case PlayRepeat.listCycle:
              if (!playNext(nextPart: true)) {
                if (index != null && index != 0 && playlist != null) {
                  playIndex(0);
                } else {
                  _replay();
                }
              }
              break;
            case PlayRepeat.autoPlayRelated:
              break;
          }
        }
      }),
    };
  }

  void _replay() {
    player?.seek(Duration.zero).whenComplete(player!.play);
  }

  // 空降助手：查询跳过片段
  Future<void> _querySponsorBlock() async {
    if (!isVideo) return; // 只对视频类型生效

    _sponsorBlockSubscription?.cancel();
    _sponsorBlockSubscription = null;
    _lastPos = -1;
    segmentList.clear();
    segmentProgressList.clear();

    final bvid = IdUtils.av2bv(oid.toInt());
    final cid = (subId.firstOrNull ?? oid).toInt();

    final result = await SponsorBlock.getSkipSegments(
      bvid: bvid,
      cid: cid,
    );
    switch (result) {
      case Success<List<SegmentItemModel>>(:final response):
        _handleSBData(response);
      case Error(:final code) when code != 404:
        result.toast();
      default:
        break;
    }
  }

  void _handleSBData(List<SegmentItemModel> list) {
    if (list.isEmpty) return;

    try {
      final blockSettings = Pref.blockSettings;
      final enableList = blockSettings
          .where((item) => item.second != SkipType.disable)
          .map((item) => item.first.name)
          .toSet();
      final blockLimit = Pref.blockLimit;

      segmentList.addAll(
        list
            .where(
              (item) =>
                  enableList.contains(item.category) &&
                  item.segment[1] >= item.segment[0],
            )
            .map(
              (item) {
                final segmentType = SegmentType.values.byName(item.category);
                SkipType skipType = blockSettings[segmentType.index].second;
                if (skipType != SkipType.showOnly) {
                  if (item.segment[1] == item.segment[0] ||
                      item.segment[1] - item.segment[0] < blockLimit) {
                    skipType = SkipType.showOnly;
                  }
                }

                return SegmentModel(
                  UUID: item.uuid,
                  segmentType: segmentType,
                  segment: Pair(
                    first: item.segment[0], // 已经是毫秒
                    second: item.segment[1], // 已经是毫秒
                  ),
                  skipType: skipType,
                );
              },
            ),
      );

      if (segmentList.isNotEmpty) {
        _updateSegmentProgressList();
        _initSponsorBlockSkip();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('failed to parse sponsorblock: $e');
    }
  }

  void _updateSegmentProgressList() {
    if (segmentList.isEmpty) return;
    final durationMs = duration.value.inMilliseconds;
    if (durationMs <= 0) return;

    segmentProgressList
      ..clear()
      ..addAll(
        segmentList.map((e) {
          double start = (e.segment.first / durationMs).clamp(0.0, 1.0);
          double end = (e.segment.second / durationMs).clamp(0.0, 1.0);
          return Segment(
            start: start,
            end: end,
            color: _getColor(e.segmentType),
          );
        }),
      );
  }

  Color _getColor(SegmentType segment) => blockColor[segment.index];

  void _initSponsorBlockSkip() {
    if (segmentList.isEmpty) {
      if (kDebugMode) {
        debugPrint('AudioController: segmentList 为空，跳过初始化');
      }
      return;
    }
    if (player == null) {
      if (kDebugMode) {
        debugPrint('AudioController: player 为空，跳过初始化');
      }
      return;
    }

    if (kDebugMode) {
      debugPrint('AudioController: 初始化空降助手跳过监听');
    }

    _sponsorBlockSubscription?.cancel();
    _sponsorBlockSubscription = player!.stream.position.listen((position) {
      int currentPos = position.inSeconds;
      if (currentPos != _lastPos) {
        _lastPos = currentPos;
        final msPos = currentPos * 1000;
        for (SegmentModel item in segmentList) {
          if (msPos <= item.segment.first &&
              item.segment.first <= msPos + 1000) {
            switch (item.skipType) {
              case SkipType.alwaysSkip:
                _onSkip(item);
                break;
              case SkipType.skipOnce:
                if (!item.hasSkipped) {
                  item.hasSkipped = true;
                  _onSkip(item);
                }
                break;
              case SkipType.skipManually:
                // 听视频页不支持手动跳过 UI，直接跳过
                _onSkip(item);
                break;
              default:
                break;
            }
            break;
          }
        }
      }
    });
  }

  Future<void> _onSkip(SegmentModel item) async {
    try {
      if (kDebugMode) {
        debugPrint(
          'AudioController: 跳过片段 ${item.segmentType.shortTitle} 到 ${item.segment.second}ms',
        );
      }
      await player?.seek(Duration(milliseconds: item.segment.second));
      if (Pref.blockToast) {
        SmartDialog.showToast('已跳过${item.segmentType.shortTitle}片段');
      }
      if (Pref.blockTrack) {
        SponsorBlock.viewedVideoSponsorTime(item.UUID);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('failed to skip: $e');
      SmartDialog.showToast('${item.segmentType.shortTitle}片段跳过失败');
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
      replyType: isVideo ? 1 : 14,
    );
  }

  void actionShareVideo(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) {
        final audioUrl = isVideo
            ? '${HttpString.baseUrl}/video/${IdUtils.av2bv(oid.toInt())}'
            : '${HttpString.baseUrl}/audio/au$oid';
        return AlertDialog(
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
                        dynType: isVideo ? 8 : 256,
                        pic: arc.cover,
                        title: arc.title,
                        uname: owner.name,
                      ),
                    );
                  }
                },
              ),
              if (isVideo)
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
        );
      },
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
        playIndex(prev);
        return true;
      }
    }
    return false;
  }

  bool playNext({bool nextPart = false}) {
    if (nextPart) {
      if (audioItem.value case DetailItem(:final parts)) {
        if (parts.length > 1) {
          final subId = this.subId.firstOrNull;
          final nextIndex = parts.indexWhere((e) => e.subId == subId) + 1;
          if (nextIndex != 0 && nextIndex < parts.length) {
            final nextPart = parts[nextIndex];
            oid = nextPart.oid;
            this.subId = [nextPart.subId];
            // 切换前保存当前视频进度
            _saveCurrentProgress();
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
        playIndex(next);
        return true;
      }
    }
    return false;
  }

  bool get _hasNextItem {
    if (playMode.value == PlayRepeat.singleCycle ||
        playMode.value == PlayRepeat.pause) {
      return false;
    }

    // 同一条目的分 P
    if (audioItem.value case final audio?) {
      final parts = audio.parts;
      if (parts.length > 1) {
        final currentSub = subId.firstOrNull;
        final currentIndex = parts.indexWhere((e) => e.subId == currentSub);
        if (currentIndex != -1 && currentIndex + 1 < parts.length) {
          return true;
        }
      }
    }

    if (playlist != null && index != null) {
      if (index! + 1 < (playlist?.length ?? 0)) {
        return true;
      }
      // 服务器还有下一页
      if (_next != null) {
        return true;
      }
    }

    return false;
  }

  void _maybeStartPlaybackForeground() {
    if (_fgStartedForCurrent || !PlaybackForegroundService.isSupported) return;
    final total = duration.value;
    if (total <= Duration.zero || !_hasNextItem) return;

    final remaining = total - position.value;
    if (remaining <= const Duration(seconds: 6)) {
      _fgStartedForCurrent = true;
      final title = audioItem.value?.arc.title ?? Constants.appName;
      if (kDebugMode) {
        debugPrint('AudioController: 启动前台服务保护切换，剩余时间: ${remaining.inSeconds}秒');
      }
      PlaybackForegroundService.start(
        title: '即将切换：$title',
        text: '保持后台播放不中断',
      );
    }
  }

  void playIndex(int index, {List<Int64>? subId}) {
    if (index == this.index && subId == null) return;
    // 切换前保存当前视频进度
    _saveCurrentProgress();
    this.index = index;
    _isLocalPlayback = false;
    final audioItem = playlist![index];
    final item = audioItem.item;
    oid = item.oid;
    this.subId =
        subId ??
        (item.subId.isNotEmpty ? item.subId : [audioItem.parts.first.subId]);
    itemType = item.itemType;
    _queryPlayUrl().then((res) {
      if (res) {
        // 保持与 VideoDetailController 的连接，不再设置为 null
        // _videoDetailController = null;
        _updateCurrItem(audioItem);
      }
    });
  }

  /// 保存当前视频的播放进度到 VideoDetailController
  void _saveCurrentProgress() {
    if (_videoDetailController == null) return;

    try {
      final currentPosition = position.value;
      if (currentPosition == Duration.zero) return;

      // 更新最后播放时间
      _videoDetailController!.playedTime = currentPosition;

      // 触发心跳以同步进度到列表页
      _videoDetailController!.makeHeartBeat();

      if (kDebugMode) {
        debugPrint(
          '🎵 AudioController: 保存进度 oid=$oid, position=${currentPosition.inSeconds}s',
        );
      }
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
    }
  }

  // Timer? _timer;

  // void _cancelTimer() {
  //   _timer?.cancel();
  //   _timer = null;
  // }

  // void showTimerDialog() {
  //   // TODO
  // }

  @override
  (Object, int) get getFavRidType => (oid, isVideo ? 2 : 12);

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
  void onClose() {
    // 退出听视频时保存最后的进度
    _saveCurrentProgress();

    // _cancelTimer();
    videoPlayerServiceHandler
      ?..onPlay = null
      ..onPause = null
      ..onSeek = null
      // 不要在这里重置 setListControlMode，因为播放器页有自己的状态管理
      // 从听视频页返回时，播放器页的 didPopNext 会恢复正确的列表控制模式
      ..onVideoDetailDispose(hashCode.toString());
    _subscriptions?.forEach((e) => e.cancel());
    _subscriptions = null;
    _sponsorBlockSubscription?.cancel();
    _sponsorBlockSubscription = null;
    PlaybackForegroundService.stop();
    player?.dispose();
    player = null;
    animController.dispose();
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
