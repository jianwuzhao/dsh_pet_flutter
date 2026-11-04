/// 内核情绪闭环集成测试：fake 时钟 + fake 宿主 + 临时档案目录。
///
/// 网关用空注册表的轻量实例（只验证“信号先喂、转发原样”的路径）；
/// 主动关心流用可推进的假时钟完整走 worried → 预算 → 表达 → 记账。
library;

import 'dart:io';

import 'package:dsh_pet_flutter/ai/embedding_provider.dart';
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
import 'package:dsh_pet_flutter/learning/metrics_store.dart';
import 'package:dsh_pet_flutter/learning/policy_store.dart';
import 'package:dsh_pet_flutter/learning/reflection_store.dart';
import 'package:dsh_pet_flutter/persona/appearance/appearance_state.dart';
import 'package:dsh_pet_flutter/persona/appearance/appearance_store.dart';
import 'package:dsh_pet_flutter/persona/appearance/trend_outfit.dart';
import 'package:dsh_pet_flutter/persona/appearance/weather_outfit.dart';
import 'package:dsh_pet_flutter/persona/emotion/emotion_machine.dart';
import 'package:dsh_pet_flutter/persona/emotion/emotion_signal.dart';
import 'package:dsh_pet_flutter/persona/expression/expression_layer.dart';
import 'package:dsh_pet_flutter/persona/memory/memory_entry.dart';
import 'package:dsh_pet_flutter/persona/memory/memory_store.dart';
import 'package:dsh_pet_flutter/persona/memory/memory_vectors.dart';
import 'package:dsh_pet_flutter/persona/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 记录表达决策的假宿主：关心是否表达、表达了几次全在这里断言。
class _FakeHost extends ExpressionHost {
  final animations = <String>[];
  final bubbles = <String>[];
  int panelOpens = 0;

  /// 最近一条气泡携带的动作（待确认触达的“去看看”落点）。
  void Function()? lastBubbleTap;

  @override
  void playAnimation(String name) => animations.add(name);

  @override
  void showBubble(
    String text, {
    String? meme,
    bool dismissible = false,
    void Function()? onTap,
  }) {
    bubbles.add(text);
    lastBubbleTap = onTap;
  }

  @override
  void openPendingConfirmations() => panelOpens++;
}

/// 可回复的假提供者：日终复盘测试用，chat 永远返回固定 JSON；
/// 顺带记录每次请求的 system，供注入断言复用。
class _ReplyProvider implements LlmProvider {
  _ReplyProvider(this.reply, {this.rewriteReply});

  final String reply;

  /// 影子措辞优化（P1-5）的专用回复：按 system 分流，
  /// 候选 JSON 与对话回复互不掺和。
  final String? rewriteReply;
  final List<String> systems = [];

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake';

  @override
  bool get supportsReply => true;

  @override
  Future<bool> get isReady async => true;

  @override
  Future<Result<LlmReply>> chat(LlmRequest request) async {
    systems.add(request.system);
    final body =
        request.system.contains('措辞优化助手') ? (rewriteReply ?? reply) : reply;
    return Success(LlmReply(content: body));
  }

  @override
  void dispose() {}
}

/// 恒定向量的假 embedder：让“query 与记忆同向”可确定构造。
class _FakeEmbedder extends EmbeddingProvider {
  int calls = 0;

  @override
  String get id => 'fake-embed';

  @override
  Future<List<double>?> embed(String text) async {
    calls++;
    return const [1.0, 0.0];
  }
}

