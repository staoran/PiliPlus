import 'package:PiliPlus/common/widgets/custom_toast.dart';
import 'package:PiliPlus/utils/desktop/window_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class PlayerWindowNavigation extends InheritedWidget {
  const PlayerWindowNavigation({
    required this.observer,
    required super.child,
    super.key,
  });

  final RouteObserver<PageRoute<dynamic>> observer;
  static final _toasts = Expando<OverlayEntry>();

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

  static Future<void> showToast(
    BuildContext? context,
    String message, {
    Duration? displayTime,
  }) async {
    if (context != null && !context.mounted) return;
    if (context == null || maybeOf(context) == null) {
      await SmartDialog.showToast(message, displayTime: displayTime);
      return;
    }
    final overlay = Navigator.maybeOf(context)?.overlay;
    if (overlay == null || !overlay.mounted) return;
    _toasts[overlay]
      ?..remove()
      ..dispose();
    final entry = OverlayEntry(
      builder: (_) => IgnorePointer(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: CustomToast(message),
        ),
      ),
    );
    overlay.insert(entry);
    _toasts[overlay] = entry;
    await Future<void>.delayed(displayTime ?? const Duration(seconds: 2));
    if (_toasts[overlay] != entry) return;
    _toasts[overlay] = null;
    entry
      ..remove()
      ..dispose();
  }

  @override
  bool updateShouldNotify(PlayerWindowNavigation oldWidget) =>
      observer != oldWidget.observer;
}
