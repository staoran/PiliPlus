import 'dart:async';
import 'dart:ui' show FlutterView;

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/multi_window/player_window_service.dart';
import 'package:PiliPlus/utils/desktop/desktop_window.dart';
import 'package:PiliPlus/utils/desktop/tray_controller.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';

/// Owns the implicit desktop view and its tray/exit behavior.
class WindowController {
  WindowController._();
  static final instance = WindowController._();

  DesktopWindow? _window;
  DesktopWindow? get window => _window;

  Timer? _geometryTimer;
  PlPlayerController? _pausedPlayer;
  int? _pauseRevision;
  Future<void>? _closing;

  Future<void> init(FlutterView view) async {
    final window = _window = DesktopWindow(view.viewId)
      ..onClose = _onCloseRequested
      ..onGeometryChanged = _scheduleSaveGeometry
      ..onMinimized = _onMinimized
      ..onActivated = () =>
          PlPlayerController.instance?.activateMediaControls();
    await window.configure(
      title: Constants.appName,
      size: Pref.windowSize,
      minimumSize: DeviceUtils.desktopMinSize,
      position: Pref.windowPosition,
      legacyScale: Pref.windowScaleFactor,
      maximized: Pref.isWindowMaximized,
      showTitleBar: Pref.showWindowTitleBar,
      alwaysOnTop: Pref.mainWindowAlwaysOnTop,
      interceptClose: true,
    );
  }

  @visibleForTesting
  set testWindow(DesktopWindow window) => _window = window;

  void _scheduleSaveGeometry() {
    _geometryTimer?.cancel();
    _geometryTimer = Timer(const Duration(milliseconds: 200), () {
      unawaited(_saveGeometry());
    });
  }

  Future<void> _saveGeometry() async {
    final window = _window;
    if (window == null || window.isMinimized || window.isFullScreen) return;
    if (PlPlayerController.instance?.updatePipBounds(window) ?? false) return;
    final bounds = window.bounds;
    await GStorage.setting.putAll({
      SettingBoxKey.isWindowMaximized: window.isMaximized,
      if (!window.isMaximized && !bounds.isEmpty) ...{
        SettingBoxKey.windowSize: [bounds.width, bounds.height],
        SettingBoxKey.windowPosition: [bounds.left, bounds.top],
        SettingBoxKey.windowScaleFactor: window.positionScale,
      },
    });
  }

  void _onMinimized(bool minimized) {
    if (minimized) {
      final player = PlPlayerController.instance;
      if (Pref.pauseOnMinimize &&
          player != null &&
          player.playerStatus.isPlaying) {
        _pausedPlayer = player;
        player.pause();
        _pauseRevision = player.playbackControlRevision;
      }
    } else {
      final player = _pausedPlayer;
      _pausedPlayer = null;
      if (Pref.pauseOnMinimize &&
          player != null &&
          identical(player, PlPlayerController.instance) &&
          player.playbackControlRevision == _pauseRevision) {
        player.play();
      }
    }
  }

  void _onCloseRequested() {
    if (TrayController.instance.showTrayIcon && Pref.minimizeOnExit) {
      hide();
    } else {
      unawaited(onClose());
    }
  }

  Future<void> onClose() => _closing ??= _exit();

  Future<void> _exit() async {
    await PlayerWindowService.instance.shutdown();
    _geometryTimer?.cancel();
    await _saveGeometry();
    await PlPlayerController.instance?.closePlayback();
    await GStorage.compact();
    await GStorage.close();
    TrayController.instance.dispose();
    DeviceUtils.exitApp();
  }

  void hide() {
    _onMinimized(true);
    _window?.hide();
  }

  void show() {
    _window?.focus();
    _onMinimized(false);
  }

  void toggleVisibility() => _window?.isVisible == true ? hide() : show();

  void dispose() {
    _geometryTimer?.cancel();
    _pausedPlayer = null;
    _window?.dispose();
    _window = null;
  }
}
