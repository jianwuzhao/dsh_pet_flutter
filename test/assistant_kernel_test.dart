/// 内核情绪闭环集成测试：fake 时钟 + fake 宿主 + 临时档案目录。
///
/// 网关用空注册表的轻量实例（只验证“信号先喂、转发原样”的路径）；
/// 主动关心流用可推进的假时钟完整走 worried → 预算 → 表达 → 记账。
library;

import 'dart:io';

import 'package:dsh_pet_flutter/ai/llm_provider.dart';
import 'package:dsh_pet_flutter/ai/llm_router.dart';
import 'package:dsh_pet_flutter/app/assistant_kernel.dart';
import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/features/linkage/assistant_adapters.dart';
import 'package:dsh_pet_flutter/features/linkage/dispatcher.dart';
import 'package:dsh_pet_flutter/features/linkage/status/assistant_event.dart';
import 'package:dsh_pet_flutter/gateway/interaction_gateway.dart';
import 'package:dsh_pet_flutter/gateway/privacy_center.dart';
import 'package:dsh_pet_flutter/learning/feedback_collector.dart';
import 'package:dsh_pet_flutter/learning/guideline_store.dart';
import 'package:dsh_pet_flutter/learning/learning_loop.dart';
import 'package:dsh_pet_flutter/learning/policy_store.dart';
import 'package:dsh_pet_flutter/learning/reflection_store.dart';
import 'package:dsh_pet_flutter/persona/appearance/appearance_state.dart';
import 'package:dsh_pet_flutter/persona/appearance/appearance_store.dart';
import 'package:dsh_pet_flutter/persona/emotion/emotion_machine.dart';
import 'package:dsh_pet_flutter/persona/emotion/emotion_signal.dart';
import 'package:dsh_pet_flutter/persona/expression/expression_layer.dart';
import 'package:dsh_pet_flutter/persona/memory/memory_entry.dart';
import 'package:dsh_pet_flutter/persona/memory/memory_store.dart';
import 'package:dsh_pet_flutter/persona/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录表达决策的假宿主：关心是否表达、表达了几次全在这里断言。
class _FakeHost extends ExpressionHost {
  final animations = <String>[];
  final bubbles = <String>[];

  @override
  void playAnimation(String name) => animations.add(name);

  @override
  void showBubble(String text, {String? meme, bool dismissible = false}) =>
      bubbles.add(text);
}

/// 可回复的假提供者：日终复盘测试用，chat 永远返回固定 JSON。
class _ReplyProvider implements LlmProvider {
  _ReplyProvider(this.reply);

  final String reply;

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake';

  @override
  bool get supportsReply => true;

  @override
  Future<bool> get isReady async => true;

  @override
  Future<Result<LlmReply>> chat(LlmRequest request) async =>
      Success(LlmReply(content: reply));

  @override
  void dispose() {}
}

