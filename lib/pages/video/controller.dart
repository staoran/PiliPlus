import 'dart:async';
import 'dart:math' show min;
import 'dart:ui';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/common/widgets/pair.dart';
import 'package:PiliPlus/common/widgets/progress_bar/segment_progress_bar.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pbenum.dart'
    show PlaylistSource;
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/sponsor_block.dart';
import 'package:PiliPlus/http/ua_type.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/main.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/sponsor_block/action_type.dart';
import 'package:PiliPlus/models/common/sponsor_block/post_segment_model.dart';
import 'package:PiliPlus/models/common/sponsor_block/segment_model.dart';
import 'package:PiliPlus/models/common/sponsor_block/segment_type.dart';
import 'package:PiliPlus/models/common/sponsor_block/skip_type.dart';
import 'package:PiliPlus/models/common/video/audio_quality.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/common/video/subtitle_pref_type.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/model_owner.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/fav/fav_detail/cnt_info.dart';
import 'package:PiliPlus/models_new/media_list/media_list.dart';
import 'package:PiliPlus/models_new/media_list/page.dart' as media_list;
import 'package:PiliPlus/models_new/pgc/pgc_info_model/result.dart';
import 'package:PiliPlus/models_new/sponsor_block/segment_item.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart' as ugc;
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/models_new/video/video_pbp/data.dart';
import 'package:PiliPlus/models_new/video/video_play_info/subtitle.dart';
import 'package:PiliPlus/models_new/video/video_stein_edgeinfo/data.dart';
import 'package:PiliPlus/pages/audio/view.dart';
import 'package:PiliPlus/pages/common/publish/publish_route.dart';
import 'package:PiliPlus/pages/later/controller.dart';
import 'package:PiliPlus/pages/search/widgets/search_text.dart';
import 'package:PiliPlus/pages/video/download_panel/view.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/pages/video/medialist/view.dart';
import 'package:PiliPlus/pages/video/note/view.dart';
import 'package:PiliPlus/pages/video/post_panel/view.dart';
import 'package:PiliPlus/pages/video/send_danmaku/view.dart';
import 'package:PiliPlus/pages/video/widgets/header_control.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/multi_window/player_window_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/context_ext.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

