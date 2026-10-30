/// 与物理相关的纯函数与状态机，参数原值照搬上游 `src/shared/physics.ts`，保证手感一致。
library;

import 'dart:math' as math;
import 'dart:ui';

class PhysicsParams {
  const PhysicsParams({
    this.gravity = 1400,
    this.restitution = 0.78,
    this.groundFriction = 2.5,
    this.ceilingBounce = true,
    this.throwPower = 1.0,
    this.throwThreshold = 500,
    this.petCollision = false,
  });

  final double gravity;
  final double restitution;
  final double groundFriction;
  final bool ceilingBounce;
  final double throwPower;

  /// 松手速度达到该值才触发甩出；低于它视为“摆放”，直接钉住。
  /// 没有这个阈值时，拖到屏幕顶部轻轻松手也会被重力拉回地面。
  final double throwThreshold;

  final bool petCollision;

  factory PhysicsParams.fromJson(
    Map<String, dynamic>? json,
    PhysicsParams fallback,
  ) {
    if (json == null) return fallback;
    double read(String key, double def) =>
        (json[key] as num?)?.toDouble() ?? def;
    bool readBool(String key, bool def) =>
        json[key] is bool ? json[key] as bool : def;

    return PhysicsParams(
      gravity: read('gravity', fallback.gravity),
      restitution: read('restitution', fallback.restitution),
      groundFriction: read('groundFriction', fallback.groundFriction),
      ceilingBounce: readBool('ceilingBounce', fallback.ceilingBounce),
      throwPower: read('throwPower', fallback.throwPower),
      throwThreshold: read('throwThreshold', fallback.throwThreshold),
      petCollision: readBool('petCollision', fallback.petCollision),
    );
  }
}

/// 拖拽采样：记录最近若干次指针位移，用最近 ~80ms 估算甩出速度。
class ThrowSampler {
  ThrowSampler({this.window = const Duration(milliseconds: 90)});

  final Duration window;
  final List<({Duration at, Offset position})> _samples = [];

  void add(Duration at, Offset position) {
    _samples.add((at: at, position: position));
    while (_samples.length > 2 && at - _samples.first.at > window) {
      _samples.removeAt(0);
    }
  }

  /// 最后一次采样时间：松手前停住超过采样窗口就不该判为“甩出”。
  Duration? get lastAt => _samples.isEmpty ? null : _samples.last.at;

  /// 释放时的速度（px/s），乘上 throwPower。
  Offset velocity(double throwPower) {
    if (_samples.length < 2) return Offset.zero;
    final last = _samples.last;
    final first = _samples.first;
    final seconds = (last.at - first.at).inMicroseconds / 1e6;
    // 采样跨度过短时速度会被放大成天文数字（测试里的连续同步调用就是如此），
    // 人类拖动不可能在 8ms 内完成，直接视为没有甩出。
    if (seconds <= 0.008) return Offset.zero;
    final delta = last.position - first.position;
    return delta / seconds * throwPower;
  }

  void clear() => _samples.clear();
}

class PetBody {
  PetBody({required this.position, required this.size, required this.params});

  /// 宠物身体左上角（相对窗口）。
  Offset position;
  final Size size;
  PhysicsParams params;

  Offset velocity = Offset.zero;
  bool dragging = false;

  /// 自由摆放：拖拽松手后不再受重力影响，宠物停在哪里就是哪里。
  /// 上游是“掉到地面”的物理手感，但桌面宠物需要能放到屏幕上方任意位置；
  /// 物理反弹仍保留给测试/未来的抛掷玩法，只是默认不启用。
  bool pinned = false;

  /// 拖拽时的弹簧跟随目标（指针位置减去抓取偏移）。
  Offset dragTarget = Offset.zero;

  Rect get rect => position & size;

  void beginDrag(Offset target) {
    dragging = true;
    pinned = false;
    dragTarget = target;
    velocity = Offset.zero;
  }

  /// 松手后钉在原地：清速度、关重力。拖拽期间由弹簧跟手，结束时由控制器
  /// 先对齐 dragTarget 再调用这里，避免松手瞬间往回弹一下。
  void pin() {
    dragging = false;
    pinned = true;
    velocity = Offset.zero;
  }

  void updateDragTarget(Offset target) {
    dragTarget = target;
  }

  void endDrag(Offset throwVelocity) {
    dragging = false;
    velocity = throwVelocity;
  }

  /// 推进一帧（dt 秒）。domain 为可移动区域（窗口工作区或某块屏幕），
  /// 坐标系与 position 相同（窗口本地，左上原点）。
  void step(double dt, Rect domain) {
    if (dt <= 0) return;

    if (dragging) {
      // 弹簧跟手：拖拽时不直接贴指针，留一点滞后，手感更“有重量”。
      final delta = dragTarget - position;
      position += delta * math.min(1.0, dt * 18);
      return;
    }

    // 自由摆放：不被重力拉回地面，也不做边界反弹。
    if (pinned) return;

    velocity = Offset(velocity.dx, velocity.dy + params.gravity * dt);
    var next = position + velocity * dt;

    final minX = domain.left;
    final maxX = math.max(minX, domain.right - size.width);
    final maxY = math.max(domain.top, domain.bottom - size.height);

    if (next.dx < minX) {
      next = Offset(minX, next.dy);
      velocity = Offset(-velocity.dx * params.restitution, velocity.dy);
    } else if (next.dx > maxX) {
      next = Offset(maxX, next.dy);
      velocity = Offset(-velocity.dx * params.restitution, velocity.dy);
    }

    if (next.dy < domain.top) {
      next = Offset(next.dx, domain.top);
      velocity = Offset(
        velocity.dx,
        params.ceilingBounce ? -velocity.dy * params.restitution : 0,
      );
    } else if (next.dy > maxY) {
      next = Offset(next.dx, maxY);
      // 落地：竖直速度按恢复系数反弹，横向按地面摩擦衰减
      velocity = Offset(
        velocity.dx - velocity.dx * math.min(1.0, params.groundFriction * dt),
        -velocity.dy * params.restitution,
      );
      if (velocity.dy.abs() < 40) velocity = Offset(velocity.dx, 0);
    }

    position = next;

    // 极慢速时收尾，避免永远微抖
    if (velocity.distance < 6 && next.dy >= maxY - 0.5) {
      velocity = Offset.zero;
    }
  }
}
