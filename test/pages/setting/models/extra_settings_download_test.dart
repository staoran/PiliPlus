import 'dart:io';

import 'package:PiliPlus/pages/setting/models/extra_settings.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_plus_test');
    Hive.init(tempDir.path);
    GStorage.setting = await Hive.openBox('setting');
  });

  tearDownAll(() async {
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'extra settings includes download task count and mobile restriction',
    () {
      final items = extraSettings;

      expect(
        items.whereType<NormalModel>().any((item) => item.title == '同时缓存任务'),
        isTrue,
      );
      expect(
        items.whereType<SwitchModel>().any(
          (item) => item.title == '禁止移动流量下载',
        ),
        isTrue,
      );
    },
  );
}
