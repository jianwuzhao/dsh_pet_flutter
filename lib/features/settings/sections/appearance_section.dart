/// 形象分区：参数化预览 + 推演 / 回滚 / 冻结。
///
/// 预览是程序化绘制（不依赖外部图像生成）：形态、体型缩放、配色、配饰、
/// 表情集直接映射到画布参数，用来验证「推演结果真的看得见」。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../persona/appearance/appearance_proposal.dart';
import '../../../persona/appearance/appearance_state.dart';
import '../../../persona/appearance/trend_outfit.dart';
import '../../../persona/appearance/weather_outfit.dart';
import 'settings_controls.dart';

class AppearanceSection extends StatelessWidget {
  const AppearanceSection({
    super.key,
    required this.state,
    required this.reason,
    required this.hint,
    required this.onEvolve,
    required this.onRollback,
    required this.onFreeze,
    this.proposal,
    this.onAcceptProposal,
    this.onRejectProposal,
    this.weatherSource = AppearanceWeatherSource.off,
    this.weatherSuggestion,
    this.onWeatherSourceChanged,
    this.onAcceptWeatherOutfit,
    this.onDismissWeatherOutfit,
    this.trendSource = AppearanceTrendSource.off,
    this.trendSuggestion,
    this.onTrendSourceChanged,
    this.onAcceptTrendOutfit,
    this.onRejectTrendOutfit,
  });

  final AppearanceState state;

  /// 待确认的形态提案；最显眼的变化不自动应用。
  final AppearanceProposal? proposal;
  final VoidCallback? onAcceptProposal;
  final VoidCallback? onRejectProposal;

  /// 最近一次推演的可读理由（内核生成，这里只展示）。
  final String reason;

  /// 操作结果提示（保存失败、没有历史等）。
  final String hint;

  final VoidCallback? onEvolve;
  final VoidCallback? onRollback;
  final ValueChanged<bool>? onFreeze;

  /// 天气装扮源（P2-3）：默认 off，开启后内核才允许发天气请求。
  final AppearanceWeatherSource weatherSource;

  /// 当日换装建议；只在当天有效（内核不持久化），null = 不渲染建议卡片。
  final ValueListenable<WeatherOutfitSuggestion?>? weatherSuggestion;

  final ValueChanged<AppearanceWeatherSource>? onWeatherSourceChanged;
  final VoidCallback? onAcceptWeatherOutfit;
  final VoidCallback? onDismissWeatherOutfit;

  /// 热门趋势装扮源（P2-3b）：默认 off，开启后每周至多 1 次 LLM 提案。
  final AppearanceTrendSource trendSource;

  /// 本周待确认的提案；治理状态（周限/冷却）在内核，这里只展示。
  final ValueListenable<TrendOutfitProposal?>? trendSuggestion;

