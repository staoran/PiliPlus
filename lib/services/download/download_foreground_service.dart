import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// 下载前台服务管理器
/// 用于在 Android 上保持下载在后台继续运行
class DownloadForegroundService {
  static bool _isRunning = false;
  static bool _isInitialized = false;
  static DateTime? _lastUpdateTime;
  static const _updateThrottleDuration = Duration(milliseconds: 500);

  /// 是否支持前台服务（仅 Android）
  static bool get isSupported => Platform.isAndroid;

  /// 初始化前台服务
  static Future<void> init() async {
    if (!isSupported || _isInitialized) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'piliplus_download_channel',
        channelName: '离线下载',
        channelDescription: '正在下载离线视频',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        visibility: NotificationVisibility.VISIBILITY_PUBLIC,
        enableVibration: false,
        playSound: false,
        showWhen: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    _isInitialized = true;
  }

  /// 启动前台服务
  static Future<void> start({
    required String title,
    String? text,
  }) async {
    if (!isSupported || _isRunning) return;

    try {
      await init();

      // 请求通知权限
      final notificationPermission =
          await FlutterForegroundTask.checkNotificationPermission();
      if (notificationPermission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }

      // 启动前台服务
      await FlutterForegroundTask.startService(
        notificationTitle: title,
        notificationText: text ?? '准备下载...',
        notificationIcon: null,
        callback: _taskCallback,
      );

      _isRunning = true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to start foreground service: $e');
      }
    }
  }

  /// 更新通知内容（带节流，避免频繁更新）
  static Future<void> updateNotification({
    required String title,
    String? text,
    bool force = false,
  }) async {
    if (!isSupported || !_isRunning) return;

    // 节流：避免频繁更新通知
    final now = DateTime.now();
    if (!force && _lastUpdateTime != null) {
      if (now.difference(_lastUpdateTime!) < _updateThrottleDuration) {
        return;
      }
    }
    _lastUpdateTime = now;

    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to update notification: $e');
      }
    }
  }

  /// 停止前台服务
  static Future<void> stop() async {
    if (!isSupported || !_isRunning) return;

    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to stop foreground service: $e');
      }
    } finally {
      _isRunning = false;
      _lastUpdateTime = null;
    }
  }

  /// 是否正在运行
  static bool get isRunning => _isRunning;
}

/// 前台任务回调（必需，但我们不需要在其中执行任何操作）
@pragma('vm:entry-point')
void _taskCallback() {
  FlutterForegroundTask.setTaskHandler(_DownloadTaskHandler());
}

class _DownloadTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {
    // 点击通知时返回应用
    FlutterForegroundTask.launchApp();
  }
}
