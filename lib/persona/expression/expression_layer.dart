/// 表达编排：把决策落到动画 + 气泡 + 表情包；TTS 留桩（ASR/TTS 暂缓）。
///
/// 不依赖 features 层：宿主能力以 [ExpressionHost] 抽象注入，
/// PetController 的适配在装配层完成。
library;

import '../emotion/response_strategy.dart';

/// 表达宿主：动画点播与气泡展示的最小能力集。
abstract class ExpressionHost {
  /// 播放一次动画；宿主负责缺名回退与播完回落。
  void playAnimation(String name);

  /// 展示气泡；宿主负责自动隐藏计时。
  void showBubble(String text, {String? meme});
}

/// TTS 留桩：首期只有空实现，接口先行（计划 4.7）。
abstract class TtsSink {
  void speak(String text);
}

class SilentTtsSink implements TtsSink {
  const SilentTtsSink();

  @override
  void speak(String text) {}
}

class ExpressionLayer {
  ExpressionLayer({required this.host, this.tts = const SilentTtsSink()});

  final ExpressionHost host;
  final TtsSink tts;

  DateTime? _lastPerformAt;
  String? _lastKey;

  /// 执行一次表达；7s 内完全相同的表达（动画与气泡都相同）去重，
  /// 防止状态机连拍导致动画/气泡抖动。
  void perform(ExpressionDecision decision, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final key = '${decision.animation}|${decision.bubbleText ?? ''}';
    final last = _lastPerformAt;
    final duplicated =
        last != null &&
        key == _lastKey &&
        at.difference(last) < const Duration(seconds: 7);
    if (duplicated) return;
    _lastPerformAt = at;
    _lastKey = key;

    host.playAnimation(decision.animation);
    final text = decision.bubbleText;
    if (text != null && text.trim().isNotEmpty) {
      host.showBubble(text, meme: decision.meme);
      tts.speak(text);
    }
  }
}
