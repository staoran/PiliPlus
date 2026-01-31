import 'dart:io';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/common/widgets/flutter/pop_scope.dart';
import 'package:PiliPlus/common/widgets/flutter/tabs.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/models/common/nav_bar_config.dart';
import 'package:PiliPlus/pages/home/view.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/multi_window/player_window_service.dart';
import 'package:PiliPlus/services/multi_window/window_controller_extension.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/extension/context_ext.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends PopScopeState<MainApp>
    with RouteAware, WidgetsBindingObserver, WindowListener, TrayListener {
  final _mainController = Get.put(MainController());
  late final _setting = GStorage.setting;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (PlatformUtils.isDesktop) {
      windowManager
        ..addListener(this)
        ..setPreventClose(true);
      if (_mainController.showTrayIcon) {
        trayManager.addListener(this);
        _handleTray();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.brightnessOf(context);
    NetworkImgLayer.reduce =
        NetworkImgLayer.reduceLuxColor != null && brightness.isDark;
    if (PlatformUtils.isDesktop) {
      windowManager.setBrightness(brightness);
    }
    PageUtils.routeObserver.subscribe(
      this,
      ModalRoute.of(context) as PageRoute,
    );
    if (!_mainController.useSideBar) {
      _mainController.useBottomNav = MediaQuery.sizeOf(context).isPortrait;
    }
  }

  @override
  void didPopNext() {
    WidgetsBinding.instance.addObserver(this);
    _mainController
      ..checkUnreadDynamic()
      ..checkDefaultSearch(true)
      ..checkUnread(_mainController.useBottomNav);
    super.didPopNext();
  }

  @override
  void didPushNext() {
    WidgetsBinding.instance.removeObserver(this);
    super.didPushNext();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _mainController
        ..checkUnreadDynamic()
        ..checkDefaultSearch(true)
        ..checkUnread(_mainController.useBottomNav);
    }
  }

  @override
  void dispose() {
    if (PlatformUtils.isDesktop) {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
    }
    PageUtils.routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    PiliScheme.listener?.cancel();
    GStorage.close();
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    _setting.put(SettingBoxKey.isWindowMaximized, true);
  }

  @override
  void onWindowUnmaximize() {
    _setting.put(SettingBoxKey.isWindowMaximized, false);
  }

  @override
  Future<void> onWindowMoved() async {
    if (PlPlayerController.instance?.isDesktopPip ?? false) {
      return;
    }
    final Offset offset = await windowManager.getPosition();
    _setting.put(SettingBoxKey.windowPosition, [offset.dx, offset.dy]);
  }

  @override
  Future<void> onWindowResized() async {
    if (PlPlayerController.instance?.isDesktopPip ?? false) {
      return;
    }
    final Rect bounds = await windowManager.getBounds();
    _setting.putAll({
      SettingBoxKey.windowSize: [bounds.width, bounds.height],
      SettingBoxKey.windowPosition: [bounds.left, bounds.top],
    });
  }

  @override
  void onWindowClose() {
    if (_mainController.showTrayIcon && _mainController.minimizeOnExit) {
      windowManager.hide();
      _onHideWindow();
    } else {
      _onClose();
    }
  }

  Future<void> _onClose() async {
    // 关闭预创建的播放器窗口（如果有）
    await PlayerWindowService.instance.closePreCreatedWindow();
    await GStorage.compact();
    await GStorage.close();
    await trayManager.destroy();
    if (Platform.isWindows) {
      const MethodChannel('window_control').invokeMethod('closeWindow');
    } else {
      exit(0);
    }
  }

  @override
  void onWindowMinimize() {
    _onHideWindow();
  }

  @override
  void onWindowRestore() {
    _onShowWindow();
  }

  void _onHideWindow() {
    if (_mainController.pauseOnMinimize) {
      _mainController.isPlaying =
          PlPlayerController.instance?.playerStatus.value ==
          PlayerStatus.playing;
      PlPlayerController.pauseIfExists();
    }
  }

  void _onShowWindow() {
    if (_mainController.pauseOnMinimize) {
      if (_mainController.isPlaying) {
        PlPlayerController.playIfExists();
      }
    }
  }

  @override
  Future<void> onTrayIconMouseDown() async {
    if (await windowManager.isVisible()) {
      _onHideWindow();
      windowManager.hide();
    } else {
      _onShowWindow();
      windowManager.show();
    }
  }

  @override
  Future<void> onTrayIconRightMouseDown() async {
    // ignore: deprecated_member_use
    trayManager.popUpContextMenu(bringAppToFront: true);
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        windowManager.show();
        return;
      case 'toggle_play_page_on_top':
        _togglePlayPageAlwaysOnTop();
        return;
      case 'exit':
        _onClose();
        return;
    }
  }

  Future<void> _handleTray() async {
    if (Platform.isWindows) {
      await trayManager.setIcon('assets/images/logo/app_icon.ico');
    } else {
      await trayManager.setIcon('assets/images/logo/logo_large.png');
    }
    if (!Platform.isLinux) {
      await trayManager.setToolTip(Constants.appName);
    }

    Menu trayMenu = Menu(
      items: [
        MenuItem(key: 'show', label: '显示窗口'),
        MenuItem(
          key: 'toggle_play_page_on_top',
          label: _playPageOnTopLabel,
          checked: _isPlayPageOnTop,
        ),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: '退出 ${Constants.appName}'),
      ],
    );
    await trayManager.setContextMenu(trayMenu);
  }

  String get _playPageOnTopLabel {
    final prefix = _isPlayPageOnTop ? '✅ ' : '';
    return '$prefix播放页置顶';
  }

  bool get _isPlayPageOnTop => Pref.usePlayerWindow
      ? Pref.playerWindowAlwaysOnTop
      : Pref.mainWindowAlwaysOnTop;

  Future<void> _togglePlayPageAlwaysOnTop() async {
    final usePlayer = Pref.usePlayerWindow;
    final next = !_isPlayPageOnTop;
    final key = usePlayer
        ? SettingBoxKey.playerWindowAlwaysOnTop
        : SettingBoxKey.mainWindowAlwaysOnTop;

    await _setting.put(key, next);

    if (usePlayer) {
      try {
        final controller = await PlayerWindowService.instance
            .findPlayerWindow();
        if (controller != null) {
          await controller.setAlwaysOnTop(next);
        }
      } catch (_) {}
    } else {
      await windowManager.setAlwaysOnTop(next);
    }

    await _refreshTrayMenu();
  }

  Future<void> _refreshTrayMenu() async {
    if (_mainController.showTrayIcon) {
      await _handleTray();
    }
  }

  static void _onBack() {
    if (Platform.isAndroid) {
      Utils.channel.invokeMethod('back');
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (_mainController.directExitOnBack) {
      _onBack();
    } else {
      if (_mainController.selectedIndex.value != 0) {
        _mainController
          ..setIndex(0)
          ..showBottomBar?.value = true
          ..setSearchBar();
      } else {
        _onBack();
      }
    }
  }

  Widget? get _bottomNav {
    Widget? bottomNav = _mainController.navigationBars.length > 1
        ? _mainController.enableMYBar
              ? Obx(
                  () => NavigationBar(
                    maintainBottomViewPadding: true,
                    labelBehavior: _mainController.showBottomLabel.value
                        ? NavigationDestinationLabelBehavior.alwaysShow
                        : NavigationDestinationLabelBehavior.alwaysHide,
                    onDestinationSelected: _mainController.setIndex,
                    selectedIndex: _mainController.selectedIndex.value,
                    destinations: _mainController.navigationBars
                        .map(
                          (e) => NavigationDestination(
                            label: e.label,
                            icon: _buildIcon(type: e),
                            selectedIcon: _buildIcon(type: e, selected: true),
                          ),
                        )
                        .toList(),
                  ),
                )
              : Obx(
                  () {
                    final padding = MediaQuery.viewPaddingOf(context);
                    final showLabel = _mainController.showBottomLabel.value;
                    // 关闭 MD3 样式时降低底栏高度
                    // 不显示文字时高度进一步降低
                    final bottomBarHeight = showLabel ? 48.0 : 40.0;
                    return MediaQuery.removePadding(
                      context: context,
                      removeBottom: true,
                      child: ClipRect(
                        child: SizedBox(
                          height: bottomBarHeight + padding.bottom,
                          child: BottomNavigationBar(
                            currentIndex: _mainController.selectedIndex.value,
                            onTap: _mainController.setIndex,
                            iconSize: showLabel ? 16 : 22,
                            selectedFontSize: 12,
                            unselectedFontSize: 12,
                            showSelectedLabels: showLabel,
                            showUnselectedLabels: showLabel,
                            type: BottomNavigationBarType.fixed,
                            items: _mainController.navigationBars
                                .map(
                                  (e) => BottomNavigationBarItem(
                                    label: e.label,
                                    icon: _buildIcon(type: e),
                                    activeIcon: _buildIcon(
                                      type: e,
                                      selected: true,
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ),
                    );
                  },
                )
        : null;
    if (bottomNav != null) {
      if (_mainController.showBottomBar case final bottomBar?) {
        return Obx(
          () => AnimatedSlide(
            curve: Curves.easeInOutCubicEmphasized,
            duration: const Duration(milliseconds: 500),
            offset: Offset(0, bottomBar.value ? 0 : 1),
            child: bottomNav,
          ),
        );
      }
    }
    return bottomNav;
  }

  Widget _sideBar(ThemeData theme) {
    return _mainController.navigationBars.length > 1
        ? context.isTablet && _mainController.optTabletNav
              ? Obx(
                  () {
                    final showLabel = _mainController.showBottomLabel.value;
                    return Column(
                      children: [
                        const SizedBox(height: 25),
                        userAndSearchVertical(theme),
                        const Spacer(flex: 2),
                        Expanded(
                          flex: 5,
                          child: SizedBox(
                            width: showLabel ? 130 : 80,
                            child: NavigationDrawer(
                              backgroundColor: Colors.transparent,
                              tilePadding: const EdgeInsets.symmetric(
                                vertical: 5,
                                horizontal: 12,
                              ),
                              indicatorShape: const RoundedRectangleBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(16),
                                ),
                              ),
                              onDestinationSelected: _mainController.setIndex,
                              selectedIndex:
                                  _mainController.selectedIndex.value,
                              children: _mainController.navigationBars
                                  .map(
                                    (
                                      e,
                                    ) => NavigationDrawerDestination(
                                      label: showLabel
                                          ? Text(e.label)
                                          : const SizedBox.shrink(),
                                      icon: _buildIcon(
                                        type: e,
                                      ),
                                      selectedIcon: _buildIcon(
                                        type: e,
                                        selected: true,
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                )
              : Obx(
                  () => NavigationRail(
                    groupAlignment: 0.5,
                    selectedIndex: _mainController.selectedIndex.value,
                    onDestinationSelected: _mainController.setIndex,
                    labelType: _mainController.showBottomLabel.value
                        ? .selected
                        : .none,
                    leading: userAndSearchVertical(theme),
                    destinations: _mainController.navigationBars
                        .map(
                          (e) => NavigationRailDestination(
                            label: Text(e.label),
                            icon: _buildIcon(type: e),
                            selectedIcon: _buildIcon(
                              type: e,
                              selected: true,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                )
        : Container(
            width: 80,
            padding: const .only(top: 10),
            child: userAndSearchVertical(theme),
          );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final padding = MediaQuery.viewPaddingOf(context);

    Widget child;
    if (_mainController.mainTabBarView) {
      child = CustomTabBarView(
        scrollDirection: _mainController.useBottomNav ? .horizontal : .vertical,
        physics: const NeverScrollableScrollPhysics(),
        controller: _mainController.controller,
        children: _mainController.navigationBars.map((i) => i.page).toList(),
      );
    } else {
      child = PageView(
        physics: const NeverScrollableScrollPhysics(),
        controller: _mainController.controller,
        children: _mainController.navigationBars.map((i) => i.page).toList(),
      );
    }

    Widget? bottomNav;
    if (_mainController.useBottomNav) {
      bottomNav = _bottomNav;
      child = Row(children: [Expanded(child: child)]);
    } else {
      child = Row(
        children: [
          _sideBar(theme),
          VerticalDivider(
            width: 1,
            endIndent: padding.bottom,
            color: theme.colorScheme.outline.withValues(alpha: 0.06),
          ),
          Expanded(child: child),
        ],
      );
    }

    child = Scaffold(
      extendBody: true,
      resizeToAvoidBottomInset: false,
      appBar: AppBar(toolbarHeight: 0),
      body: Padding(
        padding: EdgeInsets.only(
          left: _mainController.useBottomNav ? padding.left : 0.0,
          right: padding.right,
        ),
        child: child,
      ),
      bottomNavigationBar: bottomNav,
    );

    if (PlatformUtils.isMobile) {
      child = AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: theme.brightness.reverse,
        ),
        child: child,
      );
    }

    return child;
  }

  Widget _buildIcon({required NavigationBarType type, bool selected = false}) {
    final icon = selected ? type.selectIcon : type.icon;
    return type == .dynamics
        ? Obx(
            () {
              final dynCount = _mainController.dynCount.value;
              return Badge(
                isLabelVisible: dynCount > 0,
                label: _mainController.dynamicBadgeMode == .number
                    ? Text(dynCount.toString())
                    : null,
                padding: const .symmetric(horizontal: 6),
                child: icon,
              );
            },
          )
        : icon;
  }

  Widget userAndSearchVertical(ThemeData theme) {
    return Column(
      children: [
        userAvatar(theme: theme, mainController: _mainController),
        const SizedBox(height: 8),
        msgBadge(_mainController),
        IconButton(
          tooltip: '搜索',
          icon: const Icon(
            Icons.search_outlined,
            semanticLabel: '搜索',
          ),
          onPressed: () => Get.toNamed('/search'),
        ),
      ],
    );
  }
}