  final ValueChanged<AppearanceTrendSource>? onTrendSourceChanged;
  final VoidCallback? onAcceptTrendOutfit;
  final VoidCallback? onRejectTrendOutfit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 168,
              height: 118,
              decoration: BoxDecoration(
                color: const Color(0x14FFFFFF),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x1FFFFFFF)),
              ),
              child: AppearancePreview(state: state),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _param('形态', _formName(state.form)),
                  _param('体型缩放', state.bodyScale.toStringAsFixed(2)),
                  _param('配色', _paletteName(state.palette)),
                  _param('配饰', _accessoryName(state.accessory)),
                  _param('动作组', _motionName(state.motionSet)),
                  _param('表情集', _expressionName(state.expressionSet)),
                  _param(
                    '修订',
                    'v${state.revision}${state.frozen ? ' · 已冻结' : ''}',
                  ),
                ],
              ),
            ),
          ],
        ),
        if (proposal != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0x14FFD166),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0x33FFD166)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '形态提案：${_formName(state.form)} → ${_formName(proposal!.targetForm)}',
                  style: const TextStyle(
                    color: Color(0xE6FFD166),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  proposal!.reason,
                  style: const TextStyle(
                    color: Color(0xB3FFFFFF),
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    OutlinedButton(
                      onPressed: onAcceptProposal,
                      child: const Text('接受'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: onRejectProposal,
                      child: const Text('拒绝'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        // 天气装扮（P2-3）：提案制——先建议、你确认才换，不自动改形象。
        if (onWeatherSourceChanged != null)
          SettingsSwitch(
            title: '天气装扮',
            subtitle: '开启后每天最多 2 次免费天气查询，换装建议由你确认',
            value: weatherSource != AppearanceWeatherSource.off,
            onChanged: (value) => onWeatherSourceChanged!(
              value
                  ? AppearanceWeatherSource.builtin
                  : AppearanceWeatherSource.off,
            ),
          ),
        if (weatherSuggestion != null)
          ValueListenableBuilder<WeatherOutfitSuggestion?>(
            valueListenable: weatherSuggestion!,
            builder: (context, suggestion, _) {
              if (suggestion == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0x14FFB74D),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0x33FFB74D)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        suggestion.reason,
                        style: const TextStyle(
                          color: Color(0xE6FFB74D),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          OutlinedButton(
                            onPressed: onAcceptWeatherOutfit,
                            child: const Text('穿上'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: onDismissWeatherOutfit,
                            child: const Text('忽略'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        // 热门趋势装扮（P2-3b）：同为提案制，但频控更严（每周 1 次、拒绝冷却 7 天）。
        if (onTrendSourceChanged != null)
          SettingsSwitch(
            title: '热门趋势装扮',
            subtitle: '开启后每周至多 1 次创意提案（主题+配色），素材仍用本地装扮，由你确认',
            value: trendSource != AppearanceTrendSource.off,
            onChanged: (value) => onTrendSourceChanged!(
              value ? AppearanceTrendSource.builtin : AppearanceTrendSource.off,
            ),
          ),
        if (trendSuggestion != null)
          ValueListenableBuilder<TrendOutfitProposal?>(
            valueListenable: trendSuggestion!,
            builder: (context, proposal, _) {
              if (proposal == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0x14CE93D8),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0x33CE93D8)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '本周提案：${proposal.theme}',
                            style: const TextStyle(
                              color: Color(0xE6CE93D8),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 主题双色直接画出来：配色是提案的一半信息。
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: Color(proposal.main),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: Color(proposal.trim),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        proposal.reason,
                        style: const TextStyle(
                          color: Color(0xB3FFFFFF),
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          OutlinedButton(
                            onPressed: onAcceptTrendOutfit,
                            child: const Text('穿上'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: onRejectTrendOutfit,
                            child: const Text('拒绝'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        const SizedBox(height: 12),
        Text(
          reason.isEmpty ? '还没有推演过，形象保持初始参数' : '上次推演：$reason',
          style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 11.5),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(onPressed: onEvolve, child: const Text('推演一次')),
            OutlinedButton(onPressed: onRollback, child: const Text('回滚上一版')),
            OutlinedButton(
              onPressed: onFreeze == null
                  ? null
                  : () => onFreeze!(!state.frozen),
              child: Text(state.frozen ? '解冻' : '冻结'),
            ),
          ],
        ),
        if (hint.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            hint,
            style: const TextStyle(color: Color(0xCCFFB4A2), fontSize: 11),
          ),
        ],
        const SizedBox(height: 8),
        const Text(
          '推演只由情绪三维、人格主动性与 24 小时内的接受/拒绝反馈驱动：'
          '至少间隔 12 小时、一次只改一个维度、信号不足就不动；'
          '配色、体型、动作组、配饰与表情集都会作用到宠物本体；'
          '形态（form）目前只影响预览/头像，不改变动画素材；'
          '形态提案由你决定是否接受；每一次变化都会写进历史并可回滚，冻结后完全暂停。',
          style: TextStyle(color: Color(0x66FFFFFF), fontSize: 10.5),
        ),
      ],
    );
  }

  Widget _param(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 3),
    child: Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: const TextStyle(color: Color(0x80FFFFFF), fontSize: 11),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(color: Color(0xE6FFFFFF), fontSize: 11.5),
          ),
        ),
      ],
    ),
  );

  static String _formName(AppearanceForm form) => switch (form) {
    AppearanceForm.slim => '瘦长',
    AppearanceForm.round => '圆润',
    AppearanceForm.chubby => '敦实',
    AppearanceForm.tall => '高挑',
  };

  static String _paletteName(AppearancePalette palette) => switch (palette) {
    AppearancePalette.blue => '海蓝',
    AppearancePalette.green => '青绿',
    AppearancePalette.orange => '暖橙',
    AppearancePalette.purple => '暮紫',
    AppearancePalette.gray => '雾灰',
  };

  static String _accessoryName(AppearanceAccessory accessory) =>
      switch (accessory) {
        AppearanceAccessory.none => '无',
        AppearanceAccessory.scarf => '围巾',
        AppearanceAccessory.glasses => '眼镜',
        AppearanceAccessory.hat => '帽子',
      };

  static String _motionName(AppearanceMotionSet motion) => switch (motion) {
    AppearanceMotionSet.lively => '活泼',
    AppearanceMotionSet.playful => '俏皮',
    AppearanceMotionSet.calm => '安静',
    AppearanceMotionSet.sleepy => '困倦',
  };

  static String _expressionName(AppearanceExpressionSet expression) =>
      switch (expression) {
        AppearanceExpressionSet.soft => '柔和',
        AppearanceExpressionSet.bright => '明亮',
        AppearanceExpressionSet.cool => '冷静',
        AppearanceExpressionSet.shy => '害羞',
      };
}

/// 参数化形象预览：纯 Canvas 绘制，尺寸自适应父容器。
class AppearancePreview extends StatelessWidget {
  const AppearancePreview({super.key, required this.state});

  final AppearanceState state;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _AppearancePainter(state),
    child: const SizedBox.expand(),
  );
}

class _AppearancePainter extends CustomPainter {
  _AppearancePainter(this.state);

  final AppearanceState state;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = state.bodyScale;
    final form = _formFactor(state.form);
    final bodyW = size.width * 0.52 * form.$1 * scale;
    final bodyH = size.height * 0.44 * form.$2 * scale;
    final cx = size.width * 0.55;
    final cy = size.height * 0.52;
    final body = _bodyColor(state.palette);
    final belly = _bellyColor(state.palette);

    _paintFrame(canvas, size);
    _paintTail(canvas, cx, cy, bodyW, bodyH, body);
    _paintFin(canvas, cx, cy, bodyW, bodyH, body);
    _paintBody(canvas, cx, cy, bodyW, bodyH, body, belly);
    _paintFace(canvas, cx, cy, bodyW, bodyH);
    _paintAccessory(canvas, cx, cy, bodyW, bodyH);
  }

  void _paintFrame(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x1AFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(6, 6, size.width - 12, size.height - 12),
        const Radius.circular(10),
      ),
      paint,
    );
  }

  void _paintTail(
    Canvas canvas,
    double cx,
    double cy,
    double bodyW,
    double bodyH,
    Color body,
  ) {
    final left = cx - bodyW / 2;
    final tail = Path()
      ..moveTo(left + 2, cy)
      ..lineTo(left - bodyW * 0.26, cy - bodyH * 0.38)
      ..lineTo(left - bodyW * 0.26, cy + bodyH * 0.38)
      ..close();
    canvas.drawPath(
      tail,
      Paint()..color = Color.lerp(body, Colors.black, 0.16)!,
    );
  }

  void _paintFin(
    Canvas canvas,
    double cx,
    double cy,
    double bodyW,
    double bodyH,
    Color body,
  ) {
    final fin = Path()
      ..moveTo(cx - bodyW * 0.12, cy - bodyH * 0.46)
      ..quadraticBezierTo(
        cx + bodyW * 0.02,
        cy - bodyH * 0.78,
        cx + bodyW * 0.2,
        cy - bodyH * 0.42,
      )
      ..close();
    canvas.drawPath(
      fin,
      Paint()..color = Color.lerp(body, Colors.white, 0.12)!,
    );
  }

  void _paintBody(
    Canvas canvas,
    double cx,
    double cy,
    double bodyW,
    double bodyH,
    Color body,
    Color belly,
  ) {
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy), width: bodyW, height: bodyH),
      Paint()..color = body,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx + bodyW * 0.02, cy + bodyH * 0.1),
        width: bodyW * 0.78,
        height: bodyH * 0.58,
      ),
      Paint()..color = belly,
    );
  }

  void _paintFace(
    Canvas canvas,
    double cx,
    double cy,
    double bodyW,
    double bodyH,
  ) {
    final eye = Offset(cx + bodyW * 0.26, cy - bodyH * 0.08);
    final eyeRadius = switch (state.expressionSet) {
      AppearanceExpressionSet.bright => 4.8,
      AppearanceExpressionSet.cool => 2.6,
      _ => 3.6,
    };
    final mouthY = cy + bodyH * 0.2;
    final mouthPaint = Paint()
      ..color = const Color(0xFF2A3442)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;

    if (state.expressionSet == AppearanceExpressionSet.cool) {
      // 冷静：眯眼横线 + 平嘴。
      canvas.drawLine(
        Offset(eye.dx - 5, eye.dy),
        Offset(eye.dx + 5, eye.dy),
        mouthPaint,
      );
      canvas.drawLine(
        Offset(cx + bodyW * 0.18, mouthY),
        Offset(cx + bodyW * 0.34, mouthY),
        mouthPaint,
      );
    } else {
      canvas.drawCircle(
        eye,
        eyeRadius,
        Paint()..color = const Color(0xFF1F2937),
      );
      canvas.drawCircle(
        Offset(eye.dx - eyeRadius * 0.34, eye.dy - eyeRadius * 0.34),
        eyeRadius * 0.36,
        Paint()..color = const Color(0xE6FFFFFF),
      );
      final smile = (state.expressionSet == AppearanceExpressionSet.bright);
      canvas.drawArc(
        Rect.fromCenter(
          center: Offset(cx + bodyW * 0.26, mouthY),
          width: bodyW * (smile ? 0.2 : 0.14),
          height: bodyH * (smile ? 0.16 : 0.11),
        ),
        math.pi * 0.14,
        math.pi * 0.72,
        false,
        mouthPaint,
      );
    }

    if (state.expressionSet == AppearanceExpressionSet.shy) {
      // 害羞：脸颊两团淡粉。
      final blush = Paint()..color = const Color(0x66FF7B8A);
      canvas.drawCircle(
        Offset(cx + bodyW * 0.1, cy + bodyH * 0.09),
        4.2,
        blush,
      );
      canvas.drawCircle(
        Offset(cx + bodyW * 0.38, cy + bodyH * 0.12),
        3.2,
        blush,
      );
    }
  }

  void _paintAccessory(
    Canvas canvas,
    double cx,
    double cy,
    double bodyW,
    double bodyH,
  ) {
    switch (state.accessory) {
      case AppearanceAccessory.none:
        return;
      case AppearanceAccessory.scarf:
        final scarf = Paint()..color = const Color(0xFFE05A5A);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(cx, cy + bodyH * 0.3),
              width: bodyW * 0.62,
              height: bodyH * 0.16,
            ),
            const Radius.circular(5),
          ),
          scarf,
        );
        canvas.drawCircle(
          Offset(cx + bodyW * 0.2, cy + bodyH * 0.38),
          3.4,
          scarf,
        );
      case AppearanceAccessory.glasses:
        final rim = Paint()
          ..color = const Color(0xFF3B4A5F)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6;
        canvas.drawCircle(
          Offset(cx + bodyW * 0.26, cy - bodyH * 0.08),
          7.4,
          rim,
        );
        canvas.drawLine(
          Offset(cx + bodyW * 0.26 - 7.4, cy - bodyH * 0.08),
          Offset(cx + bodyW * 0.26 - 15, cy - bodyH * 0.2),
          rim,
        );
      case AppearanceAccessory.hat:
        final hat = Paint()..color = const Color(0xFF4E6E8E);
        canvas.drawRect(
          Rect.fromCenter(
            center: Offset(cx + bodyW * 0.02, cy - bodyH * 0.36),
            width: bodyW * 0.28,
            height: bodyH * 0.16,
          ),
          hat,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(cx + bodyW * 0.02, cy - bodyH * 0.28),
              width: bodyW * 0.38,
              height: 3.6,
            ),
            const Radius.circular(2),
          ),
          hat,
        );
    }
  }

  /// 形态 →（宽度系数, 高度系数）。
  static (double, double) _formFactor(AppearanceForm form) => switch (form) {
    AppearanceForm.slim => (1.16, 0.74),
    AppearanceForm.round => (1.0, 1.0),
    AppearanceForm.chubby => (1.05, 1.16),
    AppearanceForm.tall => (0.78, 1.3),
  };

  static Color _bodyColor(AppearancePalette palette) => switch (palette) {
    AppearancePalette.blue => const Color(0xFF4C8DF5),
    AppearancePalette.green => const Color(0xFF46C08A),
    AppearancePalette.orange => const Color(0xFFF59A4C),
    AppearancePalette.purple => const Color(0xFF9A7CF2),
    AppearancePalette.gray => const Color(0xFF9AA4B2),
  };

  static Color _bellyColor(AppearancePalette palette) => switch (palette) {
    AppearancePalette.blue => const Color(0xFFA9C8FF),
    AppearancePalette.green => const Color(0xFFA8E8CB),
    AppearancePalette.orange => const Color(0xFFFFD2A6),
    AppearancePalette.purple => const Color(0xFFCFC2FF),
    AppearancePalette.gray => const Color(0xFFD5DBE3),
  };

  @override
  bool shouldRepaint(covariant _AppearancePainter oldDelegate) =>
      oldDelegate.state.signature != state.signature;
}
