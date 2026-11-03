/// 助手内核：四层架构的运行时中枢（计划 4.7）。
///
/// M4 接管情绪四段闭环（感知 → 状态机 → 策略 → 表达）与主动打扰预算：
/// - 输入侧：submit/chat 在转发网关之外喂情绪信号；
/// - 信号侧：任务终态（success/error）与点击/拖拽互动折算成情绪信号；
/// - 表达侧：换态被动表达动画 + worried 持续关心（过隐私门禁与预算）。
/// M5 接管会话服务：人格+记忆+情绪上下文组装挂到网关对话路径，
/// 记忆候选走 pending 队列等用户接受/拒绝，不做无确认写入。
/// M6 接管学习治理：接受/拒绝语义的反馈闭环、策略提案与版本回滚。
/// 形象推演：由情绪三维 + 人格主动性 + 24h 接受/拒绝反馈驱动，
/// 每次最多一步、有冷却与冻结，所有变更可回滚。
/// pet_app 回归纯装配。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ai/conversation.dart';
import '../ai/llm_provider.dart';
import '../core/result.dart';
import '../features/ai/chat_memory.dart';
import '../features/linkage/assistant_adapters.dart';
import '../features/linkage/status/assistant_event.dart';
import '../gateway/interaction_gateway.dart';
import '../gateway/privacy_center.dart';
import '../learning/eval_gate.dart';
import '../learning/evolution_engine.dart';
import '../learning/feedback_collector.dart';
import '../learning/guideline_store.dart';
import '../learning/learning_loop.dart';
import '../learning/llm_reflection_synthesizer.dart';
import '../learning/policy_store.dart';
import '../learning/reflection_store.dart';
import '../persona/appearance/appearance_evolution.dart';
import '../persona/appearance/appearance_proposal.dart';
import '../persona/appearance/appearance_state.dart';
import '../persona/appearance/appearance_store.dart';
import '../persona/emotion/emotion_machine.dart';
import '../persona/emotion/emotion_signal.dart';
import '../persona/emotion/emotion_state.dart';
import '../persona/emotion/interruption_budget.dart';
import '../persona/emotion/response_strategy.dart';
import '../persona/expression/expression_layer.dart';
import '../persona/memory/memory_store.dart';
import '../persona/persona_dna.dart';
import '../persona/profile_store.dart';

class AssistantKernel {
  AssistantKernel({
    required InteractionGateway gateway,
    required ProfileStore store,
    required ExpressionHost host,
    required PrivacyCenter privacy,
    ChatMemory? conversationHistory,
    int conversationRounds = 8,
    MemoryStore? memory,
    LearningLoop? learning,
    ReflectionStore? reflections,
    GuidelineStore? guidelines,
    AppearanceStore? appearanceStore,
    AppearanceEvolution appearanceEvolution = const AppearanceEvolution(),
    DateTime Function()? clock,
  }) : _gateway = gateway,
       _store = store,
       _host = host,
       _privacy = privacy,
       _clock = clock ?? DateTime.now,
       _budget = InterruptionBudget(clock: clock),
       _expression = ExpressionLayer(host: host),
       // 状态机的节流窗基准必须与注入时钟同源，否则测试时钟永远走不满 90s。
       _machine = EmotionMachine(now: clock == null ? null : clock()),
       _memory = memory ?? MemoryStore(),
       _reflections = reflections,
       _guidelines = guidelines,
       _evolution = (reflections == null || guidelines == null)
           ? null
           : EvolutionEngine(
               reflections: reflections,
               guidelines: guidelines,
               clock: clock,
             ),
       _appearanceStore = appearanceStore ?? AppearanceStore(),
       _appearanceEvolution = appearanceEvolution,
       _learning =
           learning ??
           LearningLoop(
             collector: FeedbackCollector(clock: clock),
             policy: PolicyStore(clock: clock),
             host: host,
             gate: const EvalGate(),
             clock: clock,
           ),
       emotion = ValueNotifier(
         const EmotionView(valence: 0, arousal: 0.3, intimacy: 0.3),
       ) {
    _conversation = ConversationService(
      // 取值函数而不是值：配置热替换换掉 gateway.router 后仍能拿到最新。
      routerLoader: () => gateway.router,
      memory: _memory,
      privacy: privacy,
      history: conversationHistory,
      dnaLoader: () => _dna,
      emotionLoader: () => _emotion.view,
      userProfileLoader: () => _userProfile,
      guidelineLoader: (prompt) {
        final store = _guidelines;
        if (store == null) return const <Guideline>[];
        final picked = store.activeFor(prompt);
        // 注入即记账：useCount/lastUsedAt 是有效性追踪的最小信号。
        if (picked.isNotEmpty) store.markUsed(picked);
        return picked;
      },
      // 策略参数只影响表达偏好，不碰身份/隐私/打扰上限等安全边界。
      policyHintLoader: () => _learning.policy.params.promptHint,
      clock: _clock,
      rounds: conversationRounds,
    );
  }

