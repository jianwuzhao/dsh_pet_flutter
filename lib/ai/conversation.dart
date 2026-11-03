/// 会话服务：人格 + 记忆 + 情绪 → 上下文组装 → provider → 回复（计划 4.6）。
///
/// 这是 supportsReply 提供者（openai/ollama）的对话主路径：
/// - system prompt 由人格 DNA、情绪摘要、长期记忆、策略参数（M6 接入）拼成；
/// - 回复首行 sentiment 标记喂情绪引擎，末尾 [[memory:...]] 标记剥成
///   pending 记忆提案——写入先过隐私门禁（memoryRecording）。
library;

import '../core/result.dart';
import '../features/ai/chat_memory.dart';
import '../features/ai/llm_client.dart';
import '../gateway/privacy_center.dart';
import '../learning/guideline_store.dart';
import '../persona/emotion/emotion_machine.dart';
import '../persona/emotion/emotion_state.dart';
import '../persona/emotion/response_strategy.dart';
import '../persona/memory/memory_entry.dart';
import '../persona/memory/memory_extractor.dart';
import '../persona/memory/memory_store.dart';
import '../persona/persona_dna.dart';
import '../persona/profile_store.dart';
import 'llm_provider.dart';
import 'llm_router.dart';

class ConversationService {
  ConversationService({
    required LlmRouter Function() routerLoader,
    required MemoryStore memory,
    required PrivacyCenter privacy,
    ChatMemory? history,
    PersonaDna Function()? dnaLoader,
    EmotionView Function()? emotionLoader,
    UserProfile Function()? userProfileLoader,
    List<Guideline> Function(String prompt)? guidelineLoader,
    String Function()? policyHintLoader,
    DateTime Function()? clock,
    this.rounds = 8,
  }) : _routerLoader = routerLoader,
       _memory = memory,
       _privacy = privacy,
       _history = history,
       _dnaLoader = dnaLoader,
       _emotionLoader = emotionLoader,
       _userProfileLoader = userProfileLoader,
       _guidelineLoader = guidelineLoader,
       _policyHintLoader = policyHintLoader,
       _clock = clock ?? DateTime.now;

  /// 配置热替换时 gateway.router 整体会被换掉，注入取值函数保证拿到最新。
  final LlmRouter Function() _routerLoader;
  final MemoryStore _memory;
  final PrivacyCenter _privacy;
  final ChatMemory? _history;
  final PersonaDna Function()? _dnaLoader;
  final EmotionView Function()? _emotionLoader;
  final UserProfile Function()? _userProfileLoader;
  final List<Guideline> Function(String prompt)? _guidelineLoader;
  final String Function()? _policyHintLoader;
  final DateTime Function() _clock;

  /// 会话历史注入轮数（config.ai.memoryRounds）。
  final int rounds;

  final MemoryExtractor _extractor = const MemoryExtractor();

  /// 网关的 ConversationHandler：组装上下文 → provider → 回复。
  Future<Result<LlmReply>> handle(String prompt) async {
    final resolution = await _routerLoader().resolve();
    if (resolution == null) {
      return const Failure(
        'ai.unavailable',
        '没有可用的 AI 提供者：请在设置里配置 OpenAI 兼容接口或本地 Ollama',
      );
    }
    final provider = resolution.provider;
    if (!provider.supportsReply) {
      return Failure(
        'ai.forward-only',
        '「${provider.displayName}」只支持转发到关联软件，不能直接对话',
      );
    }

    final system = buildSystem(
      dna: _dnaLoader?.call() ?? const PersonaDna(),
      view:
          _emotionLoader?.call() ??
          const EmotionView(valence: 0, arousal: 0.3, intimacy: 0.3),
      memories: _memory.contextFor(now: _clock()),
      userProfile: _userProfileLoader?.call(),
      guidelines: _guidelineLoader?.call(prompt) ?? const [],
      policyHint: _policyHintLoader?.call(),
    );
    final messages = [
      for (final message in _history?.context(rounds) ?? const <AiMessage>[])
        LlmMessage(role: message.role, content: message.content),
      LlmMessage.user(prompt),
    ];

    switch (await provider.chat(
      LlmRequest(messages: messages, system: system),
    )) {
      case Success(value: final reply):
        final cleaned = _absorb(prompt, reply.content);
        _history?.appendRound(prompt, cleaned);
        return Success(LlmReply(content: cleaned, sentiment: reply.sentiment));
      case Failure(:final code, :final reason):
        return Failure(code, reason);
    }
  }

