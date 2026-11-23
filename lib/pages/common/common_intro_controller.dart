import 'dart:async' show FutureOr, Timer;

import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models_new/fav/fav_folder/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart';
import 'package:PiliPlus/models_new/video/video_detail/stat_detail.dart';
import 'package:PiliPlus/models_new/video/video_tag/data.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/triple_mixin.dart';
import 'package:PiliPlus/services/battery_debug_service.dart';
import 'package:PiliPlus/services/multi_window/player_window_navigation.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/loading_action_mixin.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:collection/collection.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

enum IntroAction {
  like,
  dislike,
  triple,
  coin,
  favorite,
  watchLater,
  relation,
  pgcFollow,
  pugvFavorite,
}

abstract class CommonIntroController extends GetxController
    with
        GetSingleTickerProviderStateMixin,
        LoadingActionMixin<IntroAction>,
        TripleMixin,
        FavMixin {
  late final String heroTag;

  int get aid => videoDetailCtr.aid;
  String get bvid => videoDetailCtr.bvid;
  RxInt get cid => videoDetailCtr.cid;
  late final videoDetailCtr = Get.find<VideoDetailController>(tag: heroTag);

  // 是否稍后再看
  late final RxBool hasLater;

  final Rx<List<VideoTagItem>?> videoTags = Rx<List<VideoTagItem>?>(null);

  Future<void> handleAction(
    FutureOr<void> Function() action, {
    required IntroAction loadingAction,
  }) async {
    await runWithActionLoading(loadingAction, action);
  }

  @override
  late final isLogin = Accounts.main.isLogin;

  StatDetail? getStat();

  @override
  void updateFavCount(int count) {
    getStat()?.favorite += count;
  }

  final Rx<VideoDetailData> videoDetail = VideoDetailData().obs;

  void queryVideoIntro();

  bool prevPlay();
  bool nextPlay();

  /// 恢复媒体通知列表控制模式
  /// 当从其他页面返回时调用，以确保媒体卡片按钮状态正确
  void restoreListControlMode() {}

  @override
  void actionCoinVideo();
  void actionShareVideo(BuildContext context);

  void onChangeEpisode(BaseEpisodeItem episode);

  // 同时观看
  final bool isShowOnlineTotal = Pref.enableOnlineTotal;
  late final RxString total = '1'.obs;
  Timer? timer;

  CommonIntroController({this._arguments});

  final Map? _arguments;
  Map get routeArguments => _arguments ?? Get.arguments;

  @override
  void onInit() {
    super.onInit();
    final args = routeArguments;
    heroTag = args['heroTag'];
    hasLater = RxBool(
      args['viewLater'] ?? args['sourceType'] == SourceType.watchLater,
    );

    queryVideoIntro();
    startTimer();
  }

  void startTimer() {
    if (isShowOnlineTotal) {
      queryOnlineTotal();
      timer ??= Timer.periodic(const Duration(minutes: 1), (Timer timer) {
        queryOnlineTotal();
      });
      batteryDebug.trackTimerStart(
        'onlineTotal_$heroTag',
        const Duration(minutes: 1),
      );
    }
  }

  void cancelTimer() {
    if (timer != null) {
      batteryDebug.trackTimerStop('onlineTotal_$heroTag');
    }
    timer?.cancel();
    timer = null;
  }

  // 查看同时在看人数
  Future<void> queryOnlineTotal({bool Function()? isCurrent}) async {
    if (!isShowOnlineTotal) {
      return;
    }
    // 切换分集时允许调用方传入当前性检查，避免旧 cid 的在线人数回写到新页面。
    if (isCurrent?.call() == false) {
      return;
    }
    final result = await VideoHttp.onlineTotal(
      aid: aid,
      bvid: bvid,
      cid: cid.value,
    );
    if (isCurrent?.call() == false) {
      return;
    }
    if (result case Success(:final response)) {
      total.value = response;
    }
  }

  @override
  void onClose() {
    cancelTimer();
    super.onClose();
  }

  @override
  Future<void> onPayCoin(int coin, bool coinWithLike) async {
    await runWithActionLoading(IntroAction.coin, () async {
      final stat = getStat();
      if (stat == null) {
        return;
      }
      final res = await VideoHttp.coinVideo(
        bvid: bvid,
        multiply: coin,
        selectLike: coinWithLike ? 1 : 0,
      );
      if (res.isSuccess) {
        SmartDialog.showToast('投币成功');
        coinNum.value += coin;
        GlobalData().afterCoin(coin);
        stat.coin += coin;
        if (coinWithLike && !hasLike.value) {
          stat.like++;
          hasLike.value = true;
        }
      } else {
        res.toast();
      }
    });
  }

  Future<void> queryVideoTags({bool Function()? isCurrent}) async {
    // 标签请求和简介切换并行执行，返回前后都检查一次，防止慢请求覆盖新视频标签。
    if (isCurrent?.call() == false) {
      return;
    }
    final result = await UserHttp.videoTags(bvid: bvid, cid: cid.value);
    if (isCurrent?.call() == false) {
      return;
    }
    videoTags.value = result.dataOrNull;
  }

  Future<void> viewLater() async {
    await runWithActionLoading(IntroAction.watchLater, () async {
      final target = bvid;
      final account = Accounts.main;
      final isPageActive = videoDetailCtr.capturePageActivity();
      bool isCurrent() =>
          !isClosed &&
          bvid == target &&
          isPageActive() &&
          identical(account, Accounts.main);
      void onToast(String message) {
        if (isCurrent()) videoDetailCtr.showToast(message);
      }

      final res = hasLater.value
          ? await UserHttp.toViewDel(aids: aid, onToast: onToast)
          : await UserHttp.toViewLater(bvid: target, onToast: onToast);
      if (res.isSuccess && isCurrent()) hasLater.toggle();
    });
  }
}

