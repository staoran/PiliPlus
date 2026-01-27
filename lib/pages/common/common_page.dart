import 'dart:ui' show clampDouble;

import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart'
    as custom_refresh;
import 'package:PiliPlus/pages/common/common_controller.dart';
import 'package:PiliPlus/pages/dynamics/controller.dart';
import 'package:PiliPlus/pages/home/controller.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

abstract class CommonPageState<
  T extends StatefulWidget,
  R extends CommonController
>
    extends State<T> {
  R get controller;
  final _mainController = Get.find<MainController>();
  RxBool? _showBottomBar;
  RxBool? _showSearchBar;

  // late double _downScrollCount = 0.0; // 向下滚动计数器
  late double _upScrollCount = 0.0; // 向上滚动计数器
  double? _lastScrollPosition; // 记录上次滚动位置

  // 恢复：子类依赖这些字段
  final enableScrollThreshold = Pref.enableScrollThreshold;
  late final double scrollThreshold = Pref.scrollThreshold; // 滚动阈值

  // 新增：平滑过渡范围
  late final double scrollRange = enableScrollThreshold
      ? scrollThreshold
      : 100.0;

  late final _scrollController = controller.scrollController;

  /// 刷新指示器的 Key，用于编程式触发刷新动画
  final refreshIndicatorKey = GlobalKey<custom_refresh.RefreshIndicatorState>();

  @override
  void initState() {
    super.initState();
    _showBottomBar = _mainController.showBottomBar;
    try {
      _showSearchBar = Get.find<HomeController>().showSearchBar;
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
    if (!enableScrollThreshold &&
        (_showBottomBar != null || _showSearchBar != null)) {
      return NotificationListener<UserScrollNotification>(
        onNotification: onNotification,
        child: child,
      );
    }
    return child;
  }

  // 恢复：子类覆盖了此方法
  bool onNotification(UserScrollNotification notification) {
    if (notification.metrics.axis == .horizontal) return false;
    if (!_mainController.useBottomNav) return false;
    final direction = notification.direction;
    if (direction == .forward) {
      _showBottomBar?.value = true;
      _showSearchBar?.value = true;
    } else if (direction == .reverse) {
      _showBottomBar?.value = false;
      _showSearchBar?.value = false;
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
    _showSearchBar = null;
    _showBottomBar = null;
    _scrollController.removeListener(listener);
    super.dispose();
  }
}
