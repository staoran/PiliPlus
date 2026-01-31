import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// WindowController 扩展，用于窗口间通信
extension WindowControllerExtension on WindowController {
  /// 初始化窗口方法处理器（用于子窗口）
  Future<void> doCustomInitialize() {
    return setWindowMethodHandler((call) {
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
        default:
          throw MissingPluginException(
            'Not implemented method: ${call.method}',
          );
      }
    });
  }

  /// 初始化主窗口方法处理器
  Future<void> initMainWindowHandler() {
    return setWindowMethodHandler((call) async {
      dynamic result;
      switch (call.method) {
        case 'window_center':
          await windowManager.center();
        case 'window_close':
          await windowManager.close();
        case 'window_show':
          await windowManager.show();
        case 'window_focus':
          await windowManager.focus();
        case 'window_hide':
          await windowManager.hide();
        case 'window_minimize':
          await windowManager.minimize();
        case 'window_maximize':
          await windowManager.maximize();
        case 'window_restore':
          await windowManager.restore();
        case 'window_set_always_on_top':
          final args = call.arguments as Map?;
          final isOn = args?['isOn'] as bool? ?? false;
          await windowManager.setAlwaysOnTop(isOn);
        case 'syncPlayerSettings':
          // 接收并保存来自播放器子窗口的设置
          final args = call.arguments;
          if (args != null && args is Map) {
            // 安全地转换 Map<Object?, Object?> 为 Map<String, dynamic>
            final settings = Map<String, dynamic>.from(args);
            await _syncPlayerSettingsToMain(settings);
          }
        case 'getPreInitPlayer':
          // 播放器窗口查询当前的 preInitPlayer 设置值
          result = Pref.preInitPlayer;
        default:
          throw MissingPluginException(
            'Not implemented method: ${call.method}',
          );
      }
      return result;
    });
  }

  /// 将播放器子窗口的设置同步到主窗口
  Future<void> _syncPlayerSettingsToMain(Map<String, dynamic> settings) async {
    try {
      await GStorage.setting.putAll(settings);
    } catch (e) {
      // 忽略同步错误，避免影响窗口关闭
    }
  }

  /// 让目标窗口居中
  Future<void> center() {
    return invokeMethod('window_center');
  }

  /// 关闭目标窗口
  Future<void> close() {
    return invokeMethod('window_close');
  }

  /// 显示目标窗口
  Future<void> show() {
    return invokeMethod('window_show');
  }

  /// 聚焦目标窗口
  Future<void> focus() {
    return invokeMethod('window_focus');
  }

  /// 隐藏目标窗口
  Future<void> hide() {
    return invokeMethod('window_hide');
  }

  /// 最小化目标窗口
  Future<void> minimize() {
    return invokeMethod('window_minimize');
  }

  /// 最大化目标窗口
  Future<void> maximize() {
    return invokeMethod('window_maximize');
  }

  /// 恢复目标窗口
  Future<void> restore() {
    return invokeMethod('window_restore');
  }

  /// 设置窗口置顶
  Future<void> setAlwaysOnTop(bool isOn) {
    return invokeMethod('window_set_always_on_top', {
      'isOn': isOn,
    });
  }
}
