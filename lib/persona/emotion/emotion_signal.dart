/// 情绪感知：信号源 → 三维增量。
///
/// 信号源只有两种（计划 4.2：不读屏幕、不读隐私数据）：
/// - 显式信号：任务终态、用户接受/拒绝（M6 接入）、点击/拖拽互动；
/// - 对话文本：supportsReply 时用 LLM 的 sentiment 标签，否则关键词启发式兜底。
library;

/// 情绪信号类别。
enum EmotionSignal {
  /// 正反馈：回复被接受 / 任务 success / 夸奖词。
  positiveFeedback,

  /// 负反馈：回复被拒绝或纠正 / 任务 error / 不满词。
  negativeFeedback,

  /// 疲惫/低落词（“累/烦/难过”）。
  tired,

  /// 兴奋词（“太好了/成功啦”）。
  excited,

  /// 互动：点击 / 拖拽 / 发消息。
  interaction,
}

/// 三维增量：valence（效价）/ arousal（唤醒）/ intimacy（亲密度）。
class EmotionDelta {
  const EmotionDelta(this.valence, this.arousal, this.intimacy);

  final double valence;
  final double arousal;
  final double intimacy;
}

/// 信号 → 增量常量表（计划 4.2 数值口径，改动必须同步 emotion_state 测试）。
const Map<EmotionSignal, EmotionDelta> signalDeltas = {
  EmotionSignal.positiveFeedback: EmotionDelta(0.2, 0.1, 0.02),
  EmotionSignal.negativeFeedback: EmotionDelta(-0.25, 0.15, -0.01),
  EmotionSignal.tired: EmotionDelta(-0.2, -0.1, 0),
  EmotionSignal.excited: EmotionDelta(0.3, 0.25, 0),
  EmotionSignal.interaction: EmotionDelta(0, 0.02, 0.005),
};

/// LLM sentiment 标签（positive/negative/tired/excited/neutral）→ 信号。
/// neutral 与未知标签返回 null：没有信号比猜错信号好。
EmotionSignal? signalFromSentiment(String? label) {
  switch (label) {
    case 'positive':
      return EmotionSignal.positiveFeedback;
    case 'negative':
      return EmotionSignal.negativeFeedback;
    case 'tired':
      return EmotionSignal.tired;
    case 'excited':
      return EmotionSignal.excited;
    default:
      return null;
  }
}

const List<String> _tiredWords = [
  '累了', '好累', '困', '乏', '疲惫', '熬夜', '想睡', '撑不住', '难过', '心累',
];

const List<String> _excitedWords = [
  '太好了', '成功啦', '成功了', '哈哈', '牛', '太棒了', '绝了', '开心', '兴奋',
];

const List<String> _praiseWords = ['谢谢', '好用', '喜欢', '赞', '满意', '干得不错'];

const List<String> _complaintWords = ['不对', '错了', '没用', '讨厌', '烦死', '垃圾', '别这样'];

/// 关键词启发式：无 LLM 标签时的兜底感知。
/// 疲惫优先判定——它最容易与“低唤醒的平静”混淆，先排除再谈正负。
EmotionSignal? guessSignalFromText(String text) {
  final lower = text.toLowerCase();
  for (final word in _tiredWords) {
    if (lower.contains(word)) return EmotionSignal.tired;
  }
  for (final word in _excitedWords) {
    if (lower.contains(word)) return EmotionSignal.excited;
  }
  for (final word in _praiseWords) {
    if (lower.contains(word)) return EmotionSignal.positiveFeedback;
  }
  for (final word in _complaintWords) {
    if (lower.contains(word)) return EmotionSignal.negativeFeedback;
  }
  return null;
}
