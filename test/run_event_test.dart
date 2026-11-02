import 'package:dsh_pet_flutter/interop/run_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final base = DateTime(2026, 1, 1, 12);

  RunEvent event(
    RunPhase phase, {
    DateTime? at,
    String runId = 'r1',
    int? step,
    int? totalSteps,
  }) => RunEvent(
    runId: runId,
    phase: phase,
    summary: '${runPhaseName(phase)} 阶段',
    at: at ?? base,
    step: step,
    totalSteps: totalSteps,
  );

  group('RunEvent 序列化（沿用 /event 信封）', () {
    test('保留 source/type/state/text，并带 runId/phase/step', () {
      final json = event(RunPhase.act, step: 2, totalSteps: 5).toJson();
      expect(json['source'], 'dafishu');
      expect(json['type'], 'run.progress');
      expect(json['state'], 'running');
      expect(json['text'], 'act 阶段');
      expect(json['runId'], 'r1');
      expect(json['phase'], 'act');
      expect(json['step'], 2);
      expect(json['totalSteps'], 5);
    });

    test('结局阶段映射到既有 state 语义', () {
      expect(event(RunPhase.done).toJson()['state'], 'success');
      expect(event(RunPhase.failed).toJson()['state'], 'error');
      expect(event(RunPhase.cancelled).toJson()['state'], 'error');
      expect(event(RunPhase.waitApproval).toJson()['state'], 'waiting');
    });

    test('解析：缺 runId 或阶段非法返回 null', () {
      expect(RunEvent.fromJson({'type': 'run.progress', 'phase': 'act'}), isNull);
      expect(
        RunEvent.fromJson({'runId': 'r1', 'phase': 'nope'}),
        isNull,
      );
      final parsed = RunEvent.fromJson({
        'runId': 'r1',
        'phase': 'plan',
        'text': '正在拆解目标',
        'ts': '2026-01-01T12:00:00.000',
      });
      expect(parsed!.summary, '正在拆解目标');
      expect(parsed.phase, RunPhase.plan);
    });
  });

  group('RunEventThrottle 节流', () {
    test('同 phase 5s 内只放第一条，超过 5s 才放行', () {
      final throttle = RunEventThrottle();
      expect(throttle.accept(event(RunPhase.act)), isTrue);
      expect(
        throttle.accept(
          event(RunPhase.act, at: base.add(const Duration(seconds: 3))),
        ),
        isFalse,
      );
      expect(
        throttle.accept(
          event(RunPhase.act, at: base.add(const Duration(seconds: 6))),
        ),
        isTrue,
      );
    });

    test('阶段变更立即放行（不受 5s 限制）', () {
      final throttle = RunEventThrottle();
      expect(throttle.accept(event(RunPhase.plan)), isTrue);
      expect(
        throttle.accept(
          event(RunPhase.act, at: base.add(const Duration(seconds: 1))),
        ),
        isTrue,
      );
    });

    test('结局与等待审批必发，即使刚发过同 phase', () {
      final throttle = RunEventThrottle();
      expect(throttle.accept(event(RunPhase.act)), isTrue);
      expect(
        throttle.accept(
          event(RunPhase.waitApproval, at: base.add(const Duration(seconds: 1))),
        ),
        isTrue,
      );
      expect(
        throttle.accept(
          event(RunPhase.done, at: base.add(const Duration(seconds: 2))),
        ),
        isTrue,
      );
    });

    test('单次运行 40 条上限：超出后只允许阶段变更', () {
      final throttle = RunEventThrottle(maxEventsPerRun: 40);
      // 交替 phase 让每条都能通过 5s 规则，凑满 40 条。
      for (var i = 0; i < 40; i++) {
        final phase = i.isEven ? RunPhase.act : RunPhase.observe;
        expect(
          throttle.accept(
            event(phase, at: base.add(Duration(seconds: i * 10))),
          ),
          isTrue,
          reason: '第 $i 条应放行',
        );
      }
      // 第 41 条与上一条同 phase：丢弃。
      expect(
        throttle.accept(
          event(RunPhase.observe, at: base.add(const Duration(seconds: 500))),
        ),
        isFalse,
      );
      // 但阶段变更仍放行。
      expect(
        throttle.accept(
          event(RunPhase.act, at: base.add(const Duration(seconds: 510))),
        ),
        isTrue,
      );
    });

    test('不同 runId 各自独立计数', () {
      final throttle = RunEventThrottle();
      expect(throttle.accept(event(RunPhase.act)), isTrue);
      expect(
        throttle.accept(
          event(RunPhase.act, runId: 'r2', at: base.add(const Duration(seconds: 1))),
        ),
        isTrue,
      );
    });

    test('终态后 forget 清理状态', () {
      final throttle = RunEventThrottle();
      throttle
        ..accept(event(RunPhase.act))
        ..accept(event(RunPhase.done, at: base.add(const Duration(seconds: 1))));
      throttle.forget('r1');
      expect(throttle.accept(event(RunPhase.act, runId: 'r1')), isTrue);
    });

    test('waitApproval 属于结局类：必发', () {
      expect(isRunTerminal(RunPhase.waitApproval), isTrue);
      expect(isRunTerminal(RunPhase.act), isFalse);
      expect(isRunTerminal(RunPhase.observe), isFalse);
    });
  });
}
