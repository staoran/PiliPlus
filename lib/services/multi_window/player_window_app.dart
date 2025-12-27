import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/common/widgets/custom_toast.dart';
import 'package:PiliPlus/common/widgets/mouse_back.dart';
import 'package:PiliPlus/models/common/theme/theme_color_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/router/app_pages.dart';
import 'package:PiliPlus/services/multi_window/player_window_service.dart';
import 'package:PiliPlus/services/multi_window/window_arguments.dart';
import 'package:PiliPlus/utils/calc_window_position.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart' hide calcWindowPosition;

/// 播放器窗口入口
class PlayerWindowApp extends StatefulWidget {
  const PlayerWindowApp({
    super.key,
    required this.windowController,
    required this.arguments,
  });

  final WindowController windowController;
  final PlayerWindowArguments arguments;

  @override
  State<PlayerWindowApp> createState() => _PlayerWindowAppState();
}

class _PlayerWindowAppState extends State<PlayerWindowApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    _initWindow();
    // Only setup window channel on desktop platforms
    if (PlatformUtils.isDesktop) {
      _setupWindowChannel();
    }
  }

  Future<void> _initWindow() async {
    await windowManager.ensureInitialized();
    // 注册窗口方法处理器，支持窗口控制与播放指令复用
    await widget.windowController.setWindowMethodHandler((call) async {
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
          final rawArgs = call.arguments;
          if (rawArgs is Map) {
            final args = Map<String, dynamic>.from(
              rawArgs.map(
                (key, value) => MapEntry(key.toString(), value),
              ),
            );
            _navigateToVideo(PlayerWindowArguments.fromJson(args));
          }
          return;
        default:
          throw MissingPluginException('Not implemented: ${call.method}');
      }
    });

    final savedSize = PlayerWindowService.savedPlayerWindowSize;
    final savedPosition = PlayerWindowService.savedPlayerWindowPosition;

    WindowOptions windowOptions = WindowOptions(
      size: savedSize,
      minimumSize: const Size(640, 480),
      skipTaskbar: false,
      titleBarStyle: Pref.showWindowTitleBar
          ? TitleBarStyle.normal
          : TitleBarStyle.hidden,
      title: '${Constants.appName} - 播放器',
    );

    windowManager
      ..waitUntilReadyToShow(windowOptions, () async {
      if (savedPosition != null) {
        await windowManager.setPosition(
          Offset(savedPosition[0], savedPosition[1]),
        );
      } else {
        await windowManager.setBounds(await calcWindowPosition(savedSize) & savedSize);
      }
      await windowManager.show();
      await windowManager.focus();
      if (Pref.playerWindowAlwaysOnTop) {
        await windowManager.setAlwaysOnTop(true);
      }
      })

      ..addListener(this)
      ..setPreventClose(true);
  }

  void _setupWindowChannel() {
    final _ = const WindowMethodChannel('player_window_channel')
      ..setMethodCallHandler((call) async {
      switch (call.method) {
        case 'playVideo':
          // Note: IPC may pass Map<Object?, Object?>, need to convert properly
          final rawArgs = call.arguments;
          if (rawArgs is Map) {
            final args = Map<String, dynamic>.from(
              rawArgs.map(
                (key, value) => MapEntry(key.toString(), value),
              ),
            );
            _navigateToVideo(PlayerWindowArguments.fromJson(args));
          }
          return;
        default:
          throw MissingPluginException('Not implemented: ${call.method}');
      }
    });
  }

  void _navigateToVideo(PlayerWindowArguments args) {
    // 将字符串 videoType 转换为 VideoType 枚举
    final videoType = switch (args.videoType) {
      'pgc' => VideoType.pgc,
      'pugv' => VideoType.pugv,
      _ => VideoType.ugc,
    };

    // 导航到视频页面
    Get.offAllNamed(
      '/videoV',
      arguments: {
        'aid': args.aid,
        'bvid': args.bvid,
        'cid': args.cid,
        'videoType': videoType,
        if (args.seasonId != null) 'seasonId': args.seasonId,
        if (args.epId != null) 'epId': args.epId,
        if (args.pgcType != null) 'pgcType': args.pgcType,
        if (args.cover != null) 'pic': args.cover,
        'heroTag': 'playerWindow_${args.bvid}',
        if (args.progress != null) 'progress': args.progress,
        ...?args.extraArguments,
      },
    );
  }

  @override
  Future<void> onWindowClose() async {
    // 保存窗口位置和大小
    final bounds = await windowManager.getBounds();
    PlayerWindowService.savePlayerWindowBounds(
      bounds.left,
      bounds.top,
      bounds.width,
      bounds.height,
    );
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  Future<void> onWindowResized() async {
    final bounds = await windowManager.getBounds();
    PlayerWindowService.savePlayerWindowBounds(
      bounds.left,
      bounds.top,
      bounds.width,
      bounds.height,
    );
  }

  @override
  Future<void> onWindowMoved() async {
    final bounds = await windowManager.getBounds();
    PlayerWindowService.savePlayerWindowBounds(
      bounds.left,
      bounds.top,
      bounds.width,
      bounds.height,
    );
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Color brandColor = colorThemeTypes[Pref.customColor].color;
    bool isDynamicColor = Pref.dynamicColor;
    FlexSchemeVariant variant = FlexSchemeVariant.values[Pref.schemeVariant];

    return DynamicColorBuilder(
      builder: ((ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        ColorScheme? lightColorScheme;
        ColorScheme? darkColorScheme;
        if (lightDynamic != null && darkDynamic != null && isDynamicColor) {
          lightColorScheme = lightDynamic.harmonized();
          darkColorScheme = darkDynamic.harmonized();
        } else {
          lightColorScheme = SeedColorScheme.fromSeeds(
            primaryKey: brandColor,
            brightness: Brightness.light,
            variant: variant,
            useExpressiveOnContainerColors: false,
          );
          darkColorScheme = SeedColorScheme.fromSeeds(
            primaryKey: brandColor,
            brightness: Brightness.dark,
            variant: variant,
            useExpressiveOnContainerColors: false,
          );
        }

        return GetMaterialApp(
          title: '${Constants.appName} - 播放器',
          theme: ThemeUtils.getThemeData(
            colorScheme: lightColorScheme,
            isDynamic: lightDynamic != null && isDynamicColor,
          ),
          darkTheme: ThemeUtils.getThemeData(
            colorScheme: darkColorScheme,
            isDynamic: darkDynamic != null && isDynamicColor,
            isDark: true,
          ),
          themeMode: Pref.themeMode,
          localizationsDelegates: const [
            GlobalCupertinoLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          locale: const Locale("zh", "CN"),
          supportedLocales: const [Locale("zh", "CN"), Locale("en", "US")],
          fallbackLocale: const Locale("zh", "CN"),
          getPages: Routes.getPages,
          initialRoute: '/videoV',
          initialBinding: BindingsBuilder(() {
            // 初始绑定，在路由参数中传递视频信息
          }),
          routingCallback: (routing) {
            // 拦截非播放页面的路由，在主窗口中打开
            if (routing?.current != null) {
              final route = routing!.current;
              if (_shouldOpenInMainWindow(route)) {
                // TODO: 在主窗口中打开
              }
            }
          },
          builder: FlutterSmartDialog.init(
            toastBuilder: (String msg) => CustomToast(msg: msg),
            loadingBuilder: (msg) => LoadingWidget(msg: msg),
            builder: (context, child) {
              child = MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(Pref.defaultTextScale),
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

                final plCtr = PlPlayerController.instance;
                if (plCtr != null) {
                  if (plCtr.isFullScreen.value) {
                    plCtr
                      ..triggerFullScreen(status: false)
                      ..controlsLock.value = false
                      ..showControls.value = false;
                    return;
                  }

                  if (plCtr.isDesktopPip) {
                    plCtr
                      ..exitDesktopPip().whenComplete(
                        () => plCtr.initialFocalPoint = Offset.zero,
                      )
                      ..controlsLock.value = false
                      ..showControls.value = false;
                    return;
                  }
                }

                // 关闭播放器窗口
                windowManager.close();
              }

              return Focus(
                canRequestFocus: false,
                onKeyEvent: (_, event) {
                  if (event.logicalKey == LogicalKeyboardKey.escape &&
                      event is KeyDownEvent) {
                    onBack();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: MouseBackDetector(
                  onTapDown: onBack,
                  child: child,
                ),
              );
            },
          ),
          navigatorObservers: [
            FlutterSmartDialog.observer,
          ],
        );
      }),
    );
  }

  /// 判断路由是否应该在主窗口中打开
  bool _shouldOpenInMainWindow(String route) {
    // 播放页面在当前窗口打开
    const playerRoutes = ['/videoV', '/live', '/bangumi', '/audioPlayer'];
    if (playerRoutes.any((r) => route.startsWith(r))) {
      return false;
    }
    // 其他页面在主窗口打开
    return true;
  }
}
