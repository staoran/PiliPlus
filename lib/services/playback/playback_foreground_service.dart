import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// 短时媒体前台服务，用于在后台/锁屏切曲目时降低被系统挂起的概率。
class PlaybackForegroundService {
  PlaybackForegroundService._();

  static bool _isRunning = false;
  static bool _isInitialized = false;
  static DateTime? _lastUpdate;
  static Timer? _autoStopTimer;
  static const _throttle = Duration(milliseconds: 500);
  static const _maxProtectDuration = Duration(seconds: 20);

  static bool get isSupported => Platform.isAndroid;

  static Future<void> _init() async {
    if (!isSupported || _isInitialized) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'piliplus_playback_channel',
        channelName: '媒体播放保活',
        channelDescription: '后台播放切换时保持进程存活',
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
        allowWakeLock: false,
        allowWifiLock: false,
      ),
    );

    _isInitialized = true;
  }

  static Future<void> start({
    required String title,
    String? text,
  }) async {
    if (!isSupported) return;
    if (_isRunning) {
      _scheduleAutoStop();
      return;
    }
    try {
      await _init();

      final permission = await FlutterForegroundTask.checkNotificationPermission();
      if (permission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }

      await FlutterForegroundTask.startService(
        notificationTitle: title,
        notificationText: text ?? '准备切换下一首…',
        notificationIcon: null,
        callback: _taskCallback,
      );
      _isRunning = true;
      _scheduleAutoStop();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlaybackForegroundService start error: $e');
      }
    }
  }

  static Future<void> update({
    String? title,
    String? text,
    bool force = false,
  }) async {
    if (!isSupported || !_isRunning) return;

    final now = DateTime.now();
    if (!force && _lastUpdate != null &&
        now.difference(_lastUpdate!) < _throttle) {
      return;
    }
    _lastUpdate = now;

    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: title ?? '媒体播放',
        notificationText: text,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlaybackForegroundService update error: $e');
      }
    }
  }

  static Future<void> stop() async {
    if (!isSupported || !_isRunning) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlaybackForegroundService stop error: $e');
      }
    } finally {
      _isRunning = false;
      _lastUpdate = null;
      _autoStopTimer?.cancel();
      _autoStopTimer = null;
    }
  }

  static void _scheduleAutoStop() {
    _autoStopTimer?.cancel();
    _autoStopTimer = Timer(_maxProtectDuration, () {
      if (kDebugMode) {
        debugPrint('PlaybackForegroundService auto stop after timeout');
      }
      stop();
    });
  }

  static bool get isRunning => _isRunning;
}

@pragma('vm:entry-point')
void _taskCallback() {
  FlutterForegroundTask.setTaskHandler(_PlaybackTaskHandler());
}

class _PlaybackTaskHandler extends TaskHandler {
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
    FlutterForegroundTask.launchApp();
  }
}
