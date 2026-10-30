import 'package:dsh_pet_flutter/app/flyout_layout.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const screen = Rect.fromLTWH(0, 0, 1000, 800);
  const pet = Rect.fromLTWH(450, 500, 100, 100);

  group('PetFlyoutLayout', () {
    test('右键菜单贴边时向左上翻转，但不出屏', () {
      const layout = PetFlyoutLayout(
        screen: screen,
        pet: pet,
        anchor: Offset(850, 760),
        placement: FlyoutPlacement.pointer,
        padding: 10,
      );
      const child = Size(240, 200);
      final position = layout.getPositionForChild(screen.size, child);
      // 850+240 越界 → 翻到左侧；760+200 越界 → 翻到上方。
      expect(position, const Offset(610, 560));
    });

    test('菜单在屏幕左上角时不出现负坐标', () {
      const layout = PetFlyoutLayout(
        screen: screen,
        pet: pet,
        anchor: Offset(5, 5),
        placement: FlyoutPlacement.pointer,
        padding: 10,
      );
      final position = layout.getPositionForChild(
        screen.size,
        const Size(240, 200),
      );
      expect(position, const Offset(10, 10));
    });

    test('面板优先在宠物上方居中', () {
      const layout = PetFlyoutLayout(
        screen: screen,
        pet: pet,
        placement: FlyoutPlacement.panel,
        gap: 12,
        padding: 10,
      );
      final position = layout.getPositionForChild(
        screen.size,
        const Size(420, 200),
      );
      expect(position, const Offset(290, 288));
    });

    test('宠物贴顶时面板翻到脚下', () {
      const layout = PetFlyoutLayout(
        screen: screen,
        pet: Rect.fromLTWH(450, 20, 100, 100),
        placement: FlyoutPlacement.panel,
        gap: 12,
        padding: 10,
      );
      final position = layout.getPositionForChild(
        screen.size,
        const Size(420, 200),
      );
      expect(position, const Offset(290, 132));
    });

    test('气泡在宠物上方空间不足时被钳在屏幕内', () {
      const layout = PetFlyoutLayout(
        screen: screen,
        pet: Rect.fromLTWH(400, 100, 100, 100),
        placement: FlyoutPlacement.above,
        gap: 12,
        padding: 10,
      );
      final position = layout.getPositionForChild(
        screen.size,
        const Size(200, 120),
      );
      expect(position, const Offset(350, 10));
    });

    test('外接屏上的菜单按外接屏边界收起', () {
      const external = Rect.fromLTWH(1512, 0, 1920, 1050);
      const layout = PetFlyoutLayout(
        screen: external,
        pet: Rect.fromLTWH(3000, 850, 100, 100),
        anchor: Offset(3400, 1000),
        placement: FlyoutPlacement.pointer,
        padding: 8,
      );
      final position = layout.getPositionForChild(
        external.size,
        const Size(240, 200),
      );
      expect(position.dx, 3160);
      expect(position.dy, 800);
      expect(position.dx + 240, lessThanOrEqualTo(3424));
      expect(position.dy + 200, lessThanOrEqualTo(1042));
    });

    test('布局参数变化时要求重新布局', () {
      const a = PetFlyoutLayout(
        screen: screen,
        pet: pet,
        placement: FlyoutPlacement.panel,
      );
      const b = PetFlyoutLayout(
        screen: screen,
        pet: pet,
        placement: FlyoutPlacement.above,
      );
      expect(a.shouldRelayout(b), isTrue);
      expect(
        a.shouldRelayout(
          const PetFlyoutLayout(
            screen: screen,
            pet: pet,
            placement: FlyoutPlacement.panel,
          ),
        ),
        isFalse,
      );
    });
  });
}
