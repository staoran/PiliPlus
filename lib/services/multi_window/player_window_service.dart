// Flutter 3.50.0 exposes native windowing through these internal SDK APIs.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show FlutterView;

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/common/widgets/back_detector.dart';
import 'package:PiliPlus/pages/live_room/view.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/view.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/multi_window/player_window_identity.dart';
import 'package:PiliPlus/services/multi_window/player_window_navigation.dart';
import 'package:PiliPlus/utils/desktop/desktop_window.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/src/foundation/_features.dart' as flutter_features;
import 'package:flutter/src/widgets/_window.dart' as native;
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class PlayerWindowService {
  PlayerWindowService._();
  static final instance = PlayerWindowService._();
  static bool get supported => Platform.isWindows;

  static void enableWindowing() {
    if (supported) flutter_features.isWindowingEnabled = true;
  }

  static const minimumSize = Size(640, 480);
  final _mountedWindow = ValueNotifier<_PlayerWindow?>(null);
  _PlayerWindow? _window;
  Future<_PlayerWindow>? _opening;
  Future<void>? _closing;
  int _requestVersion = 0;
  bool _shuttingDown = false;

  Widget anchor(Widget child) {
    if (!supported) return child;
    return ValueListenableBuilder(
      valueListenable: _mountedWindow,
      child: child,
      builder: (context, window, child) => ViewAnchor(
        view: window == null
            ? null
            : native.Window(
                controller: window.controller,
                child: _PlayerWindowContent(window: window),
              ),
        child: child!,
      ),
    );
  }

  bool ownsView(FlutterView? view) =>
      view != null && view == _mountedWindow.value?.controller.rootView;

  void back() => _mountedWindow.value?.back();

  void setAlwaysOnTop(bool value) {
    final window = _window;
    if (window != null) window.player.setAlwaysOnTop(value);
  }

  /// A false result asks the caller to open the same request in the main view.
  Future<bool> open(
    Object arguments, {
    bool replace = false,
    String? title,
  }) async {
    if (_shuttingDown) return true;
    if (!supported) return false;
    final version = ++_requestVersion;
    try {
      await _closing;
      if (version != _requestVersion) return true;

      final opening = _opening;
      final window = opening != null
          ? await opening
          : _window ?? await _ensureWindow();
      if (version != _requestVersion || !identical(window, _window)) {
        return true;
      }
      window.navigate(arguments, replace: replace, title: title);
      window.desktop.focus();
      return true;
    } catch (error, stack) {
      debugPrint('Could not open the native playback window: $error\n$stack');
      return version != _requestVersion;
    }
  }

  Future<_PlayerWindow> _ensureWindow() async {
    final opening = _opening = _createWindow();
    try {
      return await opening;
    } finally {
      _opening = null;
    }
  }

  Future<_PlayerWindow> _createWindow() async {
    // Native window creation must leave the Flutter frame callback.
    await Future<void>.delayed(Duration.zero);
    final controller = native.WindowController.shrinkWrap(
      resizable: true,
      title: Constants.appName,
      delegate: _WindowDelegate(close),
    );
    final window = _window = _PlayerWindow(controller);
    try {
      window.initialClientSizeInPixels = await window.desktop.configure(
        title: Constants.appName,
        size: Pref.playerWindowSize,
        minimumSize: minimumSize,
        position: Pref.playerWindowPosition,
        legacyScale: Pref.playerWindowScaleFactor,
        showTitleBar: true,
        alwaysOnTop: Pref.playerWindowAlwaysOnTop,
        sizeToContentOnFirstFrame: true,
      );
      window.player.isAlwaysOnTop.value = Pref.playerWindowAlwaysOnTop;
      if (_closing == null) {
        _mountedWindow.value = window;
        final binding = WidgetsBinding.instance;
        binding.platformDispatcher.scheduleFrame();
        await binding.endOfFrame;
        await Future<void>.delayed(Duration.zero);
      }
      return window;
    } catch (_) {
      _mountedWindow.value = null;
      _window = null;
      await Future<void>.delayed(Duration.zero);
      window.destroy();
      rethrow;
    }
  }

  Future<void> close() {
    if (_closing case final closing?) return closing;
    ++_requestVersion;
    return _closing = _retire().whenComplete(() => _closing = null);
  }

  Future<void> _retire() async {
    await Future<void>.delayed(Duration.zero);
    final opening = _opening;
    if (opening != null) {
      try {
        await opening;
      } catch (_) {
        return;
      }
    }
    final window = _window;
    if (window == null) return;
    if (window.desktop.isFullScreen) {
      await window.desktop.setFullScreen(false);
    }
    final bounds =
        window.player.boundsBeforePip ?? await window.desktop.readBounds();
    _mountedWindow.value = null;
    final binding = WidgetsBinding.instance;
    binding.platformDispatcher.scheduleFrame();
    await binding.endOfFrame;
    await window.player.closePlayback();
    try {
      if (!bounds.isEmpty &&
          !window.desktop.isMinimized &&
          !window.desktop.isMaximized) {
        await GStorage.setting.putAll({
          SettingBoxKey.playerWindowSize: [bounds.width, bounds.height],
          SettingBoxKey.playerWindowPosition: [bounds.left, bounds.top],
          SettingBoxKey.playerWindowScaleFactor: window.desktop.positionScale,
        });
      }
    } finally {
      await Future<void>.delayed(Duration.zero);
      window.destroy();
      _window = null;
    }
  }

  Future<void> shutdown() {
    _shuttingDown = true;
    return close();
  }
}

