import 'dart:async';
import 'dart:math' as math;

import 'package:PiliPlus/common/widgets/dialog/simple_dialog_option.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/pgc.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/pgc_episode_type.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/result.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart'
    hide EpisodeItem;
import 'package:PiliPlus/models_new/video/video_detail/stat_detail.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/dynamics_repost/view.dart';
import 'package:PiliPlus/pages/video/reply/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/bili_utils.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/share_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

typedef OnChangePgcEpisode = Function(
  BaseEpisodeItem episode, {
  PgcEpisodeType? episodeType,
});

class PgcIntroController extends CommonIntroController {
  PgcIntroController({super.arguments});

  int? seasonId;
  int? epId;
  int _changeEpisodeGeneration = 0;
  int _pgcInfoGeneration = 0;

  String get pgcType => pgcItem.type == 1 || pgcItem.type == 4 ? '追番' : '追剧';

  late final bool isPgc;
  late PgcInfoModel pgcItem;
  late PgcEpisodeType episodeType;

  final RxBool pgcItemLoaded = false.obs;
  ScrollController? seasonController;

  @override
  (Object, int) get getFavRidType => (epId!, 24);

  @override
  StatDetail? getStat() => pgcItemLoaded.value ? pgcItem.stat : null;

  late final RxBool isFollowed = false.obs;
  late final RxInt followStatus = (-1).obs;
  final RxBool isFav = false.obs;

  late int seasonIndex = 0;
  late int episodeIndex = 0;
  late int sectionIndex = 0;
  late int pvIndex = 0;

  late final _replyCtr = Get.find<VideoReplyController>(tag: heroTag);

  @override
  void onInit() {
    final args = routeArguments;
    seasonId = args['seasonId'];
    epId = args['epId'];
    isPgc = args['videoType'] == VideoType.pgc;
    if (args['sectionIndex'] case final int value) {
      episodeType = .section;
      sectionIndex = value;
    } else {
      episodeType = .episode;
    }

    // Important: initialize CommonIntroController fields (heroTag/bvid/cid)
    // before calling any logic that may read cid.
    super.onInit();

    final passedPgcItem = args['pgcItem'];
    if (passedPgcItem != null) {
      pgcItem = passedPgcItem;
      pgcItemLoaded.value = true;
      isFav.value = pgcItem.userStatus?.favored == 1;
      _onPgcItemReady();
    } else {
      // pgcItem 未传递，需要异步加载
      _loadPgcItem();
    }
  }

  /// 异步加载 pgcItem
  Future<void> _loadPgcItem() async {
    final generation = ++_pgcInfoGeneration;
    final requestSeasonId = seasonId;
    final requestEpId = epId;
    final changeGeneration = _changeEpisodeGeneration;
    bool isCurrent() =>
        !isClosed &&
        generation == _pgcInfoGeneration &&
        seasonId == requestSeasonId &&
        epId == requestEpId &&
        changeGeneration == _changeEpisodeGeneration;
    try {
      final loadInfo = isPgc ? SearchHttp.pgcInfo : SearchHttp.pugvInfo;
      final result = await loadInfo(
        seasonId: requestSeasonId,
        epId: requestEpId,
      );
      if (!isCurrent()) return;
      if (result.isSuccess) {
        pgcItem = result.data;
        pgcItemLoaded.value = true;
        isFav.value = pgcItem.userStatus?.favored == 1;
        _onPgcItemReady();
      } else {
        result.toast();
      }
    } catch (e) {
      if (!isCurrent()) return;
      if (kDebugMode) {
        debugPrint('_loadPgcItem error: $e');
      }
      SmartDialog.showToast('加载番剧信息失败');
    }
  }

  /// pgcItem 准备好后的初始化逻辑
  void _onPgcItemReady() {
    if (isClosed || !pgcItemLoaded.value) return;
    seasonIndex =
        pgcItem.seasons?.indexWhere((e) => e.seasonId == seasonId) ?? 0;
    final sections = pgcItem.sections;
    if (sections != null &&
        sections.isNotEmpty &&
        (sectionIndex < 0 || sectionIndex >= sections.length)) {
      sectionIndex = 0;
    }
    _updateEpisodeIndex(cid.value);
    // 调用 queryVideoIntro 更新视频详情
    queryVideoIntro();

    if (isPgc) {
      if (isLogin) {
        queryIsFollowed();
        queryPgcLikeCoinFav();
      }
      queryVideoTags();
    }

    // 设置媒体通知列表控制模式
    _updateListControlMode();
    // loaded remains true on season changes; notify both body and sidebar.
    pgcItemLoaded.refresh();
  }

