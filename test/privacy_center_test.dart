import 'dart:io';

import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/gateway/privacy_center.dart';
import 'package:dsh_pet_flutter/persona/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('privacy_center_test');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  File privacyFile() =>
      File('${tmpDir.path}${Platform.pathSeparator}privacy.json');

  group('首次启动迁移', () {
    test('privacy.json 不存在时用旧 contentRead 初始化并落盘', () {
      final center = PrivacyCenter(directory: tmpDir, legacyContentRead: true);
      final result = center.load();

      expect(result, isA<Success<void>>());
      expect(center.allowed('screenAwareness'), isTrue);
      expect(privacyFile().existsSync(), isTrue);
    });

    test('contentRead=false 迁移后 screenAwareness 仍默认关', () {
      final center = PrivacyCenter(directory: tmpDir);
      center.load();

      expect(center.allowed('screenAwareness'), isFalse);
      // 其余三项默认开：只看应用名/写记忆/主动关心都不读正文。
      expect(center.allowed('appWatch'), isTrue);
      expect(center.allowed('memoryRecording'), isTrue);
      expect(center.allowed('proactiveCare'), isTrue);
    });
  });

  group('读取与更新', () {
    test('已存在的 privacy.json 优先于旧配置，不被迁移覆盖', () {
      privacyFile().writeAsStringSync('{"screenAwareness": true}');

      final center = PrivacyCenter(directory: tmpDir, legacyContentRead: false);
      center.load();

      expect(center.allowed('screenAwareness'), isTrue);
    });

    test('update 落盘后新值立即生效，重启仍保留', () {
      final center = PrivacyCenter(directory: tmpDir);
      center.load();
      final updated = center.update(
        PrivacySettings(screenAwareness: true, appWatch: false),
      );

      expect(updated, isA<Success<void>>());
      expect(center.allowed('screenAwareness'), isTrue);
      expect(center.allowed('appWatch'), isFalse);

      final reloaded = PrivacyCenter(directory: tmpDir)..load();
      expect(reloaded.allowed('screenAwareness'), isTrue);
      expect(reloaded.allowed('appWatch'), isFalse);
    });

    test('损坏的 privacy.json 返回 Failure 而不是静默用默认值', () {
      privacyFile().writeAsStringSync('not-json');

      final center = PrivacyCenter(directory: tmpDir);
      final result = center.load();

      expect(result, isA<Failure<void>>());
      expect((result as Failure<void>).code, 'profile.parse');
    });
  });

  group('未知能力拒绝', () {
    test('未登记的 capability 一律 false', () {
      final center = PrivacyCenter(directory: tmpDir)..load();
      expect(center.allowed('readAnything'), isFalse);
    });
  });
}