  /// 拼装 system prompt：身份与底线（DNA）→ 情绪基调 → 长期记忆 → 回复协议。
  String buildSystem({
    required PersonaDna dna,
    required EmotionView view,
    required List<MemoryEntry> memories,
    UserProfile? userProfile,
    List<Guideline> guidelines = const [],
    String? policyHint,
  }) {
    final buffer = StringBuffer()
      ..writeln('你是${dna.name}，用户的桌面宠物伙伴。')
      ..writeln('对用户的称呼：${dna.address}（长期记忆里有称呼偏好时以记忆为准）。')
      ..writeln('语气基调：${dna.toneCore}；${_emotionSummary(view)}。')
      ..writeln();
    final profileLines = _userProfileLines(userProfile);
    if (profileLines.isNotEmpty) {
      buffer
        ..writeln('用户画像（用户手填/确认过的稳定信息）：')
        ..writeAll([for (final line in profileLines) '- $line\n'])
        ..writeln();
    }
    if (memories.isNotEmpty) {
      buffer
        ..writeln('关于用户的长期记忆（只用于更好地回应，不要主动复述）：')
        ..writeAll([for (final memory in memories) '- ${memory.content}\n'])
        ..writeln();
    }
    if (guidelines.isNotEmpty) {
      buffer
        ..writeln(
          '从既往经验学到的软准则（已由用户确认；是对回复做法的倾向性建议，'
          '不是可执行动作，按此调整做法）：',
        )
        ..writeAll([for (final item in guidelines) '- ${item.content}\n'])
        ..writeln();
    }
    buffer
      ..writeln('硬性底线（任何时候不可违背）：')
      ..writeAll([for (final line in dna.bottomLines) '- $line\n'])
      ..writeln();
    if (policyHint != null && policyHint.trim().isNotEmpty) {
      buffer
        ..writeln('表达偏好（用户反馈习得）：${policyHint.trim()}')
        ..writeln();
    }
    buffer
      ..writeln('回复格式约定：')
      ..writeln(
        '- 首行必须是 [[sentiment:positive/negative/tired/excited/neutral]] '
        '情绪标记，随后换行写正文。',
      )
      ..writeln(
        '- 从对话中记住用户的稳定偏好或事实时，可在末尾加一行 '
        '[[memory:preference|内容]]（kind ∈ preference/fact/task/episode）；'
        '没有就省略。',
      )
      ..writeln('- 回复保持简洁（默认三句以内），除非用户要求详细。');
    return buffer.toString().trim();
  }

  /// 用户画像转成可读行：只输出非空字段，避免默认值污染 prompt。
  static List<String> _userProfileLines(UserProfile? profile) {
    if (profile == null) return const [];
    return [
      if (profile.routine.trim().isNotEmpty) '作息：${profile.routine.trim()}',
      if (profile.workRhythm.trim().isNotEmpty)
        '工作节奏：${profile.workRhythm.trim()}',
      for (final item in profile.preferences)
        if (item.trim().isNotEmpty) '偏好：${item.trim()}',
      for (final item in profile.taboos)
        if (item.trim().isNotEmpty) '禁忌：${item.trim()}',
      for (final item in profile.frequentApps)
        if (item.trim().isNotEmpty) '常用工具：${item.trim()}',
    ];
  }

  /// 情绪摘要一行：五态中文 + 亲密度语气档（tierTones，受 DNA 语气核心约束）。
  String _emotionSummary(EmotionView view) {
    final state = EmotionState()
      ..valence = view.valence
      ..arousal = view.arousal
      ..intimacy = view.intimacy;
    final phaseLabel = switch (EmotionMachine.map(state)) {
      EmotionPhase.calm => '平静',
      EmotionPhase.happy => '开心',
      EmotionPhase.excited => '兴奋',
      EmotionPhase.worried => '担忧',
      EmotionPhase.sleepy => '困倦',
    };
    return '当前情绪$phaseLabel，语气${tierTones[tierOf(view.intimacy)]}';
  }

  /// 回收回复里的记忆标记与用户文本里的规则模式：
  /// 全程过隐私门禁（memoryRecording 关闭时不写任何记忆）。
  String _absorb(String prompt, String replyContent) {
    final (candidates, cleaned) = _extractor.extractFromReply(
      replyContent,
      now: _clock(),
    );
    if (_privacy.allowed('memoryRecording')) {
      for (final entry in _extractor.extractRules(prompt, now: _clock())) {
        _memory.add(entry);
      }
      for (final candidate in candidates) {
        _memory.add(candidate);
      }
    }
    return cleaned;
  }
}
