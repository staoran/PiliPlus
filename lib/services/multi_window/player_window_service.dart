import 'dart:ui' as ui;

import 'package:PiliPlus/services/multi_window/window_arguments.dart';
import 'package:PiliPlus/services/multi_window/window_controller_extension.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';

/// 播放器窗口服务
/// 管理播放器窗口的创建、查找、通信
class PlayerWindowService {
  PlayerWindowService._();
  static final PlayerWindowService _instance = PlayerWindowService._();
  static PlayerWindowService get instance => _instance;

  /// 当前是否在播放器窗口中
  static bool isPlayerWindow = false;

  /// 预创建的窗口控制器（待命状态）
  WindowController? _preCreatedController;

  /// 是否正在预创建窗口
  bool _isPreCreating = false;

  /// 检查是否启用播放器窗口
  static bool get usePlayerWindow => Pref.usePlayerWindow;

  /// 检查是否启用预创建播放器窗口
  /// 复用「提前初始化播放器」设置
  static bool get preInitPlayerWindow => usePlayerWindow && Pref.preInitPlayer;

  /// 处理播放器窗口相关设置变更
  /// 当「新窗口播放」或「提前初始化播放器」设置变更时调用
  void handlePlayerWindowSettingChanged({
    bool? usePlayerWindow,
    bool? preInitPlayer,
  }) {
    // 获取当前的设置状态（设置已保存，所以直接读取最新值）
    final currentUsePlayerWindow = Pref.usePlayerWindow;
    final currentPreInitPlayer = Pref.preInitPlayer;

    // 判断是否需要预创建播放器窗口
    final shouldPreCreate = currentUsePlayerWindow && currentPreInitPlayer;

    if (shouldPreCreate) {
      // 需要预创建播放器窗口
      preCreatePlayerWindow();
    } else {
      // 不需要预创建，关闭已存在的预创建窗口
      _closePreCreatedWindowIfExists();
    }

    if (kDebugMode) {
      debugPrint(
        '[PlayerWindowService] Setting changed: '
        'usePlayerWindow=$currentUsePlayerWindow, '
        'preInitPlayer=$currentPreInitPlayer, '
        'shouldPreCreate=$shouldPreCreate',
      );
    }
  }

  /// 关闭预创建的窗口（如果存在）
  Future<void> _closePreCreatedWindowIfExists() async {
    final preCreated = _preCreatedController;
    if (preCreated != null) {
      _preCreatedController = null;
      try {
        await preCreated.close();
        if (kDebugMode) {
          debugPrint('[PlayerWindowService] Closed pre-created window');
        }
      } catch (_) {}
    }
  }