  final InteractionGateway _gateway;
  final ProfileStore _store;
  final ExpressionHost _host;
  final PrivacyCenter _privacy;
  final DateTime Function() _clock;
  final InterruptionBudget _budget;
  final ResponseStrategy _strategy = ResponseStrategy();
  final ExpressionLayer _expression;
  final MemoryStore _memory;
  final ReflectionStore? _reflections;
  final GuidelineStore? _guidelines;
  final EvolutionEngine? _evolution;
  final LearningLoop _learning;
  final AppearanceStore _appearanceStore;
  final AppearanceEvolution _appearanceEvolution;
  late final ConversationService _conversation;

  EmotionState _emotion = EmotionState();
  final EmotionMachine _machine;
  EmotionProfile _profile = const EmotionProfile();
  PersonaDna _dna = const PersonaDna();
  UserProfile _userProfile = const UserProfile();
  DateTime _lastActivityAt = DateTime.now();
  DateTime? _lastTaskSynthesisAt;
  int _lastTaskSynthesisCount = 0;
  bool _synthesizingTaskLessons = false;

  /// 按 source 记连续失败次数：连续 2 次失败立即触发复盘，
  /// 不等凑满 3 条反思——高代价失败的经验不该被普通样本稀释。
  final Map<String, int> _consecutiveFailuresBySource = {};

  /// UI 可监听的情绪快照（三维数值，供画像/调试展示用）。
  final ValueNotifier<EmotionView> emotion;

  /// 当前形象（设置页预览与后续渲染层共用一份事实来源）。
  final ValueNotifier<AppearanceState> appearance = ValueNotifier(
    const AppearanceState(),
  );

  /// 最近一次推演/回滚的可读理由（设置页原样展示「为什么变了」）。
  String _appearanceReason = '';

  /// 待确认的形态提案：最显眼的变化必须用户接受才生效。
  AppearanceProposal? _formProposal;

  Timer? _decayTimer;
  Timer? _careTimer;

  EmotionPhase get phase => _machine.phase;
  EmotionProfile get emotionProfile => _profile;

  /// 记忆库：设置页的查看/纠正/遗忘/导出直接操作这里。
  MemoryStore get memory => _memory;

  /// 学习治理：设置页的策略版本/提案/回滚与记忆提案的反馈采集入口。
  LearningLoop get learning => _learning;

  /// 经验准则：设置页的待确认/已生效/停用入口。
  GuidelineStore? get guidelines => _guidelines;

  /// 反思流水：设置页展示计数，后续复盘任务读取。
  ReflectionStore? get reflections => _reflections;

  int get reflectionCount => _evolution?.reflectionCount ?? 0;

  Result<Guideline> acceptGuideline(String id) =>
      _guidelines?.accept(id) ??
      const Failure('guideline.offline', '经验准则还没准备好');

  Result<void> rejectGuideline(String id) =>
      _guidelines?.reject(id) ??
      const Failure('guideline.offline', '经验准则还没准备好');

  Result<void> archiveGuideline(String id) =>
      _guidelines?.archiveActive(id) ??
      const Failure('guideline.offline', '经验准则还没准备好');

  /// 当前人格 DNA（设置页展示与保存用）。
  PersonaDna get dna => _dna;

  /// 设置页保存人格：写盘成功才改内存；会话服务通过 loader 立即读到新值。
  Result<void> savePersonaDna(PersonaDna value) {
    final result = _store.savePersonaDna(value);
    if (result is Success<void>) _dna = value;
    return result;
  }

  /// 形象当前值（渲染与设置页都以它为准）。
  AppearanceState get appearanceState => appearance.value;

  /// 最近一次推演的可读理由。
  String get appearanceReason => _appearanceReason;

  /// 待确认的形态提案（null = 没有）。
  AppearanceProposal? get formProposal => _formProposal;

  /// 回复被采纳：用户把建议落地了（记正样本，参与自动回滚监控）。
  void acceptReply() {
    _learning.acceptReply();
    if (_privacy.allowed('memoryRecording')) _evolution?.recordAccept();
  }

