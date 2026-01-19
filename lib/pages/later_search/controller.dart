import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/models_new/later/data.dart';
import 'package:PiliPlus/models_new/later/list.dart';
import 'package:PiliPlus/pages/common/multi_select/base.dart';
import 'package:PiliPlus/pages/common/search/common_search_controller.dart';
import 'package:PiliPlus/pages/later/controller.dart' show BaseLaterController;
import 'package:get/get.dart';

class LaterSearchController
    extends CommonSearchController<LaterData, LaterItemModel>
    with
        CommonMultiSelectMixin<LaterItemModel>,
        DeleteItemMixin,
        BaseLaterController {
  dynamic mid = Get.arguments['mid'];
  dynamic count = Get.arguments['count'];

  @override
  Future<LoadingState<LaterData>> customGetData() => UserHttp.seeYouLater(
    page: page,
    keyword: editController.value.text,
  );

  @override
  List<LaterItemModel>? getDataList(LaterData response) {
    final list = response.list;
    // 注意：这里不立即检查缓存，因为 DownloadService 可能还在初始化
    // 缓存检查将在 checkOfflineCache 中异步执行
    return list;
  }

  @override
  Future<void> queryData([bool isRefresh = true]) async {
    await super.queryData(isRefresh);
    // 数据加载完成后，检查离线缓存状态
    await checkOfflineCache();
  }
}
