import 'dart:async';

import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/dynamic/dynamics_type.dart';
import 'package:PiliPlus/models/common/nav_bar_config.dart';
import 'package:PiliPlus/models/dynamics/result.dart';
import 'package:PiliPlus/pages/common/common_page.dart';
import 'package:PiliPlus/pages/dynamics/controller.dart';
import 'package:PiliPlus/pages/dynamics/widgets/dynamic_panel.dart';
import 'package:PiliPlus/pages/dynamics_tab/controller.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/waterfall.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:waterfall_flow/waterfall_flow.dart'
    hide SliverWaterfallFlowDelegateWithMaxCrossAxisExtent;

class DynamicsTabPage extends StatefulWidget {
  const DynamicsTabPage({super.key, required this.dynamicsType});

  final DynamicsTabType dynamicsType;

  @override
  State<DynamicsTabPage> createState() => _DynamicsTabPageState();
}

class _DynamicsTabPageState
    extends CommonPageState<DynamicsTabPage, DynamicsTabController>
    with AutomaticKeepAliveClientMixin, DynMixin {
  late final MainController _mainController = Get.find<MainController>();

  final dynamicsController = Get.putOrFind(DynamicsController.new);

  @override
  late final DynamicsTabController controller;

  @override
  bool get wantKeepAlive => true;

  bool get checkPage =>
      _mainController.navigationBars[0] != NavigationBarType.dynamics &&
      _mainController.selectedIndex.value == 0;

  StreamController<bool>? get _upPanelStream =>
      dynamicsController.upPanelStream;

  @override
  bool onNotificationType1(UserScrollNotification notification) {
    if (checkPage) {
      return false;
    }
    // 同时触发 UP 主面板收起
    if (notification.metrics.axis == Axis.vertical) {
      final direction = notification.direction;
      if (direction == ScrollDirection.forward) {
        _upPanelStream?.add(true);
      } else if (direction == ScrollDirection.reverse) {
        _upPanelStream?.add(false);
      }
    }
    return super.onNotificationType1(notification);
  }

  // UP主面板向上滚动计数器
  double _upPanelUpScrollCount = 0.0;
  double? _upPanelLastScrollPosition;

  @override
  bool onNotificationType2(ScrollNotification notification) {
    if (checkPage) {
      return false;
    }
    // 同时触发 UP 主面板收起（使用与底栏相同的阈值逻辑）
    if (_upPanelStream != null) {
      final scrollController = controller.scrollController;
      final direction = scrollController.position.userScrollDirection;
      final double currentPosition = scrollController.position.pixels;

      _upPanelLastScrollPosition ??= currentPosition;
      final double scrollDelta = currentPosition - _upPanelLastScrollPosition!;

      if (direction == ScrollDirection.reverse) {
        _upPanelStream?.add(false);
        _upPanelUpScrollCount = 0.0;
      } else if (direction == ScrollDirection.forward) {
        if (scrollDelta < 0) {
          _upPanelUpScrollCount += (-scrollDelta);
          if (_upPanelUpScrollCount >= scrollThreshold) {
            _upPanelStream?.add(true);
          }
        }
      }

      _upPanelLastScrollPosition = currentPosition;
    }
    return super.onNotificationType2(notification);
  }

  @override
  void initState() {
    controller = Get.putOrFind(
      () => DynamicsTabController(dynamicsType: widget.dynamicsType),
      tag: widget.dynamicsType.name,
    );
    super.initState();
  }

  Future<void> onRefresh() {
    dynamicsController.singleRefresh();
    return controller.onRefresh();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return onBuild(
      refreshIndicator(
        key: refreshIndicatorKey,
        onRefresh: onRefresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          controller: controller.scrollController,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.only(bottom: 100),
              sliver: buildPage(
                Obx(() => _buildBody(controller.loadingState.value)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(LoadingState<List<DynamicItemModel>?> loadingState) {
    return switch (loadingState) {
      Loading() => dynSkeleton,
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? GlobalData().dynamicsWaterfallFlow
                  ? SliverWaterfallFlow(
                      gridDelegate: dynGridDelegate,
                      delegate: SliverChildBuilderDelegate(
                        (_, index) => _itemBuilder(response, index),
                        childCount: response.length,
                      ),
                    )
                  : SliverList.builder(
                      itemBuilder: (context, index) =>
                          _itemBuilder(response, index),
                      itemCount: response.length,
                    )
            : HttpError(onReload: controller.onReload),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: controller.onReload,
      ),
    };
  }

  Widget _itemBuilder(List<DynamicItemModel> list, int index) {
    if (index == list.length - 1) {
      controller.onLoadMore();
    }
    final item = list[index];
    return DynamicPanel(
      item: item,
      onRemove: (idStr) => controller.onRemove(index, idStr),
      onBlock: () => controller.onBlock(index),
      onUnfold: () => controller.onUnfold(item, index),
    );
  }
}
