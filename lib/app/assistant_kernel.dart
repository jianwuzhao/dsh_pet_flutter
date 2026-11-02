/// 助手内核：四层架构的运行时中枢（计划 4.7）。
///
/// M4 接管情绪四段闭环（感知 → 状态机 → 策略 → 表达）与主动打扰预算：
/// - 输入侧：submit/chat 在转发网关之外喂情绪信号；
/// - 信号侧：任务终态（success/error）与点击/拖拽互动折算成情绪信号；
/// - 表达侧：换态被动表达动画 + worried 持续关心（过隐私门禁与预算）。
/// 会话与记忆是 M5 的占位、学习治理是 M6 的占位；pet_app 回归纯装配。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/result.dart';
import '../features/linkage/assistant_adapters.dart';
import '../features/linkage/status/assistant_event.dart';
import '../gateway/interaction_gateway.dart';
import '../gateway/privacy_center.dart';
import '../persona/emotion/emotion_machine.dart';
import '../persona/emotion/emotion_signal.dart';
import '../persona/emotion/emotion_state.dart';
import '../persona/emotion/interruption_budget.dart';
import '../persona/emotion/response_strategy.dart';
import '../persona/expression/expression_layer.dart';
import '../persona/persona_dna.dart';
import '../persona/profile_store.dart';

class AssistantKernel {
  AssistantKernel({
    required InteractionGateway gateway,
    required ProfileStore store,
    required ExpressionHost host,
    required PrivacyCenter privacy,
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
       emotion = ValueNotifier(
         const EmotionView(valence: 0, arousal: 0.3, intimacy: 0.3),
       );

  final InteractionGateway _gateway;
  final ProfileStore _store;
  final ExpressionHost _host;
  final PrivacyCenter _privacy;
  final DateTime Function() _clock;
  final InterruptionBudget _budget;
  final ResponseStrategy _strategy = ResponseStrategy();
  final ExpressionLayer _expression;

  EmotionState _emotion = EmotionState();
  final EmotionMachine _machine;
  EmotionProfile _profile = const EmotionProfile();
  PersonaDna _dna = const PersonaDna();
  DateTime _lastActivityAt = DateTime.now();

  /// UI 可监听的情绪快照（三维数值，供画像/调试展示用）。
  final ValueNotifier<EmotionView> emotion;

  Timer? _decayTimer;
  Timer? _careTimer;

  EmotionPhase get phase => _machine.phase;
  EmotionProfile get emotionProfile => _profile;

  /// 启动：读人格 DNA 与情绪档案（失败气泡报错、保持默认值不写盘），
  /// 再挂上衰减（60s/拍）与主动关心巡检（30s/拍）两个周期任务。
  void start() {
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

  void dispose() {
    _decayTimer?.cancel();
    _careTimer?.cancel();
    emotion.dispose();
  }

  /// 状态机同步 + 换态时的被动表达（纯动画，不说话、不耗预算）。
  void _syncPhase({double impulse = 0}) {
    final previous = _machine.phase;
    final phase = _machine.update(_emotion, impulse: impulse, now: _clock());
    emotion.value = _emotion.view;
    if (phase != previous) {
      _expression.perform(_strategy.passive(phase), now: _clock());
    }
  }
}
