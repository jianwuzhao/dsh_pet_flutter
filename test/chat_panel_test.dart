import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/features/chat/chat_panel.dart';
import 'package:dsh_pet_flutter/features/linkage/assistant_adapters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('内置对话回复显示在会话列表', (tester) async {
    var closed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPanel(
            activeName: '内置对话',
            onSend: (prompt) async =>
                const Success(DispatchOutcome(ok: true, reply: '你好呀，主人')),
            onClose: () => closed++,
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '在吗');
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(find.text('在吗'), findsOneWidget);
    expect(find.text('你好呀，主人'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    expect(closed, 1);
  });
}
