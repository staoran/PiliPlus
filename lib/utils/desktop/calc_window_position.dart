import 'dart:ffi' hide Size;
import 'dart:io' show Platform;

import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:collection/collection.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/rendering.dart' show Offset, Size;
import 'package:nativeapi/nativeapi.dart' as nativeapi;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:win32/win32.dart' as win32;

const _displayManager = nativeapi.DisplayManager.instance;

nativeapi.Rectangle calcWindowBounds() {
  return calcWindowBoundsFor(
    Pref.windowSize,
    savedPosition: Pref.windowPosition,
    legacyScale: Pref.windowScaleFactor,
  );
}

nativeapi.Rectangle calcWindowBoundsFor(
  Size windowSize, {
  List<double>? savedPosition,
  double? legacyScale,
}) {
  final offset = calcWindowPosition(
    windowSize,
    savedPosition: savedPosition,
    legacyScale: legacyScale,
  );
  return nativeapi.Rectangle(
    x: offset.dx,
    y: offset.dy,
    width: windowSize.width,
    height: windowSize.height,
  );
}

Offset calcWindowPosition(
  Size windowSize, {
  List<double>? savedPosition,
  double? legacyScale,
}) {
  final displays = _displayManager.getAll();
  final cursorPosition = _displayManager.getCursorPosition().toOffset();

  if (savedPosition != null && savedPosition.length >= 2) {
    final offset = restoreWindowPosition(
      Offset(savedPosition[0], savedPosition[1]),
      legacyScale,
      displays,
    );
    // A saved window may belong to any attached monitor, including negative origins.
    if (displays.any((display) {
      final area = display.workArea.toRect();
      return offset.dx >= area.left &&
          offset.dy >= area.top &&
          offset.dx < area.right - 30 &&
          offset.dy < area.bottom - 30;
    })) {
      return offset;
    }
  }

  final currentDisplay =
      displays.firstWhereOrNull(
        (display) => (display.position.toOffset() & display.size.toSize())
            .contains(cursorPosition),
      ) ??
      _displayManager.getPrimary();

  if (currentDisplay == null) return .zero;

  final workArea = currentDisplay.workArea.toRect();

  final double visibleWidth = workArea.width;
  final double visibleHeight = workArea.height;

  final double visibleStartX = workArea.left;
  final double visibleStartY = workArea.top;

  return Offset(
    visibleStartX + (visibleWidth / 2) - (windowSize.width / 2),
    visibleStartY + ((visibleHeight / 2) - (windowSize.height / 2)),
  );
}

// The old Windows plugin saved physical desktop coordinates / savedScale.
// nativeapi uses a per-monitor logical origin. New saves clear the existing
// legacy scale value, so they are never converted a second time.
Offset restoreWindowPosition(
  Offset saved,
  double? legacyScale,
  List<nativeapi.Display> displays,
) {
  if (!Platform.isWindows || legacyScale == null || legacyScale <= 0) {
    return saved;
  }
  final physical = saved * legacyScale;
  final info = calloc<win32.MONITORINFO>();
  try {
    info.ref.cbSize = sizeOf<win32.MONITORINFO>();
    for (final display in displays) {
      if (!win32.GetMonitorInfo(win32.HMONITOR(display.nativeObject), info)) {
        continue;
      }
      final rect = info.ref.rcMonitor;
      if (physical.dx >= rect.left &&
          physical.dx < rect.right &&
          physical.dy >= rect.top &&
          physical.dy < rect.bottom) {
        final origin = display.position;
        final scale = display.scaleFactor;
        return Offset(
          origin.x + (physical.dx - rect.left) / scale,
          origin.y + (physical.dy - rect.top) / scale,
        );
      }
    }
  } finally {
    calloc.free(info);
  }
  return Offset.infinite;
}
