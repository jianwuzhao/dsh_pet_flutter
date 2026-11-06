import 'package:dsh_pet_flutter/features/bubble/bubble_widget.dart';
import 'package:dsh_pet_flutter/features/pet/pet_controller.dart';
import 'package:dsh_pet_flutter/features/pet/render/face.dart';
import 'package:dsh_pet_flutter/persona/appearance/appearance_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('普通气泡不渲染关闭钮（保持纯展示/穿透）', (tester) async {
    await tester.pumpWidget(
      host(
        const BubbleWidget(
          state: BubbleState(text: '普通气泡'),
        ),
      ),
    );

    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('可关闭气泡渲染“知道了”小圆钮，点击触发回调', (tester) async {
    var dismissed = 0;
    await tester.pumpWidget(
      host(
        BubbleWidget(
          state: const BubbleState(text: '看你有点低落，要不要先休息一下？', dismissible: true),
          onDismiss: () => dismissed++,
        ),
      ),
    );

    expect(find.byIcon(Icons.close), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    expect(dismissed, 1);
  });

  testWidgets('dismissible 但没有回调时不渲染按钮（宿主未接线）', (tester) async {
    await tester.pumpWidget(
      host(
        const BubbleWidget(
          state: BubbleState(text: '关心', dismissible: true),
        ),
      ),
    );

    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('P2-4 参数化表情配图：四态可切换', (tester) async {
    CustomPaint? facePaintOf() => tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.painter != null &&
            widget.painter!.runtimeType.toString() == '_FacePainter',
      ),
    );

    await tester.pumpWidget(
      host(
        const BubbleWidget(
          state: BubbleState(
            text: '碎碎念',
            expression: AppearanceExpressionSet.bright,
          ),
        ),
      ),
    );
    expect(find.byType(Image), findsNothing);
    expect(
      (facePaintOf()!.painter as dynamic).face,
      expressionFaces[AppearanceExpressionSet.bright],
    );

    // 切换表情集：气泡配图参数跟着换。
    await tester.pumpWidget(
      host(
        const BubbleWidget(
          state: BubbleState(
            text: '碎碎念',
            expression: AppearanceExpressionSet.shy,
          ),
        ),
      ),
    );
    expect(
      (facePaintOf()!.painter as dynamic).face,
      expressionFaces[AppearanceExpressionSet.shy],
    );
  });
}