void main() {
  late Directory tmpDir;
  late _FakeHost host;
  // 中午起步：默认安静时段 22:00–08:00 之外，预算判定不被它拦。
  var now = DateTime(2026, 1, 1, 12, 0);

  AssistantKernel buildKernel({
    LlmProvider? provider,
    GuidelineStore? guidelines,
    WeatherOutfitService? weatherOutfit,
  }) {
    final gateway = InteractionGateway(
      dispatcher: Dispatcher(registry: AdapterRegistry(const {}), activeId: ''),
      // 测试要触发 LLM 路径时必须同时设 activeId，否则 resolve 不出提供者。
      router: LlmRouter(
        providers: provider == null ? const [] : [provider],
        activeId: provider == null ? '' : provider.id,
      ),
    );
    return AssistantKernel(
      gateway: gateway,
      store: ProfileStore(directory: tmpDir),
      host: host,
      privacy: PrivacyCenter(directory: tmpDir),
      // 记忆库同样必须指到临时目录：默认 MemoryStore 会写真实用户目录。
      memory: MemoryStore(directory: Directory('${tmpDir.path}/memory')),
      // 向量库默认会打开真实用户目录的 vectors.db，测试一律禁用。
      vectors: MemoryVectorStore.disabled(),
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
        guidelines: guidelines,
        host: host,
        clock: () => now,
      ),
      guidelines: guidelines,
      // 指标快照同理：默认 MetricsStore 会写真实用户目录。
      metrics: MetricsStore(
        directory: Directory('${tmpDir.path}/learning'),
        clock: () => now,
      ),
      // 形象档案同理：默认 AppearanceStore 会读真实用户目录。
      appearanceStore: AppearanceStore(
        directory: Directory('${tmpDir.path}/profile'),
      ),
      // 天气装扮（P2-3）：测试注入 MockClient 版服务，绝不碰真实网络。
      weatherOutfit: weatherOutfit,
      // 趋势治理状态同理：必须落在临时目录，绝不碰真实用户目录。
      trendStore: TrendOutfitStore(
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

    test('启动换季不重置推演冷却与回滚不变量（P2-1）', () {
      // 测试时钟是 1/1（冬）：启动即自动换冬装，但装扮是纯装饰轨道，
      // revision/updatedAt/history 都不能被动，否则人格推演被冷却卡死。
      final kernel = buildKernel()..start();
      expect(kernel.appearanceState.outfit, 'winter');
      expect(
        kernel.appearanceState.outfitSource,
        AppearanceOutfitSource.seasonal,
      );
      expect(kernel.appearanceState.revision, 0);

      kernel.acceptReply();
      kernel.acceptReply();
      expect(kernel.evolveAppearance().changed, isTrue);
      expect(kernel.rollbackAppearance(), isA<Success<AppearanceState>>());
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

  group('天气装扮（P2-3）', () {
    // 1/1 是冬：启动后已穿 winter，天气 rain 才值得建议。
    WeatherOutfitService rainyService() => WeatherOutfitService(
      client: MockClient(
        (_) async => http.Response(
          '{"current_condition":[{"weatherCode":"293"}]}',
          200,
        ),
      ),
      clock: () => now,
    );

    test('开关默认关：启动后不发任何天气请求', () async {
      var requests = 0;
      final kernel = buildKernel(
        weatherOutfit: WeatherOutfitService(
          client: MockClient((_) async {
            requests++;
            return http.Response('{}', 200);
          }),
          clock: () => now,
        ),
      )..start();
      await pumpEventQueue();

      expect(
        kernel.appearanceState.weatherSource,
        AppearanceWeatherSource.off,
      );
      expect(requests, 0);
      expect(kernel.weatherSuggestion.value, isNull);
    });

    test('开启后给出建议；确认才换装（source=weather）', () async {
      final kernel = buildKernel(weatherOutfit: rainyService())..start();
      await pumpEventQueue();
      // 开关关着：观察与建议都不存在。
      expect(kernel.weatherSuggestion.value, isNull);

      expect(
        kernel.setWeatherSource(AppearanceWeatherSource.builtin),
        isA<Success<void>>(),
      );
      await pumpEventQueue();
      final suggestion = kernel.weatherSuggestion.value;
      expect(suggestion?.outfit, 'rain');
      expect(suggestion?.reason, contains('有雨'));
      // 建议只是提案：形象还没换。
      expect(kernel.appearanceState.outfit, 'winter');

      kernel.acceptWeatherOutfit();
      expect(kernel.appearanceState.outfit, 'rain');
      expect(
        kernel.appearanceState.outfitSource,
        AppearanceOutfitSource.weather,
      );
      expect(kernel.weatherSuggestion.value, isNull);
      expect(host.bubbles.single, '换好了，这身应景吧');
    });

    test('忽略后当日不再提；开关切换不动修订号（装饰轨道）', () async {
      final kernel = buildKernel(weatherOutfit: rainyService())..start();
      await pumpEventQueue();
      kernel.setWeatherSource(AppearanceWeatherSource.builtin);
      await pumpEventQueue();
      expect(kernel.weatherSuggestion.value, isNotNull);

      kernel.dismissWeatherOutfit();
      // 同日关→开重新触发观察：日键命中「今日已忽略」，不再建议。
      kernel.setWeatherSource(AppearanceWeatherSource.off);
      kernel.setWeatherSource(AppearanceWeatherSource.builtin);
      await pumpEventQueue();
      expect(kernel.weatherSuggestion.value, isNull);
      // 全周期修订号不动：换装不占版本历史额度。
      expect(kernel.appearanceState.revision, 0);
    });
  });

  group('热门趋势装扮（P2-3b）', () {
    // 1/1 是冬：提案提示词带季节背景；固定回复可稳定解析。
    _ReplyProvider trendProvider() => _ReplyProvider(
      '{"theme":"冬日暖阳","main":"#E23E3E","trim":"#F2C14E",'
      '"reason":"暖色围巾呼应初冬氛围"}',
    );

    TrendOutfitStore gateStore() => TrendOutfitStore(
      directory: Directory('${tmpDir.path}/profile'),
    );

    test('默认关：开启前零 LLM 调用', () async {
      final provider = trendProvider();
      buildKernel(provider: provider).start();
      await pumpEventQueue();

      expect(provider.systems, isEmpty);
    });

    test('开启后挂建议；接受才换装（source=trend）并记周', () async {
      final kernel = buildKernel(provider: trendProvider())..start();
      await pumpEventQueue();

      expect(
        kernel.setTrendSource(AppearanceTrendSource.builtin),
        isA<Success<void>>(),
      );
      await pumpEventQueue();
      final proposal = kernel.trendSuggestion.value;
      expect(proposal?.outfit, 'trend-冬日暖阳');
      // 提案不自动穿：当前仍是启动换上的冬装。
      expect(kernel.appearanceState.outfit, 'winter');

      kernel.acceptTrendOutfit();
      expect(kernel.appearanceState.outfit, 'trend-冬日暖阳');
      expect(
        kernel.appearanceState.outfitSource,
        AppearanceOutfitSource.trend,
      );
      expect(kernel.trendSuggestion.value, isNull);
      expect(host.bubbles.single, contains('冬日暖阳'));
      // 换装不动修订号（装饰轨道不占版本历史额度）。
      expect(kernel.appearanceState.revision, 0);
      // 提案已记周：本周内不会再提。
      expect(gateStore().load().lastProposedWeek, trendWeekKey(now));
    });

    test('周限与冷却短路：预置治理状态后不再调 LLM', () async {
      // 本周已提。
      gateStore().save(TrendGate(lastProposedWeek: trendWeekKey(now)));
      var provider = trendProvider();
      var kernel = buildKernel(provider: provider)..start();
      await pumpEventQueue();
      kernel.setTrendSource(AppearanceTrendSource.builtin);
      await pumpEventQueue();
      expect(provider.systems, isEmpty);
      expect(kernel.trendSuggestion.value, isNull);

      // 拒绝冷却中（截止在未来 6 天）。
      gateStore().save(
        TrendGate(
          rejectedUntilMs: now
              .add(const Duration(days: 6))
              .millisecondsSinceEpoch,
        ),
      );
      provider = trendProvider();
      kernel = buildKernel(provider: provider)..start();
      await pumpEventQueue();
      kernel.setTrendSource(AppearanceTrendSource.builtin);
      await pumpEventQueue();
      expect(provider.systems, isEmpty);
    });

    test('LLM 坏输出不烧周额度；拒绝落 7 天冷却', () async {
      final kernel =
          buildKernel(provider: _ReplyProvider('这不是 JSON'))..start();
      await pumpEventQueue();
      kernel.setTrendSource(AppearanceTrendSource.builtin);
      await pumpEventQueue();
      expect(kernel.trendSuggestion.value, isNull);
      // 没记周：明天日终观察还能重试。
      expect(gateStore().load().lastProposedWeek, isNull);

      // 正常提案 → 拒绝：冷却落盘（保留已记的周键）。
      final kernel2 = buildKernel(provider: trendProvider())..start();
      await pumpEventQueue();
      kernel2.setTrendSource(AppearanceTrendSource.builtin);
      await pumpEventQueue();
      expect(kernel2.trendSuggestion.value, isNotNull);
      kernel2.rejectTrendOutfit();
      expect(kernel2.trendSuggestion.value, isNull);
      final gate = gateStore().load();
      expect(gate.lastProposedWeek, trendWeekKey(now));
      expect(
        gate.rejectedUntilMs,
        now.add(trendRejectCooldown).millisecondsSinceEpoch,
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
        metrics: MetricsStore(
          directory: Directory('${tmpDir.path}/learning'),
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

  group('日程维护', () {
    test('start 即写当日指标快照，跨天 decayOnce 补写新一天并归档旧记忆', () {
      final memory = MemoryStore(directory: Directory('${tmpDir.path}/memory'))
        ..add(
          // 创建满 30 天（阈值边界）：第一天判定用 >30 不归档，跨天即超龄。
          MemoryEntry(
            id: 'm-old',
            kind: MemoryKind.episode,
            content: '上个月的一次构建失败',
            createdAt: DateTime(2025, 12, 2),
          ),
        );
      final metrics = MetricsStore(
        directory: Directory('${tmpDir.path}/learning'),
        clock: () => now,
      );
      final kernel = AssistantKernel(
        gateway: InteractionGateway(
          dispatcher: Dispatcher(
            registry: AdapterRegistry(const {}),
            activeId: '',
          ),
          router: LlmRouter(providers: const []),
        ),
        store: ProfileStore(directory: tmpDir),
        host: host,
        privacy: PrivacyCenter(directory: tmpDir),
        memory: memory,
        vectors: MemoryVectorStore.disabled(),
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
        metrics: metrics,
        appearanceStore: AppearanceStore(
          directory: Directory('${tmpDir.path}/profile'),
        ),
        clock: () => now,
      )..start();

      // 启动即落第一条快照，当天再跑 decayOnce 也只 upsert 同一天。
      expect(metrics.days(), hasLength(1));
      expect(metrics.latest()!.date, '2026-01-01');
      expect(metrics.latest()!.memoryActive, 1);
      kernel.decayOnce();
      expect(metrics.days(), hasLength(1));

      // 跨天：episode 超 30 天被归档，快照序列补上新一天。
      now = DateTime(2026, 1, 2, 12, 0);
      kernel.decayOnce();
      expect(memory.entries(status: MemoryStatus.archived), hasLength(1));
      expect(metrics.days().map((day) => day.date), [
        '2026-01-01',
        '2026-01-02',
      ]);
      expect(metrics.latest()!.memoryActive, 0);
      expect(metrics.latest()!.memoryArchived, 1);
    });
  });

  group('待确认队列触达', () {
    test('空队列完全静默：不冒气泡', () {
      final kernel = buildKernel()..start();
      expect(kernel.pendingConfirmationCount, 0);
      kernel.notifyPendingConfirmations();
      expect(host.bubbles, isEmpty);
    });

    test('有积压冒可点开面板的气泡，冷却窗口内不重复', () {
      final memory = MemoryStore(directory: Directory('${tmpDir.path}/memory'))
        ..add(
          MemoryEntry(
            id: 'm-pending',
            kind: MemoryKind.preference,
            content: '称呼偏好：老板',
            createdAt: now,
            status: MemoryStatus.pending,
            source: 'llm',
          ),
        );
      final kernel = AssistantKernel(
        gateway: InteractionGateway(
          dispatcher: Dispatcher(
            registry: AdapterRegistry(const {}),
            activeId: '',
          ),
          router: LlmRouter(providers: const []),
        ),
        store: ProfileStore(directory: tmpDir),
        host: host,
        privacy: PrivacyCenter(directory: tmpDir),
        memory: memory,
        vectors: MemoryVectorStore.disabled(),
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
        metrics: MetricsStore(
          directory: Directory('${tmpDir.path}/learning'),
          clock: () => now,
        ),
        appearanceStore: AppearanceStore(
          directory: Directory('${tmpDir.path}/profile'),
        ),
        clock: () => now,
      )..start();

      // start（→ housekeeping）就该触达一次：重启时积压要提醒。
      expect(kernel.pendingConfirmationCount, 1);
      expect(host.bubbles.single, contains('1 条学习心得'));
      expect(host.lastBubbleTap, isNotNull);

      // 点击“去看看”：收气泡 + 打开待确认面板。
      host.lastBubbleTap!();
      expect(host.panelOpens, 1);

      // 冷却窗口内的重复触发被节流。
      kernel.notifyPendingConfirmations();
      expect(host.bubbles, hasLength(1));

      // 窗口过后恢复触达。
      now = now.add(const Duration(hours: 6, minutes: 1));
      kernel.notifyPendingConfirmations();
      expect(host.bubbles, hasLength(2));
    });
  });

  group('语义召回（P1-4）', () {
    test('对话后增量同步建索引，下一轮语义命中注入', () async {
      final memory = MemoryStore(directory: Directory('${tmpDir.path}/memory'))
        ..add(
          MemoryEntry(
            id: 'm-cat',
            kind: MemoryKind.fact,
            content: '养了只橘猫叫蛋黄',
            createdAt: now,
          ),
        );
      final vectors = MemoryVectorStore.openInMemory();
      final embedder = _FakeEmbedder();
      final provider = _ReplyProvider('[[sentiment:positive]]\n好的。');
      final gateway = InteractionGateway(
        dispatcher: Dispatcher(
          registry: AdapterRegistry(const {}),
          activeId: '',
        ),
        router: LlmRouter(providers: [provider], activeId: 'fake'),
      );
      final kernel = AssistantKernel(
        gateway: gateway,
        store: ProfileStore(directory: tmpDir),
        host: host,
        privacy: PrivacyCenter(directory: tmpDir),
        memory: memory,
        vectors: vectors,
        embeddingLoader: () => embedder,
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
        metrics: MetricsStore(
          directory: Directory('${tmpDir.path}/learning'),
          clock: () => now,
        ),
        appearanceStore: AppearanceStore(
          directory: Directory('${tmpDir.path}/profile'),
        ),
        clock: () => now,
      )..start();

      // 第一轮：启动维护的 unawaited 同步可能先于上下文构建完成，也
      // 可能赶不上——两种顺序都合法，这里只保证对话成功并泵完队列。
      final first = await gateway.chat('我出差三天宠物怎么办');
      expect(first.ok, isTrue);
      await pumpEventQueue();

      // 第二轮：query 与记忆同向（fake 恒 [1.0, 0.0]，距离 0）→ 语义
      // 命中注入。该 query 与记忆零关键词交集，注入只可能来自语义路径。
      final second = await gateway.chat('我出差三天宠物怎么办');
      expect(second.ok, isTrue);
      expect(provider.systems.last, contains('橘猫'));
      expect(embedder.calls, greaterThanOrEqualTo(2)); // 同步 + query 各 ≥1
      kernel.dispose();
    });
  });

  group('影子措辞优化（P1-5）', () {
    test('低效准则触发影子试验：候选与原文交替注入', () async {
      final guidelines = GuidelineStore(
        directory: Directory('${tmpDir.path}/learning'),
      )..load();
      guidelines.propose(
        Guideline(
          id: 'g1',
          title: '风格',
          content: '原文措辞',
          createdAt: now,
        ),
      );
      guidelines.accept('g1');
      // 注入 5 次 + 1 次采纳：接受率 100%，还谈不上低效。
      for (var i = 0; i < 5; i++) {
        guidelines.markUsed(guidelines.active);
      }
      guidelines.recordInjectionOutcome(accepted: true);

      final provider = _ReplyProvider(
        '好的',
        rewriteReply: '{"candidates":["候选措辞一","候选措辞二"]}',
      );
      final kernel = buildKernel(guidelines: guidelines, provider: provider)
        ..start();

      // 拒绝反馈（带纠正文本确保成功）把接受率压到 50%：
      // 触发 deep 生成候选并开影子试验。
      kernel.rejectReply(correction: '太啰嗦了');
      await pumpEventQueue();
      expect(
        provider.systems.where((s) => s.contains('措辞优化助手')),
        hasLength(1),
        reason: '低效准则应触发一次候选生成',
      );

      // 影子轮换注入：第一轮 base 原文、第二轮候选一，用户无感知。
      final first = await kernel.chat('第一句');
      final second = await kernel.chat('第二句');
      expect(first.ok && second.ok, isTrue);
      final dialogSystems = provider.systems
          .where((s) => !s.contains('措辞优化助手'))
          .toList();
      expect(dialogSystems[dialogSystems.length - 2], contains('原文措辞'));
      expect(dialogSystems.last, contains('候选措辞一'));
      kernel.dispose();
    });

    test('高效准则不触发候选生成；无提供者时静默跳过', () async {
      final guidelines = GuidelineStore(
        directory: Directory('${tmpDir.path}/learning'),
      )..load();
      guidelines.propose(
        Guideline(
          id: 'g1',
          title: '风格',
          content: '原文措辞',
          createdAt: now,
        ),
      );
      guidelines.accept('g1');
      for (var i = 0; i < 3; i++) {
        guidelines.markUsed(guidelines.active);
      }
      // useCount=3 未达门槛：即使全部纠正也不算证据充分。
      guidelines.recordInjectionOutcome(accepted: false);
      final provider = _ReplyProvider('好的');
      final kernel = buildKernel(guidelines: guidelines, provider: provider)
        ..start();
      kernel.rejectReply(correction: '太啰嗦了');
      await pumpEventQueue();
      expect(
        provider.systems.where((s) => s.contains('措辞优化助手')),
        isEmpty,
      );
      kernel.dispose();
    });
  });
}
