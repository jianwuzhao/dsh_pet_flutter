import 'dart:io';

import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/persona/persona_dna.dart';
import 'package:dsh_pet_flutter/persona/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmpDir;
  late ProfileStore store;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('profile_store_test');
    store = ProfileStore(directory: tmpDir);
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  group('ProfileStore 读取', () {
    test('文件不存在时返回默认值', () {
      final dna = store.loadPersonaDna();
      expect(dna, isA<Success<PersonaDna>>());
      expect((dna as Success<PersonaDna>).value.name, '大肥鱼');
      expect(dna.value.bottomLines, contains('不操纵用户'));

      final privacy = store.loadPrivacy();
      expect(
        (privacy as Success<PrivacySettings>).value.screenAwareness,
        isFalse,
      );
      expect(privacy.value.appWatch, isTrue);

      final emotion = store.loadEmotionProfile();
      expect(
        (emotion as Success<EmotionProfile>).value.dailyCareLimit,
        3,
      );
    });

    test('损坏文件返回 Failure 且带路径，不静默回退', () {
      File('${tmpDir.path}/privacy.json').writeAsStringSync('{oops');
      final result = store.loadPrivacy();
      expect(result, isA<Failure<PrivacySettings>>());
      expect(
        (result as Failure<PrivacySettings>).reason,
        contains('privacy.json'),
      );
    });

    test('顶层不是对象同样报错', () {
      File('${tmpDir.path}/user_profile.json').writeAsStringSync('[1, 2]');
      expect(store.loadUserProfile(), isA<Failure<UserProfile>>());
    });
  });

  group('ProfileStore 写入', () {
    test('保存后可读回，且不留 .tmp 残留（原子写）', () {
      final dna = const PersonaDna(
        name: '小蓝',
        address: '老板',
        proactiveness: 0.8,
      );
      final saved = store.savePersonaDna(dna);
      expect(saved, isA<Success<void>>());

      final loaded = store.loadPersonaDna() as Success<PersonaDna>;
      expect(loaded.value.name, '小蓝');
      expect(loaded.value.address, '老板');
      expect(loaded.value.proactiveness, 0.8);

      expect(
        Directory(tmpDir.path).listSync().whereType<File>().map((f) => f.path),
        everyElement(isNot(endsWith('.tmp'))),
      );
    });

    test('四份档案互不影响', () {
      store
        ..saveUserProfile(
          const UserProfile(routine: '早八晚十二', taboos: ['熬夜']),
        )
        ..saveEmotionProfile(
          const EmotionProfile(quietStart: '23:30', careEnabled: false),
        );

      final user = store.loadUserProfile() as Success<UserProfile>;
      expect(user.value.routine, '早八晚十二');
      expect(user.value.taboos, ['熬夜']);

      final emotion = store.loadEmotionProfile() as Success<EmotionProfile>;
      expect(emotion.value.quietStart, '23:30');
      expect(emotion.value.careEnabled, isFalse);
      // 未指定字段走模型默认，而不是被清空语义污染。
      expect(emotion.value.dailyCareLimit, 3);
    });
  });
}