void main() {
  late Directory tmpDir;
  late _FakeHost host;
  // 中午起步：默认安静时段 22:00–08:00 之外，预算判定不被它拦。
  var now = DateTime(2026, 1, 1, 12, 0);

  AssistantKernel buildKernel() {
    final gateway = InteractionGateway(
      dispatcher: Dispatcher(registry: AdapterRegistry(const {}), activeId: ''),
      router: LlmRouter(providers: const []),
    );
    return AssistantKernel(
      gateway: gateway,
      store: ProfileStore(directory: tmpDir),
      host: host,
      privacy: PrivacyCenter(directory: tmpDir),
      // 记忆库同样必须指到临时目录：默认 MemoryStore 会写真实用户目录。
      memory: MemoryStore(directory: Directory('${tmpDir.path}/memory')),
      // 学习层必须指到临时目录：默认 LearningLoop 会写真实用户目录。
      learning: LearningLoop(
        collector: FeedbackCollector(
          file: File('${tmpDir.path}/feedback.jsonl'),
          clock: () => now,
        ),
        policy: PolicyStore(
          directory: Directory('${tmpDir.path}/learning'),
          clock: () => now,
        ),
        host: host,
        clock: () => now,
      ),
      // 形象档案同理：默认 AppearanceStore 会读真实用户目录。
      appearanceStore: AppearanceStore(
        directory: Directory('${tmpDir.path}/profile'),
      ),
      clock: () => now,
    );
  }

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('assistant_kernel_test');
    host = _FakeHost();
    now = DateTime(2026, 1, 1, 12, 0);
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  group('信号感知', () {
    test('任务终态折算情绪信号：success 抬效价、error 压效价', () {
      final kernel = buildKernel()..start();
      kernel.onStatusSnapshot(
        StatusSnapshot(
          state: AssistantStatus.success,
          text: 'done',
          source: 'test',
          updatedAt: now,
        ),
      );
      expect(kernel.emotion.value.valence, greaterThan(0));

      now = now.add(const Duration(seconds: 120));
      kernel.onStatusSnapshot(
        StatusSnapshot(
          state: AssistantStatus.error,
          text: 'fail',
          source: 'test',
          updatedAt: now,
        ),
      );
      expect(kernel.emotion.value.valence, lessThan(0));
    });

    test('非终态与空快照不产生信号', () {
      final kernel = buildKernel()..start();
      final before = kernel.emotion.value.valence;
      kernel.onStatusSnapshot(null);
      kernel.onStatusSnapshot(
        StatusSnapshot(
          state: AssistantStatus.working,
          text: 'busy',
          source: 'test',
          updatedAt: now,
        ),
      );
      expect(kernel.emotion.value.valence, before);
    });

    test('submit 先喂互动信号再走网关（空文本被网关原样拒绝）', () async {
      final kernel = buildKernel()..start();
      final result = await kernel.submit('', InputSource.panel);
      expect(result, isA<Failure<dynamic>>());
      // interaction 信号：唤醒抬到基线之上。
      expect(kernel.emotion.value.arousal, greaterThan(0.3));
      expect(kernel.emotion.value.intimacy, greaterThan(0.3));
    });

    test('chat 失败直接返回，不喂任何信号', () async {
      final kernel = buildKernel()..start();
      final before = kernel.emotion.value.arousal;
      final reply = await kernel.chat('你好');
      expect(reply.ok, isFalse);
      expect(kernel.emotion.value.arousal, before);
    });
  });

  group('主动关心', () {
    test('worried 持续超 3 分钟：过预算后表达安慰话术并记账写盘', () {
      final kernel = buildKernel()..start();
      // 两次负反馈抬到 worried（第二次换态需先过 90s 节流窗）。
      kernel.applySignal(EmotionSignal.negativeFeedback);
      now = now.add(const Duration(seconds: 95));
      kernel.applySignal(EmotionSignal.negativeFeedback);
      expect(kernel.phase, EmotionPhase.worried);

      // 刚进 worried 还不满 3 分钟：不表达。
      kernel.checkProactiveCare();
      expect(host.bubbles, isEmpty);

      now = now.add(const Duration(seconds: 185));
      kernel.checkProactiveCare();
      expect(host.bubbles, hasLength(1));
      expect(host.bubbles.single, anyOf(EmotionProfile.defaultComfortPhrases));

      // 额度已消耗：档案计数 +1 且落盘。
      expect(kernel.emotionProfile.careCount, 1);
      final saved = File(
        '${tmpDir.path}${Platform.pathSeparator}emotion_profile.json',
      );
      expect(saved.readAsStringSync(), contains('"careCount": 1'));

      // 同状态 1h 限流：再巡检也不表达。
      now = now.add(const Duration(minutes: 2));
      kernel.checkProactiveCare();
      expect(host.bubbles, hasLength(1));
    });

    test('安静时段内一律不表达', () {
      final kernel = buildKernel()..start();
      kernel.applySignal(EmotionSignal.negativeFeedback);
      now = now.add(const Duration(seconds: 95));
      kernel.applySignal(EmotionSignal.negativeFeedback);
      expect(kernel.phase, EmotionPhase.worried);

      // 推到深夜（默认安静时段 22:00–08:00）再等满 3 分钟。
      now = DateTime(2026, 1, 1, 23, 30);
      now = now.add(const Duration(seconds: 95));
      kernel.applySignal(EmotionSignal.negativeFeedback);
      now = now.add(const Duration(seconds: 185));
      kernel.checkProactiveCare();
      expect(host.bubbles, isEmpty);
      expect(kernel.emotionProfile.careCount, 0);
    });
  });

  group('档案保存', () {
    test('saveEmotionProfile 换基线不重置三维，开关关闭复位状态机', () {
      final kernel = buildKernel()..start();
      kernel.applySignal(EmotionSignal.positiveFeedback);
      final view = kernel.emotion.value;

      final result = kernel.saveEmotionProfile(
        const EmotionProfile(intimacyBaseline: 0.6),
      );
      expect(result, isA<Success<void>>());
      expect(kernel.emotion.value.valence, view.valence);
      expect(kernel.emotion.value.arousal, view.arousal);
      expect(kernel.emotion.value.intimacy, view.intimacy);

      // 关闭引擎：状态机复位到 calm，后续信号全部丢弃。
      kernel.saveEmotionProfile(
        kernel.emotionProfile.copyWith(focusMode: true),
      );
      kernel.applySignal(EmotionSignal.positiveFeedback);
      final frozen = kernel.emotion.value.valence;
      kernel.saveEmotionProfile(
        kernel.emotionProfile.copyWith(emotionEnabled: false),
      );
      expect(kernel.phase, EmotionPhase.calm);
      kernel.applySignal(EmotionSignal.excited);
      expect(kernel.emotion.value.valence, frozen);
    });
  });

  group('学习治理接线', () {
    test('回复的接受/拒绝都落到本地反馈流水（无评分语义）', () {
      final kernel = buildKernel()..start();

      kernel.acceptReply();
      kernel.rejectReply(correction: '太长了');

      final file = File('${tmpDir.path}/feedback.jsonl');
      expect(file.existsSync(), isTrue);
      final lines = file.readAsLinesSync();
      expect(lines.length, 2);
      expect(lines.first, contains('accepted'));
      expect(lines.last, contains('corrected'));
      expect(lines.last, contains('太长了'));
    });

    test('主动关心被提前关闭记为拒绝样本（自动过期不记）', () {
      final kernel = buildKernel()..start();
      kernel.dismissCare();

      final events = File('${tmpDir.path}/feedback.jsonl').readAsLinesSync();
      expect(events.length, 1);
      expect(events.single, contains('rejected'));
      expect(events.single, contains('care:'));
    });

    test('记忆提案经学习闭环接受：生效并留正样本', () {
      final kernel = buildKernel()..start();
      kernel.memory.add(
        MemoryEntry(
          id: 'm1',
          kind: MemoryKind.preference,
          content: '称呼偏好：老板',
          createdAt: now,
          status: MemoryStatus.pending,
        ),
      );

      final result = kernel.learning.acceptMemoryProposal(kernel.memory, 'm1');
      expect(result, isA<Success<void>>());
      expect(kernel.memory.pending, isEmpty);
      expect(
        File('${tmpDir.path}/feedback.jsonl').readAsStringSync(),
        contains('accepted'),
      );
    });
  });

  group('形象推演接线', () {
    /// 除形态外都到顶：这样推演只能产出形态提案，便于验证提案制。
    AppearanceState outlineAtCeiling() => AppearanceState(
      motionSet: AppearanceMotionSet.lively,
      expressionSet: AppearanceExpressionSet.bright,
      accessory: AppearanceAccessory.hat,
      bodyScale: appearanceMaxBodyScale,
      revision: 1,
      updatedAtMs: now
          .subtract(const Duration(hours: 13))
          .millisecondsSinceEpoch,
    );

    void seedOutline() => AppearanceStore(
      directory: Directory('${tmpDir.path}/profile'),
    ).save(outlineAtCeiling());

    void feedStrongSignals(AssistantKernel kernel) {
      for (var index = 0; index < 4; index++) {
        kernel.applySignal(EmotionSignal.positiveFeedback);
        kernel.acceptReply();
      }
    }

    test('启动读取形象档案；缺失时用默认值', () {
      final kernel = buildKernel()..start();
      expect(
        kernel.appearanceState.signature,
        const AppearanceState().signature,
      );
      expect(host.bubbles, isEmpty);
    });

    test('反馈足够时推演一步并落盘，冷却期内不再变', () {
      final kernel = buildKernel()..start();
      kernel.acceptReply();
      kernel.acceptReply();

      final outcome = kernel.evolveAppearance();
      expect(outcome.changed, isTrue);
      expect(outcome.reason, contains('→'));
      expect(
        kernel.appearanceState.expressionSet,
        AppearanceExpressionSet.bright,
      );
      expect(kernel.appearanceState.revision, 1);
      expect(
        File('${tmpDir.path}/profile/appearance.json').existsSync(),
        isTrue,
      );

      final again = kernel.evolveAppearance();
      expect(again.changed, isFalse);
      expect(again.reason, contains('不足'));
    });

    test('回滚恢复上一版并让修订号继续递增', () {
      final kernel = buildKernel()..start();
      kernel.acceptReply();
      kernel.acceptReply();
      kernel.evolveAppearance();

      final rolled = kernel.rollbackAppearance();
      expect(rolled, isA<Success<AppearanceState>>());
      expect(rolled.valueOrNull!.expressionSet, AppearanceExpressionSet.soft);
      expect(rolled.valueOrNull!.revision, 2);
      expect(kernel.appearanceState.signature, rolled.valueOrNull!.signature);
    });

    test('冻结后推演不动，解冻后恢复', () {
      final kernel = buildKernel()..start();
      kernel.acceptReply();
      kernel.acceptReply();
      expect(kernel.setAppearanceFrozen(true), isA<Success<void>>());

      final frozen = kernel.evolveAppearance();
      expect(frozen.changed, isFalse);
      expect(frozen.reason, contains('冻结'));

      kernel.setAppearanceFrozen(false);
      expect(kernel.evolveAppearance().changed, isTrue);
    });

    test('形象档案损坏时明确报错并保持默认，不静默替换', () {
      Directory('${tmpDir.path}/profile').createSync(recursive: true);
      File(
        '${tmpDir.path}/profile/appearance.json',
      ).writeAsStringSync('{ broken');
      final kernel = buildKernel()..start();

      expect(
        kernel.appearanceState.signature,
        const AppearanceState().signature,
      );
      expect(host.bubbles.single, contains('形象档案读取失败'));
    });

    test('形态提案需用户接受才生效，接受后落盘并清除提案', () {
      seedOutline();
      final kernel = buildKernel()..start();
      feedStrongSignals(kernel);

      final outcome = kernel.evolveAppearance();
      expect(outcome.changed, isFalse);
      expect(outcome.proposal, isNotNull);
      expect(kernel.appearanceState.form, AppearanceForm.round);
      expect(kernel.formProposal, isNotNull);
      expect(
        File('${tmpDir.path}/profile/appearance_proposal.json').existsSync(),
        isTrue,
      );

      final accepted = kernel.acceptFormProposal();
      expect(accepted, isA<Success<AppearanceState>>());
      expect(kernel.appearanceState.form, AppearanceForm.chubby);
      expect(kernel.appearanceState.revision, 2);
      expect(kernel.formProposal, isNull);
      expect(
        File('${tmpDir.path}/profile/appearance_proposal.json').existsSync(),
        isFalse,
      );
    });

    test('已有提案时不再重复生成，拒绝后清除', () {
      seedOutline();
      final kernel = buildKernel()..start();
      feedStrongSignals(kernel);
      expect(kernel.evolveAppearance().proposal, isNotNull);

      final again = kernel.evolveAppearance();
      expect(again.proposal, isNotNull);
      expect(again.changed, isFalse);
      expect(again.reason, contains('待确认'));

      expect(kernel.rejectFormProposal(), isA<Success<void>>());
      expect(kernel.formProposal, isNull);
      expect(kernel.appearanceState.form, AppearanceForm.round);
      expect(
        File('${tmpDir.path}/profile/appearance_proposal.json').existsSync(),
        isFalse,
      );
    });
  });

  group('日终复盘', () {
    test('前一天没凑满门槛的反思，跨天后补一次总结', () async {
      final provider = _ReplyProvider(
        '{"lessons":[{"title":"先看日志","content":"任务失败时先读错误日志再重试","trigger":"失败","confidence":0.8}]}',
      );
      final gateway = InteractionGateway(
        dispatcher: Dispatcher(
          registry: AdapterRegistry(const {}),
          activeId: '',
        ),
        router: LlmRouter(providers: [provider], activeId: 'fake'),
      );
      final guidelines = GuidelineStore(
        directory: Directory('${tmpDir.path}/learning2'),
      )..load();
      final kernel = AssistantKernel(
        gateway: gateway,
        store: ProfileStore(directory: tmpDir),
        host: host,
        privacy: PrivacyCenter(directory: tmpDir),
        memory: MemoryStore(directory: Directory('${tmpDir.path}/memory')),
        learning: LearningLoop(
          collector: FeedbackCollector(
            file: File('${tmpDir.path}/feedback.jsonl'),
            clock: () => now,
          ),
          policy: PolicyStore(
            directory: Directory('${tmpDir.path}/learning'),
            clock: () => now,
          ),
          host: host,
          clock: () => now,
        ),
        appearanceStore: AppearanceStore(
          directory: Directory('${tmpDir.path}/profile'),
        ),
        reflections: ReflectionStore(
          file: File('${tmpDir.path}/reflections.jsonl'),
        ),
        guidelines: guidelines,
        clock: () => now,
      )..start();

      void terminal(String text) => kernel.onStatusSnapshot(
        StatusSnapshot(
          state: AssistantStatus.success,
          text: text,
          source: 'test',
          updatedAt: now,
        ),
      );

      // 第一天：两条终态既没凑满 3 条门槛，也不触发日终复盘（同天只判断一次）。
      terminal('任务一构建完成');
      terminal('任务二构建完成');
      await pumpEventQueue();
      expect(guidelines.pending, isEmpty);

      // 跨天：留下的 2 条未总结反思触发补总结，产出待确认提案。
      now = DateTime(2026, 1, 2, 9, 0);
      terminal('任务三构建完成');
      await pumpEventQueue();
      expect(guidelines.pending, hasLength(1));
    });
  });
}
