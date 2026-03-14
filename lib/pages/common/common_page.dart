import 'package:PiliPlus/common/constants.dart' show StyleString;
import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart'
    as custom_refresh;
import 'package:PiliPlus/pages/common/common_controller.dart';
import 'package:PiliPlus/pages/dynamics/controller.dart';
import 'package:PiliPlus/pages/home/controller.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/material.dart';
import 'package:get/get.dart';

abstract class CommonPageState<
  T extends StatefulWidget,
  R extends CommonController
>
    extends State<T> {
  R get controller;
  RxDouble? _barOffset;
  RxBool? _showTopBar;
  RxBool? _showBottomBar;
  RxBool? _showSearchBar;
  final _mainController = Get.find<MainController>();

  // late double _downScrollCount = 0.0; // 向下滚动计数器
  late double _upScrollCount = 0.0; // 向上滚动计数器
  double? _lastScrollPosition; // 记录上次滚动位置

  // 子类依赖这些字段（阈值设置已移除，使用固定默认值）
  final bool enableScrollThreshold = false;
  final double scrollThreshold = 80.0; // 滚动阈值
  final double scrollRange = 100.0; // 平滑过渡范围

  late final _scrollController = controller.scrollController;

  /// 刷新指示器的 Key，用于编程式触发刷新动画
  final refreshIndicatorKey = GlobalKey<custom_refresh.RefreshIndicatorState>();

  bool get needsCorrection => false;

  @override
  void initState() {
    super.initState();
    _barOffset = _mainController.barOffset;
    _showBottomBar = _mainController.showBottomBar;
    try {
      _showTopBar = Get.find<HomeController>().showTopBar;
    } catch (_) {}

    // 强制添加监听，不再依赖 enableScrollThreshold 配置，以实现跟随手指滑动
    // 注意：即使 enableScrollThreshold 为 false，我们也添加监听器
    controller.scrollController.addListener(listener);

    // 设置刷新回调
    controller.showRefreshIndicator = () {
      return refreshIndicatorKey.currentState?.show() ?? controller.onRefresh();
    };
  }

  Widget onBuild(Widget child) {
    if (_barOffset != null) {
      return NotificationListener<ScrollNotification>(
        onNotification: onNotificationType2,
        child: child,
      );
    }
    if (_showTopBar != null || _showBottomBar != null || _showSearchBar != null) {
      return NotificationListener<UserScrollNotification>(
        onNotification: onNotificationType1,
        child: child,
      );
    }
    return child;
  }

  bool onNotificationType1(UserScrollNotification notification) {
    if (!_mainController.useBottomNav) return false;
    if (notification.metrics.axis == .horizontal) return false;
    switch (notification.direction) {
      case .forward:
        _showTopBar?.value = true;
        _showBottomBar?.value = true;
        _showSearchBar?.value = true;
      case .reverse:
        _showTopBar?.value = false;
        _showBottomBar?.value = false;
        _showSearchBar?.value = false;
      case _:
    }
    return false;
  }

  void _updateOffset(double scrollDelta) {
    _barOffset!.value = clampDouble(
      _barOffset!.value + scrollDelta,
      0.0,
      StyleString.topBarHeight,
    );
  }

  bool onNotificationType2(ScrollNotification notification) {
    if (!_mainController.useBottomNav) return false;

    final metrics = notification.metrics;
    if (metrics.axis == .horizontal) return false;

    if (notification is ScrollUpdateNotification) {
      if (notification.dragDetails == null) return false;
      final pixel = metrics.pixels;
      final scrollDelta = notification.scrollDelta ?? 0;
      if (pixel < 0.0 && scrollDelta > 0) return false;
      if (needsCorrection) {
        final value = _barOffset!.value;
        final newValue = clampDouble(
          value + scrollDelta,
          0.0,
          StyleString.topBarHeight,
        );
        final offset = value - newValue;
        if (offset != 0) {
          _barOffset!.value = newValue;
          if (pixel < 0.0 && scrollDelta < 0.0 && value > 0.0) {
            return false;
          }
          Scrollable.of(notification.context!).position.correctBy(offset);
        }
      } else {
        _updateOffset(scrollDelta);
      }
      return false;
    }

    if (notification is OverscrollNotification) {
      _updateOffset(notification.overscroll);
      return false;
    }

    return false;
  }

  void listener() {
    if (!_mainController.useBottomNav) return;
    if (!_scrollController.hasClients) return;

    final direction = _scrollController.position.userScrollDirection;
    final double currentPosition = _scrollController.position.pixels;

    // 初始化上次位置
    _lastScrollPosition ??= currentPosition;

    // 计算滚动距离
    final double scrollDelta = currentPosition - _lastScrollPosition!;

    if (direction == .reverse) {
      _showBottomBar?.value = false;
      _showSearchBar?.value = false; // // 向下滚动，累加向下滚动距离，重置向上滚动计数器
      _upScrollCount = 0.0; // 重置向上滚动计数器
      // if (scrollDelta > 0) {
      //   _downScrollCount += scrollDelta;
      //   // _upScrollCount = 0.0; // 重置向上滚动计数器

      //   // 当累计向下滚动距离超过阈值时，隐藏顶底栏
      //   if (_downScrollCount >= _scrollThreshold) {
      //     mainStream?.add(false);
      //     searchBarStream?.add(false);
      //   }
      // }
    } else if (direction == .forward) {
      // 向上滚动，累加向上滚动距离，重置向下滚动计数器
      if (scrollDelta < 0) {
        _upScrollCount -= scrollDelta; // 使用绝对值
        // _downScrollCount = 0.0; // 重置向下滚动计数器

        // 当累计向上滚动距离超过阈值时，显示顶底栏
        if (_upScrollCount >= scrollThreshold) {
          _showBottomBar?.value = true;
          _showSearchBar?.value = true;
        }
      }
    }

    // 更新上次位置
    _lastScrollPosition = currentPosition;

    // 如果变化很小，忽略
    if (scrollDelta.abs() < 0.01) return;

    // 获取控制器
    MainController? mainCtr;
    HomeController? homeCtr;
    DynamicsController? dynCtr;
    try {
      mainCtr = Get.find<MainController>();
    } catch (_) {}
    try {
      homeCtr = Get.find<HomeController>();
    } catch (_) {}
    try {
      dynCtr = Get.find<DynamicsController>();
    } catch (_) {}

    // Debug logs
    // if (scrollDelta.abs() > 0.5) {
    //   debugPrint(
    //     'CommonPage: delta=${scrollDelta.toStringAsFixed(2)} bottom=${mainCtr?.bottomBarRatio.value.toStringAsFixed(2)} search=${homeCtr?.searchBarRatio.value.toStringAsFixed(2)}',
    //   );
    // }

    // 更新各个 Ratio
    // 逻辑：向下滑动 (delta > 0) -> ratio 减小
    //       向上滑动 (delta < 0) -> ratio 增加
    //       ratio 范围 [0, 1]

    final double change = deltaToRatioChange(scrollDelta);

    if (mainCtr != null) {
      final newRatio = clampDouble(
        mainCtr.bottomBarRatio.value + change,
        0.0,
        1.0,
      );
      mainCtr.bottomBarRatio.value = newRatio;
      // 兼容旧逻辑：发送布尔值
      if (newRatio == 0) _showBottomBar?.value = false;
      if (newRatio == 1) _showBottomBar?.value = true;
    }

    if (homeCtr != null) {
      final newRatio = clampDouble(
        homeCtr.searchBarRatio.value + change,
        0.0,
        1.0,
      );
      homeCtr.searchBarRatio.value = newRatio;
      // 兼容旧逻辑
      if (newRatio == 0) _showSearchBar?.value = false;
      if (newRatio == 1) _showSearchBar?.value = true;
    }

    if (dynCtr != null) {
      final newRatio = clampDouble(
        dynCtr.upPanelRatio.value + change,
        0.0,
        1.0,
      );
      dynCtr.upPanelRatio.value = newRatio;
      // 兼容旧逻辑
      if (newRatio == 0 && dynCtr.upPanelStream != null) {
        dynCtr.upPanelStream!.add(false);
      }
      if (newRatio == 1 && dynCtr.upPanelStream != null) {
        dynCtr.upPanelStream!.add(true);
      }
    }
  }

  /// 将滚动 delta 转换为 ratio 变化量
  /// 向下滚动 (delta > 0) -> ratio 减少 -> 返回负值
  /// 向上滚动 (delta < 0) -> ratio 增加 -> 返回正值
  double deltaToRatioChange(double delta) {
    if (delta == 0) return 0;
    // ratio 变化 = -delta / range
    return -delta / scrollRange;
  }

  @override
  void dispose() {
    _barOffset = null;
    _showSearchBar = null;
    _scrollController.removeListener(listener);
    _showTopBar = null;
    _showBottomBar = null;
    super.dispose();
  }
}