/// 宠物气泡：展示联动状态文案与 thinking 增量。
///
/// 只负责呈现；文本来源、显示时长、增量拼接都在 PetController / 联动层。
/// 尾巴方向由外层定位结果决定（头顶放不下时气泡翻到脚下，尾巴朝上）。
library;

import 'package:flutter/material.dart';

import '../pet/pet_controller.dart';

class BubbleWidget extends StatelessWidget {
  const BubbleWidget({super.key, required this.state, this.tailDown = true});

  final BubbleState state;

  /// true：气泡在宠物上方，尾巴朝下；false：气泡在宠物下方，尾巴朝上。
  final bool tailDown;

  static const Color _cardColor = Color(0xE61B1B20);

  @override
  Widget build(BuildContext context) {
    final card = Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x26FFFFFF)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.meme != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                state.meme!,
                width: 180,
                height: 180,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) =>
                    const SizedBox.shrink(),
              ),
            ),
            const SizedBox(height: 8),
          ],
          Text(
            state.text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              height: 1.4,
              fontFamily: 'ShangShouRuanTang',
            ),
          ),
          if (state.thinking) ...[
            const SizedBox(height: 6),
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: Colors.white70,
                  ),
                ),
                SizedBox(width: 6),
                Text(
                  '思考中…',
                  style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 11),
                ),
              ],
            ),
          ],
        ],
      ),
    );

    final tail = CustomPaint(
      size: const Size(18, 8),
      painter: _BubbleTailPainter(color: _cardColor, pointDown: tailDown),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: tailDown
          ? [
              card,
              // 尾巴与卡片同宽后再居中，避免 Column 收缩到只有尾巴宽度。
              SizedBox(width: 18, height: 8, child: Center(child: tail)),
            ]
          : [SizedBox(width: 18, height: 8, child: Center(child: tail)), card],
    );
  }
}

class _BubbleTailPainter extends CustomPainter {
  const _BubbleTailPainter({required this.color, required this.pointDown});

  final Color color;
  final bool pointDown;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = Path();
    if (pointDown) {
      path
        ..moveTo(0, 0)
        ..lineTo(size.width / 2, size.height)
        ..lineTo(size.width, 0)
        ..close();
    } else {
      path
        ..moveTo(0, size.height)
        ..lineTo(size.width / 2, 0)
        ..lineTo(size.width, size.height)
        ..close();
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _BubbleTailPainter oldDelegate) =>
      color != oldDelegate.color || pointDown != oldDelegate.pointDown;
}
