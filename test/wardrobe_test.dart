import 'package:dsh_pet_flutter/features/pet/render/wardrobe.dart';
import 'package:dsh_pet_flutter/persona/appearance/appearance_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('解析登记表：合法包进册，空名单与脏结构不收', () {
    final wardrobe = Wardrobe.fromJson({
      'packs': {
        'rain': {
          'names': ['待机呼吸休闲', '原地漂浮踏步'],
        },
        // 空名单：登记了也画不出任何素材，直接不收。
        'snow': {'names': []},
        'bad': 'not-a-map',
      },
    });
    expect(wardrobe.knows('rain'), isTrue);
    expect(wardrobe.knows('snow'), isFalse);
    expect(wardrobe.knows('bad'), isFalse);
    expect(wardrobe.knows('home'), isFalse);

    expect(wardrobe.has('rain', '待机呼吸休闲'), isTrue);
    // 部分包：包外动作回退默认包。
    expect(wardrobe.has('rain', '吃白饭'), isFalse);
    expect(wardrobe.has(null, '待机呼吸休闲'), isFalse);
  });

  test('结构不符按空衣橱：所有形象回退默认动画包', () {
    expect(Wardrobe.fromJson({'packs': 3}).knows('rain'), isFalse);
    expect(Wardrobe.fromJson({}).knows('rain'), isFalse);
    expect(const Wardrobe.empty().knows('rain'), isFalse);
  });

  test('选包优先级：装扮（情境）先于配色（人格）；blue 即原色不选包', () {
    final wardrobe = Wardrobe.fromJson({
      'packs': {
        'rain': {'names': ['待机呼吸休闲']},
        'green': {'names': ['待机呼吸休闲']},
      },
    });
    // 装扮与配色都有包：情境换装优先。
    expect(
      wardrobe.packVariantOf(
        const AppearanceState(
          palette: AppearancePalette.green,
          outfit: 'rain',
        ),
      ),
      'rain',
    );
    // 装扮无包、配色有包：配色兜底（人格时代的立绘）。
    expect(
      wardrobe.packVariantOf(
        const AppearanceState(
          palette: AppearancePalette.green,
          outfit: 'winter',
        ),
      ),
      'green',
    );
    // 默认居家 + blue 原色：默认动画包。
    expect(wardrobe.packVariantOf(const AppearanceState()), isNull);
    // blue 不会被选为包：素材原色不需要包。
    expect(
      wardrobe.packVariantOf(
        const AppearanceState(palette: AppearancePalette.blue, outfit: 'rain'),
      ),
      'rain',
    );
  });
}