  /// 更新媒体通知列表控制模式
  void _updateListControlMode() {
    if (isClosed || !pgcItemLoaded.value || !videoDetailCtr.canStartPlayback) {
      return;
    }
    // PGC 内容通常有多集
    final hasMultiEpisodes = episodes.length > 1;

    videoPlayerServiceHandler?.setListControlMode(
      enabled: hasMultiEpisodes,
      onNext: hasMultiEpisodes ? nextPlay : null,
      onPrevious: hasMultiEpisodes ? prevPlay : null,
    );
  }

  @override
  void restoreListControlMode() => _updateListControlMode();

  // 获取点赞/投币/收藏状态
  Future<void> queryPgcLikeCoinFav() async {
    final requestEpId = epId;
    final requestItem = pgcItem;
    if (requestEpId == null) return;
    final result = await VideoHttp.pgcLikeCoinFav(epId: requestEpId);
    if (isClosed || epId != requestEpId || !identical(pgcItem, requestItem)) {
      return;
    }
    if (result case Success(:final response)) {
      final hasLike = response.like == 1;
      final hasFav = response.favorite == 1;
      late final stat = pgcItem.stat;
      if (hasLike) {
        stat?.like = math.max(1, stat.like);
      }
      if (hasFav) {
        stat?.favorite = math.max(1, stat.favorite);
      }
      this.hasLike.value = hasLike;
      coinNum.value = response.coinNumber!;
      this.hasFav.value = hasFav;
    } else {
      result.toast();
    }
  }

  // （取消）点赞
  @override
  Future<void> actionLikeVideo() async {
    await runWithActionLoading(IntroAction.like, () async {
      if (!isLogin) {
        SmartDialog.showToast('账号未登录');
        return;
      }
      final newVal = !hasLike.value;
      final result = await VideoHttp.likeVideo(bvid: bvid, type: newVal);
      if (result case Success(:final response)) {
        SmartDialog.showToast(newVal ? response : '取消赞');
        pgcItem.stat?.like += newVal ? 1 : -1;
        hasLike.value = newVal;
      } else {
        result.toast();
      }
    });
  }

  @override
  int get copyright => 1;

