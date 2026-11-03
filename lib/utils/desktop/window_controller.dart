import 'dart:async' show Timer;

import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/multi_window/player_window_service.dart';

import 'dart:io' show Platform;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/desktop/tray_controller.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:nativeapi/nativeapi.dart' as nativeapi;
import 'package:window_manager/window_manager.dart';

class WindowController {
  WindowController._();
  static WindowController get instance => _instance;
  static final WindowController _instance = WindowController._();

  int? _windowId;
  nativeapi.Window? _window;
  nativeapi.Window? get window => _window;

  double? _opacity;

  late final _setting = GStorage.setting;
  bool _isMaximized = false;
  set windowMaximizedPref(bool value) {
    _setting.put(SettingBoxKey.isWindowMaximized, value);
  }

  Timer? _moveTimer;
  Timer? _resizeTimer;
  static const _kDuration = Duration(milliseconds: 200);

  late bool minimizeOnExit = Pref.minimizeOnExit;
  late bool pauseOnMinimize = Pref.pauseOnMinimize;
  PlPlayerController? _pausedPlayer;
  int? _pauseRevision;
  bool _closing = false;

  void init() {
    assert(_window == null);

    final window = WindowManager.instance.getCurrent();
    if (window == null) return;
    _window = window;
    _windowId = window.addListener(_windowListener);
    _isMaximized = window.isMaximized;
  }

  // A player engine only binds its own native window; it owns its listeners.
  void bindForPlayerWindow(nativeapi.Window window) {
    assert(_window == null);
    _window = window;
  }

  void _windowListener(WindowEvent event) {
    switch (event) {
      case WindowFocusedEvent():
        // https://github.com/leanflutter/window_manager/issues/571
        _setOpacityOnWindows(1.0);
        break;
      case WindowBlurredEvent():
        break;
      case WindowMinimizedEvent():
        _pauseIfNeeded();
        break;
      case WindowMaximizedEvent():
        windowMaximizedPref = _isMaximized = true;
        break;
      case WindowRestoredEvent():
        _playIfNeeded();
        if (_isMaximized) {
          windowMaximizedPref = _isMaximized = false;
        }
        break;
      case WindowMovedEvent():
        _moveTimer?.cancel();
        _moveTimer = Timer(_kDuration, onWindowMoved);
        break;
      case WindowResizedEvent():
        _resizeTimer?.cancel();
        _resizeTimer = Timer(_kDuration, onWindowResized);
        break;
      case WindowCreatedEvent():
        break;
      case WindowClosedEvent():
        break;
      case WindowEnteredFullScreenEvent():
        break;
      case WindowExitedFullScreenEvent():
        break;
      case WindowCloseRequestedEvent():
        event.request.cancel();
        if (TrayController.instance.showTrayIcon && minimizeOnExit) {
          _hide();
        } else {
          onClose();
        }
        break;
      case WindowPropertyChangedEvent():
        break;
      case WindowOcclusionChangedEvent():
        break;
      case nativeapi.WindowDockedEvent():
        break;
      case nativeapi.WindowUndockedEvent():
        break;
    }
  }

  void onWindowMoved() {
    final window = _window;
    if (window == null) return;
    if (PlPlayerController.instance?.updatePipBounds(window) ?? false) {
      return;
    }
    final position = window.position;
    _setting.putAll({
      SettingBoxKey.windowPosition: [position.x, position.y],
      SettingBoxKey.windowScaleFactor: null,
    });
  }

  void onWindowResized() {
    final window = _window;
    if (window == null) return;
    if (PlPlayerController.instance?.updatePipBounds(window) ?? false) {
      return;
    }
    final bounds = window.bounds;
    _setting.putAll({
      SettingBoxKey.windowSize: [bounds.width, bounds.height],
      SettingBoxKey.windowScaleFactor: null,
      SettingBoxKey.windowPosition: [bounds.x, bounds.y],
    });
  }

  void _playIfNeeded() {
    final player = _pausedPlayer;
    _pausedPlayer = null;
    if (pauseOnMinimize &&
        player != null &&
        identical(player, PlPlayerController.instance) &&
        player.playbackControlRevision == _pauseRevision &&
        !player.playerStatus.isPlaying) {
      player.play();
    }
  }

  void _pauseIfNeeded() {
    final player = PlPlayerController.instance;
    if (pauseOnMinimize && player != null && player.playerStatus.isPlaying) {
      _pausedPlayer = player;
      player.pause();
      _pauseRevision = player.playbackControlRevision;
    }
  }

  Future<void> onClose() async {
    if (_closing) return;
    _closing = true;
    await PlayerWindowService.instance.closePlayerWindow(force: true);
    await GStorage.compact();
    await GStorage.close();
    TrayController.instance.dispose();
    DeviceUtils.exitApp();
  }

  void _setOpacityOnWindows(double opacity) {
    if (Platform.isWindows && _opacity != opacity) {
      _opacity = opacity;
      _window?.opacity = opacity;
    }
  }

  void _hide() {
    _pauseIfNeeded();
    // https://github.com/leanflutter/window_manager/issues/571
    _setOpacityOnWindows(0.0);
    _window?.hide();
  }

  void hide() => _hide();

  void show() {
    _window
      ?..focus()
      ..show();
    _playIfNeeded();
  }

  void toggleVisibility() {
    final window = _window;
    if (window == null) return;
    window.isVisible ? _hide() : show();
  }

  void dispose() {
    _moveTimer?.cancel();
    _resizeTimer?.cancel();
    if (_windowId case final id?) _window?.removeListener(id);
    _windowId = null;
    _pausedPlayer = null;
    _window = null;
  }
}
