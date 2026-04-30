import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/rendering.dart' show Offset, Size;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

Future<Offset> calcWindowPosition(Size windowSize) async {
  final displays = await screenRetriever.getAllDisplays();
  final cursorScreenPoint = await screenRetriever.getCursorScreenPoint();

  final currentDisplay =
      displays.firstWhereOrNull(
        (display) => (display.visiblePosition! & display.size).contains(
          cursorScreenPoint,
        ),
      ) ??
      await screenRetriever.getPrimaryDisplay();

  final windowPosition = Pref.windowPosition;
  if (windowPosition != null) {
    try {
      var dx = windowPosition[0];
      var dy = windowPosition[1];

      // DPI 校正：将保存时的逻辑坐标转换为当前 DPI 下的正确坐标
      final savedScale = Pref.windowScaleFactor;
      final currentScale = windowManager.getDevicePixelRatio();
      if (savedScale != null && (savedScale - currentScale).abs() >= 0.01) {
        // 先转为物理坐标，再用当前 DPI 转回逻辑坐标
        dx = (dx * savedScale) / currentScale;
        dy = (dy * savedScale) / currentScale;
      }

      return Offset(dx, dy);
    } catch (_) {}
  }

  // 回退：在当前显示器（鼠标所在）居中
  final double visibleWidth;
  final double visibleHeight;
  if (currentDisplay.visibleSize case final size?) {
    visibleWidth = size.width;
    visibleHeight = size.height;
  } else {
    visibleWidth = currentDisplay.size.width;
    visibleHeight = currentDisplay.size.height;
  }

  final double visibleStartX;
  final double visibleStartY;
  if (currentDisplay.visiblePosition case final offset?) {
    visibleStartX = offset.dx;
    visibleStartY = offset.dy;
  } else {
    visibleStartX = visibleStartY = 0;
  }

  return Offset(
    visibleStartX + (visibleWidth / 2) - (windowSize.width / 2),
    visibleStartY + ((visibleHeight / 2) - (windowSize.height / 2)),
  );
}
