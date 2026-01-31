import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/common/widgets/back_detector.dart';
import 'package:PiliPlus/common/widgets/custom_toast.dart';
import 'package:PiliPlus/models/common/theme/theme_color_type.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/pages/live_room/view.dart';
import 'package:PiliPlus/pages/video/view.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/player_window_manager.dart';
import 'package:PiliPlus/services/multi_window/player_window_service.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:collection/collection.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// Minimal routes for player window (no Pref dependency)
final List<GetPage> _playerWindowRoutes = [
  GetPage(
    name: '/',
    page: () => const _PlayerWindowPlaceholder(),
  ),
  GetPage(
    name: '/videoV',
    page: () => const VideoDetailPageV(),
  ),
  GetPage(
    name: '/liveRoom',
    page: () => const LiveRoomPage(),
  ),
];

/// Placeholder widget for player window root
class _PlayerWindowPlaceholder extends StatelessWidget {
  const _PlayerWindowPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}

/// 播放器窗口入口
class PlayerEntry extends StatefulWidget {
  const PlayerEntry({super.key, this.args});

  /// Window arguments passed from main
  final Map<String, dynamic>? args;

  @override
  State<PlayerEntry> createState() => _PlayerEntryState();
}

class _PlayerEntryState extends State<PlayerEntry> with WindowListener {
  // Settings from args
  late final Map<String, dynamic>? _settings;
  late final Size _windowSize;
  late final List<double>? _windowPosition;
  late final double? _savedScaleFactor; // 保存位置时的显示器缩放比例
  late final bool _showTitleBar;
  late final int _customColor;
  late final bool _dynamicColor;
  late final int _schemeVariant;
  late final ThemeMode _themeMode;
  late final double _textScale;
  late bool _alwaysOnTop;
  late final String _initialRoute;
  late final dynamic _initialArguments;

  /// 是否是预创建模式（没有视频参数，窗口保持隐藏等待使用）
  late final bool _isPreCreatedMode;