  /// 回复被拒绝（重说）；可附一句纠正，规则解析后可能生成策略/准则提案。
  void rejectReply({String correction = ''}) {
    _learning.rejectReply(correction: correction);
    if (_privacy.allowed('memoryRecording')) {
      _evolution?.recordCorrection(correction);
    }
  }

  /// 碎碎念：与聊天共用人格/记忆/情绪/策略与同一 provider 路径，
  /// 但只取一句话，不写入 ChatMemory（避免碎碎念污染对话历史）。
  Future<Result<String>> whisper() async {
    final resolution = await _gateway.router.resolve();
    if (resolution == null) {
      return const Failure(
        'ai.unavailable',
        '没有可用的 AI 提供者：请在设置里配置 OpenAI 兼容接口、DeepSeek 或本地 Ollama',
      );
    }
    final provider = resolution.provider;
    if (!provider.supportsReply) {
      return Failure(
        'ai.forward-only',
        '「${provider.displayName}」只支持转发，不能生成碎碎念',
      );
    }
    final system = _conversation.buildSystem(
      dna: _dna,
      view: _emotion.view,
      memories: _memory.contextFor(now: _clock()),
      userProfile: _userProfile,
      guidelines: _guidelines?.activeFor('') ?? const <Guideline>[],
      policyHint: _learning.policy.params.promptHint,
    );
    final result = await provider.chat(
      LlmRequest(
        messages: const [LlmMessage.user('用一句不超过 25 字的中文说一句此刻的碎碎念，不要提问，不要解释。')],
        system: system,
      ),
    );
    switch (result) {
      case Success(value: final reply):
        final content = LlmReply.parse(reply.content).content;
        if (content.trim().isEmpty) {
          return const Failure('ai.empty', 'AI 返回了空碎碎念');
        }
        return Success(content.trim());
      case Failure(:final code, :final reason):
        return Failure(code, reason);
    }
  }

  int get _taskReflectionCount =>
      _reflections
          ?.load()
          .where((entry) => entry.kind == ReflectionKind.task)
          .length ??
      0;

  /// 每累计 3 条新任务反思、且距上次总结超过 10 分钟，才尝试一次模型复盘。
  /// [force] = true 时跳过“3 条新反思”门槛（连续失败专用通道），
  /// 但仍受 10 分钟冷却与并发闸约束。失败不阻塞任务；产出只进待确认队列。
  Future<void> _maybeSynthesizeTaskLessons({bool force = false}) async {
    if (_synthesizingTaskLessons ||
        _reflections == null ||
        _guidelines == null ||
        _evolution == null) {
      return;
    }
    if (!_privacy.allowed('memoryRecording')) return;
    final count = _taskReflectionCount;
    if (!force && count - _lastTaskSynthesisCount < 3) return;
    final now = _clock();
    final last = _lastTaskSynthesisAt;
    if (last != null && now.difference(last) < const Duration(minutes: 10)) {
      return;
    }
    final resolution = await _gateway.router.resolve();
    if (resolution == null || !resolution.provider.supportsReply) return;

    _synthesizingTaskLessons = true;
    try {
      final tasks = _reflections
          .load()
          .where((entry) => entry.kind == ReflectionKind.task)
          .toList(growable: false);
      final recent = tasks.length <= 10
          ? tasks
          : tasks.sublist(tasks.length - 10);
      final result = await LlmReflectionSynthesizer(
        resolution.provider,
      ).synthesize(recent);
      switch (result) {
        case Success(value: final drafts):
          final added = _evolution.proposeTaskLessons(drafts);
          _lastTaskSynthesisAt = _clock();
          _lastTaskSynthesisCount = count;
          if (added > 0) {
            _host.showBubble('总结了 $added 条任务经验，去设置页确认');
          }
        case Failure(:final code, :final reason):
          // 失败也记录时间，避免每个终态都重试；下一批任务再试。
          _lastTaskSynthesisAt = _clock();
          _lastTaskSynthesisCount = count;
          debugPrint('[dafishu] 任务复盘失败：[$code] $reason');
      }
    } finally {
      _synthesizingTaskLessons = false;
    }
  }

  /// 自动形象推演：由装配层在任务终态/用户反馈后调用。
  /// 冷却、冻结、信号阈值都在 [evolveAppearance] 内；这里只负责“有机会就试一次”。
  EvolutionOutcome maybeEvolveAppearance() {
    // 已有待确认提案时不再反复提醒，避免每个状态终态都冒一条气泡。
    if (_formProposal != null) return evolveAppearance();
    final outcome = evolveAppearance();
    if (outcome.proposal != null) {
      _host.showBubble('有一个形态建议，去设置页看看要不要接受');
    }
    return outcome;
  }

