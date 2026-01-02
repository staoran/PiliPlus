import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

/// 下载确认对话框工具类
class DownloadDialogUtils {
  /// 显示下载确认对话框，带画质选择和网络状态显示
  ///
  /// [context] - 上下文
  /// [title] - 对话框标题，默认为"确认缓存该视频？"
  /// [content] - 对话框内容，默认为"将把此视频加入离线下载队列。"
  ///
  /// 返回用户选择的画质，如果用户取消则返回 null
  static Future<VideoQuality?> showDownloadConfirmDialog(
    BuildContext context, {
    String title = '确认缓存该视频？',
    String content = '将把此视频加入离线下载队列。',
  }) async {
    VideoQuality quality = VideoQuality.fromCode(Pref.defaultVideoQa);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) {
          final theme = Theme.of(context);
          final textStyle = TextStyle(
            color: theme.colorScheme.onSurfaceVariant,
          );

          return AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(content),
                const SizedBox(height: 16),
                Row(
                  spacing: 16,
                  children: [
                    Text('最高画质', style: textStyle),
                    PopupMenuButton<VideoQuality>(
                      initialValue: quality,
                      onSelected: (value) {
                        setState(() => quality = value);
                      },
                      itemBuilder: (context) => VideoQuality.values
                          .map(
                            (e) => PopupMenuItem(
                              value: e,
                              child: Text(e.desc),
                            ),
                          )
                          .toList(),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              quality.desc,
                              style: const TextStyle(height: 1),
                              strutStyle: const StrutStyle(
                                height: 1,
                                leading: 0,
                              ),
                            ),
                            Icon(
                              size: 18,
                              Icons.keyboard_arrow_down,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                StreamBuilder(
                  stream: Connectivity().onConnectivityChanged,
                  builder: (context, snapshot) {
                    if (snapshot.data case final data?) {
                      final network = data.contains(ConnectivityResult.wifi)
                          ? 'WIFI'
                          : '数据';
                      return Text('当前网络：$network', style: textStyle);
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('确认'),
              ),
            ],
          );
        },
      ),
    );

    return confirmed == true ? quality : null;
  }
}
