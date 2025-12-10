import 'dart:math';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/member.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/member_card_info/data.dart';
import 'package:PiliPlus/models_new/triple/ugc_triple.dart';
import 'package:PiliPlus/models_new/video/video_detail/stat_detail.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/download/controller.dart';
import 'package:PiliPlus/pages/dynamics_repost/view.dart';
import 'package:PiliPlus/pages/video/pay_coins/view.dart';
import 'package:PiliPlus/pages/video/reply/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:expandable/expandable.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class LocalIntroController extends CommonIntroController {
  // 网络状态
  final RxBool hasNetwork = false.obs;
  // 是否加载了在线详情
  final RxBool onlineDetailLoaded = false.obs;
  // 是否点踩
  final RxBool hasDislike = false.obs;
  // up主粉丝数
  final Rx<MemberCardInfoData> userStat = MemberCardInfoData().obs;
  // 关注状态
  late final RxMap followStatus = {}.obs;

  late ExpandableController expandableCtr;

  @override
  void queryVideoIntro() {
    // 检查网络后加载在线详情
    _checkNetworkAndLoadDetail();
  }

  /// 检查网络状态并加载在线详情
  Future<void> _checkNetworkAndLoadDetail() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    hasNetwork.value = !connectivityResult.contains(ConnectivityResult.none);

    // 同步网络状态到 VideoDetailController
    videoDetailCtr.localHasNetwork.value = hasNetwork.value;

    if (hasNetwork.value) {
      await _loadOnlineDetail();
    }
  }

  /// 加载在线视频详情
  Future<void> _loadOnlineDetail() async {
    try {
      queryVideoTags();
      final res = await VideoHttp.videoIntro(bvid: bvid);
      if (res.isSuccess) {
        final data = res.data;
        // 保留本地标题，但更新其他在线数据
        final localTitle = videoDetail.value.title;
        videoDetail.value = data;
        if (localTitle?.isNotEmpty == true) {
          videoDetail.value.title = localTitle;
        }
        onlineDetailLoaded.value = true;

        // 更新评论数
        if (videoDetailCtr.showReply) {
          try {
            Get.find<VideoReplyController>(tag: heroTag).count.value =
                data.stat?.reply ?? 0;
          } catch (_) {}
        }

        // 获取UP主信息
        final mid = data.owner?.mid;
        if (mid != null) {
          _queryUserStat(mid);
        }

        // 登录状态下查询点赞收藏状态
        if (isLogin) {
          _queryAllStatus();
          _queryFollowStatus();
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Load online detail error: $e');
    }
  }

  /// 获取UP主粉丝数
  Future<void> _queryUserStat(int mid) async {
    final result = await MemberHttp.memberCardInfo(mid: mid);
    if (result.isSuccess) {
      userStat.value = result.data;
    }
  }

  /// 查询视频状态（点赞、收藏等）
  Future<void> _queryAllStatus() async {
    final result = await VideoHttp.videoRelation(bvid: bvid);
    if (result case Success(:var response)) {
      late final stat = videoDetail.value.stat!;
      if (response.like!) {
        stat.like = max(1, stat.like);
      }
      if (response.favorite!) {
        stat.favorite = max(1, stat.favorite);
      }
      hasLike.value = response.like!;
      hasDislike.value = response.dislike!;
      coinNum.value = response.coin!;
      hasFav.value = response.favorite!;
    }
  }

  /// 查询关注状态
  Future<void> _queryFollowStatus() async {
    final mid = videoDetail.value.owner?.mid;
    if (mid == null) return;
    final result = await UserHttp.hasFollow(mid);
    if (result['status']) {
      followStatus['attribute'] = result['data']['attribute'];
    }
  }

  @override
  void actionCoinVideo() {
    if (!hasNetwork.value) {
      SmartDialog.showToast('当前无网络连接');
      return;
    }
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }

    int copyright = videoDetail.value.copyright ?? 1;
    if ((copyright != 1 && coinNum.value >= 1) || coinNum.value >= 2) {
      SmartDialog.showToast('达到投币上限啦~');
      return;
    }

    if (GlobalData().coins != null && GlobalData().coins! < 1) {
      SmartDialog.showToast('硬币不足');
    }

    PayCoinsPage.toPayCoinsPage(
      onPayCoin: coinVideo,
      copyright: copyright,
      hasCoin: coinNum.value == 1,
    );
  }

  @override
  Future<void> actionLikeVideo() async {
    if (!hasNetwork.value) {
      SmartDialog.showToast('当前无网络连接');
      return;
    }
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    if (videoDetail.value.stat == null) {
      return;
    }
    final newVal = !hasLike.value;
    var result = await VideoHttp.likeVideo(bvid: bvid, type: newVal);
    if (result['status']) {
      SmartDialog.showToast(newVal ? result['data']['toast'] : '取消赞');
      videoDetail.value.stat!.like += newVal ? 1 : -1;
      hasLike.value = newVal;
      if (newVal) {
        hasDislike.value = false;
      }
    } else {
      SmartDialog.showToast(result['msg']);
    }
  }

  /// 点踩视频
  Future<void> actionDislikeVideo() async {
    if (!hasNetwork.value) {
      SmartDialog.showToast('当前无网络连接');
      return;
    }
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    var result = await VideoHttp.dislikeVideo(
      bvid: bvid,
      type: !hasDislike.value,
    );
    if (result['status']) {
      if (!hasDislike.value) {
        SmartDialog.showToast('点踩成功');
        hasDislike.value = true;
        if (hasLike.value) {
          videoDetail.value.stat!.like--;
          hasLike.value = false;
        }
      } else {
        SmartDialog.showToast('取消踩');
        hasDislike.value = false;
      }
    } else {
      SmartDialog.showToast(result['msg']);
    }
  }

  @override
  void actionShareVideo(context) {
    if (!hasNetwork.value) {
      SmartDialog.showToast('当前无网络连接');
      return;
    }
    final vd = videoDetail.value;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => RepostPanel(
        rid: vd.aid,
        dynType: 8,
        pic: vd.pic,
        title: vd.title,
        uname: vd.owner?.name,
      ),
    );
  }

  @override
  Future<void> actionTriple() async {
    feedBack();
    if (!hasNetwork.value) {
      SmartDialog.showToast('当前无网络连接');
      return;
    }
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    if (hasLike.value && hasCoin && hasFav.value) {
      SmartDialog.showToast('已三连');
      return;
    }
    var result = await VideoHttp.ugcTriple(bvid: bvid);
    if (result['status']) {
      UgcTriple data = result['data'];
      late final stat = videoDetail.value.stat!;
      if (data.like == true && !hasLike.value) {
        stat.like++;
        hasLike.value = true;
      }
      if (data.coin == true && !hasCoin) {
        stat.coin += 2;
        coinNum.value = 2;
        GlobalData().afterCoin(2);
      }
      if (data.fav == true && !hasFav.value) {
        stat.favorite++;
        hasFav.value = true;
      }
      hasDislike.value = false;
      if (!hasCoin) {
        SmartDialog.showToast('投币失败');
      } else {
        SmartDialog.showToast('三连成功');
      }
    } else {
      SmartDialog.showToast(result['msg']);
    }
  }

  @override
  Future<void> actionFavVideo({bool isQuick = false}) async {
    if (!hasNetwork.value) {
      SmartDialog.showToast('当前无网络连接');
      return;
    }
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    await super.actionFavVideo(isQuick: isQuick);
  }

  @override
  (Object, int) get getFavRidType => (IdUtils.bv2av(bvid), 2);

  @override
  StatDetail? getStat() => videoDetail.value.stat;

  @override
  bool get isShowOnlineTotal => hasNetwork.value && super.isShowOnlineTotal;

  late final Set<String> aidSet = {};

  @override
  void onClose() {
    aidSet.clear();
    videoPlayerServiceHandler?.onVideoDetailDispose(heroTag);
    super.onClose();
  }

  @override
  void onInit() {
    super.onInit();
    videoDetail.value.title = videoDetailCtr.args['title'];
    final controller = Get.find<DownloadPageController>();
    final list = <BiliDownloadEntryInfo>[];
    for (final e in controller.pages) {
      final items = e.entries..sort((a, b) => a.sortKey.compareTo(b.sortKey));
      final completed = items.where((e) => e.isCompleted);
      list.addAllIf(completed.isNotEmpty, completed);
      if (completed.length == 1) {
        aidSet.add(e.pageId);
      }
    }
    this.list.value = list;
    final currCid = videoDetailCtr.cid.value;
    final index = list.indexWhere((e) => e.cid == currCid);
    this.index.value = index;
    if (Utils.isMobile) {
      onVideoDetailChange(list[index]);
    }
    if (index != 0) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        try {
          if (videoDetailCtr.scrollKey.currentState?.mounted ?? false) {
            (videoDetailCtr.scrollKey.currentState!.innerController
                    as ExtendedNestedScrollController)
                .nestedPositions
                .first
                .localJumpTo(_offset);
          } else if (videoDetailCtr.introScrollCtr?.hasClients ?? false) {
            videoDetailCtr.introScrollCtr!.jumpTo(_offset);
          }
        } catch (_) {
          if (kDebugMode) rethrow;
        }
      });
    }

    // 设置媒体通知列表控制模式
    _updateListControlMode();
  }

  /// 更新媒体通知列表控制模式
  void _updateListControlMode() {
    final hasMultiItems = list.length > 1;

    videoPlayerServiceHandler?.setListControlMode(
      enabled: hasMultiItems,
      onNext: hasMultiItems ? nextPlay : null,
      onPrevious: hasMultiItems ? prevPlay : null,
    );
  }

  @override
  void restoreListControlMode() => _updateListControlMode();

  final index = (-1).obs;
  double get _offset => index * 100 + 7 - 35;
  final list = RxList<BiliDownloadEntryInfo>();

  @override
  bool nextPlay() {
    final next = index.value + 1;
    if (next < list.length) {
      playIndex(next);
      return true;
    } else {
      final playCtr = videoDetailCtr.plPlayerController;
      if (playCtr.playRepeat == PlayRepeat.listCycle) {
        if (list.length == 1) {
          if (playCtr.videoPlayerController case final ctr?) {
            ctr.seek(Duration.zero).whenComplete(ctr.play);
          }
        } else {
          playIndex(0);
        }
        return true;
      }
    }
    return false;
  }

  @override
  bool prevPlay() {
    final prev = index.value - 1;
    if (prev >= 0) {
      playIndex(prev);
      return true;
    }
    return false;
  }

  void playIndex(
    int index, {
    BiliDownloadEntryInfo? entry,
  }) {
    entry ??= list[index];
    videoDetailCtr
      ..onReset()
      ..cover.value = entry.cover
      ..aid = entry.avid
      ..bvid = entry.bvid
      ..cid.value = entry.cid
      ..args['dirPath'] = entry.entryDirPath
      ..initFileSource(entry, isInit: false)
      // 调用 queryVideoUrl() 来获取新视频的空降助手数据（如果有网络）
      ..queryVideoUrl();
    videoDetail
      ..value.title = entry.showTitle
      ..refresh();
    this.index.value = index;
    if (Utils.isMobile) {
      onVideoDetailChange(entry);
    }
  }

  void onVideoDetailChange(BiliDownloadEntryInfo entry) {
    videoPlayerServiceHandler?.onVideoDetailChange(entry, entry.cid, heroTag);
  }
}
