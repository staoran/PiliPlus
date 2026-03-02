import 'dart:async';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/widgets.dart' show ScrollController;
import 'package:get/get.dart';

mixin ScrollOrRefreshMixin {
  ScrollController get scrollController;

  /// 显示刷新指示器的回调，由 View 层设置
  Future<void> Function()? showRefreshIndicator;

  void animateToTop() => scrollController.animToTop();

  Future<void> onRefresh();

  void toTopOrRefresh() {
    if (scrollController.hasClients) {
      EasyThrottle.throttle(
        'topOrRefresh',
        const Duration(milliseconds: 500),
        () {
          // 无论在哪个位置，都回到顶部并刷新
          animateToTop();
          // 显示刷新动画
          if (showRefreshIndicator != null) {
            showRefreshIndicator!();
          } else {
            onRefresh();
          }
        },
      );
    }
  }
}

abstract class CommonController<R, T> extends GetxController
    with ScrollOrRefreshMixin {
  @override
  final ScrollController scrollController = ScrollController();

  bool isLoading = false;
  Rx<LoadingState> get loadingState;

  Future<LoadingState<R>> customGetData();

  Future<void> queryData([bool isRefresh = true]);

  bool customHandleResponse(bool isRefresh, Success<R> response) {
    return false;
  }

  bool handleError(String? errMsg) {
    return false;
  }

  @override
  Future<void> onRefresh() {
    return queryData();
  }

  Future<void> onLoadMore() {
    return queryData(false);
  }

  Future<void> onReload() {
    return onRefresh();
  }

  @override
  void onClose() {
    scrollController.dispose();
    super.onClose();
  }
}
