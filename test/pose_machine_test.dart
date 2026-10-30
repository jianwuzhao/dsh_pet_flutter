import 'dart:math';

import 'package:dsh_pet_flutter/core/config/animation_manifest.dart';
import 'package:dsh_pet_flutter/features/pet/behavior/pose_machine.dart';
import 'package:flutter_test/flutter_test.dart';

AnimationManifest _manifest() => AnimationManifest.fromJson({
  'width': 240,
  'height': 135,
  'fps': 12,
  'names': [
    'idle',
    'turn',
    'drag',
    'click',
    'move',
    'cat',
    'cat-text',
    'ws0',
    'ws1',
  ],
  'idle': ['idle'],
  'turn': ['turn'],
  'drag': ['drag'],
  'clicks': ['click'],
  'moves': {
    'default': {'minDist': 60, 'maxDist': 240, 'leadSec': 2, 'tailSec': 2},
    'actions': [
      {'name': 'move', 'params': {}},
    ],
  },
  'categories': [
    {
      'id': 'no-text',
      'weight': 10,
      'noMirror': false,
      'actions': ['cat'],
    },
    {
      'id': 'text',
      'weight': 10,
      'noMirror': true,
      'actions': ['cat-text'],
    },
  ],
  'events': {
    'workStatus': ['ws0', 'ws1'],
  },
  'weights': {'idle': 0, 'turn': 0, 'move': 0},
});

void main() {
  group('PoseMachine', () {
    test('权重全给分类时必定抽到分类动画', () {
      final machine = PoseMachine(_manifest(), random: Random(1));
      final pick = machine.rollNext();
      expect(pick, isNotNull);
      expect(pick!.kind, PetPoseKind.category);
      expect(['cat', 'cat-text'], contains(pick.animation));
    });

    test('朝左时跳过 noMirror 分类', () {
      final machine = PoseMachine(_manifest(), random: Random(2))..facing = -1;
      for (var i = 0; i < 40; i++) {
        final pick = machine.rollNext();
        expect(pick?.animation, isNot('cat-text'));
      }
    });

    test('fixed 模式不抽转向与移动', () {
      final machine = PoseMachine(_manifest(), random: Random(3));
      for (var i = 0; i < 40; i++) {
        final pick = machine.rollNext(fixed: true);
        expect(pick?.kind, isNot(PetPoseKind.turn));
        expect(pick?.kind, isNot(PetPoseKind.move));
      }
    });

    test('事件动画按档位取 workStatus', () {
      final machine = PoseMachine(_manifest());
      expect(machine.workStatusAnimation(0), 'ws0');
      expect(machine.workStatusAnimation(1), 'ws1');
      expect(machine.workStatusAnimation(2), isNull);
    });

    test('清单里不存在的动画不会被选中', () {
      final machine = PoseMachine(
        AnimationManifest.fromJson({
          'names': ['idle', 'cat'],
          'idle': ['idle', 'missing-idle'],
          'categories': [
            {
              'id': 'cat',
              'weight': 10,
              'actions': ['cat', 'missing-cat'],
            },
          ],
          'weights': {'idle': 0, 'turn': 0, 'move': 0},
        }),
        random: Random(4),
      );
      for (var i = 0; i < 20; i++) {
        final pick = machine.rollNext();
        expect(pick!.animation, isNot(startsWith('missing')));
      }
    });
  });
}
