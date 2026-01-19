import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/models/common/later_view_type.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models_new/later/data.dart';
import 'package:PiliPlus/models_new/later/list.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart'
    show CommonListController;
import 'package:PiliPlus/pages/common/multi_select/base.dart';
import 'package:PiliPlus/pages/common/multi_select/multi_select_controller.dart';
import 'package:PiliPlus/pages/later/base_controller.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

mixin BaseLaterController
    on
        CommonListController<LaterData, LaterItemModel>,
        CommonMultiSelectMixin<LaterItemModel>,
        DeleteItemMixin<LaterData, LaterItemModel> {
  ValueChanged<int>? updateCount;

  /// 检查列表中的视频是否有离线缓存
  Future<void> checkOfflineCache() async {
    if (!Get.isRegistered<DownloadService>()) return;

    final downloadService = Get.find<DownloadService>();
    // 等待 DownloadService 初始化完成
    await downloadService.waitForInitialization;

    // 检查当前列表中的每个视频是否有离线缓存
    if (loadingState.value case Success(:final response)) {
      if (response != null) {
        bool hasChanges = false;
        for (var item in response) {
          if (item.cid != null) {
            final hasCache = downloadService.downloadList.any(
              (e) => e.cid == item.cid,
            );
            if (item.hasOfflineCache != hasCache) {
              item.hasOfflineCache = hasCache;
              hasChanges = true;
            }
          }
        }
        // 如果有变化，刷新UI
        if (hasChanges) {
          loadingState.refresh();
        }
      }
    }
  }

  @override
  void onRemove() {
    final removeList = allChecked.toSet();
    // 检查是否有视频有离线缓存
    final hasAnyCache = removeList.any((item) => item.hasOfflineCache);
    bool deleteCache = false;

    showDialog(
      context: Get.context!,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('提示'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('确认删除所选 ${removeList.length} 个稍后再看吗？'),
                  if (hasAnyCache) ...[
                    const SizedBox(height: 16),
                    CheckboxListTile(
                      value: deleteCache,
                      onChanged: (value) {
                        setState(() {
                          deleteCache = value ?? false;
                        });
                      },
                      title: const Text('同时删除有离线缓存的视频'),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: Get.back,
                  child: Text(
                    '取消',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    Get.back();
                    SmartDialog.showLoading(msg: '请求中');
                    final res = await UserHttp.toViewDel(
                      aids: removeList.map((item) => item.aid).join(','),
                    );
                    if (res.isSuccess) {
                      // 如果勾选了删除缓存，删除所有有离线缓存的视频
                      if (deleteCache && Get.isRegistered<DownloadService>()) {
                        final downloadService = Get.find<DownloadService>();
                        int deletedCount = 0;
                        for (var item in removeList) {
                          if (item.hasOfflineCache && item.cid != null) {
                            final downloadEntry = downloadService.downloadList
                                .firstWhereOrNull((e) => e.cid == item.cid);
                            if (downloadEntry != null) {
                              await downloadService.deleteDownload(
                                entry: downloadEntry,
                                removeList: true,
                                downloadNext: false,
                                refresh: false,
                              );
                              deletedCount++;
                            }
                          }
                        }
                        if (deletedCount > 0) {
                          downloadService.flagNotifier.refresh();
                          SmartDialog.dismiss();
                          SmartDialog.showToast(
                            '已删除 ${removeList.length} 个稍后再看和 $deletedCount 个离线缓存',
                          );
                        }
                      } else {
                        SmartDialog.dismiss();
                        res.toast();
                      }
                      updateCount?.call(removeList.length);
                      afterDelete(removeList);
                    } else {
                      SmartDialog.dismiss();
                      res.toast();
                    }
                  },
                  child: const Text('确认删除'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // single
  void toViewDel(
    BuildContext context,
    int index,
    int? aid,
  ) {
    final item = loadingState.value.data![index];
    final hasCache = item.hasOfflineCache;
    bool deleteCache = false;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('提示'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('即将移除该视频，确定是否移除'),
                  if (hasCache) ...[
                    const SizedBox(height: 16),
                    CheckboxListTile(
                      value: deleteCache,
                      onChanged: (value) {
                        setState(() {
                          deleteCache = value ?? false;
                        });
                      },
                      title: const Text('同时删除离线缓存'),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: Get.back,
                  child: Text(
                    '取消',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    Get.back();
                    final res = await UserHttp.toViewDel(aids: aid.toString());
                    if (res.isSuccess) {
                      // 如果勾选了删除缓存，同时删除离线缓存
                      if (deleteCache &&
                          item.cid != null &&
                          Get.isRegistered<DownloadService>()) {
                        final downloadService = Get.find<DownloadService>();
                        final downloadEntry = downloadService.downloadList
                            .firstWhereOrNull((e) => e.cid == item.cid);
                        if (downloadEntry != null) {
                          await downloadService.deleteDownload(
                            entry: downloadEntry,
                            removeList: true,
                            downloadNext: false,
                          );
                          SmartDialog.showToast('已删除稍后再看和离线缓存');
                        }
                      }
                      loadingState
                        ..value.data!.removeAt(index)
                        ..refresh();
                      updateCount?.call(1);
                    }
                    if (!deleteCache || !hasCache) {
                      res.toast();
                    }
                  },
                  child: const Text('确认移除'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class LaterController extends MultiSelectController<LaterData, LaterItemModel>
    with BaseLaterController {
  LaterController(this.laterViewType);
  final LaterViewType laterViewType;

  late final mid = Accounts.main.mid;

  final RxBool asc = false.obs;

  final LaterBaseController baseCtr = Get.put(LaterBaseController());

  @override
  RxBool get enableMultiSelect => baseCtr.enableMultiSelect;

  @override
  RxInt get rxCount => baseCtr.checkedCount;

  @override
  Future<LoadingState<LaterData>> customGetData() => UserHttp.seeYouLater(
    page: page,
    viewed: laterViewType.type,
    asc: asc.value,
  );

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  Future<void> queryData([bool isRefresh = true]) async {
    await super.queryData(isRefresh);
    // 数据加载完成后，检查离线缓存状态
    await checkOfflineCache();
  }

  @override
  List<LaterItemModel>? getDataList(response) {
    baseCtr.counts[laterViewType.index] = response.count ?? 0;
    final list = response.list;
    // 注意：这里不立即检查缓存，因为 DownloadService 可能还在初始化
    // 缓存检查将在 checkOfflineCache 中异步执行
    return list;
  }

  @override
  void checkIsEnd(int length) {
    if (length >= baseCtr.counts[laterViewType.index]) {
      isEnd = true;
    }
  }

  // 一键清空
  void toViewClear(BuildContext context, [int? cleanType]) {
    String content = switch (cleanType) {
      1 => '确定清空已失效视频吗？',
      2 => '确定清空已看完视频吗？',
      _ => '确定清空稍后再看列表吗？',
    };
    showConfirmDialog(
      context: context,
      title: '确认',
      content: content,
      onConfirm: () async {
        final res = await UserHttp.toViewClear(cleanType);
        if (res.isSuccess) {
          onReload();
          final restTypes = List<LaterViewType>.from(LaterViewType.values)
            ..remove(laterViewType);
          for (final item in restTypes) {
            try {
              Get.find<LaterController>(tag: item.type.toString()).onReload();
            } catch (_) {}
          }
          SmartDialog.showToast('操作成功');
        } else {
          res.toast();
        }
      },
    );
  }

  // 稍后再看播放全部
  void toViewPlayAll() {
    if (loadingState.value case Success(:final response)) {
      if (response == null || response.isEmpty) return;

      for (LaterItemModel item in response) {
        if (item.cid == null || item.pgcLabel?.isNotEmpty == true) {
          continue;
        } else {
          PageUtils.toVideoPage(
            bvid: item.bvid,
            cid: item.cid!,
            cover: item.pic,
            title: item.title,
            extraArguments: {
              'sourceType': SourceType.watchLater,
              'count': baseCtr.counts[LaterViewType.all.index],
              'favTitle': '稍后再看',
              'mediaId': mid,
              'desc': asc.value,
            },
          );
          break;
        }
      }
    }
  }

  /// 批量缓存当前选中的 "稍后再看" 条目
  Future<void> batchDownloadSelected({VideoQuality? quality}) async {
    final selected = allChecked.toList();
    if (selected.isEmpty) {
      SmartDialog.showToast('未选择条目');
      return;
    }
    SmartDialog.showLoading(msg: '正在加入下载队列');
    final ds = Get.find<DownloadService>();
    for (final item in selected) {
      try {
        final bvid = item.bvid;
        final aid = item.aid;
        int? cid = item.cid;
        if (bvid == null && cid == null) continue;
        cid ??= await SearchHttp.ab2c(aid: aid, bvid: bvid);
        final int totalTimeMilli = (item.duration ?? 0) * 1000;
        if (cid == null || totalTimeMilli <= 0) continue;
        await ds.downloadByIdentifiers(
          cid: cid,
          bvid: bvid ?? '',
          totalTimeMilli: totalTimeMilli,
          aid: aid,
          title: item.title,
          cover: item.pic,
          ownerId: item.owner?.mid,
          ownerName: item.owner?.name,
          quality: quality,
        );
      } catch (_) {}
    }
    SmartDialog.dismiss();
    SmartDialog.showToast('已加入下载队列（如需查看请前往离线缓存）');
    // 关闭多选
    handleSelect(checked: false);
  }

  @override
  ValueChanged<int>? get updateCount =>
      (count) => baseCtr.counts[laterViewType.index] -= count;

  @override
  Future<void> onReload() {
    scrollController.jumpToTop();
    return super.onReload();
  }
}
