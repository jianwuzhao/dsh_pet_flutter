import 'dart:math' as math;

import 'package:dsh_pet_flutter/persona/emotion/emotion_machine.dart';
import 'package:dsh_pet_flutter/persona/emotion/response_strategy.dart';
import 'package:dsh_pet_flutter/persona/expression/expression_layer.dart';
import 'package:dsh_pet_flutter/persona/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingHost implements ExpressionHost {
  final List<String> animations = [];
  final List<(String, String?)> bubbles = [];

  @override
  void playAnimation(String name) => animations.add(name);

  @override
  void showBubble(String text, {String? meme}) => bubbles.add((text, meme));
}

class _RecordingTts implements TtsSink {
  final List<String> spoken = [];

  @override
  void speak(String text) => spoken.add(text);
}

void main() {
  final base = DateTime(2026, 11, 2, 12, 0);

  group('ExpressionLayer 去重', () {
    test('7s 内完全相同的表达只执行一次', () {
      final host = _RecordingHost();
      final layer = ExpressionLayer(host: host);
      const decision = ExpressionDecision(
        animation: '东张西望',
        bubbleText: '我在呢。',
      );
      layer.perform(decision, now: base);
      layer.perform(decision, now: base.add(const Duration(seconds: 3)));
      expect(host.animations, ['东张西望']);
      expect(host.bubbles.length, 1);
    });

    test('7s 窗口过后同样的表达再次执行', () {
      final host = _RecordingHost();
      final layer = ExpressionLayer(host: host);
      const decision = ExpressionDecision(animation: '东张西望');
      layer.perform(decision, now: base);
      layer.perform(decision, now: base.add(const Duration(seconds: 8)));
      expect(host.animations.length, 2);
    });

    test('不同表达不去重', () {
      final host = _RecordingHost();
      final layer = ExpressionLayer(host: host);
      layer.perform(
        const ExpressionDecision(animation: '东张西望', bubbleText: 'A'),
        now: base,
      );
      layer.perform(
        const ExpressionDecision(animation: '东张西望', bubbleText: 'B'),
        now: base,
      );
      expect(host.animations.length, 2);
      expect(host.bubbles.length, 2);
    });

    test('气泡非空才说话并驱动 TTS 桩', () {
      final host = _RecordingHost();
      final tts = _RecordingTts();
      final layer = ExpressionLayer(host: host, tts: tts);
      layer.perform(
        const ExpressionDecision(animation: '东张西望', bubbleText: 'hi'),
        now: base,
      );
      // 纯动画：无气泡、无 TTS。
      layer.perform(
        const ExpressionDecision(animation: '待机呼吸休闲'),
        now: base,
      );
      expect(host.bubbles.length, 1);
      expect(tts.spoken, ['hi']);
    });
  });

  group('ResponseStrategy', () {
    test('亲密度三档分界', () {
      expect(tierOf(0.2), IntimacyTier.reserved);
      expect(tierOf(0.3), IntimacyTier.close);
      expect(tierOf(0.6), IntimacyTier.close);
      expect(tierOf(0.61), IntimacyTier.intimate);
    });

    test('情绪态动画映射覆盖五态且用 manifest 实名', () {
      expect(emotionAnimations[EmotionPhase.calm], '待机呼吸休闲');
      expect(emotionAnimations[EmotionPhase.happy], '工作状态-雀跃庆祝');
      expect(emotionAnimations[EmotionPhase.excited], '工作状态-雀跃庆祝');
      expect(emotionAnimations[EmotionPhase.worried], '东张西望');
      expect(emotionAnimations[EmotionPhase.sleepy], '打瞌睡被惊醒');
    });

    test('care 从默认话术池挑一条并带语气', () {
      final strategy = ResponseStrategy(random: _FixedRandom());
      final decision = strategy.care(
        const EmotionProfile(),
        phase: EmotionPhase.worried,
        tier: IntimacyTier.close,
      );
      expect(decision, isNotNull);
      expect(decision!.bubbleText, '辛苦了，要不要先休息一下？');
      expect(decision.animation, '东张西望');
      expect(decision.tone, '亲近、自然');
    });

    test('care 过滤含回避话题的话术；全被过滤则不表达', () {
      final strategy = ResponseStrategy(random: _FixedRandom());
      final withSafe = const EmotionProfile(
        comfortPhrases: ['加班辛苦啦', '别提工作了'],
        avoidedTopics: ['工作'],
      );
      final decision = strategy.care(
        withSafe,
        phase: EmotionPhase.worried,
        tier: IntimacyTier.reserved,
      );
      expect(decision!.bubbleText, '加班辛苦啦');

      final allBlocked = const EmotionProfile(
        comfortPhrases: ['别提工作了'],
        avoidedTopics: ['工作'],
      );
      expect(
        strategy.care(
          allBlocked,
          phase: EmotionPhase.worried,
          tier: IntimacyTier.reserved,
        ),
        isNull,
      );
    });

    test('passive 纯动画不说话', () {
      final strategy = ResponseStrategy(random: _FixedRandom());
      final decision = strategy.passive(EmotionPhase.happy);
      expect(decision.animation, '工作状态-雀跃庆祝');
      expect(decision.bubbleText, isNull);
    });
  });
}

/// 固定随机源：永远取下标 0，测试可预期。
class _FixedRandom implements math.Random {
  @override
  int nextInt(int max) => 0;

  @override
  double nextDouble() => 0;

  @override
  bool nextBool() => false;
}