class VideoDetailController extends GetxController
    with GetTickerProviderStateMixin {
  /// 路由传参
  late final Map args;
  late String bvid;
  late int aid;
  late final RxInt cid;
  int? epId;
  int? seasonId;
  int? pgcType;
  late final String heroTag;
  late final RxString cover;

  // 视频类型 默认投稿视频
  late final VideoType videoType;
  late final isUgc = videoType == VideoType.ugc;
  VideoType? _actualVideoType;

  // 页面来源 稍后再看 收藏夹
  late bool isPlayAll;
  late SourceType sourceType;
  late BiliDownloadEntryInfo entry;
  late bool isFileSource;
  late bool _mediaDesc = false;

  int? _mediaListCountOverride;
  bool get _isOfflineListPlayAll => args['offlineList'] == true;

  // 保存当前使用的本地缓存条目（用于从其他页面返回时恢复本地播放）
  BiliDownloadEntryInfo? currentLocalEntry;
  late final RxList<MediaListItemModel> mediaList = <MediaListItemModel>[].obs;
  late String watchLaterTitle;

  // 视频切换状态追踪：防止切换过程中退出时保存错误的进度
  // 当视频切换时设为true，播放器初始化完成后设为false
  bool _isSwitchingVideo = false;

  /// tabs相关配置
  late TabController tabCtr;

  // 请求返回的视频信息
  late PlayUrlModel data;
  final Rx<LoadingState> videoState = LoadingState.loading().obs;

  /// 播放器配置 画质 音质 解码格式
  final Rxn<VideoQuality> currentVideoQa = Rxn<VideoQuality>();
  AudioQuality? currentAudioQa;
  late VideoDecodeFormatType currentDecodeFormats;

  // 是否开始自动播放 存在多p的情况下，第二p需要为true
  final RxBool autoPlay = Pref.autoPlayEnable.obs;

  final videoPlayerKey = GlobalKey();
  final childKey = GlobalKey<ScaffoldState>();

  final plPlayerController = PlPlayerController.getInstance()
    ..brightness.value = -1;
  bool get setSystemBrightness => plPlayerController.setSystemBrightness;

  late VideoItem firstVideo;
  String? videoUrl;
  String? audioUrl;
  Duration? defaultST;
  Duration? playedTime;
  String get playedTimePos {
    final pos = playedTime?.inMilliseconds;
    return pos == null || pos == 0 ? '' : '?t=${pos / 1000}';
  }

  // 亮度
  double? brightness;

  late final headerCtrKey = GlobalKey<TimeBatteryMixin>();

  Box setting = GStorage.setting;

  // 预设的解码格式
  late String cacheDecode = Pref.defaultDecode; // def avc
  late String cacheSecondDecode = Pref.secondDecode; // def av1

  bool get showReply => isFileSource
      ? false
      : isUgc
      ? plPlayerController.showVideoReply
      : plPlayerController.showBangumiReply;

  bool get showRelatedVideo =>
      isFileSource ? false : plPlayerController.showRelatedVideo;

  ScrollController? introScrollCtr;
  ScrollController get effectiveIntroScrollCtr =>
      introScrollCtr ??= ScrollController();

  int? seasonCid;
  late final RxInt seasonIndex = 0.obs;

  PlayerStatus? playerStatus;
  StreamSubscription<Duration>? positionSubscription;
  StreamSubscription<int?>? _widthSubscription;
  StreamSubscription<int?>? _heightSubscription;

  late final scrollKey = GlobalKey<ExtendedNestedScrollViewState>();
  late final RxBool isVertical = false.obs;
  late final RxDouble scrollRatio = 0.0.obs;
  ScrollController? _scrollCtr;
  ScrollController get scrollCtr =>
      _scrollCtr ??= ScrollController()..addListener(scrollListener);
  late bool isExpanding = false;
  late bool isCollapsing = false;
  AnimationController? animController;

  AnimationController get animationController =>
      animController ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 200),
      );
  late double minVideoHeight;
  late double maxVideoHeight;
  late double videoHeight;

  void animToTop() {
    final outerController = scrollKey.currentState!.outerController;
    if (outerController.hasClients) {
      outerController.animateTo(
        outerController.offset,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<void> updateDesktopWindowTitle({
    String? title,
    String? subTitle,
  }) async {
    if (!PlatformUtils.isDesktop || !PlayerWindowService.isPlayerWindow) return;
    final base = title?.trim();
    if (base == null || base.isEmpty) return;

    var display = base;
    final sub = subTitle?.trim();
    if (sub != null && sub.isNotEmpty && sub != display) {
      display = '$base - $sub';
    }

    try {
      await windowManager.setTitle(display);
    } catch (_) {}
  }

  @pragma('vm:notify-debugger-on-exception')
  void setVideoHeight() {
    try {
      final isVertical = firstVideo.width != null && firstVideo.height != null
          ? firstVideo.width! < firstVideo.height!
          : false;
      if (!scrollCtr.hasClients) {
        videoHeight = isVertical ? maxVideoHeight : minVideoHeight;
        this.isVertical.value = isVertical;
        return;
      }
      if (this.isVertical.value != isVertical) {
        this.isVertical.value = isVertical;
        double videoHeight = isVertical ? maxVideoHeight : minVideoHeight;
        if (this.videoHeight != videoHeight) {
          if (videoHeight > this.videoHeight) {
            // current minVideoHeight
            isExpanding = true;
            animationController.forward(
              from: (minVideoHeight - scrollCtr.offset) / maxVideoHeight,
            );
            this.videoHeight = maxVideoHeight;
          } else {
            // current maxVideoHeight
            final currentHeight = DoubleExt(
              maxVideoHeight - scrollCtr.offset,
            ).toPrecision(2);
            double minVideoHeightPrecise = DoubleExt(
              minVideoHeight,
            ).toPrecision(2);
            if (currentHeight == minVideoHeightPrecise) {
              isExpanding = true;
              this.videoHeight = minVideoHeight;
              animationController.forward(from: 1);
            } else if (currentHeight < minVideoHeightPrecise) {
              // expand
              isExpanding = true;
              animationController.forward(from: currentHeight / minVideoHeight);
              this.videoHeight = minVideoHeight;
            } else {
              // collapse
              isCollapsing = true;
              animationController.forward(
                from: scrollCtr.offset / (maxVideoHeight - minVideoHeight),
              );
              this.videoHeight = minVideoHeight;
            }
          }
        }
      } else {
        if (scrollCtr.offset != 0) {
          isExpanding = true;
          animationController.forward(from: 1 - scrollCtr.offset / videoHeight);
        }
      }
    } catch (_) {}
  }

  void scrollListener() {
    if (scrollCtr.hasClients) {
      if (scrollCtr.offset == 0) {
        scrollRatio.value = 0;
      } else {
        double offset = scrollCtr.offset - (videoHeight - minVideoHeight);
        if (offset > 0) {
          scrollRatio.value = clampDouble(
            DoubleExt(offset).toPrecision(2) /
                DoubleExt(minVideoHeight - kToolbarHeight).toPrecision(2),
            0.0,
            1.0,
          );
        } else {
          scrollRatio.value = 0;
        }
      }
    }
  }

  /// 离线视频：从播放器获取实际视频尺寸并更新竖屏状态
  void _updateVerticalStateFromPlayer() {
    try {
      final state = plPlayerController.videoController?.player.state;
      final actualWidth = state?.width;
      final actualHeight = state?.height;
      debugPrint(
        '[VideoDetailController] _updateVerticalStateFromPlayer: actualWidth=$actualWidth, actualHeight=$actualHeight',
      );
      debugPrint(
        '[VideoDetailController] firstVideo: width=${firstVideo.width}, height=${firstVideo.height}',
      );
      debugPrint(
        '[VideoDetailController] isVertical.value=${isVertical.value}, plPlayerController.isVertical=${plPlayerController.isVertical}',
      );
      if (actualWidth != null &&
          actualHeight != null &&
          actualWidth > 0 &&
          actualHeight > 0) {
        final actualIsVertical = actualWidth < actualHeight;
        debugPrint(
          '[VideoDetailController] actualIsVertical=$actualIsVertical',
        );
        // 更新 VideoDetailController 的状态
        if (actualIsVertical != isVertical.value) {
          debugPrint(
            '[VideoDetailController] Updating isVertical from ${isVertical.value} to $actualIsVertical',
          );
          isVertical.value = actualIsVertical;
          // 更新视频高度（但不要让它再改变 isVertical）
          setVideoHeight();
        }
        // 始终同步更新播放器控制器的竖屏状态（确保全屏方向正确）
        if (actualIsVertical != plPlayerController.isVertical) {
          debugPrint(
            '[VideoDetailController] Syncing plPlayerController.isVertical to $actualIsVertical',
          );
          plPlayerController.updateVerticalState(actualIsVertical);
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('_updateVerticalStateFromPlayer error: $e');
    }
  }

  /// 监听视频尺寸变化，用于离线视频检测竖屏状态
  void _listenVideoSizeForVerticalState() {
    // 取消之前的订阅
    _widthSubscription?.cancel();
    _heightSubscription?.cancel();

    final player = plPlayerController.videoController?.player;
    if (player == null) {
      debugPrint(
        '[VideoDetailController] _listenVideoSizeForVerticalState: player is null',
      );
      return;
    }

    debugPrint(
      '[VideoDetailController] _listenVideoSizeForVerticalState: setting up listeners',
    );

    // 监听宽度变化
    _widthSubscription = player.stream.width.listen((width) {
      debugPrint('[VideoDetailController] width changed: $width');
      if (width != null && width > 0) {
        _updateVerticalStateFromPlayer();
      }
    });

    // 监听高度变化
    _heightSubscription = player.stream.height.listen((height) {
      debugPrint('[VideoDetailController] height changed: $height');
      if (height != null && height > 0) {
        _updateVerticalStateFromPlayer();
      }
    });
  }

  void _cancelVideoSizeSubscriptions() {
    _widthSubscription?.cancel();
    _widthSubscription = null;
    _heightSubscription?.cancel();
    _heightSubscription = null;
  }

  bool imageview = false;

  final isLoginVideo = Accounts.get(AccountType.video).isLogin;

  late final watchProgress = GStorage.watchProgress;
  void cacheLocalProgress() {
    if (plPlayerController.playerStatus.completed) {
      watchProgress.put(cid.value.toString(), entry.totalTimeMilli);
    } else if (playedTime case final playedTime?) {
      watchProgress.put(cid.value.toString(), playedTime.inMilliseconds);
    }
  }

  void initFileSource(BiliDownloadEntryInfo entry, {bool isInit = true}) {
    this.entry = entry;
    firstVideo = VideoItem(
      quality: VideoQuality.fromCode(entry.preferedVideoQuality),
      width: entry.ep?.width ?? entry.pageData?.width ?? 1,
      height: entry.ep?.height ?? entry.pageData?.height ?? 1,
    );
    if (watchProgress.get(cid.value.toString()) case final int progress?) {
      if (progress >= entry.totalTimeMilli - 400) {
        defaultST = Duration.zero;
      } else {
        defaultST = Duration(milliseconds: progress);
      }
    } else {
      defaultST = Duration.zero;
    }
    data = PlayUrlModel(timeLength: entry.totalTimeMilli);
    if (isInit) {
      Future.delayed(const Duration(milliseconds: 120), setVideoHeight);
    } else {
      setVideoHeight();
    }
  }

  @override
  void onInit() {
    super.onInit();
    args = Get.arguments;
    videoType = args['videoType'];
    if (videoType == VideoType.pgc) {
      if (!isLoginVideo) {
        _actualVideoType = VideoType.ugc;
      }
    } else if (args['pgcApi'] == true) {
      _actualVideoType = VideoType.pgc;
    }

    bvid = args['bvid'];
    aid = args['aid'];
    cid = RxInt(args['cid']);
    epId = args['epId'];
    seasonId = args['seasonId'];
    pgcType = args['pgcType'];
    heroTag = args['heroTag'];
    cover = RxString(args['cover'] ?? '');

    sourceType = args['sourceType'] ?? SourceType.normal;
    // 离线列表播放：需要走在线详情/评论逻辑，因此不能被视为纯 file source。
    isFileSource = sourceType == SourceType.file && !_isOfflineListPlayAll;
    // 支持通过 arguments 显式开启列表播放（用于离线列表 -> 在线数据 + 本地播放的混合模式）。
    isPlayAll =
        args['isPlayAll'] == true ||
        (sourceType != SourceType.normal && !isFileSource);

    if (isFileSource) {
      // 尝试从 args 获取 entry，如果为 null 则从下载服务中查找
      BiliDownloadEntryInfo? entryArg;
      final rawEntry = args['entry'];
      if (rawEntry is BiliDownloadEntryInfo) {
        entryArg = rawEntry;
      } else if (rawEntry is Map<String, dynamic>) {
        // 处理序列化传递的 entry（在已打开的窗口中切换视频时）
        try {
          entryArg = BiliDownloadEntryInfo.fromJson(rawEntry);
        } catch (_) {}
      }

      if (entryArg == null && Get.isRegistered<DownloadService>()) {
        // 从下载服务中通过 cid 查找 entry
        final downloadService = Get.find<DownloadService>();
        entryArg = downloadService.downloadList.firstWhereOrNull(
          (e) => e.cid == cid.value,
        );
      }
      if (entryArg != null) {
        initFileSource(entryArg);
      } else {
        // 如果仍然找不到 entry，则回退到列表播放模式
        isFileSource = false;
        isPlayAll = true;
        watchLaterTitle = '离线缓存';
        getMediaList();
      }
    } else if (isPlayAll) {
      watchLaterTitle = _isOfflineListPlayAll
          ? '离线缓存'
          : (args['favTitle'] ?? '播放列表');
      _mediaDesc = args['desc'] ?? (_isOfflineListPlayAll ? true : false);
      getMediaList();
    }

    tabCtr = TabController(
      length: 2,
      vsync: this,
      initialIndex: Pref.defaultShowComment ? 1 : 0,
    );
  }

  Future<void> getMediaList({
    bool isReverse = false,
    bool isLoadPrevious = false,
  }) async {
    if (_isOfflineListPlayAll) {
      if (isLoadPrevious) {
        return;
      }
      await _buildOfflineMediaList(isReverse: isReverse);
      return;
    }
    final count = args['count'];
    if (!isReverse && count != null && mediaList.length >= count) {
      return;
    }
    final res = await UserHttp.getMediaList(
      type: args['mediaType'] ?? sourceType.mediaType,
      bizId: args['mediaId'] ?? -1,
      ps: 20,
      direction: isLoadPrevious ? true : false,
      oid: isReverse
          ? null
          : mediaList.isEmpty
          ? args['isContinuePlaying'] == true
                ? args['oid']
                : null
          : isLoadPrevious
          ? mediaList.first.aid
          : mediaList.last.aid,
      otype: isReverse
          ? null
          : mediaList.isEmpty
          ? null
          : isLoadPrevious
          ? mediaList.first.type
          : mediaList.last.type,
      desc: _mediaDesc,
      sortField: args['sortField'] ?? 1,
      withCurrent: mediaList.isEmpty && args['isContinuePlaying'] == true
          ? true
          : false,
    );
    if (res case Success(:final response)) {
      if (response.mediaList.isNotEmpty) {
        if (isReverse) {
          mediaList.value = response.mediaList;
          for (final item in mediaList) {
            if (item.cid != null) {
              try {
                Get.find<UgcIntroController>(
                  tag: heroTag,
                ).onChangeEpisode(item);
              } catch (_) {}
              break;
            }
          }
        } else if (isLoadPrevious) {
          mediaList.insertAll(0, response.mediaList);
        } else {
          mediaList.addAll(response.mediaList);
        }
      }
    } else {
      res.toast();
    }
  }

  // 稍后再看面板展开
  void showMediaListPanel(BuildContext context) {
    if (mediaList.isNotEmpty) {
      Widget panel() => MediaListPanel(
        mediaList: mediaList,
        onChangeEpisode: (episode) {
          try {
            Get.find<UgcIntroController>(tag: heroTag).onChangeEpisode(episode);
          } catch (_) {}
        },
        panelTitle: watchLaterTitle,
        bvid: () {
          // 访问 cid.value 使 Obx 能够监听到视频切换
          cid.value;
          return bvid;
        },
        count: _mediaListCountOverride ?? args['count'],
        loadMoreMedia: _isOfflineListPlayAll
            ? _loadOfflineMoreMedia
            : getMediaList,
        desc: _mediaDesc,
        onReverse: () {
          _mediaDesc = !_mediaDesc;
          getMediaList(isReverse: true);
        },
        loadPrevious: _isOfflineListPlayAll
            ? null
            : (args['isContinuePlaying'] == true
                  ? () => getMediaList(isLoadPrevious: true)
                  : null),
        onDelete:
            sourceType == SourceType.watchLater ||
                (sourceType == SourceType.fav && args['isOwner'] == true)
            ? (item, index) async {
                if (sourceType == SourceType.watchLater) {
                  final res = await UserHttp.toViewDel(
                    aids: item.aid.toString(),
                  );
                  if (res.isSuccess) {
                    mediaList.removeAt(index);
                  }
                } else {
                  final res = await FavHttp.favVideo(
                    resources: '${item.aid}:${item.type}',
                    delIds: '${args['mediaId']}',
                  );
                  if (res.isSuccess) {
                    mediaList.removeAt(index);
                    SmartDialog.showToast('取消收藏');
                  } else {
                    res.toast();
                  }
                }
              }
            : null,
      );
      if (plPlayerController.isFullScreen.value || showVideoSheet) {
        PageUtils.showVideoBottomSheet(
          context,
          child: plPlayerController.darkVideoPage && MyApp.darkThemeData != null
              ? Theme(
                  data: MyApp.darkThemeData!,
                  child: panel(),
                )
              : panel(),
          isFullScreen: () => plPlayerController.isFullScreen.value,
        );
      } else {
        childKey.currentState?.showBottomSheet(
          backgroundColor: Colors.transparent,
          constraints: const BoxConstraints(),
          (context) => panel(),
        );
      }
    } else {
      getMediaList();
    }
  }

  Future<void> _loadOfflineMoreMedia({
    bool isReverse = false,
    bool isLoadPrevious = false,
  }) async {
    // 离线列表播放不分页；仅用于适配 MediaListPanel 的 loadMore 回调签名。
    if (isReverse) {
      await getMediaList(isReverse: true);
    }
  }

  Future<void> _buildOfflineMediaList({
    bool isReverse = false,
  }) async {
    final downloadService = Get.find<DownloadService>();
    await downloadService.waitForInitialization;

    final String? pageId = args['offlinePageId'] as String?;
    // 构建离线播放队列顺序：
    // - 同一页面/分组内按 sortKey 正序（与离线缓存详情页一致）
    // - 若未指定 pageId，则按下载页分组出现顺序依次展开（更接近离线缓存页的感知顺序）
    final List<BiliDownloadEntryInfo> flattened;
    if (pageId != null && pageId.isNotEmpty) {
      final list =
          downloadService.downloadList.where((e) => e.pageId == pageId).toList()
            ..sort((a, b) => a.sortKey.compareTo(b.sortKey));
      flattened = list;
    } else {
      final order = <String>[];
      final grouped = <String, List<BiliDownloadEntryInfo>>{};
      for (final e in downloadService.downloadList) {
        final pid = e.pageId;
        final _ = grouped.putIfAbsent(pid, () {
          order.add(pid);
          return <BiliDownloadEntryInfo>[];
        })..add(e);
      }
      final out = <BiliDownloadEntryInfo>[];
      for (final pid in order) {
        final bucket = grouped[pid];
        if (bucket == null || bucket.isEmpty) continue;
        bucket.sort((a, b) => a.sortKey.compareTo(b.sortKey));
        out.addAll(bucket);
      }
      flattened = out;
    }

    // desc=true 视为“顺序播放”，false 为倒序
    final sorted = _mediaDesc ? flattened : flattened.reversed.toList();
    final items = sorted
        .map((e) {
          final int? localCid = e.source?.cid ?? e.pageData?.cid;
          if (localCid == null) {
            return null;
          }
          return MediaListItemModel(
            aid: e.avid,
            bvid: e.bvid,
            cover: e.cover,
            title: e.showTitle,
            // MediaListPanel 内部仅允许 type==2 的条目点击播放
            type: 2,
            duration: e.totalTimeMilli ~/ 1000,
            upper: Owner(name: e.ownerName ?? ''),
            cntInfo: CntInfo(play: 0, danmaku: e.danmakuCount),
            pages: [
              media_list.Page(
                id: localCid,
                title: e.showTitle,
                duration: e.totalTimeMilli ~/ 1000,
              ),
            ],
          );
        })
        .whereType<MediaListItemModel>()
        .toList();

    _mediaListCountOverride = items.length;
    if (items.isNotEmpty) {
      mediaList.value = items;
      if (isReverse) {
        for (var item in mediaList) {
          if (item.cid != null) {
            try {
              Get.find<UgcIntroController>(
                tag: heroTag,
              ).onChangeEpisode(item);
            } catch (_) {}
            break;
          }
        }
      }
    }
  }

  bool isPortrait = true;

  bool get horizontalScreen => plPlayerController.horizontalScreen;

  bool get showVideoSheet =>
      (!horizontalScreen && !isPortrait) || plPlayerController.isDesktopPip;

  late final _isBlock = isUgc || !plPlayerController.enablePgcSkip;
  int? _lastPos;
  late final List<PostSegmentModel> postList = [];
  late final List<SegmentModel> segmentList = <SegmentModel>[];
  late final RxList<Segment> segmentProgressList = <Segment>[].obs;

  Color _getColor(SegmentType segment) =>
      plPlayerController.blockColor[segment.index];
  late RxString videoLabel = ''.obs;

  Timer? skipTimer;
  late final listKey = GlobalKey<AnimatedListState>();
  late final List listData = [];

  void _vote(String uuid, int type) {
    SponsorBlock.voteOnSponsorTime(
      uuid: uuid,
      type: type,
    ).then((i) => SmartDialog.showToast(i.isSuccess ? '投票成功' : '投票失败: $i'));
  }

  void _showCategoryDialog(BuildContext context, SegmentModel segment) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        clipBehavior: Clip.hardEdge,
        contentPadding: const EdgeInsets.fromLTRB(0, 10, 0, 10),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: SegmentType.values
                .map(
                  (item) => ListTile(
                    dense: true,
                    onTap: () {
                      Get.back();
                      SponsorBlock.voteOnSponsorTime(
                        uuid: segment.UUID,
                        category: item,
                      ).then((i) {
                        SmartDialog.showToast(
                          '类别更改${i.isSuccess ? '成功' : '失败: $i'}',
                        );
                      });
                    },
                    title: Text.rich(
                      TextSpan(
                        children: [
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Container(
                              height: 10,
                              width: 10,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _getColor(item),
                              ),
                            ),
                            style: const TextStyle(fontSize: 14, height: 1),
                          ),
                          TextSpan(
                            text: ' ${item.title}',
                            style: const TextStyle(fontSize: 14, height: 1),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }

  void _showVoteDialog(BuildContext context, SegmentModel segment) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        clipBehavior: Clip.hardEdge,
        contentPadding: const EdgeInsets.fromLTRB(0, 10, 0, 10),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                dense: true,
                title: const Text(
                  '赞成票',
                  style: TextStyle(fontSize: 14),
                ),
                onTap: () {
                  Get.back();
                  _vote(segment.UUID, 1);
                },
              ),
              ListTile(
                dense: true,
                title: const Text(
                  '反对票',
                  style: TextStyle(fontSize: 14),
                ),
                onTap: () {
                  Get.back();
                  _vote(segment.UUID, 0);
                },
              ),
              ListTile(
                dense: true,
                title: const Text(
                  '更改类别',
                  style: TextStyle(fontSize: 14),
                ),
                onTap: () {
                  Get.back();
                  _showCategoryDialog(context, segment);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showSBDetail(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        clipBehavior: Clip.hardEdge,
        contentPadding: const EdgeInsets.fromLTRB(0, 10, 0, 10),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: segmentList
                .map(
                  (item) => ListTile(
                    onTap: () {
                      Get.back();
                      if (_isBlock) {
                        _showVoteDialog(context, item);
                      }
                    },
                    dense: true,
                    title: Text.rich(
                      TextSpan(
                        children: [
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Container(
                              height: 10,
                              width: 10,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _getColor(item.segmentType),
                              ),
                            ),
                            style: const TextStyle(fontSize: 14, height: 1),
                          ),
                          TextSpan(
                            text: ' ${item.segmentType.title}',
                            style: const TextStyle(fontSize: 14, height: 1),
                          ),
                        ],
                      ),
                    ),
                    contentPadding: const EdgeInsets.only(left: 16, right: 8),
                    subtitle: Text(
                      '${DurationUtils.formatDuration(item.segment.first / 1000)} 至 ${DurationUtils.formatDuration(item.segment.second / 1000)}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          item.skipType.label,
                          style: const TextStyle(fontSize: 13),
                        ),
                        if (item.segment.second != 0)
                          SizedBox(
                            width: 36,
                            height: 36,
                            child: IconButton(
                              tooltip: item.skipType == SkipType.showOnly
                                  ? '跳至此片段'
                                  : '跳过此片段',
                              onPressed: () {
                                Get.back();
                                onSkip(
                                  item,
                                  isSkip: item.skipType != SkipType.showOnly,
                                  isSeek: false,
                                );
                              },
                              style: IconButton.styleFrom(
                                padding: EdgeInsets.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              icon: Icon(
                                item.skipType == SkipType.showOnly
                                    ? Icons.my_location
                                    : MdiIcons.debugStepOver,
                                size: 18,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.7),
                              ),
                            ),
                          )
                        else
                          const SizedBox(width: 10),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }

  void _showBlockToast(String msg) {
    SmartDialog.showToast(
      msg,
      alignment: plPlayerController.isFullScreen.value
          ? const Alignment(0, 0.7)
          : null,
    );
  }

  Future<void> _querySponsorBlock() async {
    positionSubscription?.cancel();
    positionSubscription = null;
    videoLabel.value = '';
    segmentList.clear();
    segmentProgressList.clear();

    final result = await SponsorBlock.getSkipSegments(
      bvid: bvid,
      cid: cid.value,
    );
    switch (result) {
      case Success<List<SegmentItemModel>>(:final response):
        handleSBData(response);
      case Error(:final code) when code != 404:
        if (kDebugMode) {
          result.toast();
        }
      default:
    }
  }

  /// 离线播放时检查网络后再查询空降助手
  Future<void> _querySponsorBlockIfOnline() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      if (!connectivityResult.contains(ConnectivityResult.none)) {
        _querySponsorBlock();
      }
    } catch (_) {}
  }

  Future<void> handleSBData(List<SegmentItemModel> list) async {
    if (list.isNotEmpty) {
      try {
        Future? future;
        final duration = list.first.videoDuration ?? data.timeLength!;
        // segmentList
        segmentList.addAll(
          list
              .where(
                (item) =>
                    plPlayerController.enableList.contains(item.category) &&
                    item.segment[1] >= item.segment[0],
              )
              .map(
                (item) {
                  final segmentType = SegmentType.values.byName(item.category);
                  if (item.segment[0] == 0 && item.segment[1] == 0) {
                    videoLabel.value +=
                        '${videoLabel.value.isNotEmpty ? '/' : ''}${segmentType.title}';
                  }
                  SkipType skipType;
                  if (_isBlock) {
                    skipType = plPlayerController
                        .blockSettings[segmentType.index]
                        .second;
                    if (skipType != SkipType.showOnly) {
                      if (item.segment[1] == item.segment[0] ||
                          item.segment[1] - item.segment[0] <
                              plPlayerController.blockLimit) {
                        skipType = SkipType.showOnly;
                      }
                    }
                  } else {
                    skipType = Pref.pgcSkipType;
                  }

                  final segmentModel = SegmentModel(
                    UUID: item.uuid,
                    segmentType: segmentType,
                    segment: Pair(
                      first: item.segment[0],
                      second: item.segment[1],
                    ),
                    skipType: skipType,
                  );

                  if (positionSubscription == null &&
                      autoPlay.value &&
                      plPlayerController.videoPlayerController != null) {
                    final currPost =
                        defaultST?.inMilliseconds ??
                        plPlayerController.position.value.inMilliseconds;

                    if (currPost >= segmentModel.segment.first &&
                        currPost < segmentModel.segment.second) {
                      _lastPos = currPost;

                      switch (segmentModel.skipType) {
                        case SkipType.alwaysSkip:
                        case SkipType.skipOnce:
                          segmentModel.hasSkipped = true;
                          final videoPlayerController =
                              plPlayerController.videoPlayerController!;
                          if (videoPlayerController.state.playing) {
                            future = onSkip(
                              segmentModel,
                            );
                          } else {
                            videoPlayerController.stream.playing.firstWhere((
                              e,
                            ) {
                              if (e) {
                                future = onSkip(
                                  segmentModel,
                                );
                                return true;
                              }
                              return false;
                            });
                          }

                          break;
                        case SkipType.skipManually:
                          onAddItem(segmentModel);
                          break;
                        default:
                          break;
                      }
                    }
                  }

                  return segmentModel;
                },
              ),
        );

        // _segmentProgressList
        segmentProgressList.addAll(
          segmentList.map((e) {
            double start = (e.segment.first / duration).clamp(0.0, 1.0);
            double end = (e.segment.second / duration).clamp(0.0, 1.0);
            return Segment(
              start: start,
              end: end,
              color: _getColor(e.segmentType),
            );
          }),
        );

        if (positionSubscription == null &&
            (autoPlay.value || plPlayerController.preInitPlayer)) {
          await future;
          initSkip();
        }
      } catch (e) {
        if (kDebugMode) debugPrint('failed to parse sponsorblock: $e');
      }
    }
  }

  void initSkip() {
    if (isClosed) return;
    if (segmentList.isNotEmpty) {
      positionSubscription?.cancel();
      positionSubscription = plPlayerController
          .videoPlayerController
          ?.stream
          .position
          .listen((position) {
            int currentPos = position.inSeconds;
            if (currentPos != _lastPos) {
              _lastPos = currentPos;
              final msPos = currentPos * 1000;
              for (SegmentModel item in segmentList) {
                // if (kDebugMode) {
                //   debugPrint(
                //       '${position.inSeconds},,${item.segment.first},,${item.segment.second},,${item.skipType.name},,${item.hasSkipped}');
                // }
                if (msPos <= item.segment.first &&
                    item.segment.first <= msPos + 1000) {
                  switch (item.skipType) {
                    case SkipType.alwaysSkip:
                      onSkip(item, isSeek: false);
                      break;
                    case SkipType.skipOnce:
                      if (!item.hasSkipped) {
                        item.hasSkipped = true;
                        onSkip(item, isSeek: false);
                      }
                      break;
                    case SkipType.skipManually:
                      onAddItem(item);
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
  }

  void onAddItem(dynamic item) {
    if (listData.contains(item)) return;
    listData.insert(0, item);
    listKey.currentState?.insertItem(0);
    skipTimer ??= Timer.periodic(const Duration(seconds: 4), (_) {
      if (listData.isNotEmpty) {
        onRemoveItem(listData.length - 1, listData.last);
      }
    });
  }

  void cancelSkipTimer() {
    skipTimer?.cancel();
    skipTimer = null;
  }

  void onRemoveItem(int index, item) {
    EasyThrottle.throttle(
      'onRemoveItem',
      const Duration(milliseconds: 500),
      () {
        try {
          listData.removeAt(index);
          if (listData.isEmpty) {
            cancelSkipTimer();
          }
          listKey.currentState?.removeItem(
            index,
            (context, animation) => buildItem(item, animation),
          );
        } catch (_) {}
      },
    );
  }

  Widget buildItem(dynamic item, Animation<double> animation) {
    final theme = Get.theme;
    return Align(
      alignment: Alignment.centerLeft,
      child: SlideTransition(
        position: animation.drive(
          Tween<Offset>(
            begin: const Offset(-1.0, 0.0),
            end: Offset.zero,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: GestureDetector(
            onHorizontalDragUpdate: (DragUpdateDetails details) {
              if (details.delta.dx < 0) {
                onRemoveItem(listData.indexOf(item), item);
              }
            },
            child: SearchText(
              bgColor: theme.colorScheme.secondaryContainer.withValues(
                alpha: 0.8,
              ),
              textColor: theme.colorScheme.onSecondaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              fontSize: 14,
              text: item is SegmentModel
                  ? '跳过: ${item.segmentType.shortTitle}'
                  : '上次看到第${item + 1}P，点击跳转',
              onTap: (_) {
                if (item is int) {
                  try {
                    UgcIntroController ugcIntroController =
                        Get.find<UgcIntroController>(tag: heroTag);
                    Part part =
                        ugcIntroController.videoDetail.value.pages![item];
                    ugcIntroController.onChangeEpisode(part);
                    SmartDialog.showToast('已跳至第${item + 1}P');
                  } catch (e) {
                    if (kDebugMode) debugPrint('$e');
                    SmartDialog.showToast('跳转失败');
                  }
                  onRemoveItem(listData.indexOf(item), item);
                } else if (item is SegmentModel) {
                  onSkip(item, isSeek: false);
                  onRemoveItem(listData.indexOf(item), item);
                }
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> onSkip(
    SegmentModel item, {
    bool isSkip = true,
    bool isSeek = true,
  }) async {
    try {
      await plPlayerController.seekTo(
        Duration(milliseconds: item.segment.second),
        isSeek: isSeek,
      );
      if (isSkip) {
        if (autoPlay.value && Pref.blockToast) {
          _showBlockToast('已跳过${item.segmentType.shortTitle}片段');
        }
        if (_isBlock && Pref.blockTrack) {
          SponsorBlock.viewedVideoSponsorTime(item.UUID);
        }
      } else {
        _showBlockToast('已跳至${item.segmentType.shortTitle}');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('failed to skip: $e');
      if (isSkip) {
        _showBlockToast('${item.segmentType.shortTitle}片段跳过失败');
      } else {
        _showBlockToast('跳转失败');
      }
    }
  }

  ({int mode, int fontSize, Color color})? dmConfig;
  String? savedDanmaku;

  /// 发送弹幕
  Future<void> showShootDanmakuSheet() async {
    if (plPlayerController.dmState.contains(cid.value)) {
      SmartDialog.showToast('UP主已关闭弹幕');
      return;
    }
    final isPlaying = autoPlay.value && plPlayerController.playerStatus.playing;
    if (isPlaying) {
      await plPlayerController.pause();
    }
    await Get.key.currentState!.push(
      PublishRoute(
        pageBuilder: (buildContext, animation, secondaryAnimation) {
          return SendDanmakuPanel(
            cid: cid.value,
            bvid: bvid,
            progress: plPlayerController.position.value.inMilliseconds,
            initialValue: savedDanmaku,
            onSave: (danmaku) => savedDanmaku = danmaku,
            onSuccess: (danmakuModel) {
              savedDanmaku = null;
              plPlayerController.danmakuController?.addDanmaku(danmakuModel);
            },
            darkVideoPage: plPlayerController.darkVideoPage,
            dmConfig: dmConfig,
            onSaveDmConfig: (dmConfig) => this.dmConfig = dmConfig,
          );
        },
      ),
    );
    if (isPlaying) {
      plPlayerController.play();
    }
  }

  VideoItem findVideoByQa(int qa) {
    /// 根据currentVideoQa和currentDecodeFormats 重新设置videoUrl
    final videoList = data.dash!.video!.where((i) => i.id == qa).toList();

    final currentDecodeFormats = this.currentDecodeFormats.codes;
    final defaultDecodeFormats = VideoDecodeFormatType.fromString(
      cacheDecode,
    ).codes;
    final secondDecodeFormats = VideoDecodeFormatType.fromString(
      cacheSecondDecode,
    ).codes;

    VideoItem? video;
    for (final i in videoList) {
      final codec = i.codecs!;
      if (currentDecodeFormats.any(codec.startsWith)) {
        video = i;
        break;
      } else if (defaultDecodeFormats.any(codec.startsWith)) {
        video = i;
      } else if (video == null && secondDecodeFormats.any(codec.startsWith)) {
        video = i;
      }
    }
    return video ?? videoList.first;
  }

  /// 更新画质、音质
  void updatePlayer() {
    final currentVideoQa = this.currentVideoQa.value;
    if (currentVideoQa == null) return;
    autoPlay.value = true;
    playedTime = plPlayerController.position.value;
    plPlayerController
      ..removeListeners()
      ..isBuffering.value = false
      ..buffered.value = Duration.zero;

    final video = findVideoByQa(currentVideoQa.code);
    if (firstVideo.codecs != video.codecs) {
      currentDecodeFormats = VideoDecodeFormatType.fromString(video.codecs!);
    }
    firstVideo = video;
    videoUrl = VideoUtils.getCdnUrl(firstVideo.playUrls);

    /// 根据currentAudioQa 重新设置audioUrl
    if (currentAudioQa != null) {
      final firstAudio = data.dash!.audio!.firstWhere(
        (i) => i.id == currentAudioQa!.code,
        orElse: () => data.dash!.audio!.first,
      );
      audioUrl = VideoUtils.getCdnUrl(firstAudio.playUrls, isAudio: true);
    }

    playerInit();
  }

  FutureOr<void> _initPlayerIfNeeded({
    BiliDownloadEntryInfo? localEntry,
  }) {
    // 后台播放模式下，无需检查 widget mounted 状态
    final isBackgroundPlayEnabled =
        plPlayerController.continuePlayInBackground.value;

    if (autoPlay.value ||
        isBackgroundPlayEnabled ||
        (plPlayerController.preInitPlayer && !plPlayerController.processing) &&
            (isFileSource
                ? true
                : videoPlayerKey.currentState?.mounted == true)) {
      return playerInit(localEntry: localEntry);
    }
  }

  Future<void> playerInit({
    String? video,
    String? audio,
    Duration? seekToTime,
    Duration? duration,
    bool? autoplay,
    Volume? volume,
    BiliDownloadEntryInfo? localEntry,
  }) async {
    final onlyPlayAudio = plPlayerController.onlyPlayAudio.value;

    final bool playFromLocal = localEntry != null;
    final BiliDownloadEntryInfo? effectiveLocalEntry = playFromLocal
        ? localEntry
        : (isFileSource ? entry : null);

    // 保存传入的本地缓存条目（如果有的话）
    if (localEntry != null) {
      currentLocalEntry = localEntry;
    }

    // 当 playFromLocal=true 时，只替换播放数据源为本地文件，不改变页面的 isFileSource 判定
    // （以避免影响列表播放的在线简介/评论等逻辑）。
    final DataSourceType dataSourceType = (playFromLocal || isFileSource)
        ? DataSourceType.file
        : DataSourceType.network;

    await plPlayerController.setDataSource(
      DataSource(
        videoSource: dataSourceType == DataSourceType.file
            ? null
            : onlyPlayAudio
            ? audio ?? audioUrl
            : video ?? videoUrl,
        audioSource: (dataSourceType == DataSourceType.file || onlyPlayAudio)
            ? null
            : audio ?? audioUrl,
        type: dataSourceType,
        httpHeaders: dataSourceType == DataSourceType.file
            ? null
            : {
                'user-agent': UaType.pc.ua,
                'referer': HttpString.baseUrl,
              },
      ),
      seekTo: seekToTime ?? defaultST ?? playedTime,
      duration:
          duration ??
          (effectiveLocalEntry != null
              ? Duration(milliseconds: effectiveLocalEntry.totalTimeMilli)
              : (data.timeLength == null
                    ? null
                    : Duration(milliseconds: data.timeLength!))),
      isVertical: isVertical.value,
      aid: aid,
      bvid: bvid,
      cid: cid.value,
      autoplay: autoplay ?? autoPlay.value,
      epid: isUgc ? null : epId,
      seasonId: isUgc ? null : seasonId,
      pgcType: isUgc ? null : pgcType,
      videoType: videoType,
      onInit: () {
        if (videoState.value is! Success) {
          videoState.value = const Success(null);
        }
        setSubtitle(vttSubtitlesIndex.value);
        // 离线视频：监听视频尺寸变化来更新竖屏状态
        // 因为此时视频尺寸可能还未解码完成，所以需要通过流监听
        if (dataSourceType == DataSourceType.file) {
          _listenVideoSizeForVerticalState();
        }
      },
      width: playFromLocal
          ? (effectiveLocalEntry?.ep?.width ??
                effectiveLocalEntry?.pageData?.width ??
                firstVideo.width)
          : firstVideo.width,
      height: playFromLocal
          ? (effectiveLocalEntry?.ep?.height ??
                effectiveLocalEntry?.pageData?.height ??
                firstVideo.height)
          : firstVideo.height,
      volume: volume ?? this.volume,
      dirPath: dataSourceType == DataSourceType.file
          ? (playFromLocal
                ? effectiveLocalEntry?.entryDirPath
                : args['dirPath'])
          : null,
      typeTag: dataSourceType == DataSourceType.file
          ? effectiveLocalEntry?.typeTag
          : null,
      mediaType: dataSourceType == DataSourceType.file
          ? effectiveLocalEntry?.mediaType
          : null,
    );

    if (isClosed) return;

    if (!isFileSource) {
      if (plPlayerController.enableBlock) {
        initSkip();
      }

      if (vttSubtitlesIndex.value == -1) {
        _queryPlayInfo();
      }

      if (plPlayerController.showDmChart && dmTrend.value == null) {
        _getDmTrend();
      }
    }

    defaultST = null;

    // 播放器初始化完成，重置视频切换标志
    _isSwitchingVideo = false;
  }

  bool isQuerying = false;

  final Rx<List<LanguageItem>?> languages = Rx<List<LanguageItem>?>(null);
  final Rx<String?> currLang = Rx<String?>(null);
  void setLanguage(String language) {
    if (currLang.value == language) return;
    if (!isLoginVideo) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    currLang.value = language;
    queryVideoUrl(defaultST: playedTime);
  }

  Volume? volume;

  // 视频链接
  Future<void> queryVideoUrl({
    Duration? defaultST,
    bool fromReset = false,
  }) async {
    if (isFileSource) {
      // 离线播放也支持空降助手（需要有网络）
      if (plPlayerController.enableSponsorBlock && _isBlock && !fromReset) {
        _querySponsorBlockIfOnline();
      }
      return _initPlayerIfNeeded();
    }

    if (isQuerying) {
      return;
    }
    isQuerying = true;

    // 在线播放：优先使用本地缓存条目作为播放器数据源。
    // 注意：只替换播放器数据源，不改变列表播放队列/切集/在线详情评论等逻辑。
    final bool forceLocalPlay = args['forceLocalPlay'] == true;
    final bool shouldTryLocal =
        forceLocalPlay || Pref.enableLocalPlayInOnlineList;
    BiliDownloadEntryInfo? localEntry;
    if (shouldTryLocal) {
      final passed = args['entry'];
      if (passed is BiliDownloadEntryInfo &&
          passed.isCompleted &&
          passed.cid == cid.value) {
        localEntry = passed;
      } else if (passed is Map<String, dynamic>) {
        // 处理序列化传递的 entry（在已打开的窗口中切换视频时）
        try {
          final entry = BiliDownloadEntryInfo.fromJson(passed);
          if (entry.isCompleted && entry.cid == cid.value) {
            localEntry = entry;
          }
        } catch (_) {}
      }

      localEntry ??= await _findLocalCompletedEntryByCid(cid.value);
    }
    // 保存找到的本地缓存条目，以便从其他页面返回时能继续使用
    currentLocalEntry = localEntry;
    if (plPlayerController.enableSponsorBlock && _isBlock && !fromReset) {
      // 空降助手请求异步进行，不阻止视频加载
      // SponsorBlock请求超时或失败不应该阻塞主流程
      _querySponsorBlock().onError((error, stackTrace) {
        if (kDebugMode) debugPrint('SponsorBlock query failed: $error');
        return null;
      });
    }
    if (plPlayerController.cacheVideoQa == null) {
      final isWiFi = await Utils.isWiFi;
      plPlayerController
        ..cacheVideoQa = isWiFi
            ? Pref.defaultVideoQa
            : Pref.defaultVideoQaCellular
        ..cacheAudioQa = isWiFi
            ? Pref.defaultAudioQa
            : Pref.defaultAudioQaCellular;
    }

    final result = await VideoHttp.videoUrl(
      cid: cid.value,
      bvid: bvid,
      epid: epId,
      seasonId: seasonId,
      tryLook: plPlayerController.tryLook,
      videoType: _actualVideoType ?? videoType,
      language: currLang.value,
    );

    if (result case Success(:final response)) {
      data = response;

      languages.value = data.language?.items;
      currLang.value = data.curLanguage;

      volume = data.volume;

      final progress = args['progress'];
      if (progress != null) {
        this.defaultST = Duration(milliseconds: progress);
        args['progress'] = null;
      } else {
        this.defaultST =
            defaultST ??
            (data.lastPlayTime == null
                ? Duration.zero
                : Duration(milliseconds: data.lastPlayTime!));
      }

      if (!isUgc && !fromReset && plPlayerController.enablePgcSkip) {
        if (data.clipInfoList case final clipInfoList?) {
          positionSubscription?.cancel();
          positionSubscription = null;
          handleSBData(clipInfoList);
        }
      }

      if (data.acceptDesc?.contains('试看') == true) {
        SmartDialog.showToast(
          '该视频为专属视频，仅提供试看',
          displayTime: const Duration(seconds: 3),
        );
      }
      if (data.dash == null && data.durl != null) {
        final first = data.durl!.first;
        videoUrl = VideoUtils.getCdnUrl(first.playUrls);
        audioUrl = '';

        // 实际为FLV/MP4格式，但已被淘汰，这里仅做兜底处理
        final videoQuality = VideoQuality.fromCode(data.quality!);
        firstVideo = VideoItem(
          id: data.quality!,
          baseUrl: videoUrl,
          codecs: 'avc1',
          quality: videoQuality,
        );
        setVideoHeight();
        currentDecodeFormats = VideoDecodeFormatType.fromString('avc1');
        currentVideoQa.value = videoQuality;
        await _initPlayerIfNeeded(localEntry: localEntry);
        isQuerying = false;
        return;
      }
      if (data.dash == null) {
        SmartDialog.showToast('视频资源不存在');
        autoPlay.value = false;
        videoState.value = const Error('视频资源不存在');
        if (plPlayerController.isFullScreen.value) {
          plPlayerController.toggleFullScreen(false);
        }
        isQuerying = false;
        return;
      }
      final List<VideoItem> videoList = data.dash!.video!;
      // if (kDebugMode) debugPrint("allVideosList:${allVideosList}");
      // 当前可播放的最高质量视频
      final curHighestVideoQa = videoList.first.quality.code;
      // 预设的画质为null，则当前可用的最高质量
      int targetVideoQa = curHighestVideoQa;

      // 如果使用本地缓存播放，优先使用缓存的清晰度
      if (localEntry != null) {
        targetVideoQa = localEntry.preferedVideoQuality;
        if (kDebugMode) {
          debugPrint(
            '使用本地缓存播放，清晰度: ${VideoQuality.fromCode(targetVideoQa).desc}',
          );
        }
      } else if (data.acceptQuality?.isNotEmpty == true &&
          plPlayerController.cacheVideoQa! <= curHighestVideoQa) {
        // 如果预设的画质低于当前最高
        targetVideoQa = data.acceptQuality!.findClosestTarget(
          (e) => e <= plPlayerController.cacheVideoQa!,
          (a, b) => a > b ? a : b,
        );
      }
      currentVideoQa.value = VideoQuality.fromCode(targetVideoQa);

      /// 取出符合当前画质的videoList
      final List<VideoItem> videosList = videoList
          .where((e) => e.quality.code == targetVideoQa)
          .toList();

      /// 优先顺序 设置中指定解码格式 -> 当前可选的首个解码格式
      final List<FormatItem> supportFormats = data.supportFormats!;
      // 根据画质选编码格式
      final List<String> supportDecodeFormats = supportFormats
          .firstWhere(
            (e) => e.quality == targetVideoQa,
            orElse: () => supportFormats.first,
          )
          .codecs!;
      // 默认从设置中取AV1
      currentDecodeFormats = VideoDecodeFormatType.fromString(cacheDecode);
      VideoDecodeFormatType secondDecodeFormats =
          VideoDecodeFormatType.fromString(cacheSecondDecode);
      // 当前视频没有对应格式返回第一个
      int flag = 0;
      for (final e in supportDecodeFormats) {
        if (currentDecodeFormats.codes.any(e.startsWith)) {
          flag = 1;
          break;
        } else if (secondDecodeFormats.codes.any(e.startsWith)) {
          flag = 2;
        }
      }
      if (flag == 2) {
        currentDecodeFormats = secondDecodeFormats;
      } else if (flag == 0) {
        currentDecodeFormats = VideoDecodeFormatType.fromString(
          supportDecodeFormats.first,
        );
      }

      /// 取出符合当前解码格式的videoItem
      firstVideo = videosList.firstWhere(
        (e) => currentDecodeFormats.codes.any(e.codecs!.startsWith),
        orElse: () => videosList.first,
      );
      setVideoHeight();

      videoUrl = VideoUtils.getCdnUrl(firstVideo.playUrls);

      /// 优先顺序 设置中指定质量 -> 当前可选的最高质量
      AudioItem? firstAudio;
      final audioList = data.dash?.audio;
      if (audioList != null && audioList.isNotEmpty) {
        final List<int> audioIds = audioList.map((map) => map.id!).toList();
        int closestNumber = audioIds.findClosestTarget(
          (e) => e <= plPlayerController.cacheAudioQa,
          (a, b) => a > b ? a : b,
        );
        if (!audioIds.contains(plPlayerController.cacheAudioQa) &&
            audioIds.any((e) => e > plPlayerController.cacheAudioQa)) {
          closestNumber = AudioQuality.k192.code;
        }
        firstAudio = audioList.firstWhere(
          (e) => e.id == closestNumber,
          orElse: () => audioList.first,
        );
        audioUrl = VideoUtils.getCdnUrl(firstAudio.playUrls, isAudio: true);
        if (firstAudio.id case final int id?) {
          currentAudioQa = AudioQuality.fromCode(id);
        }
      } else {
        audioUrl = '';
      }
      await _initPlayerIfNeeded(localEntry: localEntry);
    } else {
      if (forceLocalPlay && localEntry != null) {
        // 在线 playurl 获取失败时，仍允许离线列表使用本地文件播放。
        autoPlay.value = true;
        await _initPlayerIfNeeded(localEntry: localEntry);
      } else {
        autoPlay.value = false;
        videoState.value = result..toast();
        if (plPlayerController.isFullScreen.value) {
          plPlayerController.toggleFullScreen(false);
        }
      }
    }
    isQuerying = false;
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

  void onBlock(BuildContext context) {
    if (postList.isEmpty) {
      postList.add(
        PostSegmentModel(
          segment: Pair(
            first: 0,
            second: plPlayerController.position.value.inMilliseconds / 1000,
          ),
          category: SegmentType.sponsor,
          actionType: ActionType.skip,
        ),
      );
    }
    if (plPlayerController.isFullScreen.value || showVideoSheet) {
      PageUtils.showVideoBottomSheet(
        context,
        child: plPlayerController.darkVideoPage && MyApp.darkThemeData != null
            ? Theme(
                data: MyApp.darkThemeData!,
                child: PostPanel(
                  enableSlide: false,
                  videoDetailController: this,
                  plPlayerController: plPlayerController,
                ),
              )
            : PostPanel(
                enableSlide: false,
                videoDetailController: this,
                plPlayerController: plPlayerController,
              ),
        isFullScreen: () => plPlayerController.isFullScreen.value,
      );
    } else {
      childKey.currentState?.showBottomSheet(
        backgroundColor: Colors.transparent,
        constraints: const BoxConstraints(),
        (context) => PostPanel(
          videoDetailController: this,
          plPlayerController: plPlayerController,
        ),
      );
    }
  }

  RxList<Subtitle> subtitles = RxList<Subtitle>();
  final Map<int, ({bool isData, String id})> vttSubtitles = {};
  late final RxInt vttSubtitlesIndex = (-1).obs;
  late final RxBool showVP = true.obs;
  late final RxList<ViewPointSegment> viewPointList = <ViewPointSegment>[].obs;

  // 设定字幕轨道
  Future<void> setSubtitle(int index) async {
    if (index <= 0) {
      await plPlayerController.videoPlayerController?.setSubtitleTrack(
        SubtitleTrack.no(),
      );
      vttSubtitlesIndex.value = index;
      return;
    }

    Future<void> setSub(({bool isData, String id}) subtitle) async {
      final sub = subtitles[index - 1];
      await plPlayerController.videoPlayerController?.setSubtitleTrack(
        SubtitleTrack(
          subtitle.id,
          sub.lanDoc,
          sub.lan,
          uri: !subtitle.isData,
          data: subtitle.isData,
        ),
      );
      vttSubtitlesIndex.value = index;
    }

    ({bool isData, String id})? subtitle = vttSubtitles[index - 1];
    if (subtitle != null) {
      await setSub(subtitle);
    } else {
      final result = await VideoHttp.vttSubtitles(
        subtitles[index - 1].subtitleUrl!,
      );
      if (!isClosed && result != null) {
        final subtitle = (isData: true, id: result);
        vttSubtitles[index - 1] = subtitle;
        await setSub(subtitle);
      }
    }
  }

  // interactive video
  int? graphVersion;
  EdgeInfoData? steinEdgeInfo;
  late final RxBool showSteinEdgeInfo = false.obs;

  Future<void> getSteinEdgeInfo([int? edgeId]) async {
    steinEdgeInfo = null;
    try {
      final res = await Request().get(
        '/x/stein/edgeinfo_v2',
        queryParameters: {
          'bvid': bvid,
          'graph_version': graphVersion,
          'edge_id': ?edgeId,
        },
      );
      if (res.data['code'] == 0) {
        steinEdgeInfo = EdgeInfoData.fromJson(res.data['data']);
      } else {
        if (kDebugMode) {
          debugPrint('getSteinEdgeInfo error: ${res.data['message']}');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('getSteinEdgeInfo: $e');
    }
  }

  late bool continuePlayingPart = Pref.continuePlayingPart;

  Future<void> _queryPlayInfo() async {
    vttSubtitles.clear();
    vttSubtitlesIndex.value = 0;
    if (plPlayerController.showViewPoints) {
      viewPointList.clear();
    }
    final res = await VideoHttp.playInfo(
      bvid: bvid,
      cid: cid.value,
      seasonId: seasonId,
      epId: epId,
    );
    if (res case Success(:final response)) {
      // interactive video
      if (isUgc && graphVersion == null) {
        try {
          final introCtr = Get.find<UgcIntroController>(tag: heroTag);
          if (introCtr.videoDetail.value.rights?.isSteinGate == 1) {
            graphVersion = response.interaction?.graphVersion;
            getSteinEdgeInfo();
          }
        } catch (e) {
          if (kDebugMode) debugPrint('handle stein: $e');
        }
      }

      if (isUgc && continuePlayingPart) {
        continuePlayingPart = false;
        try {
          UgcIntroController ugcIntroController = Get.find<UgcIntroController>(
            tag: heroTag,
          );
          if ((ugcIntroController.videoDetail.value.pages?.length ?? 0) > 1 &&
              response.lastPlayCid != null &&
              response.lastPlayCid != 0) {
            if (response.lastPlayCid != cid.value) {
              int index = ugcIntroController.videoDetail.value.pages!
                  .indexWhere((item) => item.cid == response.lastPlayCid);
              if (index != -1) {
                onAddItem(index);
              }
            }
          }
        } catch (_) {}
      }

      if (plPlayerController.showViewPoints &&
          response.viewPoints?.firstOrNull?.type == 2) {
        try {
          viewPointList.value = response.viewPoints!.map((item) {
            double start = (item.to! / (data.timeLength! / 1000)).clamp(
              0.0,
              1.0,
            );
            return ViewPointSegment(
              start: start,
              end: start,
              title: item.content,
              url: item.imgUrl,
              from: item.from,
              to: item.to,
            );
          }).toList();
        } catch (_) {}
      }

      if (response.subtitle?.subtitles?.isNotEmpty == true) {
        subtitles.value = response.subtitle!.subtitles!;

        final idx = switch (Pref.subtitlePreferenceV2) {
          SubtitlePrefType.off => 0,
          SubtitlePrefType.on => 1,
          SubtitlePrefType.withoutAi =>
            subtitles.first.lan.startsWith('ai') ? 0 : 1,
          SubtitlePrefType.auto =>
            !subtitles.first.lan.startsWith('ai') ||
                    (PlatformUtils.isMobile &&
                        (await FlutterVolumeController.getVolume() ?? 0.0) <=
                            0.0)
                ? 1
                : 0,
        };
        await setSubtitle(idx);
      }
    }
  }

  void updateMediaListHistory(int aid) {
    if (args['sortField'] != null) {
      VideoHttp.medialistHistory(
        desc: _mediaDesc ? 1 : 0,
        oid: aid,
        upperMid: args['mediaId'],
      );
    }
  }

  void makeHeartBeat() {
    if (plPlayerController.enableHeart &&
        !plPlayerController.playerStatus.completed &&
        playedTime != null) {
      try {
        plPlayerController.makeHeartBeat(
          data.timeLength != null
              ? (data.timeLength! - playedTime!.inMilliseconds).abs() <= 1000
                    ? -1
                    : playedTime!.inSeconds
              : playedTime!.inSeconds,
          type: HeartBeatType.status,
          isManual: true,
          aid: aid,
          bvid: bvid,
          cid: cid.value,
          epid: isUgc ? null : epId,
          seasonId: isUgc ? null : seasonId,
          pgcType: isUgc ? null : pgcType,
          videoType: videoType,
        );

        // 同步更新列表页面的进度
        if (sourceType != SourceType.normal) {
          // 立即捕获当前视频的 ID，避免异步时已切换视频
          final currentAid = aid;
          final currentBvid = bvid;
          final currentCid = cid.value;
          final currentDuration = data.timeLength ?? 0;
          final progressSeconds = playedTime!.inSeconds;

          if (kDebugMode) {
            debugPrint(
              '💓 心跳触发进度更新: sourceType=${sourceType.name}, bvid=$currentBvid, progress=${progressSeconds}s',
            );
          }

          _updateListProgress(
            progressSeconds,
            currentAid,
            currentBvid,
            currentCid,
            currentDuration,
          );
        }
      } catch (_) {}
    }
  }

  /// 在切换视频前保存当前视频的进度（确保旧视频进度被保存）
  void saveProgressBeforeChange() {
    if (sourceType == SourceType.normal ||
        plPlayerController.position.value == Duration.zero ||
        data.timeLength == null) {
      return;
    }

    try {
      final playedTime = plPlayerController.position.value;
      final currentAid = aid;
      final currentBvid = bvid;
      final currentCid = cid.value;
      final currentDuration = data.timeLength ?? 0;
      final progressSeconds = playedTime.inSeconds;

      if (kDebugMode) {
        debugPrint(
          '🔄 切换视频前保存进度: bvid=$currentBvid, progress=${progressSeconds}s',
        );
      }

      // 标记正在切换视频，在 playerInit 完成后会重置
      _isSwitchingVideo = true;

      _updateListProgressSync(
        progressSeconds,
        currentAid,
        currentBvid,
        currentCid,
        currentDuration,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('切换视频前保存进度失败: $e');
      }
    }
  }

  /// 更新列表页面中当前视频的播放进度（仅主窗口和移动端）
  void _updateListProgress(
    int progressSeconds,
    int videoAid,
    String videoBvid,
    int videoCid,
    int videoDuration,
  ) {
    // 仅在主窗口和移动端更新进度（不支持跨窗口同步）
    _updateListProgressSync(
      progressSeconds,
      videoAid,
      videoBvid,
      videoCid,
      videoDuration,
    );
  }

  /// 同步更新列表进度（本地执行）
  void _updateListProgressSync(
    int progressSeconds,
    int videoAid,
    String videoBvid,
    int videoCid,
    int videoDuration,
  ) {
    try {
      // 1. 更新 mediaList（播放列表）的进度
      _updateMediaListProgress(
        progressSeconds,
        videoAid,
        videoBvid,
        videoDuration,
      );

      // 2. 根据 sourceType 更新对应的列表页面
      switch (sourceType) {
        case SourceType.watchLater:
          _updateWatchLaterList(progressSeconds, videoAid, videoBvid);
          break;
        case SourceType.file:
          // 离线缓存：更新 GStorage.watchProgress
          _updateOfflineCacheProgress(progressSeconds, videoCid, videoDuration);
          break;
        case SourceType.archive:
        case SourceType.fav:
        case SourceType.playlist:
          // 收藏夹、合集等没有独立的进度字段，只更新 mediaList
          break;
        default:
          break;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('更新列表进度失败: $e');
      }
    }
  }

  /// 更新播放列表（mediaList）的进度百分比
  void _updateMediaListProgress(
    int progressSeconds,
    int videoAid,
    String videoBvid,
    int videoDuration,
  ) {
    try {
      // 使用 aid 和 bvid 双重匹配确保准确找到目标视频
      final targetItem = mediaList.firstWhereOrNull(
        (item) => item.aid == videoAid && item.bvid == videoBvid,
      );

      if (targetItem != null && videoDuration > 0) {
        final newProgressPercent = progressSeconds == -1
            ? 100.0 // 已完成
            : (progressSeconds / videoDuration * 100).clamp(0.0, 100.0);

        if ((targetItem.progressPercent ?? 0) != newProgressPercent) {
          targetItem.progressPercent = newProgressPercent;
          mediaList.refresh();
          if (kDebugMode) {
            debugPrint(
              '✅ 更新 mediaList 进度: aid=$videoAid, bvid=$videoBvid -> $newProgressPercent%',
            );
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('更新 mediaList 进度失败: $e');
      }
    }
  }

  /// 更新稍后再看列表的进度
  void _updateWatchLaterList(
    int progressSeconds,
    int videoAid,
    String videoBvid,
  ) {
    try {
      // 尝试获取稍后再看页面的 controller
      // tag 为 "0" (全部) 和 "2" (未看完)
      for (final tag in ['0', '2']) {
        if (!Get.isRegistered<LaterController>(tag: tag)) continue;

        final laterController = Get.find<LaterController>(tag: tag);
        if (laterController.loadingState.value.data case List list?) {
          // 查找当前播放的视频（使用 aid 和 bvid 双重匹配确保准确性）
          final targetItem = list.firstWhereOrNull(
            (item) => item.aid == videoAid && item.bvid == videoBvid,
          );

          if (targetItem != null) {
            // 更新进度（秒数格式）
            final newProgress = progressSeconds == -1
                ? -1 // 已完成标记
                : progressSeconds;

            if (targetItem.progress != newProgress) {
              targetItem.progress = newProgress;
              // 延迟到下一帧更新状态，避免在 widget tree 锁定时触发重建
              SchedulerBinding.instance.addPostFrameCallback((_) {
                // 再次确认该 item 仍然在列表中，避免在异步过程中列表已变化
                if (laterController.loadingState.value.data
                    case List currentList?) {
                  final stillExists = currentList.any(
                    (item) => item.aid == videoAid && item.bvid == videoBvid,
                  );
                  if (stillExists) {
                    laterController.loadingState.value = Success(
                      List.from(currentList),
                    );
                    if (kDebugMode) {
                      debugPrint(
                        '✅ 本地更新稍后再看进度: aid=$videoAid, bvid=$videoBvid -> ${newProgress}s',
                      );
                    }
                  } else {
                    if (kDebugMode) {
                      debugPrint(
                        '⚠️ 视频已不在列表中，跳过进度更新: aid=$videoAid, bvid=$videoBvid',
                      );
                    }
                  }
                }
              });
            }
          }
        }
      }
    } catch (e) {
      // 稍后再看页面未打开或其他错误，忽略
      if (kDebugMode) {
        debugPrint('更新稍后再看进度失败: $e');
      }
    }
  }

  /// 更新离线缓存的播放进度
  void _updateOfflineCacheProgress(
    int progressSeconds,
    int videoCid,
    int videoDuration,
  ) {
    try {
      // 计算进度（毫秒）
      final progressMilli = progressSeconds == -1
          ? videoDuration *
                1000 // 已完成
          : progressSeconds * 1000;

      // 保存到 GStorage.watchProgress
      watchProgress.put(videoCid.toString(), progressMilli);

      if (kDebugMode) {
        debugPrint('✅ 更新离线缓存进度: cid=$videoCid -> ${progressMilli}ms');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('更新离线缓存进度失败: $e');
      }
    }
  }

  @override
  void onClose() {
    // 在关闭前保存最后的进度（主窗口和移动端）
    // 注意：如果正在切换视频，跳过保存进度，因为：
    // 1. 旧视频的进度已经在 saveProgressBeforeChange() 中正确保存了
    // 2. 新视频还在加载中，播放器位置还是旧视频的值，保存会导致错误
    if (!_isSwitchingVideo &&
        sourceType != SourceType.normal &&
        plPlayerController.position.value != Duration.zero &&
        data.timeLength != null) {
      final playedTime = plPlayerController.position.value;
      final currentAid = aid;
      final currentBvid = bvid;
      final currentCid = cid.value;
      final currentDuration = data.timeLength ?? 0;
      final progressSeconds = playedTime.inSeconds;

      if (kDebugMode) {
        debugPrint(
          '🚪 窗口关闭，保存最后的进度: bvid=$currentBvid, progress=${progressSeconds}s',
        );
      }

      try {
        _updateListProgressSync(
          progressSeconds,
          currentAid,
          currentBvid,
          currentCid,
          currentDuration,
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('关闭时更新进度失败: $e');
        }
      }
    } else if (_isSwitchingVideo && kDebugMode) {
      debugPrint('🚪 窗口关闭，正在切换视频中，跳过保存进度（已在切换前保存）');
    }

    cancelSkipTimer();
    positionSubscription?.cancel();
    positionSubscription = null;
    cid.close();
    if (isFileSource) {
      cacheLocalProgress();
    }
    // 取消定时器和流订阅，防止后台耗电
    cancelSkipTimer();
    positionSubscription?.cancel();
    positionSubscription = null;
    _cancelVideoSizeSubscriptions();
    introScrollCtr?.dispose();
    introScrollCtr = null;
    tabCtr.dispose();
    _scrollCtr
      ?..removeListener(scrollListener)
      ..dispose();
    animController?.dispose();
    subtitles.clear();
    vttSubtitles.clear();
    super.onClose();
  }

  void onReset({bool isStein = false}) {
    if (isFileSource) {
      cacheLocalProgress();
    }

    playedTime = null;
    defaultST = null;
    videoUrl = null;
    audioUrl = null;

    if (scrollRatio.value != 0) {
      scrollRatio.refresh();
    }

    // danmaku
    savedDanmaku = null;

    // subtitle
    subtitles.clear();
    vttSubtitlesIndex.value = -1;
    vttSubtitles.clear();

    // sponsor block - 离线文件也需要清除，以便重新获取新视频的空降助手数据
    if (plPlayerController.enableBlock) {
      _lastPos = null;
      positionSubscription?.cancel();
      positionSubscription = null;
      videoLabel.value = '';
      segmentList.clear();
      segmentProgressList.clear();
    }

    // 清除视频尺寸监听
    _cancelVideoSizeSubscriptions();

    if (!isFileSource) {
      // language
      languages.value = null;
      currLang.value = null;

      // dm trend
      if (plPlayerController.showDmChart) {
        dmTrend.value = null;
      }

      // view point
      if (plPlayerController.showViewPoints) {
        viewPointList.clear();
      }

      // interactive video
      if (!isStein) {
        graphVersion = null;
      }
      steinEdgeInfo = null;
      showSteinEdgeInfo.value = false;
    }
  }

  late final Rx<LoadingState<List<double>>?> dmTrend =
      Rx<LoadingState<List<double>>?>(null);
  late final RxBool showDmTrendChart = true.obs;

  Future<void> _getDmTrend() async {
    dmTrend.value = LoadingState<List<double>>.loading();
    try {
      final res = await Request().get(
        'https://bvc.bilivideo.com/pbp/data',
        queryParameters: {
          'bvid': bvid,
          'cid': cid.value,
        },
      );
      PbpData data = PbpData.fromJson(res.data);
      int stepSec = data.stepSec ?? 0;
      if (stepSec != 0 && data.events?.eDefault?.isNotEmpty == true) {
        dmTrend.value = Success(data.events!.eDefault!);
        return;
      }
      dmTrend.value = const Error(null);
    } catch (e) {
      dmTrend.value = const Error(null);
      if (kDebugMode) debugPrint('_getDmTrend: $e');
    }
  }

  void showNoteList(BuildContext context) {
    String? title;
    try {
      title = Get.find<UgcIntroController>(
        tag: heroTag,
      ).videoDetail.value.title;
    } catch (_) {}
    if (plPlayerController.isFullScreen.value || showVideoSheet) {
      PageUtils.showVideoBottomSheet(
        context,
        child: plPlayerController.darkVideoPage && MyApp.darkThemeData != null
            ? Theme(
                data: MyApp.darkThemeData!,
                child: NoteListPage(
                  oid: aid,
                  enableSlide: false,
                  heroTag: heroTag,
                  isStein: graphVersion != null,
                  title: title,
                ),
              )
            : NoteListPage(
                oid: aid,
                enableSlide: false,
                heroTag: heroTag,
                isStein: graphVersion != null,
                title: title,
              ),
        isFullScreen: () => plPlayerController.isFullScreen.value,
      );
    } else {
      childKey.currentState?.showBottomSheet(
        backgroundColor: Colors.transparent,
        constraints: const BoxConstraints(),
        (context) => NoteListPage(
          oid: aid,
          heroTag: heroTag,
          isStein: graphVersion != null,
          title: title,
        ),
      );
    }
  }

  @pragma('vm:notify-debugger-on-exception')
  bool onSkipSegment() {
    try {
      if (plPlayerController.enableBlock) {
        if (listData.lastOrNull case final SegmentModel item) {
          onSkip(item, isSeek: false);
          onRemoveItem(listData.indexOf(item), item);
          return true;
        }
      }
    } catch (e, s) {
      Utils.reportError(e, s);
    }
    return false;
  }

  void toAudioPage() {
    int? id;
    int? extraId;
    PlaylistSource from = PlaylistSource.UP_ARCHIVE;
    if (isPlayAll) {
      id = args['mediaId'];
      extraId = sourceType.extraId;
      from = sourceType.playlistSource!;
    } else if (isUgc) {
      try {
        final ctr = Get.find<UgcIntroController>(tag: heroTag);
        id = ctr.videoDetail.value.ugcSeason?.id;
        if (id != null) {
          extraId = 8;
          from = PlaylistSource.MEDIA_LIST;
        }
      } catch (_) {}
    }
    AudioPage.toAudioPage(
      itemType: 1,
      id: id,
      oid: aid,
      subId: [cid.value],
      from: from,
      heroTag: heroTag,
      start: playedTime,
      audioUrl: audioUrl,
      extraId: extraId,
    );
  }

  Future<void> onDownload(BuildContext context) async {
    VideoDetailData? videoDetail;
    List<ugc.BaseEpisodeItem>? episodes;
    UgcIntroController? ugcIntroController;
    PgcInfoModel? pgcItem;
    if (isUgc) {
      try {
        ugcIntroController = Get.find<UgcIntroController>(tag: heroTag);
        videoDetail = ugcIntroController.videoDetail.value;
        if (videoDetail.ugcSeason?.sections case final sections?) {
          episodes = <ugc.BaseEpisodeItem>[];
          for (final i in sections) {
            if (i.episodes case final e?) {
              episodes.addAll(e);
            }
          }
        } else {
          episodes = videoDetail.pages;
        }
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('download ugc: $e\n\n$s');
        }
      }
    } else {
      try {
        pgcItem = Get.find<PgcIntroController>(tag: heroTag).pgcItem;
        episodes = pgcItem.episodes;
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('download pgc: $e\n\n$s');
        }
      }
    }
    if (episodes != null && episodes.isNotEmpty) {
      final downloadService = Get.find<DownloadService>();
      await downloadService.waitForInitialization;
      if (!context.mounted) {
        return;
      }
      final Set<int> cidSet = downloadService.downloadList
          .followedBy(downloadService.waitDownloadQueue)
          .map((e) => e.cid)
          .toSet();
      final index = episodes.indexWhere(
        (e) => e.cid == (seasonCid ?? cid.value),
      );

      showModalBottomSheet(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        constraints: BoxConstraints(
          maxWidth: min(640, context.mediaQueryShortestSide),
        ),
        builder: (context) {
          final maxChildSize =
              PlatformUtils.isMobile && !context.mediaQuerySize.isPortrait
              ? 1.0
              : 0.7;
          return DraggableScrollableSheet(
            snap: true,
            expand: false,
            minChildSize: 0,
            snapSizes: [maxChildSize],
            maxChildSize: maxChildSize,
            initialChildSize: maxChildSize,
            builder: (context, scrollController) => DownloadPanel(
              index: index,
              videoDetail: videoDetail,
              pgcItem: pgcItem,
              episodes: episodes!,
              scrollController: scrollController,
              videoDetailController: this,
              heroTag: heroTag,
              ugcIntroController: ugcIntroController,
              cidSet: cidSet,
            ),
          );
        },
      );
    }
  }

  void editPlayUrl() {
    String videoUrl = this.videoUrl ?? '';
    String audioUrl = this.audioUrl ?? '';
    Widget textField({
      required String label,
      required String initialValue,
      required ValueChanged<String> onChanged,
    }) => TextFormField(
      minLines: 1,
      maxLines: 3,
      onChanged: onChanged,
      initialValue: initialValue,
      decoration: InputDecoration(
        label: Text(label),
        border: const OutlineInputBorder(),
      ),
    );
    showDialog(
      context: Get.context!,
      builder: (context) => AlertDialog(
        constraints: StyleString.dialogFixedConstraints,
        title: const Text('播放地址'),
        content: Column(
          spacing: 20,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            textField(
              label: 'Video Url',
              initialValue: videoUrl,
              onChanged: (value) => videoUrl = value,
            ),
            textField(
              label: 'Audio Url',
              initialValue: audioUrl,
              onChanged: (value) => audioUrl = value,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
              this.videoUrl = videoUrl;
              this.audioUrl = audioUrl;
              playerInit();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<void> onCast() async {
    SmartDialog.showLoading();
    final res = await VideoHttp.tvPlayUrl(
      cid: cid.value,
      objectId: epId ?? aid,
      playurlType: epId != null ? 2 : 1,
      qn: currentVideoQa.value?.code,
    );
    SmartDialog.dismiss();
    if (res case Success(:final response)) {
      final first = response.durl?.firstOrNull;
      if (first == null || first.playUrls.isEmpty) {
        SmartDialog.showToast('不支持投屏');
        return;
      }
      final url = VideoUtils.getCdnUrl(first.playUrls);

      String? title;
      try {
        if (isUgc) {
          title = Get.find<UgcIntroController>(
            tag: heroTag,
          ).videoDetail.value.title;
        } else {
          title = Get.find<PgcIntroController>(
            tag: heroTag,
          ).videoDetail.value.title;
        }
      } catch (_) {}
      if (kDebugMode) {
        debugPrint(title);
      }
      Get.toNamed(
        '/dlna',
        parameters: {
          'url': url,
          'title': ?title,
        },
      );
    } else {
      res.toast();
    }
  }
}
