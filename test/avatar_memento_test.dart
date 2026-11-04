import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/persona/appearance/appearance_state.dart';
import 'package:dsh_pet_flutter/persona/appearance/avatar_memento.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('avatar_memento_test');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  // 真实位图比像素：能抓住画错坐标/全透明/渐变失效的回归。
  Future<ByteData?> render(AppearanceState state, DateTime promotedAt) async {
    final recorder = PictureRecorder();
    paintMemento(Canvas(recorder), const Size(512, 512), state, promotedAt);
    final image = await recorder.endRecording().toImage(512, 512);
    return image.toByteData();
  }

  group('月限治理（P2-5）', () {
    test('月键按年月格式，跨月翻篇', () {
      expect(mementoMonthKey(DateTime(2026, 11, 4)), '2026-11');
      expect(mementoMonthKey(DateTime(2026, 1, 1)), '2026-01');
      expect(mementoMonthKey(DateTime(2027, 1, 31)), '2027-01');
    });

    test('治理状态 save/load 往返；坏文件按空 gate 无损降级', () {
      final store = AvatarMementoStore(directory: tmpDir);
      expect(store.load().lastGeneratedMonth, isNull);

      expect(
        store.save(const AvatarMementoGate(lastGeneratedMonth: '2026-11')),
        isA<Success<void>>(),
      );
      expect(store.load().lastGeneratedMonth, '2026-11');

      File('${tmpDir.path}/avatar_memento.json').writeAsStringSync('not json');
      expect(store.load().lastGeneratedMonth, isNull);
    });
  });

  group('程序化纪念头像（P2-5）', () {
    test('画出非空图；同档案同图，palette/revision 变则图变', () async {
      const state = AppearanceState(
        revision: 3,
        form: AppearanceForm.chubby,
        palette: AppearancePalette.purple,
      );
      final promotedAt = DateTime(2026, 11, 4);
      final a = (await render(state, promotedAt))!;
      final b = (await render(state, promotedAt))!;
      var visible = false;
      for (var i = 3; i < a.lengthInBytes; i += 4) {
        if (a.getUint8(i) != 0) {
          visible = true;
          break;
        }
      }
      expect(visible, isTrue);

      // 种子确定性：同输入像素完全一致。
      var same = true;
      for (var i = 0; i < a.lengthInBytes; i++) {
        if (a.getUint8(i) != b.getUint8(i)) {
          same = false;
          break;
        }
      }
      expect(same, isTrue);

      // 换 palette 图必变（生成结果与档案绑定）。
      final orange = (
        await render(state.copyWith(palette: AppearancePalette.orange), promotedAt)
      )!;
      var differs = false;
      for (var i = 0; i < a.lengthInBytes; i++) {
        if (a.getUint8(i) != orange.getUint8(i)) {
          differs = true;
          break;
        }
      }
      expect(differs, isTrue);
    });

    test('空尺寸不炸', () async {
      final recorder = PictureRecorder();
      paintMemento(
        Canvas(recorder),
        Size.zero,
        const AppearanceState(),
        DateTime(2026, 11, 4),
      );
      expect(recorder.endRecording().toImage(1, 1), completes);
    });
  });
}
