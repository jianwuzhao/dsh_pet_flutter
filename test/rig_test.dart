import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_pet_flutter/features/pet/rig/rig.dart';

void main() {
  test('motion interpolation and unknown-event fallback', () {
    final rig = BaseRig(
      size: const Size(100, 100),
      slots: {'head': const Rect.fromLTWH(0, 0, 30, 30)},
    );
    final motion = ParametricRigMotion(
      duration: 1,
      tracks: {
        'head': [const RigKeyframe(0, 0), const RigKeyframe(1, .4)],
      },
    );
    expect(motion.angle('head', .5), closeTo(.2, .001));
    expect(MotionRegistry(rig).resolve('tap').angle('head', 1), 0);
    expect(
      () => MotionRegistry(rig).register(
        'tap',
        ParametricRigMotion(
          duration: 1,
          tracks: {
            'unknown': [const RigKeyframe(0, 0)],
          },
        ),
      ),
      throwsArgumentError,
    );
  });
  test('reject unsafe keyframes and unreviewed replacement', () {
    expect(
      () => ParametricRigMotion(
        duration: 1,
        tracks: {
          'head': [const RigKeyframe(0, double.nan)],
        },
      ),
      throwsFormatException,
    );
    final slots = SlotRegistry(
      BaseRig(
        size: const Size(100, 100),
        slots: {'head': const Rect.fromLTWH(0, 0, 30, 30)},
      ),
    );
    final instruction = SlotInstruction.fromJson({
      'slot': 'head',
      'action': 'replace',
      'description': 'hair',
      'qa_anchor': 'eyes visible',
    });
    expect(() => slots.apply(instruction), throwsStateError);
    expect(slots.images, isEmpty);
  });
}