  @override
  void initState() {
    super.initState();
    // Mark that we are in a player sub-window
    PlayerWindowService.isPlayerWindow = true;
    _parseSettings();
    _determineInitialRoute();
    _initWindow();
    // Only setup window channels on desktop platforms
    if (PlatformUtils.isDesktop) {
      // Register window method handler early so main window can reuse this one
      // without spawning extra player windows.
      _setupWindowMethodHandler();
      _setupPlayerChannel();
    }
    // Navigate to initial page after build
    if (_initialRoute != '/') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _navigateToInitialPage();
      });
    }
  }

  void _parseSettings() {
    _settings = widget.args?['settings'] as Map<String, dynamic>?;

    // Parse window size
    final sizeList = _settings?['playerWindowSize'] as List?;
    if (sizeList != null && sizeList.length >= 2) {
      _windowSize = Size(
        (sizeList[0] as num).toDouble(),
        (sizeList[1] as num).toDouble(),
      );
    } else {
      _windowSize = const Size(1280, 720);
    }

    // Parse window position
    final posList = _settings?['playerWindowPosition'] as List?;
    if (posList != null && posList.length >= 2) {
      _windowPosition = [
        (posList[0] as num).toDouble(),
        (posList[1] as num).toDouble(),
      ];
    } else {
      _windowPosition = null;
    }

    // Parse saved scale factor (用于多显示器不同缩放比例时的坐标校正)
    _savedScaleFactor = (_settings?['playerWindowScaleFactor'] as num?)
        ?.toDouble();

    _showTitleBar = _settings?['showWindowTitleBar'] as bool? ?? true;
    _customColor = _settings?['customColor'] as int? ?? 0;
    _dynamicColor = _settings?['dynamicColor'] as bool? ?? false;
    _schemeVariant = _settings?['schemeVariant'] as int? ?? 0;
    _themeMode = ThemeMode.values[_settings?['themeMode'] as int? ?? 0];
    _textScale = (_settings?['defaultTextScale'] as num?)?.toDouble() ?? 1.0;
    _alwaysOnTop = _settings?['playerWindowAlwaysOnTop'] as bool? ?? false;
  }

  void _determineInitialRoute() {
    final args = widget.args;
    if (args == null) {
      _initialRoute = '/';
      _initialArguments = null;
    } else if (args['roomId'] != null) {
      // Live room
      _initialRoute = '/liveRoom';
      _initialArguments = args['roomId'] as int;
    } else if (args['aid'] != null && args['bvid'] != null && args['cid'] != null) {
      // Video
      _initialRoute = '/videoV';
      _initialArguments = _buildVideoArguments(args);
    } else {
      // Default placeholder - 预创建模式
      _initialRoute = '/';
      _initialArguments = null;
    }

    // 如果没有视频参数且启用了提前初始化，则为预创建模式
    _isPreCreatedMode = _initialRoute == '/';
  }

  Map<String, dynamic> _buildVideoArguments(Map args) {
    final videoTypeArg = args['videoType'];
    VideoType videoType = VideoType.ugc;
    if (videoTypeArg is VideoType) {
      videoType = videoTypeArg;
    } else if (videoTypeArg is int) {
      videoType = VideoType.values[videoTypeArg.clamp(0, VideoType.values.length - 1)];
    } else if (videoTypeArg is String) {
      switch (videoTypeArg) {
        case 'ugc':
          videoType = VideoType.ugc;
          break;
        case 'pgc':
          videoType = VideoType.pgc;
          break;
        case 'pugv':
          videoType = VideoType.pugv;
          break;
      }
    }

    final rawExtraArgs = args['extraArguments'];
    final Map<String, dynamic> extraArgs = rawExtraArgs is Map
        ? Map<String, dynamic>.from(
            rawExtraArgs.map(
              (key, value) => MapEntry(key.toString(), value),
            ),
          )
        : {};
    SourceType? sourceType;
    final sourceTypeArg = extraArgs['sourceType'];
    if (sourceTypeArg is SourceType) {
      sourceType = sourceTypeArg;
    } else if (sourceTypeArg is int) {
      sourceType = SourceType.values[sourceTypeArg.clamp(0, SourceType.values.length - 1)];
    } else if (sourceTypeArg is String) {
      sourceType = SourceType.values.firstWhereOrNull((e) => e.name == sourceTypeArg);
    }

    extraArgs.remove('sourceType');

    // 反序列化 entry 对象（如果存在）
    final entryArg = extraArgs['entry'];
    if (entryArg is Map<String, dynamic>) {
      try {
        extraArgs['entry'] = BiliDownloadEntryInfo.fromJson(entryArg);
      } catch (_) {
        // 如果反序列化失败，移除 entry
        extraArgs.remove('entry');
      }
    }

    return {
      'videoType': videoType,
      'aid': args['aid'],
      'bvid': args['bvid'],
      'cid': args['cid'],
      if (args['seasonId'] != null) 'seasonId': args['seasonId'],
      if (args['epId'] != null) 'epId': args['epId'],
      if (args['pgcType'] != null) 'pgcType': args['pgcType'],
      if (args['cover'] != null) 'pic': args['cover'],
      'heroTag': 'playerWindow_${args['bvid'] ?? args['aid']}',
      if (args['progress'] != null) 'progress': args['progress'],
      'sourceType': ?sourceType,
      ...extraArgs,
    };
  }

  Future<void> _initWindow() async {
    await windowManager.ensureInitialized();

    WindowOptions windowOptions = WindowOptions(
      size: _windowSize,
      minimumSize: const Size(640, 480),
      skipTaskbar: false,
      titleBarStyle:
          _showTitleBar ? TitleBarStyle.normal : TitleBarStyle.hidden,
      title: '${Constants.appName} - 播放器',
    );

    windowManager
      ..waitUntilReadyToShow(windowOptions, () async {
      final pos = _windowPosition;
      if (pos != null) {
          // 校正多显示器不同缩放比例导致的位置偏移
          final correctedPos = await _correctPositionForDpi(
            Offset(pos[0], pos[1]),
          );
          await windowManager.setPosition(correctedPos);
      } else {
        // Calculate center position without using Pref
        final position = await _calcCenterPosition(_windowSize);
        await windowManager.setBounds(position & _windowSize);
      }
        // 预创建模式下不显示窗口，保持隐藏等待使用
        if (!_isPreCreatedMode) {
          await windowManager.show();
          await windowManager.focus();
        }
      if (_alwaysOnTop) {
        await windowManager.setAlwaysOnTop(true);
      }
      })

      ..addListener(this)
      ..setPreventClose(true);
  }

  /// Calculate center position for window (simplified, no Pref dependency)
  Future<Offset> _calcCenterPosition(Size windowSize) async {
    try {
      final primaryDisplay = await screenRetriever.getPrimaryDisplay();
      final screenSize = primaryDisplay.size;
      return Offset(
        (screenSize.width - windowSize.width) / 2,
        (screenSize.height - windowSize.height) / 2,
      );
    } catch (_) {
      return Offset.zero;
    }
  }

  /// 校正多显示器不同缩放比例导致的位置偏移
  ///
  /// window_manager 的 getBounds() 和 setPosition() 使用 Flutter 的 devicePixelRatio 进行坐标转换，
  /// 但这个值是当前窗口所在显示器的缩放比例。当窗口在不同缩放比例的显示器上保存和恢复时，
  /// 坐标会出现偏移。此方法通过保存的缩放比例和当前的 devicePixelRatio 来校正坐标。
  Future<Offset> _correctPositionForDpi(Offset savedPosition) async {
    try {
      // 如果没有保存缩放比例，直接返回原位置
      final savedScale = _savedScaleFactor;
      if (savedScale == null) {
        return savedPosition;
      }

      // 获取当前的 devicePixelRatio（窗口启动时 Flutter 使用的值）
      final currentScale = windowManager.getDevicePixelRatio();

      // 如果保存时的缩放比例和当前的相同，无需校正
      if ((savedScale - currentScale).abs() < 0.01) {
        return savedPosition;
      }

      // 计算物理坐标（保存的逻辑坐标 × 保存时的缩放比例）
      final physicalX = savedPosition.dx * savedScale;
      final physicalY = savedPosition.dy * savedScale;

      // 将物理坐标转换为当前 devicePixelRatio 下的逻辑坐标
      // setPosition() 会用当前 devicePixelRatio 乘以这个值来还原物理坐标
      final correctedX = physicalX / currentScale;
      final correctedY = physicalY / currentScale;

      return Offset(correctedX, correctedY);
    } catch (e) {
      debugPrint('Failed to correct position for DPI: $e');
      return savedPosition;
    }
  }

  /// Build theme data without depending on Pref/GStorage
  ThemeData _buildThemeData({
    required ColorScheme colorScheme,
    required bool isDynamic,
    bool isDark = false,
  }) {
    return ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      appBarTheme: AppBarTheme(
        elevation: 0,
        titleSpacing: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
        backgroundColor: colorScheme.surface,
        titleTextStyle: TextStyle(
          fontSize: 16,
          color: colorScheme.onSurface,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        surfaceTintColor: isDynamic ? colorScheme.onSurfaceVariant : null,
      ),
      snackBarTheme: SnackBarThemeData(
        actionTextColor: colorScheme.primary,
        backgroundColor: colorScheme.secondaryContainer,
        closeIconColor: colorScheme.secondary,
        contentTextStyle: TextStyle(color: colorScheme.onSecondaryContainer),
        elevation: 20,
      ),
      popupMenuTheme: PopupMenuThemeData(
        surfaceTintColor: isDynamic ? colorScheme.onSurfaceVariant : null,
      ),
      cardTheme: CardThemeData(
        elevation: 1,
        margin: EdgeInsets.zero,
        surfaceTintColor: isDynamic
            ? colorScheme.onSurfaceVariant
            : isDark
                ? colorScheme.onSurfaceVariant
                : null,
        shadowColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        titleTextStyle: TextStyle(
          fontSize: 18,
          color: colorScheme.onSurface,
        ),
        backgroundColor: colorScheme.surface,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        textStyle: const TextStyle(
          color: Colors.white,
          fontSize: 14,
        ),
        decoration: BoxDecoration(
          color: Colors.grey[700]!.withValues(alpha: 0.9),
          borderRadius: const BorderRadius.all(Radius.circular(4)),
        ),
      ),
      cupertinoOverrideTheme: CupertinoThemeData(
        selectionHandleColor: colorScheme.primary,
      ),
      switchTheme: const SwitchThemeData(
        thumbIcon: WidgetStateProperty<Icon?>.fromMap(
          <WidgetStatesConstraint, Icon?>{
            WidgetState.selected: Icon(Icons.done),
            WidgetState.any: null,
          },
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
        },
      ),
    );
  }

  void _setupPlayerChannel() {
    final _ = const WindowMethodChannel(PlayerWindowManager.channelName)
      ..setMethodCallHandler((call) async {
      switch (call.method) {
        case 'playVideo':
          final args = call.arguments as Map?;
          if (args != null) {
            _navigateToVideo(args);
          }
          return;
        case 'playLive':
          final args = call.arguments as Map?;
          if (args != null) {
            _navigateToLive(args);
          }
          return;
        default:
          throw MissingPluginException('Not implemented: ${call.method}');
      }
    });
  }

  /// 设置 WindowController 的方法处理器，用于接收来自主窗口的消息
  Future<void> _setupWindowMethodHandler() async {
    try {
      final controller = await WindowController.fromCurrentEngine();
      await controller.setWindowMethodHandler((call) async {
        switch (call.method) {
          case 'window_center':
            return windowManager.center();
          case 'window_close':
            return windowManager.close();
          case 'window_show':
            return windowManager.show();
          case 'window_focus':
            return windowManager.focus();
          case 'window_hide':
            return windowManager.hide();
          case 'window_minimize':
            return windowManager.minimize();
          case 'window_maximize':
            return windowManager.maximize();
          case 'window_restore':
            return windowManager.restore();
          case 'window_set_always_on_top':
            final args = call.arguments as Map?;
            final isOn = args?['isOn'] as bool? ?? false;
            return windowManager.setAlwaysOnTop(isOn);
          case 'playVideo':
            final args = call.arguments;
            if (args is Map) {
              _navigateToVideo(args);
            }
            return;
          case 'playLive':
            final args = call.arguments;
            if (args is Map) {
              _navigateToLive(args);
            }
            return;
          default:
            throw MissingPluginException('Not implemented: ${call.method}');
        }
      });
    } catch (e) {
      debugPrint('_setupWindowMethodHandler error: $e');
    }
  }

  void _navigateToInitialPage() {
    if (_initialRoute == '/liveRoom' && _initialArguments != null) {
      windowManager.setTitle('${Constants.appName} - 直播');
      Get.offAllNamed(
        '/liveRoom',
        arguments: _initialArguments,
      );
    } else if (_initialRoute == '/videoV' && _initialArguments != null) {
      windowManager.setTitle('${Constants.appName} - 播放器');
      Get.offAllNamed(
        '/videoV',
        arguments: _initialArguments,
      );
    }
  }

  /// 重置到预加载状态（销毁播放器，返回 placeholder 页面，隐藏窗口）
  Future<void> _resetToPreloadState() async {
    // 1. 销毁播放器
    try {
      final plCtr = PlPlayerController.instance;
      if (plCtr != null) {
        plCtr.isCloseAll = true;
        await plCtr.dispose();
      }
    } catch (_) {}

    // 2. 返回 placeholder 页面
    Get.offAllNamed('/');
    windowManager.setTitle('${Constants.appName} - 播放器');

    // 3. 隐藏窗口
    await windowManager.hide();
  }

  void _navigateToVideo(Map args) {
    // Update window title for video
    windowManager.setTitle('${Constants.appName} - 播放器');

    Get.offAllNamed(
      '/videoV',
      arguments: _buildVideoArguments(args),
    );
  }

  void _navigateToLive(Map args) {
    final roomId = args['roomId'] as int?;
    if (roomId == null) {
      debugPrint('Cannot navigate to live: roomId is null');
      return;
    }

    // Update window title for live
    windowManager.setTitle('${Constants.appName} - 直播');

    // LiveRoomPage expects roomId as a direct int argument, not a Map
    Get.offAllNamed(
      '/liveRoom',
      arguments: roomId,
    );
  }

  @override
  Future<void> onWindowClose() async {
    // 同步设置到主窗口
    try {
      // 只同步播放器窗口特有的设置（尺寸、位置等），避免覆盖主窗口的其他设置
      final bounds = await windowManager.getBounds();
      final playerWindowSettings = <String, dynamic>{
        'playerWindowSize': [bounds.width, bounds.height],
        'playerWindowPosition': [bounds.left, bounds.top],
        // 保存当前 devicePixelRatio，用于恢复时校正坐标
        'playerWindowScaleFactor': windowManager.getDevicePixelRatio(),
        'playerWindowAlwaysOnTop': _alwaysOnTop,
      };

      // 发送到主窗口保存
      final mainWindow = await PlayerWindowService.findMainWindow();
      if (mainWindow != null) {
        await mainWindow.invokeMethod(
          'syncPlayerSettings',
          playerWindowSettings,
        );
      }
    } catch (e) {
      debugPrint('Failed to sync player settings: $e');
    }

    // 查询主窗口的最新 preInitPlayer 设置值
    bool shouldHideInsteadOfClose = false;
    try {
      final mainWindow = await PlayerWindowService.findMainWindow();
      if (mainWindow != null) {
        final result = await mainWindow.invokeMethod('getPreInitPlayer');
        shouldHideInsteadOfClose = result == true;
      }
    } catch (e) {
      debugPrint('Failed to query preInitPlayer: $e');
    }

    // 如果启用了提前初始化播放器，则隐藏窗口并重置状态，而非真正关闭
    if (shouldHideInsteadOfClose) {
      await _resetToPreloadState();
      return;
    }

    // 真正关闭窗口
    // 销毁播放器，确保视频停止播放
    try {
      final plCtr = PlPlayerController.instance;
      if (plCtr != null) {
        plCtr.isCloseAll = true; // 确保完全销毁
        await plCtr.dispose();
      }
    } catch (e) {
      // 忽略销毁错误
    }

    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Color brandColor = colorThemeTypes[_customColor].color;
    FlexSchemeVariant variant = FlexSchemeVariant.values[_schemeVariant];

    return DynamicColorBuilder(
      builder: ((ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        ColorScheme? lightColorScheme;
        ColorScheme? darkColorScheme;
        if (lightDynamic != null && darkDynamic != null && _dynamicColor) {
          lightColorScheme = lightDynamic.harmonized();
          darkColorScheme = darkDynamic.harmonized();
        } else {
          lightColorScheme = SeedColorScheme.fromSeeds(
            primaryKey: brandColor,
            brightness: Brightness.light,
            variant: variant,
          );
          darkColorScheme = SeedColorScheme.fromSeeds(
            primaryKey: brandColor,
            brightness: Brightness.dark,
            variant: variant,
          );
        }

        return GetMaterialApp(
          title: '${Constants.appName} - 播放器',
          theme: _buildThemeData(
            colorScheme: lightColorScheme,
            isDynamic: lightDynamic != null && _dynamicColor,
          ),
          darkTheme: _buildThemeData(
            colorScheme: darkColorScheme,
            isDynamic: darkDynamic != null && _dynamicColor,
            isDark: true,
          ),
          themeMode: _themeMode,
          localizationsDelegates: const [
            GlobalCupertinoLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          locale: const Locale("zh", "CN"),
          supportedLocales: const [Locale("zh", "CN"), Locale("en", "US")],
          fallbackLocale: const Locale("zh", "CN"),
          getPages: _playerWindowRoutes,
          initialRoute: '/',
          builder: FlutterSmartDialog.init(
            toastBuilder: (String msg) => CustomToast(msg: msg),
            loadingBuilder: (msg) => LoadingWidget(msg: msg),
            builder: (context, child) {
              child = MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(_textScale),
                ),
                child: child!,
              );

              void onBack() {
                if (SmartDialog.checkExist()) {
                  SmartDialog.dismiss();
                  return;
                }

                if (Get.routing.route is! GetPageRoute) {
                  Get.back();
                  return;
                }

                final route = Get.routing.route;
                if (route is GetPageRoute) {
                  if (route.popDisposition == .doNotPop) {
                    route.onPopInvokedWithResult(false, null);
                    return;
                  }
                }

                // 关闭播放器窗口
                windowManager.close();
              }

              return BackDetector(
                onBack: onBack,
                child: child,
              );
            },
          ),
          navigatorObservers: [
            FlutterSmartDialog.observer,
            PageUtils.routeObserver,
            _PlayerWindowRouteObserver(),
          ],
          scrollBehavior: const MaterialScrollBehavior().copyWith(
            scrollbars: false,
            dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.stylus,
              PointerDeviceKind.invertedStylus,
              PointerDeviceKind.trackpad,
              PointerDeviceKind.unknown,
              if (PlatformUtils.isDesktop) PointerDeviceKind.mouse,
            },
          ),
        );
      }),
    );
  }
}

/// 播放器窗口路由观察者
/// 拦截非播放页面的路由，在主窗口中打开
class _PlayerWindowRouteObserver extends NavigatorObserver {
  static const _playerRoutes = ['/videoV', '/live', '/bangumi', '/audioPlayer'];

  bool _isPlayerRoute(String? routeName) {
    if (routeName == null) return false;
    return _playerRoutes.any((r) => routeName.startsWith(r));
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    final routeName = route.settings.name;
    // 如果不是播放页面且不是根路由，在主窗口打开
    if (routeName != null && routeName != '/' && !_isPlayerRoute(routeName)) {
      // 在主窗口打开此路由
      PlayerWindowManager.instance.openInMainWindow(
        routeName,
        route.settings.arguments,
      );
      // 阻止在播放器窗口中导航
      Future.microtask(() {
        if (navigator?.canPop() ?? false) {
          navigator?.pop();
        }
      });
    }
    super.didPush(route, previousRoute);
  }
}
