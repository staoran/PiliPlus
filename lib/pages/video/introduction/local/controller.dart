import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/download/download_info.dart';
import 'package:PiliPlus/models_new/video/video_detail/stat_detail.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/download/download/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class LocalIntroController extends CommonIntroController {
  @override
  void queryVideoIntro() {}

  @override
  int get copyright => throw UnimplementedError();

  @override
  void actionCoinVideo() {
    SmartDialog.showToast('离线播放不支持该操作');
  }

  @override
  Future<void> actionLikeVideo() async {
    SmartDialog.showToast('离线播放不支持该操作');
  }

  @override
  void actionShareVideo(context) {
    SmartDialog.showToast('离线播放不支持该操作');
  }

  @override
  Future<void> actionTriple() async {
    SmartDialog.showToast('离线播放不支持该操作');
  }

  @override
  Future<void> actionFavVideo({bool isQuick = false}) async {
    SmartDialog.showToast('离线播放不支持该操作');
  }

  @override
  (Object, int) get getFavRidType => (bvid, 2);

  @override
  StatDetail? getStat() => videoDetail.value.stat;

  @override
  bool get isShowOnlineTotal => false;

  late final Set<String> aidSet = {};

  @override
  void onClose() {
    aidSet.clear();
    super.onClose();
  }

  @override
  void onInit() {
    super.onInit();
    final argTitle = videoDetailCtr.args['title'];
    if (argTitle is String && argTitle.trim().isNotEmpty) {
      videoDetail.value.title = argTitle;
    }

    _loadDownloadList();
  }

  Future<void> _loadDownloadList() async {
    final list = <BiliDownloadEntryInfo>[];

    if (!Get.isRegistered<DownloadService>()) return;
    final downloadService = Get.find<DownloadService>();
    await downloadService.waitForInitialization;
    if (isClosed) return;
    final registeredSeasons = Get.isRegistered<DownloadController>()
        ? Get.find<DownloadController>().seasons
        : null;
    final seasons = registeredSeasons?.isNotEmpty == true
        ? registeredSeasons!
        : groupDownloadEntries(downloadService.downloadList);
    for (final season in seasons) {
      final pages = season.pages.toList()
        ..sort((a, b) => a.sortKey.compareTo(b.sortKey));
      for (final page in pages) {
        final completed = page.entries.where((e) => e.isCompleted).toList()
          ..sort(downloadEntrySort);
        list.addAll(completed);
        if (completed.length == 1) aidSet.add(page.pageId);
      }
    }

    this.list.value = list;
    final currCid = videoDetailCtr.cid.value;
    final index = list.indexWhere((e) => e.cid == currCid);
    this.index.value = index;
    if (!(videoDetail.value.title?.trim().isNotEmpty ?? false) &&
        index >= 0 &&
        index < list.length) {
      videoDetail.value.title = list[index].showTitle;
    }
    if (PlatformUtils.isMobile && index >= 0 && index < list.length) {
      onVideoDetailChange(list[index]);
    }
    if (index != 0) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (isClosed) return;
        try {
          final state = videoDetailCtr.scrollKey.currentState;
          if (state != null && state.mounted) {
            (state.innerController as ExtendedNestedScrollController)
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
  double get _offset => index * 112 + 7 - 35;
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
          playCtr.play(repeat: true);
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
      ..initFileSource(entry)
      ..queryVideoUrl();

    // 仅更新本地标题，避免引入在线详情/评论等不稳定逻辑
    videoDetail
      ..value.title = entry.showTitle
      ..refresh();

    this.index.value = index;
    if (PlatformUtils.isMobile) {
      onVideoDetailChange(entry);
    }
  }

  void onVideoDetailChange(BiliDownloadEntryInfo entry) {
    if (isClosed) {
      return;
    }
    videoPlayerServiceHandler?.onVideoDetailChange(entry, entry.cid, heroTag);
  }
}
