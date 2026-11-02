/// 回应策略：亲密度分档、情绪→动画映射、主动关心话术挑选。
///
/// 受人格 DNA 约束（语气核心/底线）；话术挑选必须过滤回避话题——
/// 主动关心踩雷区比不说话糟糕得多。
library;

import 'dart:math' as math;

import '../profile_store.dart';
import 'emotion_machine.dart';

/// 亲密度三档（计划 4.2：<0.3 客气 / 0.3–0.6 亲近 / >0.6 亲昵）。
enum IntimacyTier { reserved, close, intimate }

IntimacyTier tierOf(double intimacy) {
  if (intimacy < 0.3) return IntimacyTier.reserved;
  if (intimacy <= 0.6) return IntimacyTier.close;
  return IntimacyTier.intimate;
}

/// 情绪态 → 动画名（manifest 实名；缺名时表达层回退待机动画）。
const Map<EmotionPhase, String> emotionAnimations = {
  EmotionPhase.calm: '待机呼吸休闲',
  EmotionPhase.happy: '工作状态-雀跃庆祝',
  EmotionPhase.excited: '工作状态-雀跃庆祝',
  EmotionPhase.worried: '东张西望',
  EmotionPhase.sleepy: '打瞌睡被惊醒',
};

/// 语气三档：M5 会话服务拼 system prompt 时取用，受人格 DNA 语气核心约束。
const Map<IntimacyTier, String> tierTones = {
  IntimacyTier.reserved: '客气、保持距离',
  IntimacyTier.close: '亲近、自然',
  IntimacyTier.intimate: '亲昵、可以开玩笑',
};

/// 一次表达的全部要素；气泡可空（纯动画切换不说话，不耗打扰预算）。
class ExpressionDecision {
  const ExpressionDecision({
    required this.animation,
    this.bubbleText,
    this.meme,
    this.tone = '',
    this.dismissible = false,
  });

  final String animation;
  final String? bubbleText;
  final String? meme;
  final String tone;

  /// true = 气泡带“知道了”关闭入口（目前只有主动关心使用）。
  /// 关闭即“拒绝这次关心”，由装配层接到学习闭环；自动过期仍是中性。
  final bool dismissible;
}

class ResponseStrategy {
  ResponseStrategy({math.Random? random}) : _random = random ?? math.Random();

  final math.Random _random;

  String toneFor(IntimacyTier tier) => tierTones[tier]!;

  /// 被动表达（情绪态切换时的动画/语气）：不说话，不耗打扰预算。
  ExpressionDecision passive(EmotionPhase phase) => ExpressionDecision(
    animation: emotionAnimations[phase] ?? emotionAnimations[EmotionPhase.calm]!,
    tone: '',
  );

  /// 主动关心决策：worried 持续>3min 且预算已放行时由内核调用。
  /// 从安慰话术池挑一条；池空回退默认池；全被回避话题过滤则返回 null（宁可不表达）。
  ExpressionDecision? care(
    EmotionProfile profile, {
    required EmotionPhase phase,
    required IntimacyTier tier,
  }) {
    final pool = _comfortPool(profile);
    if (pool.isEmpty) return null;
    return ExpressionDecision(
      animation:
          emotionAnimations[phase] ?? emotionAnimations[EmotionPhase.calm]!,
      bubbleText: pool[_random.nextInt(pool.length)],
      tone: tierTones[tier]!,
      // 主动关心是唯一允许“提前关闭”的表达：用户点掉 = 拒绝样本。
      dismissible: true,
    );
  }

  List<String> _comfortPool(EmotionProfile profile) {
    final custom = profile.comfortPhrases;
    final pool = custom.isEmpty ? EmotionProfile.defaultComfortPhrases : custom;
    final topics = profile.avoidedTopics;
    if (topics.isEmpty) return pool;
    return [
      for (final phrase in pool)
        if (!topics.any(phrase.contains)) phrase,
    ];
  }
}
