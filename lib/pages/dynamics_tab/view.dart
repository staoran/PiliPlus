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
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/waterfall.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart';
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
  StreamSubscription? _listener;
  late final MainController _mainController = Get.find<MainController>();

  DynamicsController dynamicsController = Get.put(DynamicsController());
  @override
  late DynamicsTabController controller = Get.put(
    DynamicsTabController(dynamicsType: widget.dynamicsType)
      ..mid = dynamicsController.mid.value,
    tag: widget.dynamicsType.name,
  );

  @override
  bool get wantKeepAlive => true;

  bool get checkPage =>
      _mainController.navigationBars[0] != NavigationBarType.dynamics &&
      _mainController.selectedIndex.value == 0;

  StreamController<bool>? get _upPanelStream => dynamicsController.upPanelStream;

  @override
  bool onNotification(UserScrollNotification notification) {
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
    return super.onNotification(notification);
  }

  // UP主面板向上滚动计数器
  double _upPanelUpScrollCount = 0.0;
  double? _upPanelLastScrollPosition;

  @override
  void listener() {
    if (checkPage) {
      return;
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
    super.listener();
  }

  @override
  void initState() {
    super.initState();
    // 如果启用阈值且有 upPanelStream，但父类没有添加监听器，则在此添加
    if (enableScrollThreshold &&
        _upPanelStream != null &&
        mainStream == null &&
        searchBarStream == null) {
      controller.scrollController.addListener(listener);
    }
    if (widget.dynamicsType == DynamicsTabType.up) {
      _listener = dynamicsController.mid.listen((mid) {
        if (mid != -1) {
          controller
            ..mid = mid
            ..onReload();
        }
      });
    }
  }

  @override
  void dispose() {
    _listener?.cancel();
    dynamicsController.mid.close();
    super.dispose();
  }

  @override
  Widget onBuild(Widget child) {
    // 如果未启用阈值且有 upPanelStream，需要添加 NotificationListener
    if (!enableScrollThreshold &&
        _upPanelStream != null &&
        mainStream == null &&
        searchBarStream == null) {
      return NotificationListener<UserScrollNotification>(
        onNotification: onNotification,
        child: child,
      );
    }
    return super.onBuild(child);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return onBuild(
      refreshIndicator(
        key: refreshIndicatorKey,
        onRefresh: () {
          dynamicsController.queryFollowUp();
          return controller.onRefresh();
        },
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
      Success(:var response) =>
        response != null && response.isNotEmpty
            ? GlobalData().dynamicsWaterfallFlow
                  ? SliverWaterfallFlow(
                      gridDelegate: dynGridDelegate,
                      delegate: SliverChildBuilderDelegate(
                        (_, index) {
                          if (index == response.length - 1) {
                            controller.onLoadMore();
                          }
                          final item = response[index];
                          return DynamicPanel(
                            item: item,
                            onRemove: (idStr) =>
                                controller.onRemove(index, idStr),
                            onBlock: () => controller.onBlock(index),
                            maxWidth: maxWidth,
                            onUnfold: () => controller.onUnfold(item, index),
                          );
                        },
                        childCount: response.length,
                      ),
                    )
                  : SliverList.builder(
                      itemBuilder: (context, index) {
                        if (index == response.length - 1) {
                          controller.onLoadMore();
                        }
                        final item = response[index];
                        return DynamicPanel(
                          item: item,
                          onRemove: (idStr) =>
                              controller.onRemove(index, idStr),
                          onBlock: () => controller.onBlock(index),
                          maxWidth: maxWidth,
                          onUnfold: () => controller.onUnfold(item, index),
                        );
                      },
                      itemCount: response.length,
                    )
            : HttpError(onReload: controller.onReload),
      Error(:var errMsg) => HttpError(
        errMsg: errMsg,
        onReload: controller.onReload,
      ),
    };
  }
}
