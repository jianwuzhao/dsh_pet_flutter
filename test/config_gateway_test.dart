import 'dart:io';

import 'package:dsh_pet_flutter/core/config/app_config.dart';
import 'package:dsh_pet_flutter/core/config/jsonc.dart';
import 'package:dsh_pet_flutter/core/paths/app_paths.dart';
import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/features/pet/behavior/physics.dart';
import 'package:flutter_test/flutter_test.dart';

AppConfig _base() => AppConfig(
  pets: const [],
  physics: const PhysicsParams(),
  linkage: LinkageConfig(
    active: 'trae-cn',
    adapters: const {},
    port: 7341,
    contentRead: false,
  ),
);

void main() {
  group('gateway 配置段', () {
    test('缺省时回退默认快捷键 cmd+shift+p', () {
      final config = AppConfig.fromJson({}, _base());
      expect(config.gateway.hotkey, 'cmd+shift+p');
    });

    test('用户覆盖 hotkey 会被读取并归一为小写', () {
      final config = AppConfig.fromJson({
        'gateway': {'hotkey': ' Cmd+Shift+K '},
      }, _base());
      expect(config.gateway.hotkey, 'cmd+shift+k');
    });

    test('hotkey 为空串时回退默认而不是注册一个空热键', () {
      final config = AppConfig.fromJson({
        'gateway': {'hotkey': '  '},
      }, _base());
      expect(config.gateway.hotkey, 'cmd+shift+p');
    });
  });

  group('配置保存往返', () {
    late Directory tmpRoot;

    setUp(() {
      tmpRoot = Directory.systemTemp.createTempSync('config_gateway_test');
      AppPaths.overrideRoot(tmpRoot);
    });

    tearDown(() {
      tmpRoot.deleteSync(recursive: true);
    });

    test('save 写出 gateway 段，重新解析不丢', () async {
      final config = AppConfig.fromJson({
        'gateway': {'hotkey': 'cmd+shift+space'},
      }, _base());

      final repository = ConfigRepository();
      final saved = await repository.save(config);
      expect(saved, isA<Success<void>>());

      final reread = AppConfig.fromJson(
        decodeJsonc(AppPaths.configFile.readAsStringSync())
            as Map<String, dynamic>,
        _base(),
      );
      expect(reread.gateway.hotkey, 'cmd+shift+space');
    });
  });
}
