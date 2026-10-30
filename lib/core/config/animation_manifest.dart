/// 动画清单模型：由 [tools/gen_manifest.dart] 从上游 `config.jsonc` 生成。
///
/// 清单只描述“有哪些动画、属于哪个角色/分类、权重多少”，不含帧数据本身；
/// 帧由 `FramePlayer` 按需从 webp 解码，因此清单很小、可热改。
library;

import 'dart:convert';

class MoveParams {
  const MoveParams({
    required this.minDist,
    required this.maxDist,
    required this.margin,
    required this.leadSec,
    required this.tailSec,
  });

  final double minDist;
  final double maxDist;
  final double margin;
  final double leadSec;
  final double tailSec;

  factory MoveParams.fromJson(Map<String, dynamic> json, MoveParams fallback) {
    double read(String key, double def) {
      final v = json[key];
      return v is num ? v.toDouble() : def;
    }

    return MoveParams(
      minDist: read('minDist', fallback.minDist),
      maxDist: read('maxDist', fallback.maxDist),
      margin: read('margin', fallback.margin),
      leadSec: read('leadSec', fallback.leadSec),
      tailSec: read('tailSec', fallback.tailSec),
    );
  }
}

class MoveAction {
  const MoveAction({required this.name, required this.params});

  final String name;
  final MoveParams params;
}

class AnimationCategory {
  const AnimationCategory({
    required this.id,
    required this.weight,
    required this.noMirror,
    required this.actions,
  });

  final String id;
  final double weight;
  final bool noMirror;
  final List<String> actions;
}

class AnimationWeights {
  const AnimationWeights({
    required this.idle,
    required this.turn,
    required this.move,
  });

  final double idle;
  final double turn;
  final double move;
}

class AnimationManifest {
  const AnimationManifest({
    required this.width,
    required this.height,
    required this.fps,
    required this.names,
    required this.idle,
    required this.turn,
    required this.drag,
    required this.clicks,
    required this.moveDefault,
    required this.moves,
    required this.categories,
    required this.events,
    required this.weights,
  });

  final int width;
  final int height;
  final double fps;

  /// 磁盘上真实存在的动画名（转码产物）。
  final Set<String> names;

  final List<String> idle;
  final List<String> turn;
  final List<String> drag;
  final List<String> clicks;
  final MoveParams moveDefault;
  final List<MoveAction> moves;
  final List<AnimationCategory> categories;

  /// 事件动画池：workStatus（6 档 = 6 种状态）、whisper、balance。
  final Map<String, List<String>> events;
  final AnimationWeights weights;

  factory AnimationManifest.fromJson(Map<String, dynamic> json) {
    List<String> stringList(dynamic v) => v is List
        ? v.whereType<String>().toList(growable: false)
        : const <String>[];

    // 嵌套对象统一转一次：JSON 解码得到的是 Map<String, dynamic>，
    // 但手写/测试传入的字面量可能是 Map<String, int>，直接 cast 会崩。
    Map<String, dynamic>? mapOf(dynamic value) =>
        value is Map ? Map<String, dynamic>.from(value) : null;

    final movesJson = mapOf(json['moves']) ?? const <String, dynamic>{};
    final defaults = MoveParams.fromJson(
      mapOf(movesJson['default']) ?? const {},
      const MoveParams(
        minDist: 60,
        maxDist: 240,
        margin: 20,
        leadSec: 2,
        tailSec: 2,
      ),
    );
    final moveActions = <MoveAction>[];
    for (final raw in (movesJson['actions'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final name = raw['name'];
      if (name is! String || name.isEmpty) continue;
      moveActions.add(
        MoveAction(
          name: name,
          params: MoveParams.fromJson(
            mapOf(raw['params']) ?? const {},
            defaults,
          ),
        ),
      );
    }

    final categories = <AnimationCategory>[];
    for (final raw in (json['categories'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final id = raw['id'];
      if (id is! String) continue;
      categories.add(
        AnimationCategory(
          id: id,
          weight: (raw['weight'] as num?)?.toDouble() ?? 0,
          noMirror: raw['noMirror'] == true,
          actions: stringList(raw['actions']),
        ),
      );
    }

    final events = <String, List<String>>{};
    final eventsRaw = json['events'];
    if (eventsRaw is Map) {
      for (final entry in eventsRaw.entries) {
        // 档位可能是“单个名字”或“候选数组”，统一成数组消费端就不必分支。
        final value = entry.value;
        if (value is String) {
          events[entry.key as String] = [value];
        } else {
          events[entry.key as String] = stringList(value);
        }
      }
    }

    final weightsJson = mapOf(json['weights']) ?? const <String, dynamic>{};

    return AnimationManifest(
      width: (json['width'] as num?)?.toInt() ?? 320,
      height: (json['height'] as num?)?.toInt() ?? 180,
      fps: (json['fps'] as num?)?.toDouble() ?? 12,
      names: stringList(json['names']).toSet(),
      idle: stringList(json['idle']),
      turn: stringList(json['turn']),
      drag: stringList(json['drag']),
      clicks: stringList(json['clicks']),
      moveDefault: defaults,
      moves: moveActions,
      categories: categories,
      events: events,
      weights: AnimationWeights(
        idle: (weightsJson['idle'] as num?)?.toDouble() ?? 10,
        turn: (weightsJson['turn'] as num?)?.toDouble() ?? 5,
        move: (weightsJson['move'] as num?)?.toDouble() ?? 5,
      ),
    );
  }

  static AnimationManifest parse(String source) =>
      AnimationManifest.fromJson(jsonDecode(source) as Map<String, dynamic>);

  /// 工作状态档位：索引顺序与上游 workStatus 事件池一致（thinking…error）。
  List<String> get workStatusPool => events['workStatus'] ?? const [];
}
