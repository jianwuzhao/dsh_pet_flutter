import 'dart:ui';

import 'package:dsh_pet_flutter/features/pet/behavior/physics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PetBody', () {
    test('自由落体一秒后竖直速度接近 gravity', () {
      final body = PetBody(
        position: Offset.zero,
        size: const Size(100, 100),
        params: const PhysicsParams(),
      );
      for (var i = 0; i < 60; i++) {
        body.step(1 / 60, const Rect.fromLTWH(0, 0, 1000, 1000));
      }
      expect(body.velocity.dy, closeTo(1400, 40));
    });

    test('落地按恢复系数反弹并衰减竖直速度', () {
      final body = PetBody(
        position: const Offset(0, 190),
        size: const Size(100, 100),
        params: const PhysicsParams(),
      )..velocity = const Offset(0, 600);

      body.step(1 / 60, const Rect.fromLTWH(0, 0, 400, 300));

      expect(body.position.dy, closeTo(200, 0.001));
      expect(body.velocity.dy, lessThan(0));
      expect(body.velocity.dy, closeTo(-600 * 0.78, 40));
    });

    test('左边界反弹且位置不越界', () {
      final body = PetBody(
        position: const Offset(0, 0),
        size: const Size(100, 100),
        params: const PhysicsParams(),
      )..velocity = const Offset(-500, 0);

      body.step(1 / 60, const Rect.fromLTWH(0, 0, 400, 300));

      expect(body.position.dx, 0);
      expect(body.velocity.dx, greaterThan(0));
    });

    test('拖拽时弹簧跟手但不瞬移', () {
      final body = PetBody(
        position: Offset.zero,
        size: const Size(100, 100),
        params: const PhysicsParams(),
      )..beginDrag(const Offset(300, 300));

      body.step(1 / 60, const Rect.fromLTWH(0, 0, 1000, 1000));

      expect(body.position.dx, greaterThan(0));
      expect(body.position.dx, lessThan(300));
    });

    test('低速落地后收尾为零速度', () {
      final body = PetBody(
        position: const Offset(0, 200),
        size: const Size(100, 100),
        params: const PhysicsParams(),
      );

      body.step(1 / 60, const Rect.fromLTWH(0, 0, 400, 300));

      expect(body.velocity, Offset.zero);
    });

    test('钉住后不再受重力影响', () {
      final body = PetBody(
        position: const Offset(10, 10),
        size: const Size(100, 100),
        params: const PhysicsParams(),
      )..pin();

      for (var i = 0; i < 120; i++) {
        body.step(1 / 60, const Rect.fromLTWH(0, 0, 1000, 1000));
      }
      expect(body.position, const Offset(10, 10));
      expect(body.velocity, Offset.zero);
      expect(body.pinned, isTrue);
    });
  });

  group('ThrowSampler', () {
    test('用最近窗口位移估算甩出速度', () {
      final sampler = ThrowSampler(window: const Duration(milliseconds: 90))
        ..add(Duration.zero, Offset.zero)
        ..add(const Duration(milliseconds: 60), const Offset(60, 0));

      expect(sampler.velocity(1.0).dx, closeTo(1000, 1));
      expect(sampler.velocity(2.0).dx, closeTo(2000, 1));
    });

    test('只有一个采样点时速度为 0', () {
      final sampler = ThrowSampler()..add(Duration.zero, const Offset(10, 10));
      expect(sampler.velocity(1.0), Offset.zero);
    });
  });
}
