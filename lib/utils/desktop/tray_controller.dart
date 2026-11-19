import 'dart:io' show Platform;

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/utils/desktop/window_controller.dart';
import 'package:PiliPlus/services/multi_window/player_window_service.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:tray_manager/tray_manager.dart' as tray_manager show Image;
import 'package:tray_manager/tray_manager.dart';

class TrayController {
  TrayController._();
  static TrayController get instance => _instance;
  static final TrayController _instance = TrayController._();

  TrayIcon? _trayIcon;
  tray_manager.Image? _icon;
  int? _trayListenerId;
  Menu? _trayMenu;
  final List<(MenuItem, int)> _trayMenuItems = <(MenuItem, int)>[];
  MenuItem? _onTopItem;
  bool _disposed = false;
  bool _togglingOnTop = false;

  final bool showTrayIcon = Pref.showTrayIcon;

  void init() {
    if (!showTrayIcon) return;

    assert(_trayIcon == null);
    _disposed = false;
    try {
      final trayIcon = TrayIcon.create();
      if (trayIcon == null) return;

      _trayIcon = trayIcon;
      _trayListenerId = trayIcon.addListener(_trayListener);
      _icon = ImageAsset.fromAsset(
        Platform.isWindows ? Assets.logoIco : Assets.logoLarge,
      );
      trayIcon
        ..icon = _icon
        ..setTooltip(Constants.appName);

      final trayMenu = Menu.create();
      if (trayMenu != null) {
        _trayMenu = trayMenu;
        _addTrayMenuItem(trayMenu, '显示窗口', WindowController.instance.show);
        final item = MenuItem.createWithLabelAndType(_onTopLabel, .checkbox);
        if (item != null) {
          _onTopItem = item;
          item.state = _isOnTop ? .checked : .unchecked;
          final id = item.addListener((event) {
            if (!_disposed && event is MenuItemClickedEvent) _toggleOnTop();
          });
          _trayMenuItems.add((item, id));
          trayMenu.addItem(item);
        }
        trayMenu.addSeparator();
        _addTrayMenuItem(
          trayMenu,
          '退出 ${Constants.appName}',
          WindowController.instance.onClose,
        );
        trayIcon.setContextMenu(_trayMenu);
      }

      trayIcon.setVisible(true);

      // "KDE: Activate on a click, ContextMenu on a right click"。
      if (Platform.isLinux) {
        trayIcon.setContextMenuTrigger(.rightClicked);
      }
    } catch (e) {
      dispose();
      debugPrint('Tray initialization failed: $e');
    }
  }

  void _addTrayMenuItem(Menu menu, String label, void Function() onTap) {
    final item = MenuItem.createWithLabelAndType(label, .normal);
    if (item == null) return;
    final id = item.addListener((MenuEvent event) {
      if (event is MenuItemClickedEvent) {
        if (!_disposed) onTap();
      }
    });
    _trayMenuItems.add((item, id));
    menu.addItem(item);
  }

  Future<void> _trayListener(TrayIconEvent event) async {
    if (_disposed) return;
    switch (event) {
      case TrayIconClickedEvent():
        WindowController.instance.toggleVisibility();
      case TrayIconRightClickedEvent():
        _refreshOnTop();
        _trayIcon?.openContextMenu();
      case TrayIconDoubleClickedEvent():
    }
  }

  bool get _usesPlaybackWindow =>
      PlayerWindowService.supported && Pref.usePlayerWindow;

  bool get _isOnTop => _usesPlaybackWindow
      ? Pref.playerWindowAlwaysOnTop
      : Pref.mainWindowAlwaysOnTop;

  String get _onTopLabel => '${_isOnTop ? '✅ ' : ''}播放页置顶';

  void _refreshOnTop() {
    if (_disposed) return;
    _onTopItem
      ?..label = _onTopLabel
      ..state = _isOnTop ? .checked : .unchecked;
  }

  Future<void> _toggleOnTop() async {
    if (_disposed || _togglingOnTop) return;
    _togglingOnTop = true;
    try {
      final usePlayer = _usesPlaybackWindow;
      final next = !_isOnTop;
      await GStorage.setting.put(
        usePlayer
            ? SettingBoxKey.playerWindowAlwaysOnTop
            : SettingBoxKey.mainWindowAlwaysOnTop,
        next,
      );
      if (_disposed) return;
      if (usePlayer) {
        PlayerWindowService.instance.setAlwaysOnTop(next);
      } else {
        WindowController.instance.window?.isAlwaysOnTop = next;
      }
      _refreshOnTop();
    } finally {
      _togglingOnTop = false;
    }
  }

  void dispose() {
    if (!showTrayIcon || _disposed) return;
    _disposed = true;

    void release(void Function() action) {
      try {
        action();
      } catch (e) {
        debugPrint('Tray cleanup failed: $e');
      }
    }

    final tray = _trayIcon;
    _trayIcon = null;
    if (tray != null) {
      if (_trayListenerId case final id?)
        release(() => tray.removeListener(id));
      release(tray.dispose);
    }
    final menu = _trayMenu;
    _trayMenu = null;
    if (menu != null) release(menu.dispose);

    for (final (item, id) in _trayMenuItems) {
      release(() => item.removeListener(id));
      release(item.dispose);
    }
    _trayMenuItems.clear();

    final icon = _icon;
    _icon = null;
    if (icon != null) release(icon.dispose);
    _onTopItem = null;
  }
}
