import 'package:dsh_pet_flutter/features/pet/render/wardrobe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('有配色的装扮可识别：冬/节令/天气；居家与春夏秋默认形态不识别', () {
    for (final outfit in [
      'winter',
      'newyear',
      'midautumn',
      'halloween',
      'christmas',
      // 天气装扮（P2-3a）：rain/snow/sunny 三态都有配色。
      'rain',
      'snow',
      'sunny',
    ]) {
      expect(wardrobeKnows(outfit), isTrue, reason: outfit);
      expect(outfitTintOf(outfit), isNotNull, reason: outfit);
    }

    // home/春夏秋与未注册装扮（含未来配色表扩张之前的名字）：安全侧
    // 无配色，底稿保持原样。
    for (final outfit in ['home', 'spring', 'summer', 'autumn', 'trend-xyz']) {
      expect(wardrobeKnows(outfit), isFalse, reason: outfit);
      expect(outfitTintOf(outfit), isNull, reason: outfit);
    }
  });

  test('装扮主题色两两可区分（换装可见的前提）', () {
    final outfits = [
      'winter',
      'newyear',
      'midautumn',
      'halloween',
      'christmas',
      'rain',
      'snow',
      'sunny',
    ];
    final tints = [for (final outfit in outfits) outfitTintOf(outfit)!];
    // 像素输出由主题色唯一决定：色值撞车 = 换装后画面不变。
    expect(tints.toSet().length, tints.length);
  });

  group('趋势装扮动态注册（P2-3b）', () {
    setUp(resetTrendColors);
    tearDown(resetTrendColors);

    test('注册前无配色；注册后按提案主色，重复注册幂等', () {
      expect(wardrobeKnows('trend-冬日暖阳'), isFalse);
      expect(outfitTintOf('trend-冬日暖阳'), isNull);

      registerTrendColors('trend-冬日暖阳', 0xFFE23E3E, 0xFFF2C14E);
      expect(wardrobeKnows('trend-冬日暖阳'), isTrue);
      // 主色作主题色（trim 暂留注册表，接素材帧后启用）。
      expect(outfitTintOf('trend-冬日暖阳')!.toARGB32(), 0xFFE23E3E);

      // 同主题重复注册（同周内重复提案场景）：幂等覆盖不炸。
      registerTrendColors('trend-冬日暖阳', 0xFFE23E3E, 0xFFF2C14E);
      expect(wardrobeKnows('trend-冬日暖阳'), isTrue);
    });

    test('同装扮名不同配色可区分；换色即换主题色', () {
      registerTrendColors('trend-星夜', 0xFF6A3FA0, 0xFFF2C14E);
      registerTrendColors('trend-薄荷', 0xFF4DB6AC, 0xFF212121);
      expect(outfitTintOf('trend-星夜'), isNot(outfitTintOf('trend-薄荷')));

      // 主题更新配色：注册表覆盖，主题色跟着换。
      registerTrendColors('trend-星夜', 0xFF1B2A49, 0xFFF2C14E);
      expect(outfitTintOf('trend-星夜')!.toARGB32(), 0xFF1B2A49);
    });
  });
}
