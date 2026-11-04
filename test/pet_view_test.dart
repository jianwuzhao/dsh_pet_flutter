/// 装扮/配色矩阵的像素级测试：合成底稿（亮部 + 暗部）过
/// [PetView.colorMatrixFor] 渲染成位图逐字节比较——比「矩阵数值相等」
/// 强，能抓住组合顺序错误、alpha 行被装扮级吞掉等回归。
library;

import 'dart:typed_data';
import 'dart:ui';

import 'package:dsh_pet_flutter/features/pet/render/pet_view.dart';
import 'package:dsh_pet_flutter/features/pet/render/wardrobe.dart';
import 'package:dsh_pet_flutter/persona/appearance/appearance_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(resetTrendColors);
  tearDown(resetTrendColors);

  // 合成底稿：上半亮部（围裙/帽子）、下半暗部（裙摆/头发）——
  // 保明暗混色对亮暗两段的作用不同，两段都验才完整。
  Future<ByteData> render(List<double> matrix) async {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    final filter = ColorFilter.matrix(matrix);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 4, 2),
      Paint()
        ..color = const Color(0xFFF8F8F4)
        ..colorFilter = filter,
    );
    canvas.drawRect(
      const Rect.fromLTWH(0, 2, 4, 2),
      Paint()
        ..color = const Color(0xFF1A2540)
        ..colorFilter = filter,
    );
    final image = await recorder.endRecording().toImage(4, 4);
    return (await image.toByteData())!;
  }

  bool differs(ByteData a, ByteData b) {
    for (var i = 0; i < a.lengthInBytes; i += 4) {
      for (var channel = 0; channel < 4; channel++) {
        if (a.getUint8(i + channel) != b.getUint8(i + channel)) return true;
      }
    }
    return false;
  }

  test('换装有感：装扮主题色让底稿亮暗两部都变色', () async {
    final plain = await render(PetView.colorMatrixFor(
      AppearancePalette.blue,
      'home',
      1.0,
    ));
    for (final outfit in ['winter', 'rain', 'snow', 'sunny', 'christmas']) {
      final dressed = await render(
        PetView.colorMatrixFor(AppearancePalette.blue, outfit, 1.0),
      );
      expect(differs(plain, dressed), isTrue, reason: outfit);
    }
  });

  test('装扮两两可区分：同底稿不同装扮渲染结果不同', () async {
    final renders = <String, ByteData>{};
    for (final outfit in ['winter', 'rain', 'snow', 'sunny']) {
      renders[outfit] = await render(
        PetView.colorMatrixFor(AppearancePalette.blue, outfit, 1.0),
      );
    }
    final names = renders.keys.toList();
    for (var i = 0; i < names.length; i++) {
      for (var j = i + 1; j < names.length; j++) {
        expect(
          differs(renders[names[i]]!, renders[names[j]]!),
          isTrue,
          reason: '${names[i]} vs ${names[j]}',
        );
      }
    }
  });

  test('两级主题合成：配色+装扮与单开任何一级都不同', () async {
    final both = await render(PetView.colorMatrixFor(
      AppearancePalette.green,
      'rain',
      1.0,
    ));
    final paletteOnly = await render(PetView.colorMatrixFor(
      AppearancePalette.green,
      'home',
      1.0,
    ));
    final outfitOnly = await render(PetView.colorMatrixFor(
      AppearancePalette.blue,
      'rain',
      1.0,
    ));
    expect(differs(both, paletteOnly), isTrue);
    expect(differs(both, outfitOnly), isTrue);
  });

  test('装扮级不吞透明度：交叉淡入的 alpha 行不受换装影响', () {
    for (final outfit in ['home', 'rain', 'trend-未注册']) {
      final matrix = PetView.colorMatrixFor(
        AppearancePalette.green,
        outfit,
        0.4,
      );
      // alpha 行在 index 15..19：[0,0,0,alpha,0]。
      expect(matrix[15], 0.0);
      expect(matrix[16], 0.0);
      expect(matrix[17], 0.0);
      expect(matrix[18], closeTo(0.4, 1e-9));
      expect(matrix[19], 0.0);
    }
  });

  test('未注册趋势装扮 = 居家：矩阵完全一致（安全侧无感）', () {
    expect(
      PetView.colorMatrixFor(AppearancePalette.blue, 'trend-xyz', 1.0),
      PetView.colorMatrixFor(AppearancePalette.blue, 'home', 1.0),
    );
  });
}
