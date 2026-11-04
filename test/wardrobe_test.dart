import 'dart:typed_data';
import 'dart:ui';

import 'package:dsh_pet_flutter/features/pet/render/wardrobe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 渲染到真实位图再验像素：比「不抛异常」强，能抓住画错坐标系/全透明的回归。
  Future<ByteData?> render(String outfit) async {
    final recorder = PictureRecorder();
    paintOutfit(Canvas(recorder), const Size(240, 135), outfit);
    final image = await recorder.endRecording().toImage(240, 135);
    return image.toByteData();
  }

  bool hasVisiblePixels(ByteData data) {
    for (var i = 3; i < data.lengthInBytes; i += 4) {
      if (data.getUint8(i) != 0) return true;
    }
    return false;
  }

  test('已注册装扮画出可见图层，未知与居家装扮不画', () async {
    for (final outfit in [
      'winter',
      'newyear',
      'midautumn',
      'halloween',
      'christmas',
    ]) {
      expect(wardrobeKnows(outfit), isTrue, reason: outfit);
      expect(hasVisiblePixels((await render(outfit))!), isTrue, reason: outfit);
    }

    // home 与未注册装扮（含未来白名单扩张先于绘制器的名字）：安全侧不画。
    for (final outfit in ['home', 'spring', 'rain', 'trend-xyz']) {
      expect(wardrobeKnows(outfit), isFalse, reason: outfit);
      expect(hasVisiblePixels((await render(outfit))!), isFalse, reason: outfit);
    }
  });

  test('不同装扮的图层颜色可区分（换装可见）', () async {
    final winter = await render('winter');
    final newyear = await render('newyear');
    var differs = false;
    for (var i = 0; i < winter!.lengthInBytes; i += 4) {
      if (winter.getUint8(i) != newyear!.getUint8(i)) {
        differs = true;
        break;
      }
    }
    expect(differs, isTrue);
  });
}
