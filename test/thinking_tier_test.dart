import 'package:dsh_pet_flutter/ai/thinking_tier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeepSeek 档位映射（官方 effort 语义）', () {
    test('fast 关闭思考并用最低 effort', () {
      final plan = deepseekThinkingFor(ThinkingTier.fast);
      expect(plan.thinkingEnabled, isFalse);
      expect(plan.effort, 'low');
    });

    test('balanced 与官方默认一致（思考开 + high）', () {
      final plan = deepseekThinkingFor(ThinkingTier.balanced);
      expect(plan.thinkingEnabled, isTrue);
      expect(plan.effort, 'high');
    });

    test('deep 用最高 effort', () {
      final plan = deepseekThinkingFor(ThinkingTier.deep);
      expect(plan.thinkingEnabled, isTrue);
      expect(plan.effort, 'max');
    });
  });

  group('OpenAI 兼容档位映射', () {
    test('low / medium / high 三档', () {
      expect(openAiEffortFor(ThinkingTier.fast), 'low');
      expect(openAiEffortFor(ThinkingTier.balanced), 'medium');
      expect(openAiEffortFor(ThinkingTier.deep), 'high');
    });
  });
}