mixin FavMixin on TripleMixin {
  Set? favIds;
  int? quickFavId;
  late final enableQuickFav = Pref.enableQuickFav;
  final Rx<FavFolderData> favFolderData = FavFolderData().obs;

  bool isActionLoading(IntroAction action);

  Future<T?> runWithActionLoading<T>(
    IntroAction action,
    FutureOr<T> Function() callback,
  );

  (Object, int) get getFavRidType;

  Future<LoadingState<FavFolderData>> queryVideoInFolder() async {
    favIds = null;
    final (rid, type) = getFavRidType;
    final res = await FavHttp.videoInFolder(
      mid: Accounts.main.mid,
      rid: rid,
      type: type,
    );
    if (res case Success(:final response)) {
      favFolderData.value = response;
      favIds = response.list
          ?.where((item) => item.favState == 1)
          .map((item) => item.id)
          .toSet();
    }
    return res;
  }

  int get favFolderId {
    if (this.quickFavId != null) {
      return this.quickFavId!;
    }
    final quickFavId = Pref.quickFavId;
    final list = favFolderData.value.list!;
    if (quickFavId != null) {
      final folderInfo = list.firstWhereOrNull((e) => e.id == quickFavId);
      if (folderInfo != null) {
        return this.quickFavId = quickFavId;
      } else {
        GStorage.setting.delete(SettingBoxKey.quickFavId);
      }
    }
    return this.quickFavId = list.first.id;
  }

  // 收藏
  void showFavBottomSheet(BuildContext context, {bool isLongPress = false}) {
    if (!Accounts.main.isLogin) {
      PlayerWindowNavigation.showToast(context, '账号未登录');
      return;
    }
    // 快速收藏 &
    // 点按 收藏至默认文件夹
    // 长按选择文件夹
    if (enableQuickFav) {
      if (!isLongPress) {
        actionFavVideo(isQuick: true, context: context);
      } else {
        PageUtils.showFavBottomSheet(context: context, ctr: this);
      }
    } else if (!isLongPress) {
      PageUtils.showFavBottomSheet(context: context, ctr: this);
    }
  }

  void updateFavCount(int count);

  Future<LoadingState<bool>?> actionFavVideo({
    bool isQuick = false,
    BuildContext? context,
  }) {
    if (isQuick && context != null && !Accounts.main.isLogin) {
      PlayerWindowNavigation.showToast(context, '账号未登录');
      return Future.value();
    }
    void showFeedback(String message) =>
        PlayerWindowNavigation.showToast(context, message);
    return runWithActionLoading<LoadingState<bool>?>(.favorite, () async {
      final (rid, type) = getFavRidType;
      final account = Accounts.main;
      final showGlobalFeedback =
          PlayerWindowNavigation.maybeOf(context) == null;
      bool isCurrent() =>
          !isClosed &&
          getFavRidType == (rid, type) &&
          identical(account, Accounts.main);
      // 收藏至默认文件夹
      if (isQuick) {
        if (showGlobalFeedback) SmartDialog.showLoading(msg: '请求中');
        String? message;
        try {
          final folders = await queryVideoInFolder();
          if (!isCurrent()) return null;
          if (!folders.isSuccess) {
            message = folders.toString();
            return null;
          }
          final hasFav = this.hasFav.value;
          if (!hasFav && folders.data.list?.isNotEmpty != true) {
            message = '没有可用的收藏夹';
            return null;
          }
          final result = hasFav
              ? await FavHttp.unfavAll(
                  rid: rid,
                  type: type,
                  showErrorToast: showGlobalFeedback,
                )
              : await FavHttp.favVideo(
                  resources: '$rid:$type',
                  addIds: favFolderId.toString(),
                  showErrorToast: showGlobalFeedback,
                );
          if (!isCurrent()) return null;
          if (result.isSuccess) {
            updateFavCount(hasFav ? -1 : 1);
            this.hasFav.toggle();
            message = '${hasFav ? '取消' : ''}收藏成功';
          } else {
            message = result.toString();
          }
        } finally {
          if (showGlobalFeedback) {
            SmartDialog.dismiss(status: SmartStatus.loading);
          }
          if (message != null) showFeedback(message);
        }
        return null;
      }

      final folders = favFolderData.value.list;
      if (folders == null) return null;
      final favIds = this.favIds;
      final addMediaIds = <int>[];
      final delMediaIds = <int>[];
      for (final folder in folders) {
        final wasFavorite = favIds?.contains(folder.id) == true;
        if (folder.favState == 1 && !wasFavorite) {
          addMediaIds.add(folder.id);
        } else if (folder.favState != 1 && wasFavorite) {
          delMediaIds.add(folder.id);
        }
      }
      final result = await FavHttp.favVideo(
        resources: '$rid:$type',
        addIds: addMediaIds.join(','),
        delIds: delMediaIds.join(','),
        showErrorToast: showGlobalFeedback,
      );
      if (!isCurrent()) return null;
      if (!result.isSuccess) return Error(result.toString());

      final isFavorite =
          addMediaIds.isNotEmpty || (favIds?.length ?? 0) > delMediaIds.length;
      if (hasFav.value != isFavorite) {
        updateFavCount(isFavorite ? 1 : -1);
        hasFav.value = isFavorite;
      }
      return Success(isFavorite);
    });
  }
}
