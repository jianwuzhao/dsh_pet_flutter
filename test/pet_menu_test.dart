import 'package:dsh_pet_flutter/core/config/animation_manifest.dart';
import 'package:dsh_pet_flutter/features/menu/pet_menu.dart';
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
  testWidgets('菜单按 dsh-pet 模式级联展开动作分类', (tester) async {
    final calls = <String>[];
    var closed = 0;
    String? played;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF202020),
          body: PetMenu(
            screen: const Rect.fromLTWH(0, 0, 800, 600),
            anchor: const Offset(40, 40),
            manifest: _manifest(),
            activeName: 'Trae CN',
            onChat: () => calls.add('chat'),
            onSettings: () => calls.add('settings'),
            onQuit: () => calls.add('quit'),
            onPlayAnimation: (name) => played = name,
            onClose: () => closed++,
            onResetPosition: () => calls.add('reset'),
            onOpenApp: () => calls.add('open'),
            onReloadConfig: () => calls.add('reload'),
            onWhisper: () => calls.add('whisper'),
          ),
        ),
      ),
    );

    // 一级：工具项 + 动作；不再有旧的卡片标题/副标题。
    expect(find.text('打开 Trae CN'), findsOneWidget);
    expect(find.text('碎碎念'), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('回到初始位置'), findsOneWidget);
    expect(find.text('重载配置'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('退出桌宠'), findsOneWidget);
    expect(find.text('动作'), findsOneWidget);

    // 二级：点「动作」展开分类。
    await tester.tap(find.text('动作'));
    await tester.pumpAndSettle();
    expect(find.text('待机'), findsOneWidget);
    expect(find.text('小动作'), findsOneWidget);

    // 三级：点分类展开具体动画；点动画回调并关闭菜单。
    await tester.tap(find.text('小动作'));
    await tester.pumpAndSettle();
    expect(find.text('吃掉'), findsOneWidget);
    await tester.tap(find.text('吃掉'));
    await tester.pumpAndSettle();
    expect(played, '吃掉');
    expect(closed, 1);
  });

  testWidgets('没有关联软件时不显示打开项，点击工具项走对应回调', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PetMenu(
            screen: const Rect.fromLTWH(0, 0, 800, 600),
            anchor: const Offset(40, 40),
            manifest: _manifest(),
            activeName: '',
            onChat: () => calls.add('chat'),
            onSettings: () => calls.add('settings'),
            onQuit: () => calls.add('quit'),
            onPlayAnimation: (_) {},
            onClose: () {},
            onResetPosition: () => calls.add('reset'),
            onReloadConfig: () => calls.add('reload'),
            onWhisper: () => calls.add('whisper'),
          ),
        ),
      ),
    );

    expect(find.textContaining('打开 '), findsNothing);
    await tester.tap(find.text('碎碎念'));
    await tester.tap(find.text('对话'));
    await tester.tap(find.text('回到初始位置'));
    await tester.tap(find.text('重载配置'));
    await tester.tap(find.text('设置'));
    await tester.tap(find.text('退出桌宠'));
    expect(calls, ['whisper', 'chat', 'reset', 'reload', 'settings', 'quit']);
  });
}
