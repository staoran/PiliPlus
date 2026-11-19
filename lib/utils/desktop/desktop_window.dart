import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Operations the Flutter window controller does not expose, addressed by view.
class DesktopWindow {
  DesktopWindow(this.viewId, {this.changeFullscreen});

  static const _runner = MethodChannel('window_control');
  static final _windows = <int, DesktopWindow>{};

  final int viewId;
  final ValueChanged<bool>? changeFullscreen;
  VoidCallback? onClose;
  VoidCallback? onGeometryChanged;
  ValueChanged<bool>? onMinimized;
  VoidCallback? onActivated;

  Rect _bounds = Rect.zero;
  Rect get bounds => _bounds;
  double? positionScale;
  bool isMaximized = false;
  bool isMinimized = false;
  bool isVisible = false;
  bool isFullScreen = false;
  bool _disposed = false;

  static Future<void> _handleEvent(MethodCall call) async {
    final data = call.arguments as Map;
    final window = _windows[data['viewId']];
    if (window == null) return;
    switch (call.method) {
      case 'closeRequested':
        window.onClose?.call();
      case 'windowChanged':
        window._update(data);
      case 'activated':
        window.onActivated?.call();
    }
  }

  Future<Size?> configure({
    required String title,
    required Size size,
    required Size minimumSize,
    required bool showTitleBar,
    required bool alwaysOnTop,
    List<double>? position,
    double? legacyScale,
    bool maximized = false,
    bool interceptClose = false,
    bool sizeToContentOnFirstFrame = false,
  }) async {
    if (_windows.isEmpty) _runner.setMethodCallHandler(_handleEvent);
    _windows[viewId] = this;
    final state = await _request<Map<Object?, Object?>>('configure', {
      'title': title,
      'size': [size.width, size.height],
      'minimumSize': [minimumSize.width, minimumSize.height],
      'showTitleBar': showTitleBar,
      'alwaysOnTop': alwaysOnTop,
      'position': position,
      'legacyScale': legacyScale,
      'maximized': maximized,
      'interceptClose': interceptClose,
      if (sizeToContentOnFirstFrame) 'sizeToContentOnFirstFrame': true,
    });
    if (_disposed || state == null) return null;
    _update(state);
    final sizeInPixels = state['clientSizeInPixels'] as List?;
    return sizeInPixels == null
        ? null
        : Size(
            (sizeInPixels[0] as num).toDouble(),
            (sizeInPixels[1] as num).toDouble(),
          );
  }

  void _update(Map data) {
    final values = data['bounds'] as List;
    final next = Rect.fromLTWH(
      (values[0] as num).toDouble(),
      (values[1] as num).toDouble(),
      (values[2] as num).toDouble(),
      (values[3] as num).toDouble(),
    );
    final minimized = data['minimized'] == true;
    final geometryChanged =
        next != _bounds || isMaximized != (data['maximized'] == true);
    final minimizedChanged = isMinimized != minimized;
    _bounds = next;
    positionScale = (data['positionScale'] as num?)?.toDouble();
    isMaximized = data['maximized'] == true;
    isMinimized = minimized;
    isVisible = data['visible'] == true;
    if (geometryChanged) onGeometryChanged?.call();
    if (minimizedChanged) onMinimized?.call(minimized);
  }

  Future<T?> _request<T>(String method, [Map<String, Object?>? data]) {
    if (_disposed) return Future<T?>.value();
    return _runner.invokeMethod<T>(method, {'viewId': viewId, ...?data});
  }

  Future<void> _set(String key, Object? value) async {
    await _request<void>('setWindow', {'key': key, 'value': value});
  }

  void _updateProperty(String key, Object? value) {
    unawaited(
      _set(key, value).catchError((Object error) {
        debugPrint('Window $viewId $key: $error');
      }),
    );
  }

  Future<Rect> readBounds() async {
    final state = await _request<Map<Object?, Object?>>('windowState');
    if (!_disposed && state != null) _update(state);
    return bounds;
  }

  set bounds(Rect value) => _updateProperty('bounds', [
    value.left,
    value.top,
    value.width,
    value.height,
  ]);
  set minimumSize(Size value) =>
      _updateProperty('minimumSize', [value.width, value.height]);
  set contentSize(Size value) =>
      _updateProperty('contentSize', [value.width, value.height]);
  set title(String value) => _updateProperty('title', value);
  set showTitleBar(bool value) => _updateProperty('showTitleBar', value);
  set isAlwaysOnTop(bool value) => _updateProperty('alwaysOnTop', value);
  set aspectRatio(double value) => _updateProperty('aspectRatio', value);
  set dark(bool value) => _updateProperty('dark', value);

  void focus() => _updateProperty('show', true);

  void hide() => _updateProperty('show', false);
  void startDragging() => _updateProperty('drag', null);

  Future<void> setFullScreen(bool value) async {
    if (_disposed || isFullScreen == value) return;
    final change = changeFullscreen;
    if (change != null) {
      change(value);
    } else {
      await _set('fullscreen', value);
    }
    isFullScreen = value;
  }

  void dispose() {
    _disposed = true;
    _windows.remove(viewId);
  }
}
