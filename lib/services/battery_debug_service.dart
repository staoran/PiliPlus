// 电池调试服务 - 用于追踪可能导致耗电的操作
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 电池调试服务，用于追踪可能导致耗电的操作
class BatteryDebugService with WidgetsBindingObserver {
  static final BatteryDebugService _instance = BatteryDebugService._internal();
  factory BatteryDebugService() => _instance;
  BatteryDebugService._internal();

  // 是否启用电池调试
  static bool enabled = kDebugMode;

  // 活跃的定时器
  final Map<String, _TimerInfo> _activeTimers = {};

  // 活跃的网络请求
  int _activeNetworkRequests = 0;

  // 应用生命周期状态
  AppLifecycleState? _lifecycleState;

  // 最后记录时间
  DateTime? _lastLogTime;

  void init() {
    if (!enabled) return;
    WidgetsBinding.instance.addObserver(this);
    _log('BatteryDebugService initialized');
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (!enabled) return;

    _log('App lifecycle changed: $state');

    if (state == AppLifecycleState.paused) {
      // 应用进入后台，输出当前所有活跃的定时器和任务
      _logActiveResources();
    } else if (state == AppLifecycleState.resumed) {
      _log('App resumed from background');
    }
  }

  /// 记录定时器启动
  void trackTimerStart(String name, Duration interval, {String? caller}) {
    if (!enabled) return;
    _activeTimers[name] = _TimerInfo(
      name: name,
      interval: interval,
      startTime: DateTime.now(),
      caller: caller ?? _getCallerInfo(),
    );
    _log('⏱️ Timer started: $name (interval: ${interval.inSeconds}s)');
  }

  /// 记录定时器停止
  void trackTimerStop(String name) {
    if (!enabled) return;
    final info = _activeTimers.remove(name);
    if (info != null) {
      final duration = DateTime.now().difference(info.startTime);
      _log('⏱️ Timer stopped: $name (ran for: ${duration.inSeconds}s)');
    }
  }

  /// 记录网络请求开始
  void trackNetworkStart(String url) {
    if (!enabled) return;
    _activeNetworkRequests++;
    // 只在后台状态下详细记录
    if (_lifecycleState == AppLifecycleState.paused) {
      _log('🌐 Network request in background: $url');
    }
  }

  /// 记录网络请求结束
  void trackNetworkEnd(String url) {
    if (!enabled) return;
    _activeNetworkRequests--;
  }

  /// 记录唤醒锁操作
  void trackWakelock(bool isEnabled) {
    if (!enabled) return;
    _log('🔒 Wakelock ${isEnabled ? "enabled" : "disabled"}');
  }

  /// 记录后台任务
  void trackBackgroundTask(String name, {bool start = true}) {
    if (!enabled) return;
    _log('📋 Background task ${start ? "started" : "ended"}: $name');
  }

  /// 输出当前所有活跃资源
  void _logActiveResources() {
    if (!enabled) return;

    final buffer = StringBuffer()
      ..writeln('========== 后台活跃资源报告 ==========')
      ..writeln('时间: ${DateTime.now()}');

    // 活跃定时器
    if (_activeTimers.isNotEmpty) {
      buffer.writeln('\n活跃定时器 (${_activeTimers.length}个):');
      for (final timer in _activeTimers.values) {
        buffer.writeln(
          '  - ${timer.name}: 间隔${timer.interval.inSeconds}s, '
          '运行${DateTime.now().difference(timer.startTime).inSeconds}s',
        );
        if (timer.caller != null) {
          buffer.writeln('    调用者: ${timer.caller}');
        }
      }
    } else {
      buffer.writeln('\n无活跃定时器');
    }

    // 活跃网络请求
    buffer
      ..writeln('\n活跃网络请求: $_activeNetworkRequests')

      ..writeln('=====================================');
    _log(buffer.toString());
  }

  /// 获取当前状态摘要
  String getStatusSummary() {
    return '''
BatteryDebugService Status:
- Lifecycle: $_lifecycleState
- Active Timers: ${_activeTimers.length}
- Active Network Requests: $_activeNetworkRequests
- Timers: ${_activeTimers.keys.join(', ')}
''';
  }

  /// 手动触发状态报告
  void logStatus() {
    if (!enabled) return;
    _logActiveResources();
  }

  void _log(String message) {
    if (!enabled) return;

    final now = DateTime.now();

    // 避免过于频繁的日志
    if (_lastLogTime != null &&
        now.difference(_lastLogTime!).inMilliseconds < 100) {
      return;
    }
    _lastLogTime = now;

    final timestamp =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';

    debugPrint('[BatteryDebug $timestamp] $message');
  }

  String _getCallerInfo() {
    try {
      final frames = StackTrace.current.toString().split('\n');
      // 跳过当前方法和调用者的帧，获取实际调用位置
      if (frames.length > 3) {
        return frames[3].trim();
      }
    } catch (_) {}
    return 'unknown';
  }
}

class _TimerInfo {
  final String name;
  final Duration interval;
  final DateTime startTime;
  final String? caller;

  _TimerInfo({
    required this.name,
    required this.interval,
    required this.startTime,
    this.caller,
  });
}

// 全局实例
final batteryDebug = BatteryDebugService();