class _WindowDelegate extends native.WindowControllerDelegate {
  _WindowDelegate(this.close);
  final Future<void> Function() close;

  @override
  void onWindowCloseRequested(native.WindowController controller) {
    unawaited(close());
  }
}

class _PlayerWindow {
  _PlayerWindow(this.controller) {
    desktop = DesktopWindow(
      controller.rootView.viewId,
      changeFullscreen: controller.setFullscreen,
    );
    player = PlPlayerController.forWindow(desktop, navigatorKey);
    desktop
      ..onActivated = player.activateMediaControls
      ..onMinimized = _onMinimized
      ..onGeometryChanged = () => player.updatePipBounds(desktop);
  }

  final native.WindowController controller;
  final navigatorKey = GlobalKey<NavigatorState>();
  final observer = _PlaybackRouteObserver();
  final heroController = HeroController();
  late final DesktopWindow desktop;
  late final PlPlayerController player;
  Size? initialClientSizeInPixels;
  int? _pauseRevision;

  void _onMinimized(bool minimized) {
    if (minimized) {
      if (Pref.pauseOnMinimize && player.playerStatus.isPlaying) {
        player.pause();
        _pauseRevision = player.playbackControlRevision;
      }
    } else {
      if (_pauseRevision == player.playbackControlRevision &&
          Pref.pauseOnMinimize) {
        player.play();
      }
      _pauseRevision = null;
    }
  }

  void back() => unawaited(navigatorKey.currentState?.maybePop());

  void navigate(Object arguments, {required bool replace, String? title}) {
    final navigator = navigatorKey.currentState!;
    final current = observer.currentPage;
    final previous = current?.settings.arguments;
    final Widget page;
    final RouteSettings settings;
    switch (arguments) {
      case final int roomId:
        if (previous == roomId) return;
        page = LiveRoomPage(roomId: roomId, player: player);
        settings = RouteSettings(name: '/liveRoom', arguments: roomId);
      case final Map<String, dynamic> video:
        final tag = previous is Map ? previous['heroTag'] : null;
        final detail =
            tag is String && Get.isRegistered<VideoDetailController>(tag: tag)
            ? Get.find<VideoDetailController>(tag: tag)
            : null;
        if (previous is Map &&
            PlayerWindowIdentity.shouldSkipVideoNavigation(
              routeArguments: previous,
              nextArguments: video,
              currentVideoType: detail?.videoType,
              currentAid: detail?.aid,
              currentBvid: detail?.bvid,
              currentCid: detail?.cid.value,
              currentEpId: detail?.epId,
            )) {
          return;
        }
        final args = <String, dynamic>{
          ...video,
          'heroTag': PlayerWindowIdentity.heroTag(
            aid: video['aid'],
            bvid: video['bvid'],
            cid: video['cid'],
            seasonId: video['seasonId'],
            epId: video['epId'],
            pgcType: video['pgcType'],
            videoType: video['videoType'],
            sourceType: video['sourceType'],
          ),
        };
        page = VideoDetailPageV(arguments: Map.of(args), player: player);
        settings = RouteSettings(name: '/videoV', arguments: args);
        title ??= video['title'] as String?;
      default:
        throw ArgumentError.value(arguments.runtimeType, 'arguments');
    }
    desktop.title = title?.isNotEmpty == true ? title! : Constants.appName;
    final route = MaterialPageRoute<void>(
      builder: (_) => page,
      settings: settings,
    );
    if (current?.settings.name == '/' || replace) {
      navigator.pushReplacement(route);
    } else {
      navigator.push(route);
    }
  }

  void destroy() {
    desktop.dispose();
    controller
      ..destroy()
      ..dispose();
  }
}

class _PlaybackRouteObserver extends RouteObserver<PageRoute<dynamic>> {
  PageRoute<dynamic>? currentPage;

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    if (topRoute is PageRoute<dynamic>) currentPage = topRoute;
  }
}

class _PlayerWindowContent extends StatelessWidget {
  const _PlayerWindowContent({required this.window});
  final _PlayerWindow window;

  @override
  Widget build(BuildContext context) {
    final data = MediaQuery.of(context);
    final scale = Pref.uiScale;
    final devicePixelRatio = data.devicePixelRatio * scale;
    final clientSizeInPixels = window.initialClientSizeInPixels;
    return MediaQuery(
      data: data.copyWith(
        size: data.size / scale,
        devicePixelRatio: devicePixelRatio,
        padding: data.padding / scale,
        viewPadding: data.viewPadding / scale,
        viewInsets: data.viewInsets / scale,
        textScaler: TextScaler.linear(Pref.defaultTextScale),
      ),
      child: SizedBox.fromSize(
        // Tight view constraints take over after the shrink-wrap first frame.
        size: clientSizeInPixels == null
            ? null
            : clientSizeInPixels / devicePixelRatio,
        child: PlayerWindowNavigation(
          observer: window.observer,
          child: HeroControllerScope(
            controller: window.heroController,
            child: BackDetector(
              onBack: window.back,
              child: Material(
                type: MaterialType.transparency,
                child: Navigator(
                  key: window.navigatorKey,
                  observers: [window.observer],
                  onGenerateRoute: (settings) => MaterialPageRoute<void>(
                    settings: settings,
                    builder: (_) => const ColoredBox(color: Colors.black),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
