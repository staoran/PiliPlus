import 'package:PiliPlus/common/widgets/custom_toast.dart';
import 'package:PiliPlus/utils/desktop/window_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

class PlayerWindowNavigation extends InheritedWidget {
  const PlayerWindowNavigation({
    required this.observer,
    required super.child,
    super.key,
  });

  final RouteObserver<PageRoute<dynamic>> observer;

  static PlayerWindowNavigation? maybeOf(BuildContext? context) =>
      context?.getInheritedWidgetOfExactType<PlayerWindowNavigation>();

  static T putController<T>(T controller, {required String? tag}) {
    // These controllers are deleted by their page. GetX only observes the
    // main Navigator and would otherwise attach them to its current route.
    final management = Get.smartManagement;
    Get.smartManagement = SmartManagement.onlyBuilder;
    try {
      return Get.put(controller, tag: tag);
    } finally {
      Get.smartManagement = management;
    }
  }

  static void showMainFrom(BuildContext context) {
    if (maybeOf(context) != null) WindowController.instance.show();
  }

  static Future<T?>? openInMain<T>(
    BuildContext context,
    String name, {
    Object? arguments,
    Map<String, String>? parameters,
  }) {
    showMainFrom(context);
    return Get.toNamed<T>(name, arguments: arguments, parameters: parameters);
  }

  static Future<void> showToast(BuildContext context, String message) async {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final entry = OverlayEntry(
      builder: (_) => IgnorePointer(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: CustomToast(message),
        ),
      ),
    );
    overlay.insert(entry);
    await Future<void>.delayed(const Duration(seconds: 2));
    entry
      ..remove()
      ..dispose();
  }

  @override
  bool updateShouldNotify(PlayerWindowNavigation oldWidget) =>
      observer != oldWidget.observer;
}
