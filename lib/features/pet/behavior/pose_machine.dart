/// 姿态选择：把上游“空闲/转向/移动/随机分类”的权重抽签语义搬过来。
///
/// 与上游一致的两条规则：
/// 1. 抽到分类时，若宠物朝左（已镜像）且该分类 noMirror（带文字），跳过它重抽；
/// 2. 事件动画（workStatus 等）不进随机链，只能显式触发。
library;

import 'dart:math' as math;

import '../../../core/config/animation_manifest.dart';

enum PetPoseKind { idle, turn, move, category, click, drag, event }

class PosePick {
  const PosePick({
    required this.kind,
    required this.animation,
    this.categoryId,
    this.moveParams,
  });

  final PetPoseKind kind;
  final String animation;
  final String? categoryId;
  final MoveParams? moveParams;
}

class PoseMachine {
  PoseMachine(this.manifest, {math.Random? random})
    : _random = random ?? math.Random();

  final AnimationManifest manifest;
  final math.Random _random;

  /// 1 = 面向右，-1 = 面向左（镜像绘制）。
  int facing = 1;

  String? pickIdle() => _pickFrom(manifest.idle);

  String? pickDrag() => _pickFrom(manifest.drag);

  String? pickClick() => _pickFrom(manifest.clicks);

  String? pickTurn() => _pickFrom(manifest.turn);

  /// 从随机链抽下一段：idle / 转向 / 移动 / 分类动作。
  PosePick? rollNext({bool fixed = false}) {
    final weights = manifest.weights;
    final turnWeight = fixed ? 0.0 : weights.turn;
    final moveWeight = fixed ? 0.0 : weights.move;
    final idleWeight = weights.idle;

    // 固定模式：转向/移动的份额并入随机分类（上游同款处理）
    var categoryBudget = manifest.categories.fold<double>(
      0,
      (sum, c) => sum + c.weight,
    );
    if (fixed) categoryBudget = math.max(categoryBudget, 0);

    final total = idleWeight + turnWeight + moveWeight + categoryBudget;
    if (total <= 0) return _fallbackIdle();

    var roll = _random.nextDouble() * total;
    if (roll < idleWeight) {
      final name = pickIdle();
      return name == null
          ? _fallbackIdle()
          : PosePick(kind: PetPoseKind.idle, animation: name);
    }
    roll -= idleWeight;

    if (roll < turnWeight) {
      final name = pickTurn();
      return name == null
          ? _fallbackIdle()
          : PosePick(kind: PetPoseKind.turn, animation: name);
    }
    roll -= turnWeight;

    if (roll < moveWeight) {
      final move = _pickMove();
      if (move == null) return _fallbackIdle();
      return PosePick(
        kind: PetPoseKind.move,
        animation: move.name,
        moveParams: move.params,
      );
    }

    final category = _pickCategory();
    if (category == null) return _fallbackIdle();
    final usable = category.actions
        .where(manifest.names.contains)
        .toList(growable: false);
    if (usable.isEmpty) return _fallbackIdle();
    final action = usable[_random.nextInt(usable.length)];
    return PosePick(
      kind: PetPoseKind.category,
      animation: action,
      categoryId: category.id,
    );
  }

  AnimationCategory? _pickCategory() {
    final candidates = manifest.categories
        .where((c) => c.actions.any(manifest.names.contains))
        .where((c) => !(c.noMirror && facing < 0))
        .toList(growable: false);
    if (candidates.isEmpty) return null;
    final total = candidates.fold<double>(0, (sum, c) => sum + c.weight);
    if (total <= 0) return null;
    var roll = _random.nextDouble() * total;
    for (final category in candidates) {
      roll -= category.weight;
      if (roll <= 0) return category;
    }
    return candidates.last;
  }

  MoveAction? _pickMove() {
    final moves = manifest.moves
        .where((m) => manifest.names.contains(m.name))
        .toList(growable: false);
    if (moves.isEmpty) return null;
    return moves[_random.nextInt(moves.length)];
  }

  String? _pickFrom(List<String> pool) {
    final usable = pool.where(manifest.names.contains).toList(growable: false);
    if (usable.isEmpty) return null;
    return usable[_random.nextInt(usable.length)];
  }

  PosePick? _fallbackIdle() {
    final name = manifest.names.isEmpty ? null : manifest.idle.firstOrNull;
    if (name == null) return null;
    return PosePick(kind: PetPoseKind.idle, animation: name);
  }

  /// 工作状态档位 → 动画（档位顺序由清单里的 events.workStatus 决定）。
  String? workStatusAnimation(int index) {
    final pool = manifest.workStatusPool;
    if (index < 0 || index >= pool.length) return null;
    final name = pool[index];
    return manifest.names.contains(name) ? name : null;
  }
}
