import 'dart:io' show File;
import 'dart:typed_data' show Uint8List;

import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

abstract final class StorageUtils {
  static Future<void> saveBytes2File({
    required String name,
    required Uint8List bytes,
    void Function(String)? onToast,
  }) async {
    final toast = onToast ?? SmartDialog.showToast;
    try {
      final path = await FilePicker.saveFile(
        fileName: name,
        bytes: PlatformUtils.isDesktop ? Uint8List(0) : bytes,
      );
      if (path == null) {
        toast("取消保存");
        return;
      }
      if (PlatformUtils.isDesktop) {
        await File(path.toFilePath()).writeAsBytes(bytes);
      }
      toast("已保存");
    } catch (e) {
      toast("保存失败: $e");
    }
  }
}
