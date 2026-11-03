/// 宠物气泡：展示联动状态文案与 thinking 增量。
///
/// 只负责呈现；文本来源、显示时长、增量拼接都在 PetController / 联动层。
/// 尾巴方向由外层定位结果决定（头顶放不下时气泡翻到脚下，尾巴朝上）。
library;

import 'package:flutter/material.dart';

import '../pet/pet_controller.dart';

class BubbleWidget extends StatelessWidget {
  const BubbleWidget({
    super.key,
    required this.state,
    this.tailDown = true,
    this.onDismiss,
    this.onOpen,
  });

  final BubbleState state;

  /// true：气泡在宠物上方，尾巴朝下；false：气泡在宠物下方，尾巴朝上。
  final bool tailDown;

  /// 主动关心的“知道了”入口；非 dismissible 气泡传 null。
  final VoidCallback? onDismiss;

  /// 气泡动作（“去看看”）入口；待确认队列触达等可点开面板的场景。
  final VoidCallback? onOpen;

  static const Color _cardColor = Color(0xE61B1B20);

  @override
  Widget build(BuildContext context) {
    final card = Container(
      constraints: const BoxConstraints(maxWidth: 260),
      // 可关闭时右侧多留 12，给右上角的关闭钮让位，不压住正文。
      padding: EdgeInsets.fromLTRB(14, 10, state.dismissible ? 26 : 14, 10),
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

    // 卡片主体永远不接收指针：桌面穿透行为与原先完全一致。
    // 只有可关闭气泡（主动关心）在卡片右上角叠一个小圆钮（22×22），
    // 命中测试先问按钮、未命中时落到被 IgnorePointer 包住的卡片 → 继续穿透。
    final content = Stack(
      children: [
        IgnorePointer(child: card),
        if (state.dismissible && onDismiss != null)
          Positioned(top: 2, right: 2, child: _DismissButton(onTap: onDismiss!)),
        if (onOpen != null)
          Positioned(
            bottom: 4,
            right: 4,
            child: _ActionButton(onTap: onOpen!),
          ),
      ],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: tailDown
          ? [
              content,
              // 尾巴与卡片同宽后再居中，避免 Column 收缩到只有尾巴宽度。
              SizedBox(width: 18, height: 8, child: Center(child: tail)),
            ]
          : [SizedBox(width: 18, height: 8, child: Center(child: tail)), content],
    );
  }
}

/// 主动关心的关闭钮：点击 = 提前关闭 = 拒绝样本（自动过期仍算中性）。
class _DismissButton extends StatelessWidget {
  const _DismissButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    behavior: HitTestBehavior.opaque,
    child: Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: const Color(0xF21B1B20),
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0x40FFFFFF)),
      ),
      child: const Icon(Icons.close, size: 12, color: Color(0xF2FFFFFF)),
    ),
  );
}

/// 气泡动作钮（“去看看”）：与关闭钮同一套命中语义——只点按钮本体，
/// 未命中区域继续桌面穿透。
class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    behavior: HitTestBehavior.opaque,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0x33FFFFFF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x40FFFFFF)),
      ),
      child: const Text(
        '去看看',
        style: TextStyle(color: Color(0xF2FFFFFF), fontSize: 11),
      ),
    ),
  );
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
