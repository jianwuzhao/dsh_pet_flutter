import 'package:dsh_pet_flutter/features/menu/pet_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('菜单展示宠物名与联动对象，点击入口回调一次', (tester) async {
    var chat = 0;
    var settings = 0;
    var quit = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF202020),
          body: Center(
            child: PetMenu(
              petName: '蓝毛小女仆',
              activeName: 'Trae CN',
              onChat: () => chat++,
              onSettings: () => settings++,
              onQuit: () => quit++,
            ),
          ),
        ),
      ),
    );

    expect(find.text('蓝毛小女仆'), findsOneWidget);
    expect(find.text('正在与 Trae CN 联动'), findsOneWidget);
    expect(find.text('和它说点什么'), findsOneWidget);
    expect(find.text('关联软件设置'), findsOneWidget);
    expect(find.text('退出桌宠'), findsOneWidget);

    await tester.tap(find.text('和它说点什么'));
    await tester.tap(find.text('关联软件设置'));
    await tester.tap(find.text('退出桌宠'));
    expect(chat, 1);
    expect(settings, 1);
    expect(quit, 1);
  });

  testWidgets('未联动时显示桌面伙伴兜底文案', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PetMenu(
          petName: '蓝毛小女仆',
          activeName: '',
          onChat: () {},
          onSettings: () {},
          onQuit: () {},
        ),
      ),
    );
    expect(find.text('桌面伙伴'), findsOneWidget);
    expect(find.text('把话发给当前关联软件'), findsOneWidget);
  });

  testWidgets('菜单提供动作/回原位/打开软件/重载配置入口', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PetMenu(
              petName: '蓝毛小女仆',
              activeName: 'Trae CN',
              onChat: () => calls.add('chat'),
              onSettings: () => calls.add('settings'),
              onQuit: () => calls.add('quit'),
              onActions: () => calls.add('actions'),
              onResetPosition: () => calls.add('reset'),
              onOpenApp: () => calls.add('open'),
              onReloadConfig: () => calls.add('reload'),
              onWhisper: () => calls.add('whisper'),
            ),
          ),
        ),
      ),
    );

    expect(find.text('让它说句话'), findsOneWidget);
    expect(find.text('动作'), findsOneWidget);
    expect(find.text('回到初始位置'), findsOneWidget);
    expect(find.text('打开 Trae CN'), findsOneWidget);
    expect(find.text('重新加载配置'), findsOneWidget);

    await tester.tap(find.text('让它说句话'));
    await tester.tap(find.text('动作'));
    await tester.tap(find.text('回到初始位置'));
    await tester.tap(find.text('打开 Trae CN'));
    await tester.tap(find.text('重新加载配置'));
    expect(calls, ['whisper', 'actions', 'reset', 'open', 'reload']);
  });
}
