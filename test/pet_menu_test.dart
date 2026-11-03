import 'package:dsh_pet_flutter/core/config/animation_manifest.dart';
import 'package:dsh_pet_flutter/features/menu/pet_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const Rect _screen = Rect.fromLTWH(0, 0, 800, 600);
const Rect _pet = Rect.fromLTWH(30, 40, 120, 68);

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

Widget _menu({
  Offset anchor = const Offset(40, 40),
  String activeName = 'Trae CN',
  VoidCallback? onOpenApp,
  VoidCallback? onWhisper,
  VoidCallback? onResetPosition,
  VoidCallback? onReloadConfig,
  VoidCallback? onChat,
  VoidCallback? onSettings,
  VoidCallback? onQuit,
  ValueChanged<String>? onPlayAnimation,
  VoidCallback? onClose,
}) {
  return MaterialApp(
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(
      body: PetMenu(
        screen: _screen,
        pet: _pet,
        anchor: anchor,
        manifest: _manifest(),
        activeName: activeName,
        onChat: onChat ?? () {},
        onSettings: onSettings ?? () {},
        onQuit: onQuit ?? () {},
        onPlayAnimation: onPlayAnimation ?? (_) {},
        onClose: onClose ?? () {},
        onResetPosition: onResetPosition,
        onOpenApp: onOpenApp,
        onReloadConfig: onReloadConfig,
        onWhisper: onWhisper,
      ),
    ),
  );
}

void main() {
  testWidgets('根视图只保留高频入口，低频项收进更多', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      _menu(
        onOpenApp: () => calls.add('open'),
        onWhisper: () => calls.add('whisper'),
        onChat: () => calls.add('chat'),
        onSettings: () => calls.add('settings'),
        onQuit: () => calls.add('quit'),
        onResetPosition: () => calls.add('reset'),
        onReloadConfig: () => calls.add('reload'),
      ),
    );

    expect(find.text('对话'), findsOneWidget);
    expect(find.text('碎碎念'), findsOneWidget);
    expect(find.text('打开 Trae CN'), findsOneWidget);
    expect(find.text('动作'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('更多'), findsOneWidget);
    expect(find.text('退出大肥鱼助手'), findsOneWidget);
    // 低频维护项不再占主菜单。
    expect(find.text('重载配置'), findsNothing);
    expect(find.text('回到初始位置'), findsNothing);

    await tester.tap(find.text('对话'));
    await tester.tap(find.text('碎碎念'));
    await tester.tap(find.text('打开 Trae CN'));
    await tester.tap(find.text('设置'));
    await tester.tap(find.text('退出大肥鱼助手'));
    expect(calls, ['chat', 'whisper', 'open', 'settings', 'quit']);
  });

  testWidgets('没有 AI / 没有关联软件时隐藏对应入口', (tester) async {
    await tester.pumpWidget(_menu(activeName: ''));

    expect(find.text('碎碎念'), findsNothing);
    expect(find.textContaining('打开 '), findsNothing);
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('更多视图收纳回到初始位置与重载配置', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      _menu(
        onResetPosition: () => calls.add('reset'),
        onReloadConfig: () => calls.add('reload'),
      ),
    );

    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    expect(find.text('回到初始位置'), findsOneWidget);
    expect(find.text('重载配置'), findsOneWidget);
    expect(find.text('动作'), findsNothing);

    await tester.tap(find.text('回到初始位置'));
    await tester.pumpAndSettle();
    expect(calls, ['reset']);

    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(find.text('更多'), findsOneWidget);
  });

  testWidgets('动作视图按分类分组，点动画名即播放并关闭', (tester) async {
    final played = <String>[];
    var closed = 0;
    await tester.pumpWidget(
      _menu(onPlayAnimation: played.add, onClose: () => closed++),
    );

    await tester.tap(find.text('动作'));
    await tester.pumpAndSettle();
    expect(find.text('待机'), findsOneWidget);
    expect(find.text('拖拽'), findsOneWidget);
    expect(find.text('小动作'), findsOneWidget);
    expect(find.text('待机呼吸休闲'), findsOneWidget);
    expect(find.text('被鼠标拖拽悬空反馈'), findsOneWidget);
    expect(find.text('吃掉'), findsOneWidget);

    await tester.tap(find.text('吃掉'));
    await tester.pumpAndSettle();
    expect(played, ['吃掉']);
    expect(closed, 1);

    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(find.text('动作'), findsOneWidget);
  });

  testWidgets('Esc 可关闭菜单', (tester) async {
    var closed = 0;
    await tester.pumpWidget(_menu(onClose: () => closed++));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 1);
  });

  testWidgets('贴近屏幕右下时翻转到屏幕内', (tester) async {
    await tester.pumpWidget(_menu(anchor: const Offset(780, 580)));
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.byKey(const ValueKey('pet-menu-panel')));
    expect(panel.left, greaterThanOrEqualTo(_screen.left + 6));
    expect(panel.top, greaterThanOrEqualTo(_screen.top + 6));
    expect(panel.right, lessThanOrEqualTo(_screen.right - 6));
    expect(panel.bottom, lessThanOrEqualTo(_screen.bottom - 6));
  });
}
