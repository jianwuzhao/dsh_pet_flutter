import 'dart:typed_data';
import 'dart:ui';

import 'package:dsh_pet_flutter/features/pet/render/face.dart';
import 'package:dsh_pet_flutter/persona/appearance/appearance_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 与装扮层同款验证：渲染到真实位图比像素，能抓住画错/全透明的回归。
  Future<ByteData?> render(FaceParams face, {bool base = true}) async {
    final recorder = PictureRecorder();
    paintFace(Canvas(recorder), const Size(180, 180), face, base: base);
    final image = await recorder.endRecording().toImage(180, 180);
    return image.toByteData();
  }

  bool differs(ByteData a, ByteData b) {
    for (var i = 0; i < a.lengthInBytes; i += 4) {
      if (a.getUint8(i) != b.getUint8(i)) return true;
    }
    return false;
  }

  group('表情参数化（P2-4）', () {
    test('四态映射两两参数可区分（换表情必可见）', () {
      final faces = expressionFaces.values.toList();
      for (var i = 0; i < faces.length; i++) {
        for (var j = i + 1; j < faces.length; j++) {
          expect(faces[i], isNot(faces[j]));
        }
      }
    });

    test('插值端点还原、中点是平均', () {
      const a = FaceParams(
        eyeOpenness: 0.2,
        browAngle: -0.4,
        mouthCurve: 0.8,
        blushOpacity: 0.1,
      );
      const b = FaceParams(
        eyeOpenness: 1,
        browAngle: 0.4,
        mouthCurve: -0.6,
        blushOpacity: 0.9,
      );
      expect(lerpFaceParams(a, b, 0), a);
      expect(lerpFaceParams(a, b, 1), b);
      final mid = lerpFaceParams(a, b, 0.5);
      expect(mid.eyeOpenness, closeTo(0.6, 1e-9));
      expect(mid.browAngle, closeTo(0, 1e-9));
      expect(mid.mouthCurve, closeTo(0.1, 1e-9));
      expect(mid.blushOpacity, closeTo(0.5, 1e-9));
    });

    test('四态绘制像素两两可区分', () async {
      final images = <AppearanceExpressionSet, ByteData?>{};
      for (final entry in expressionFaces.entries) {
        images[entry.key] = await render(entry.value);
      }
      final keys = images.keys.toList();
      for (var i = 0; i < keys.length; i++) {
        for (var j = i + 1; j < keys.length; j++) {
          expect(
            differs(images[keys[i]]!, images[keys[j]]!),
            isTrue,
            reason: '${keys[i]} vs ${keys[j]}',
          );
        }
      }
    });

    test('闭眼与圆睁、笑嘴与撇嘴像素可区分', () async {
      const closed = FaceParams(
        eyeOpenness: 0,
        browAngle: 0,
        mouthCurve: 0.2,
        blushOpacity: 0,
      );
      const open = FaceParams(
        eyeOpenness: 1,
        browAngle: 0,
        mouthCurve: 0.2,
        blushOpacity: 0,
      );
      const frown = FaceParams(
        eyeOpenness: 1,
        browAngle: 0,
        mouthCurve: -0.9,
        blushOpacity: 0,
      );
      expect(differs((await render(closed))!, (await render(open))!), isTrue);
      expect(differs((await render(open))!, (await render(frown))!), isTrue);
    });

    test('空尺寸与零腮红不炸', () async {
      final recorder = PictureRecorder();
      paintFace(Canvas(recorder), Size.zero, expressionFaces.values.first);
      expect(
        recorder.endRecording().toImage(1, 1),
        completes,
      );
    });

    test('base=false 只画五官：无脸底仍画出可见像素', () async {
      final bytes = await render(expressionFaces[AppearanceExpressionSet.bright]!, base: false);
      var visible = false;
      final data = bytes!;
      for (var i = 3; i < data.lengthInBytes; i += 4) {
        if (data.getUint8(i) != 0) {
          visible = true;
          break;
        }
      }
      expect(visible, isTrue);
    });
  });
}