  // 分享视频
  @override
  void actionShareVideo(BuildContext context) {
    String videoUrl =
        '${HttpString.baseUrl}/bangumi/play/ep$epId${videoDetailCtr.playedTimePos(false)}';
    showDialog(
      context: context,
      builder: (_) => SimpleDialog(
        clipBehavior: Clip.hardEdge,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          DialogOption(
            child: const Text('复制链接', style: TextStyle(fontSize: 14)),
            onPressed: () {
              Navigator.of(context).pop();
              Utils.copyText(videoUrl);
            },
          ),
          DialogOption(
            child: const Text('其它app打开', style: TextStyle(fontSize: 14)),
            onPressed: () {
              Navigator.of(context).pop();
              PiliAndroidHelper.openUrl(videoUrl);
            },
          ),
          if (PlatformUtils.isMobile)
            DialogOption(
              child: const Text('分享视频', style: TextStyle(fontSize: 14)),
              onPressed: () {
                final item = findEpisode(cid.value);
                Navigator.of(context).pop();
                ShareUtils.shareText(
                  '${pgcItem.title} ${item.showTitle}'
                  ' - $videoUrl',
                );
              },
            ),
          if (isLogin)
            DialogOption(
              child: const Text('分享至动态', style: TextStyle(fontSize: 14)),
              onPressed: () {
                Navigator.of(context).pop();
                final item = findEpisode(cid.value);
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  builder: (context) => RepostPanel(
                    rid: epId,
                    /*
                    1：番剧 // 4097
                    2：电影 // 4098
                    3：纪录片 // 4101
                    4：国创 // 4100
                    5：电视剧 // 4099
                    6：漫画
                    7：综艺 // 4099
                  */
                    dynType: switch (pgcItem.type) {
                      1 => 4097,
                      2 => 4098,
                      3 => 4101,
                      4 => 4100,
                      5 || 7 => 4099,
                      _ => -1,
                    },
                    pic: pgcItem.cover,
                    title: '${pgcItem.title}\n${item.showTitle}',
                    uname: '',
                    replyInfo: (
                      oid: videoDetailCtr.aid,
                      replyType: videoDetailCtr.videoType.replyType,
                    ),
                  ),
                );
              },
            ),
          if (isLogin)
            DialogOption(
              child: const Text(
                '分享至消息',
                style: TextStyle(fontSize: 14),
              ),
              onPressed: () {
                Navigator.of(context).pop();
                try {
                  final item = findEpisode(cid.value);
                  final title =
                      item.shareCopy ??
                      '${pgcItem.title} ${item.showTitle ?? item.longTitle}';
                  PageUtils.pmShare(
                    context,
                    content: {
                      "id": epId.toString(),
                      "title": title,
                      "url": item.shareUrl,
                      "headline": title,
                      "source": 16,
                      "thumb": item.cover,
                      "source_desc": BiliUtils.pgcType2Label(pgcItem.type),
                    },
                  );
                } catch (e) {
                  SmartDialog.showToast(e.toString());
                }
              },
            ),
        ],
      ),
    );
  }

  void _updateEpisodeIndex(int cid) {
    final index = episodes.indexWhere((e) => e.cid == cid);
    if (episodeType == .episode) {
      episodeIndex = index;
      pvIndex = -1;
    } else {
      episodeIndex = -1;
      pvIndex = index;
    }
  }

  // 修改分P或番剧分集
  @override
  Future<bool> onChangeEpisode(
    BaseEpisodeItem episode, {
    PgcEpisodeType? episodeType,
    bool fromAudioPage = false,
    Duration? audioPosition,
  }) async {
    final changeGeneration = ++_changeEpisodeGeneration;
    bool isCurrentChange() =>
        !isClosed && changeGeneration == _changeEpisodeGeneration;
    int? switchGeneration;
    // PGC 自己的 changeGeneration 和视频控制器的 switchGeneration 都有效时，才允许继续写状态。
    bool isCurrentSwitch() {
      final generation = switchGeneration;
      return generation != null &&
          isCurrentChange() &&
          videoDetailCtr.isCurrentVideoSwitch(generation);
    }

    // 本次 PGC 切换只取消自己创建的 switch，避免误结束后续点击触发的新切换。
    Future<void> cancelOwnedSwitch({required String reason}) async {
      final generation = switchGeneration;
      if (generation != null) {
        await videoDetailCtr.cancelVideoSwitch(
          switchGeneration: generation,
          reason: reason,
        );
      }
    }

    try {
      final int epId = episode.epId ?? episode.id!;
      final String bvid = episode.bvid ?? this.bvid;
      final int aid = episode.aid ?? IdUtils.bv2av(bvid);
      int? cid = episode.cid;
      if (cid == null) {
        cid = await SearchHttp.ab2c(aid: aid, bvid: bvid);
        if (!isCurrentChange()) {
          return false;
        }
      }
      if (cid == null) {
        return false;
      }
      final String? cover = episode.cover;

      if (!fromAudioPage &&
          videoDetailCtr.epId == epId &&
          videoDetailCtr.bvid == bvid &&
          videoDetailCtr.cid.value == cid) {
        return false;
      }

      // 切换生命周期交给 VideoDetailController 统一管理，PGC 只保存本轮 generation。
      final currentSwitchGeneration = videoDetailCtr.beginVideoSwitch(
        reason: 'pgc_switch',
      );
      switchGeneration = currentSwitchGeneration;
      await videoDetailCtr.ensureVideoSwitchProtection(
        switchGeneration: currentSwitchGeneration,
        reason: 'pgc_switch',
        text: '正在切换剧集…',
      );
      if (!isCurrentSwitch()) {
        await cancelOwnedSwitch(reason: 'pgc_switch_stale');
        return false;
      }

      // 重新获取视频资源
      this.epId = epId;

      if (episodeType != null) this.episodeType = episodeType;
      _updateEpisodeIndex(cid);

      videoDetailCtr.plPlayerController.pause();
      if (!isCurrentSwitch()) {
        await cancelOwnedSwitch(reason: 'pgc_switch_stale');
        return false;
      }
      if (!fromAudioPage) {
        videoDetailCtr
          ..saveProgressBeforeChange()
          ..makeHeartBeat();
      }
      if (!isCurrentSwitch()) {
        await cancelOwnedSwitch(reason: 'pgc_switch_stale');
        return false;
      }
      videoDetailCtr
        ..onReset()
        ..seasonId = seasonId
        ..epId = epId
        ..bvid = bvid
        ..aid = aid
        ..cid.value = cid;

      // 重要：在后台/锁屏场景下，必须等待 queryVideoUrl 完成才能继续
      final Duration? progressToPass =
          fromAudioPage &&
              audioPosition != null &&
              audioPosition > Duration.zero
          ? audioPosition
          : null;
      if (progressToPass != null) {
        if (!isCurrentSwitch()) {
          await cancelOwnedSwitch(reason: 'pgc_switch_stale');
          return false;
        }
        videoDetailCtr
          ..playedTime = progressToPass
          ..defaultST = progressToPass;
      }

      await videoDetailCtr.queryVideoUrl(
        defaultST: progressToPass,
        fromSwitch: true,
        switchGeneration: currentSwitchGeneration,
      );
      if (!isCurrentSwitch()) {
        return false;
      }
      if (videoDetailCtr.epId != epId ||
          videoDetailCtr.bvid != bvid ||
          videoDetailCtr.cid.value != cid) {
        await cancelOwnedSwitch(reason: 'pgc_switch_identity_mismatch');
        return false;
      }
      if (!videoDetailCtr.videoState.value) return false;

      if (!isCurrentSwitch()) {
        return false;
      }
      if (cover != null && cover.isNotEmpty) {
        videoDetailCtr.cover.value = cover;
      }

      // 重新请求评论
      if (videoDetailCtr.showReply) {
        if (!isCurrentSwitch()) {
          return false;
        }
        try {
          if (_replyCtr.loadingState.value is! Loading) {
            _replyCtr.onReload();
          }
        } catch (_) {}
      }

      if (isPgc && isLogin) {
        if (!isCurrentSwitch()) {
          return false;
        }
        queryPgcLikeCoinFav();
      }

      if (!isCurrentSwitch()) {
        return false;
      }
      hasLater.value = videoDetailCtr.sourceType == SourceType.watchLater;
      queryOnlineTotal(isCurrent: isCurrentSwitch);

      // 异步查询视频简介，不阻止播放切换；返回时仍需确认本轮 switch 未过期。
      queryVideoIntroForSwitch(currentSwitchGeneration, episode as EpisodeItem);
      return true;
    } catch (e, s) {
      await cancelOwnedSwitch(reason: 'pgc_switch_failed');
      if (kDebugMode) debugPrint('pgc onChangeEpisode: $e');
      Utils.reportError(e, s);
      return false;
    }
  }

  // 追番
  Future<void> pgcAdd() async {
    await runWithActionLoading(IntroAction.pgcFollow, () async {
      final result = await VideoHttp.pgcAdd(seasonId: pgcItem.seasonId);
      if (result case Success(:final response)) {
        isFollowed.value = true;
        followStatus.value = 2;
        SmartDialog.showToast(response);
      } else {
        result.toast();
      }
    });
  }

  // 取消追番
  Future<void> pgcDel() async {
    await runWithActionLoading(IntroAction.pgcFollow, () async {
      final result = await VideoHttp.pgcDel(seasonId: pgcItem.seasonId);
      if (result case Success(:final response)) {
        isFollowed.value = false;
        SmartDialog.showToast(response);
      } else {
        result.toast();
      }
    });
  }

  Future<void> pgcUpdate(int status) async {
    await runWithActionLoading(IntroAction.pgcFollow, () async {
      final result = await VideoHttp.pgcUpdate(
        seasonId: pgcItem.seasonId.toString(),
        status: status,
      );
      if (result case Success(:final response)) {
        followStatus.value = status;
        SmartDialog.showToast(response);
      } else {
        result.toast();
      }
    });
  }

  @override
  bool prevPlay() {
    final episodes = this.episodes;
    if (episodes.isEmpty) return false;
    int currentIndex = episodes.indexWhere(
      (e) => e.cid == videoDetailCtr.cid.value,
    );
    // 如果找不到当前视频在列表中的位置，返回失败
    if (currentIndex == -1) {
      return false;
    }
    int prevIndex = currentIndex - 1;
    PlayRepeat playRepeat = videoDetailCtr.plPlayerController.playRepeat;
    if (prevIndex < 0) {
      if (playRepeat == PlayRepeat.listCycle) {
        prevIndex = episodes.length - 1;
      } else {
        return false;
      }
    }
    onChangeEpisode(episodes[prevIndex]);
    return true;
  }

  /// 列表循环或者顺序播放时，自动播放下一个；自动连播时，播放相关视频
  @override
  bool nextPlay() {
    try {
      final episodes = this.episodes;
      if (episodes.isEmpty) return false;

      PlayRepeat playRepeat = videoDetailCtr.plPlayerController.playRepeat;

      int currentIndex = episodes.indexWhere(
        (e) => e.cid == videoDetailCtr.cid.value,
      );
      // 如果找不到当前视频在列表中的位置，返回失败
      if (currentIndex == -1) {
        return false;
      }
      int nextIndex = currentIndex + 1;
      // 列表循环
      if (nextIndex >= episodes.length) {
        if (playRepeat == PlayRepeat.listCycle) {
          nextIndex = 0;
        } else {
          return false;
        }
      }
      onChangeEpisode(episodes[nextIndex]);
      return true;
    } catch (_) {
      return false;
    }
  }

  // 一键三连
  @override
  Future<void> actionTriple() async {
    if (epId == null || !pgcItemLoaded.value) return;
    await runWithActionLoading(IntroAction.triple, () async {
      feedBack();
      if (!isLogin) {
        SmartDialog.showToast('账号未登录');
        return;
      }
      if (hasLike.value && hasCoin && hasFav.value) {
        // 已点赞、投币、收藏
        SmartDialog.showToast('已三连');
        return;
      }
      final result = await VideoHttp.pgcTriple(epId: epId!, seasonId: seasonId);
      if (result case Success(:final response)) {
        late final stat = pgcItem.stat;
        if (response.like == 1 && !hasLike.value) {
          stat?.like++;
          hasLike.value = true;
        }
        if (response.coin == 1 && !hasCoin) {
          stat?.coin += 2;
          coinNum.value = 2;
          GlobalData().afterCoin(2);
        }
        if (response.favorite == 1 && !hasFav.value) {
          stat?.favorite++;
          hasFav.value = true;
        }
        if (!hasCoin) {
          SmartDialog.showToast('投币失败');
        } else {
          SmartDialog.showToast('三连成功');
        }
      } else {
        result.toast();
      }
    });
  }

  Future<void> queryIsFollowed() async {
    // try {
    //   final result = await Request().get(
    //     'https://www.bilibili.com/bangumi/play/ss$seasonId',
    //   );
    //   dom.Document document = html_parser.parse(result.data);
    //   dom.Element? scriptElement =
    //       document.querySelector('script#__NEXT_DATA__');
    //   if (scriptElement != null) {
    //     dynamic scriptContent = jsonDecode(scriptElement.text);
    //     isFollowed.value =
    //         scriptContent['props']['pageProps']['followState']['isFollowed'];
    //     followStatus.value =
    //         scriptContent['props']['pageProps']['followState']['followStatus'];
    //   }
    // } catch (_) {}

    // ViewGrpc.view(bvid: bvid).then((res) {
    //   if (res.isSuccess) {
    //     ViewPgcAny view = ViewPgcAny.fromBuffer(res.data.supplement.value);
    //     final userStatus = view.ogvData.userStatus;
    //     isFollowed.value = userStatus.follow == 1;
    //     followStatus.value = userStatus.followStatus;
    //   }
    // });

    final requestSeasonId = seasonId;
    if (requestSeasonId == null) return;
    final res = await PgcHttp.seasonStatus(requestSeasonId);
    if (isClosed || seasonId != requestSeasonId) return;
    if (res case Success(:final response)) {
      isFollowed.value = response['follow'] == 1;
      followStatus.value = response['follow_status'];
    }
  }

  List<EpisodeItem> get episodes {
    if (!pgcItemLoaded.value) return const [];
    if (episodeType == .section) {
      final sections = pgcItem.sections;
      if (sections == null ||
          sectionIndex < 0 ||
          sectionIndex >= sections.length) {
        return const [];
      }
      return sections[sectionIndex].episodes ?? const [];
    }
    return pgcItem.episodes ?? const [];
  }

  EpisodeItem findEpisode(int cid) {
    return episodes.firstWhere((e) => e.cid == cid);
  }

  @override
  void queryVideoIntro([EpisodeItem? episode]) {
    _queryVideoIntro(episode: episode);
  }

  void queryVideoIntroForSwitch(int switchGeneration, [EpisodeItem? episode]) {
    _queryVideoIntro(
      episode: episode,
      isCurrent: () => videoDetailCtr.isCurrentVideoSwitch(switchGeneration),
    );
  }

  // PGC 简介会被切换流程异步触发，isCurrent 用来拦截旧剧集返回后的状态回写。
  void _queryVideoIntro({
    EpisodeItem? episode,
    bool Function()? isCurrent,
  }) {
    bool isCurrentIntro() => isCurrent?.call() ?? true;
    if (isClosed || !isCurrentIntro()) return;
    // 如果 pgcItem 未加载，跳过（会在 _onPgcItemReady 中再次调用）
    if (!pgcItemLoaded.value) return;

    episode ??= episodes.firstWhereOrNull((e) => e.cid == cid.value);
    if (episode == null) return;
    if (!isCurrentIntro()) return;
    videoDetail
      ..value.title = episode.showTitle
      ..refresh();
    if (isClosed || !isCurrentIntro()) {
      return;
    }
    videoPlayerServiceHandler?.onVideoDetailChange(
      episode,
      cid.value,
      heroTag,
      artist: pgcItem.title,
    );
    unawaited(
      videoDetailCtr.updateDesktopWindowTitle(
        title: pgcItem.title,
        subTitle: episode.showTitle ?? episode.longTitle ?? episode.title,
      ),
    );
  }

  Future<void> onFavPugv(bool isFav) async {
    if (seasonId == null || !pgcItemLoaded.value) return;
    await runWithActionLoading(IntroAction.pugvFavorite, () async {
      final res = isFav
          ? await FavHttp.delFavPugv(seasonId!)
          : await FavHttp.addFavPugv(seasonId!);
      if (res.isSuccess) {
        this.isFav.toggle();
        SmartDialog.showToast('${isFav ? '取消' : ''}收藏成功');
      } else {
        res.toast();
      }
    });
  }

  bool _changingSeason = false;
  bool get changingSeason => _changingSeason;

  Future<bool> changeSeason(int seasonId, int seasonIndex) async {
    if (_changingSeason || isClosed || !pgcItemLoaded.value) return false;
    _changingSeason = true;
    final generation = ++_pgcInfoGeneration;
    final previousChange = _changeEpisodeGeneration;
    final previousEpId = epId;
    bool isCurrentRequest() => !isClosed && generation == _pgcInfoGeneration;
    SmartDialog.showLoading();
    try {
      final res = await SearchHttp.pgcInfo(seasonId: seasonId);
      if (!isCurrentRequest() ||
          previousChange != _changeEpisodeGeneration ||
          previousEpId != epId) {
        return false;
      }
      if (res case Success(:final response)) {
        final (EpisodeItem? episode, int? sectionIndex) = response
            .findEpisode();
        if (episode != null) {
          pgcItem = response;
          isFav.value = pgcItem.userStatus?.favored == 1;
          this.seasonId = seasonId;
          this.seasonIndex = seasonIndex;
          this.sectionIndex = sectionIndex ?? 0;
          final expectedChange = _changeEpisodeGeneration + 1;
          final changed = await onChangeEpisode(
            episode,
            episodeType: sectionIndex != null ? .section : .episode,
          );
          if (!isCurrentRequest() ||
              expectedChange != _changeEpisodeGeneration) {
            return false;
          }
          pgcItemLoaded.refresh();
          if (!changed) return false;
          _onPgcItemReady();
          return true;
        } else {
          SmartDialog.showToast('剧集为空');
        }
      } else {
        res.toast();
      }
    } catch (e) {
      if (isCurrentRequest() && kDebugMode) debugPrint('changeSeason: $e');
    } finally {
      SmartDialog.dismiss();
      _changingSeason = false;
    }
    return false;
  }

  @override
  void onClose() {
    _pgcInfoGeneration++;
    _changeEpisodeGeneration++;
    seasonController?.dispose();
    seasonController = null;
    super.onClose();
  }
}
