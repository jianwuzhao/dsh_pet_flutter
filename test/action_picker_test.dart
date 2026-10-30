import 'package:dsh_pet_flutter/core/config/animation_manifest.dart';
import 'package:dsh_pet_flutter/features/menu/action_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AnimationManifest _manifest() => AnimationManifest.fromJson({
  'width': 240,
  'height': 135,
  'fps': 12,
  'names': ['待机呼吸休闲', '吃掉', '被鼠标拖拽悬空反馈'],
  'idle': ['待机呼吸休闲'],
  'turn': <String>[],
  'drag': ['被鼠标拖拽悬空反馈'],
  'clicks': <String>[],
  'categories': [
    {
      'id': '小动作',
      'weight': 20,
      'noMirror': false,
      'actions': ['吃掉'],
    },
  ],
  'events': <String, List<String>>{},
  'weights': {'idle': 10, 'turn': 0, 'move': 0},
});

void main() {
  testWidgets('动作面板按分类展示并可点播动画', (tester) async {
    String? picked;
    var closed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF101418),
          body: Center(
            child: ActionPicker(
              manifest: _manifest(),
              onPick: (name) => picked = name,
              onClose: () => closed++,
            ),
          ),
        ),
      ),
    );

    expect(find.text('动作点播'), findsOneWidget);
    // 默认待机分类，动作名可见。
    expect(find.text('待机呼吸休闲'), findsOneWidget);

    // 切到“小动作”分类，再点播“吃掉”。
    await tester.tap(find.text('小动作'));
    await tester.pumpAndSettle();
    expect(find.text('吃掉'), findsOneWidget);
    await tester.tap(find.text('吃掉'));
    expect(picked, '吃掉');

    await tester.tap(find.byTooltip('关闭'));
    expect(closed, 1);
  });
}
