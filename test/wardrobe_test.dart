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
      // 天气装扮（P2-3a）：rain/snow/sunny 三态都有图层。
      'rain',
      'snow',
      'sunny',
    ]) {
      expect(wardrobeKnows(outfit), isTrue, reason: outfit);
      expect(hasVisiblePixels((await render(outfit))!), isTrue, reason: outfit);
    }

    // home 与未注册装扮（含未来白名单扩张先于绘制器的名字）：安全侧不画。
    for (final outfit in ['home', 'spring', 'trend-xyz']) {
      expect(wardrobeKnows(outfit), isFalse, reason: outfit);
      expect(hasVisiblePixels((await render(outfit))!), isFalse, reason: outfit);
    }
  });

  test('天气装扮与季节装扮像素可区分（雨天换装有感）', () async {
    final winter = (await render('winter'))!;
    final rain = (await render('rain'))!;
    final snow = (await render('snow'))!;
    final sunny = (await render('sunny'))!;
    bool anyDiffers(ByteData a, ByteData b) {
      for (var i = 0; i < a.lengthInBytes; i += 4) {
        if (a.getUint8(i) != b.getUint8(i)) return true;
      }
      return false;
    }

    // rain 与默认冬装（同为冬天可能同时在衣柜）必须可区分；
    // 雪装主色冰蓝、晴日装主色向日葵黄，与雨装两两可区分。
    expect(anyDiffers(winter, rain), isTrue);
    expect(anyDiffers(snow, rain), isTrue);
    expect(anyDiffers(sunny, rain), isTrue);
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

  group('趋势装扮动态注册（P2-3b）', () {
    setUp(resetTrendColors);
    tearDown(resetTrendColors);

    test('注册前不画；注册后按提案配色画，重复注册幂等', () async {
      expect(wardrobeKnows('trend-冬日暖阳'), isFalse);
      expect(hasVisiblePixels((await render('trend-冬日暖阳'))!), isFalse);

      registerTrendColors('trend-冬日暖阳', 0xFFE23E3E, 0xFFF2C14E);
      expect(wardrobeKnows('trend-冬日暖阳'), isTrue);
      expect(hasVisiblePixels((await render('trend-冬日暖阳'))!), isTrue);

      // 同主题重复注册（同周内重复提案场景）：幂等覆盖不炸。
      registerTrendColors('trend-冬日暖阳', 0xFFE23E3E, 0xFFF2C14E);
      expect(wardrobeKnows('trend-冬日暖阳'), isTrue);
    });

    test('同形状不同配色：两个趋势装扮像素可区分', () async {
      registerTrendColors('trend-星夜', 0xFF6A3FA0, 0xFFF2C14E);
      registerTrendColors('trend-薄荷', 0xFF4DB6AC, 0xFF212121);
      final night = await render('trend-星夜');
      final mint = await render('trend-薄荷');
      var differs = false;
      for (var i = 0; i < night!.lengthInBytes; i += 4) {
        if (night.getUint8(i) != mint!.getUint8(i)) {
          differs = true;
          break;
        }
      }
      expect(differs, isTrue);
    });
  });
}