  /// 主动关心气泡被提前关闭：拒绝样本；自然过期不记。
  void dismissCare() => _learning.dismissCare();

  /// 启动：读人格 DNA 与情绪档案（失败气泡报错、保持默认值不写盘），
  /// 再挂上衰减（60s/拍）与主动关心巡检（30s/拍）两个周期任务，
  /// 最后把会话服务挂到网关对话路径。
  void start() {
    _gateway.conversation = _conversation.handle;
    _guidelines?.load();
    _lastTaskSynthesisCount = _taskReflectionCount;
    switch (_store.loadPersonaDna()) {
      case Success(value: final dna):
        _dna = dna;
      case Failure(:final reason):
        _host.showBubble('人格 DNA 读取失败：$reason');
    }
    switch (_store.loadEmotionProfile()) {
      case Success(value: final profile):
        _profile = profile;
        _emotion = EmotionState(intimacyBaseline: profile.intimacyBaseline);
      case Failure(:final reason):
        _host.showBubble('情绪档案读取失败：$reason');
    }
    switch (_store.loadUserProfile()) {
      case Success(value: final profile):
        _userProfile = profile;
      case Failure(:final reason):
        // 画像损坏不阻塞启动：用空画像继续，但明确告知而不是静默。
        _host.showBubble('用户画像读取失败：$reason');
    }
    switch (_appearanceStore.load()) {
      case Success(value: final state):
        appearance.value = state;
      case Failure(:final reason):
        // 形象直接影响渲染：读不出来就先用默认值，并明确告知不是「宠物变异了」。
        _host.showBubble('形象档案读取失败，先用默认形象：$reason');
    }
    switch (_appearanceStore.loadProposal()) {
      case Success(value: final proposal):
        _formProposal = proposal;
      case Failure(:final reason):
        _host.showBubble('形态提案读取失败：$reason');
    }
    if (!_profile.emotionEnabled) _machine.reset(now: _clock());
    _lastActivityAt = _clock();
    emotion.value = _emotion.view;
    _decayTimer?.cancel();
    _decayTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => decayOnce(),
    );
    _careTimer?.cancel();
    _careTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => checkProactiveCare(),
    );
  }

  /// 统一输入入口（面板/热键/事件服务）：先喂互动信号与文本启发式，
  /// 再原样走网关——网关行为完全不变，情绪感知是纯增量。
  Future<Result<DispatchOutcome>> submit(String text, InputSource source) {
    applySignal(EmotionSignal.interaction);
    final guessed = guessSignalFromText(text);
    if (guessed != null) applySignal(guessed);
    return _gateway.submit(text, source);
  }

  /// `/v2/chat`：回复失败直接返回；成功时优先用模型自报的情绪标签，
  /// 缺失再退回文本启发式。
  Future<GatewayChatReply> chat(String text) async {
    final reply = await _gateway.chat(text);
    if (!reply.ok) return reply;
    final signal =
        signalFromSentiment(reply.sentiment) ?? guessSignalFromText(text);
    if (signal != null) applySignal(signal);
    return reply;
  }

  /// 联动状态流：只有终态（任务成功/失败）才折算成情绪信号（计划 4.2）。
  void onStatusSnapshot(StatusSnapshot? snapshot) {
    if (snapshot == null || !snapshot.isTerminal) return;
    applySignal(
      snapshot.state == AssistantStatus.success
          ? EmotionSignal.positiveFeedback
          : EmotionSignal.negativeFeedback,
    );
    if (_privacy.allowed('memoryRecording')) {
      _evolution?.recordStatus(snapshot);
      final failures = snapshot.state == AssistantStatus.error
          ? (_consecutiveFailuresBySource[snapshot.source] ?? 0) + 1
          : 0;
      _consecutiveFailuresBySource[snapshot.source] = failures;
      if (failures >= 2) {
        // 计数清零：再触发需要新的连续两次失败；10 分钟冷却兜底限频。
        _consecutiveFailuresBySource[snapshot.source] = 0;
        unawaited(_maybeSynthesizeTaskLessons(force: true));
        return;
      }
      unawaited(_maybeSynthesizeTaskLessons());
    }
  }

  /// 点击（面板关闭时）/拖拽开始的互动信号入口。
  void notifyInteraction() => applySignal(EmotionSignal.interaction);

  /// 应用一个情绪信号并同步状态机；情绪引擎总开关关闭时全部丢弃。
  void applySignal(EmotionSignal signal) {
    if (!_profile.emotionEnabled) return;
    final impulse = _emotion.apply(signal, now: _clock());
    _lastActivityAt = _clock();
    _syncPhase(impulse: impulse);
  }

  /// 衰减一拍（timer 调用；公开以便离线测试）：
  /// 三维回归基线，空闲超半小时再压唤醒。
  void decayOnce() {
    _emotion.decayTick();
    if (_clock().difference(_lastActivityAt) > const Duration(minutes: 30)) {
      _emotion.applyIdleFatigue();
    }
    _syncPhase();
  }

  /// 主动关心巡检（timer 调用；公开以便离线测试）：
  /// worried 持续 >3min → 隐私门禁 → 打扰预算 → 话术挑选 → 表达+记账。
  void checkProactiveCare() {
    final profile = _profile;
    if (!profile.emotionEnabled) return;
    if (_machine.phase != EmotionPhase.worried) return;
    if (_machine.worriedFor(now: _clock()) <= const Duration(minutes: 3)) {
      return;
    }
    if (!_privacy.allowed('proactiveCare')) return;
    if (!_budget.allow(
      profile,
      phase: EmotionPhase.worried,
      proactiveness: _dna.proactiveness,
    )) {
      return;
    }
    final decision = _strategy.care(
      profile,
      phase: EmotionPhase.worried,
      tier: tierOf(_emotion.intimacy),
      expressionSet: appearance.value.expressionSet,
    );
    // 话术全被回避话题过滤：宁可不表达（踩雷区比沉默糟糕）。
    if (decision == null) return;
    _expression.perform(decision, now: _clock());
    _profile = _budget.consume(profile, phase: EmotionPhase.worried);
    switch (_store.saveEmotionProfile(_profile)) {
      case Success():
        break;
      case Failure(:final reason):
        _host.showBubble('情绪档案保存失败：$reason');
    }
  }

  /// 设置页保存情绪档案：写盘成功才改内存；换基线不重置当前三维，
  /// 只让亲密度的慢回归朝新目标走；总开关从开到关时状态机复位。
  Result<void> saveEmotionProfile(EmotionProfile value) {
    final result = _store.saveEmotionProfile(value);
    if (result is Failure<void>) return result;
    final wasEnabled = _profile.emotionEnabled;
    _profile = value;
    final next = EmotionState(intimacyBaseline: value.intimacyBaseline)
      ..valence = _emotion.valence
      ..arousal = _emotion.arousal
      ..intimacy = _emotion.intimacy;
    _emotion = next;
    if (wasEnabled && !value.emotionEnabled) _machine.reset(now: _clock());
    _syncPhase();
    return const Success(null);
  }

  /// 推演一次形象：情绪三维 + 人格主动性 + 24h 反馈计数 → 纯函数决策。
  ///
  /// 四道护栏都在 [AppearanceEvolution] 内：冻结优先、12h 冷却、
  /// 单次只改一维、信号不足不动。这里只负责汇总信号与落盘。
  EvolutionOutcome evolveAppearance() {
    final pending = _formProposal;
    if (pending != null) {
      _appearanceReason = '已有一条待确认的形态提案，先处理它再继续推演';
      return EvolutionOutcome(
        state: appearance.value,
        changed: false,
        reason: _appearanceReason,
        proposal: pending,
      );
    }
    final now = _clock();
    final outcome = _appearanceEvolution.evolve(
      appearance.value,
      AppearanceSignals(
        valence: _emotion.valence,
        arousal: _emotion.arousal,
        intimacy: _emotion.intimacy,
        proactiveness: _dna.proactiveness,
        acceptedCount: _feedbackCount(FeedbackVerdict.accepted, now),
        rejectedCount: _feedbackCount(FeedbackVerdict.rejected, now),
        correctedCount: _feedbackCount(FeedbackVerdict.corrected, now),
        now: now,
      ),
    );
    _appearanceReason = outcome.reason;
    if (outcome.proposal != null) {
      final saved = _appearanceStore.saveProposal(outcome.proposal!);
      if (saved is Failure<void>) {
        _host.showBubble('形态提案保存失败：${saved.reason}');
        _appearanceReason = saved.reason;
        return EvolutionOutcome(
          state: appearance.value,
          changed: false,
          reason: saved.reason,
        );
      }
      _formProposal = outcome.proposal;
      return outcome;
    }
    if (!outcome.changed) return outcome;
    if (_appearanceStore.history().isEmpty) {
      // 首次演化：先把「演化前」的形象留档，回滚才有上一版可回。
      _appearanceStore.save(appearance.value);
    }
    final saved = _appearanceStore.save(outcome.state);
    if (saved is Failure<void>) {
      // 没写进盘就不改内存：避免界面显示一个重启后不存在的形象。
      _host.showBubble('形象保存失败，这次推演没有生效：${saved.reason}');
      _appearanceReason = saved.reason;
      return EvolutionOutcome(
        state: appearance.value,
        changed: false,
        reason: saved.reason,
      );
    }
    appearance.value = outcome.state;
    return outcome;
  }

  /// 回滚到上一版形象（回滚本身也留痕，修订号继续递增）。
  Result<AppearanceState> rollbackAppearance() {
    final result = _appearanceStore.rollback();
    switch (result) {
      case Success(value: final state):
        appearance.value = state;
        _appearanceReason = '已回滚到上一版（修订 ${state.revision}）';
      case Failure(:final reason):
        _appearanceReason = reason;
    }
    return result;
  }

  /// 冻结/解冻自动演化；冻结后手动回滚仍然可用。
  Result<void> setAppearanceFrozen(bool frozen) {
    final next = appearance.value.copyWith(frozen: frozen);
    // 冻结不是一次外观变化：不写历史、不动修订号，避免污染回滚链。
    final result = _appearanceStore.save(next, recordHistory: false);
    if (result is Success<void>) appearance.value = next;
    _appearanceReason = frozen ? '已冻结：自动演化暂停' : '已解冻：下次推演恢复';
    return result;
  }

  /// 接受形态提案：以「当前形象 + 目标形态」生成新版本，接受本身也留痕。
  Result<AppearanceState> acceptFormProposal() {
    final proposal = _formProposal;
    if (proposal == null) {
      return const Failure('appearance.no-proposal', '没有待确认的形态提案');
    }
    final next = appearance.value.copyWith(
      form: proposal.targetForm,
      revision: appearance.value.revision + 1,
      updatedAtMs: _clock().millisecondsSinceEpoch,
    );
    if (_appearanceStore.history().isEmpty) {
      // 提案生效是第一次真实变化时，同样把「变更前」留档供回滚。
      _appearanceStore.save(appearance.value);
    }
    final saved = _appearanceStore.save(next);
    if (saved is Failure<void>) {
      _appearanceReason = saved.reason;
      return AppearanceStore.failureAs<AppearanceState>(saved);
    }
    final cleared = _appearanceStore.clearProposal();
    if (cleared is Failure<void>) {
      _host.showBubble('形态提案已生效，但提案文件没清掉：${cleared.reason}');
    }
    _formProposal = null;
    appearance.value = next;
    _appearanceReason = '已采纳形态提案：${proposal.targetForm.name}';
    return Success(next);
  }

  /// 拒绝形态提案：只删提案文件，不动当前形象，也不产生反馈样本。
  Result<void> rejectFormProposal() {
    if (_formProposal == null) {
      return const Failure('appearance.no-proposal', '没有待确认的形态提案');
    }
    final result = _appearanceStore.clearProposal();
    switch (result) {
      case Success():
        _formProposal = null;
        _appearanceReason = '已拒绝形态提案，保持当前形态';
      case Failure(:final reason):
        _appearanceReason = reason;
    }
    return result;
  }

  /// 24h 内的某类反馈条数：只读学习流水，不产生新样本。
  int _feedbackCount(FeedbackVerdict verdict, DateTime now) {
    final since = now.subtract(const Duration(hours: 24));
    return _learning.collector
        .load()
        .where((event) => event.verdict == verdict && event.at.isAfter(since))
        .length;
  }

  void dispose() {
    _decayTimer?.cancel();
    _careTimer?.cancel();
    emotion.dispose();
    appearance.dispose();
  }

  /// 状态机同步 + 换态时的被动表达（纯动画，不说话、不耗预算）。
  void _syncPhase({double impulse = 0}) {
    final previous = _machine.phase;
    final phase = _machine.update(_emotion, impulse: impulse, now: _clock());
    emotion.value = _emotion.view;
    if (phase != previous) {
      _expression.perform(
        _strategy.passive(phase, expressionSet: appearance.value.expressionSet),
        now: _clock(),
      );
    }
  }
}