  /// 预创建播放器窗口（隐藏状态，等待使用）
  /// 应在主窗口启动后调用
  Future<void> preCreatePlayerWindow() async {
    if (!preInitPlayerWindow) return;
    if (_isPreCreating) return;
    if (_preCreatedController != null) return;

    // 检查是否已有播放器窗口存在
    final existing = await findPlayerWindow();
    if (existing != null) return;

    _isPreCreating = true;
    try {
      // 创建带有设置快照但无视频参数的空播放器窗口
      final preCreateArgs = PlayerWindowArguments(
        settings: {
          ..._getSettingsSnapshot(),
          'businessId': WindowArguments.businessIdPlayer,
        },
      );

      final controller = await WindowController.create(
        WindowConfiguration(
          hiddenAtLaunch: true, // 保持隐藏
          arguments: preCreateArgs.toArguments(),
        ),
      );

      _preCreatedController = controller;

      if (kDebugMode) {
        debugPrint(
          '[PlayerWindowService] Pre-created player window: ${controller.windowId}',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[PlayerWindowService] preCreatePlayerWindow error: $e');
      }
    } finally {
      _isPreCreating = false;
    }
  }

  /// 检查播放器窗口是否存在
  Future<WindowController?> findPlayerWindow() async {
    try {
      final controllers = await WindowController.getAll();
      for (var controller in controllers) {
        final args = WindowArguments.fromArguments(controller.arguments);
        if (args.businessId == WindowArguments.businessIdPlayer) {
          return controller;
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('findPlayerWindow error: $e');
      }
    }
    return null;
  }

  /// 打开或重用播放器窗口（支持视频和直播）
  Future<void> openPlayerWindow(PlayerWindowArguments arguments) async {
    try {
      // 查找现有播放器窗口
      final existingController = await findPlayerWindow();

      if (existingController != null) {
        // 已存在播放器窗口，尝试发送新的视频参数
        try {
          await _sendVideoToPlayer(existingController, arguments);
          await existingController.show();
          await existingController.focus();
          return;
        } catch (e) {
          // 窗口可能已关闭，继续创建新窗口
          if (kDebugMode) {
            debugPrint(
              'Existing player window not responding, creating new one: $e',
            );
          }
        }
      }

      // 尝试使用预创建的窗口
      final preCreated = _preCreatedController;
      if (preCreated != null) {
        _preCreatedController = null; // 清除引用，窗口已被使用
        try {
          // 向预创建的窗口发送视频参数
          await _sendVideoToPlayer(preCreated, arguments);
          await preCreated.show();
          await preCreated.focus();

          if (kDebugMode) {
            debugPrint(
              '[PlayerWindowService] Using pre-created window: ${preCreated.windowId}',
            );
          }

          // 异步预创建下一个窗口
          Future.delayed(
            const Duration(seconds: 2),
            preCreatePlayerWindow,
          );
          return;
        } catch (e) {
          // 预创建的窗口可能已失效，继续创建新窗口
          if (kDebugMode) {
            debugPrint(
              '[PlayerWindowService] Pre-created window failed, creating new one: $e',
            );
          }
        }
      }

      // 添加设置快照到参数中
      final argsWithSettings = PlayerWindowArguments(
        aid: arguments.aid,
        bvid: arguments.bvid,
        cid: arguments.cid,
        seasonId: arguments.seasonId,
        epId: arguments.epId,
        pgcType: arguments.pgcType,
        roomId: arguments.roomId,
        cover: arguments.cover,
        title: arguments.title,
        progress: arguments.progress,
        videoType: arguments.videoType,
        extraArguments: arguments.extraArguments,
        settings: {
          ..._getSettingsSnapshot(),
          'businessId': WindowArguments.businessIdPlayer, // Add businessId to settings
        },
      );

      // 创建新窗口
      final controller = await WindowController.create(
        WindowConfiguration(
          hiddenAtLaunch: true,
          arguments: argsWithSettings.toArguments(),
        ),
      );

      if (kDebugMode) {
        debugPrint(
          'Created player window: ${controller.windowId} ${controller.arguments}',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('openPlayerWindow error: $e');
      }
      rethrow;
    }
  }

  /// 获取需要传递给子窗口的设置快照
  Map<String, dynamic> _getSettingsSnapshot() {
    return {
      'customColor': Pref.customColor,
      'dynamicColor': Pref.dynamicColor,
      'schemeVariant': Pref.schemeVariant.index,
      'themeMode': Pref.themeMode.index,
      'showWindowTitleBar': Pref.showWindowTitleBar,
      'defaultTextScale': Pref.defaultTextScale,
      'playerWindowSize': [
        Pref.playerWindowSize.width,
        Pref.playerWindowSize.height,
      ],
      'playerWindowPosition': Pref.playerWindowPosition,
      'playerWindowScaleFactor': Pref.playerWindowScaleFactor,
      'playerWindowAlwaysOnTop': Pref.playerWindowAlwaysOnTop,
      // 传递提前初始化播放器设置，用于子窗口判断关闭时是隐藏还是销毁
      'preInitPlayer': Pref.preInitPlayer,
      // Export all settings for sub-window in-memory storage
      'allSettings': GStorage.exportAllSettingsAsJson(),
      // Export account data for sub-window
      'accountData': _exportAccountData(),
    };
  }

  /// Export account data as JSON for sub-window
  Map<String, dynamic>? _exportAccountData() {
    final account = Accounts.main;
    if (kDebugMode) {
      debugPrint(
        '[PlayerWindowService] Exporting account, isLogin: ${account.isLogin}',
      );
    }
    if (!account.isLogin) return null;
    final json = account.toJson();
    if (kDebugMode) {
      debugPrint('[PlayerWindowService] Exported account data: $json');
    }
    return json;
  }

  /// 向播放器窗口发送新视频参数
  Future<void> _sendVideoToPlayer(
    WindowController controller,
    PlayerWindowArguments arguments,
  ) async {
    // 使用 WindowController.invokeMethod 向特定窗口发送消息
    // 根据参数类型决定发送playVideo还是playLive
    final method = arguments.roomId != null ? 'playLive' : 'playVideo';
    await controller.invokeMethod(method, arguments.toJson());
  }

  /// 关闭播放器窗口
  Future<void> closePlayerWindow() async {
    try {
      // 关闭预创建的窗口
      final preCreated = _preCreatedController;
      if (preCreated != null) {
        _preCreatedController = null;
        try {
          await preCreated.close();
        } catch (_) {}
      }

      // 关闭正在使用的播放器窗口
      final controller = await findPlayerWindow();
      if (controller != null) {
        await controller.close();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('closePlayerWindow error: $e');
      }
    }
  }

  /// 关闭预创建的窗口（程序退出时调用）
  Future<void> closePreCreatedWindow() async {
    final preCreated = _preCreatedController;
    if (preCreated != null) {
      _preCreatedController = null;
      try {
        await preCreated.close();
      } catch (_) {}
    }
  }

  /// 保存播放器窗口位置和大小
  static void savePlayerWindowBounds(double x, double y, double w, double h) {
    GStorage.setting.put(SettingBoxKey.playerWindowSize, [w, h]);
    GStorage.setting.put(SettingBoxKey.playerWindowPosition, [x, y]);
  }

  /// 获取保存的播放器窗口大小
  static ui.Size get savedPlayerWindowSize => Pref.playerWindowSize;

  /// 获取保存的播放器窗口位置
  static List<double>? get savedPlayerWindowPosition =>
      Pref.playerWindowPosition;

  /// 查找主窗口
  static Future<WindowController?> findMainWindow() async {
    try {
      final controllers = await WindowController.getAll();
      for (var controller in controllers) {
        final args = WindowArguments.fromArguments(controller.arguments);
        // 主窗口的 businessId 是 'main' 或空
        if (args.businessId == WindowArguments.businessIdMain ||
            args.businessId.isEmpty) {
          return controller;
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('findMainWindow error: $e');
      }
    }
    return null;
  }

  /// 显示主窗口（从子窗口调用）
  static Future<void> showMainWindow() async {
    try {
      final controller = await findMainWindow();
      if (controller != null) {
        await controller.show();
        await controller.focus();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('showMainWindow error: $e');
      }
    }
  }
}
