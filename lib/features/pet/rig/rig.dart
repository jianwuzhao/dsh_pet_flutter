import 'dart:ui';

/// Canonical coordinates and immutable attachment definitions define identity.
class BaseRig {
  BaseRig({required this.size, required Map<String, Rect> slots})
    : slots = Map.unmodifiable(slots) {
    if (size.isEmpty ||
        !size.width.isFinite ||
        !size.height.isFinite ||
        slots.values.any(
          (r) =>
              r.isEmpty ||
              ![r.left, r.top, r.right, r.bottom].every((v) => v.isFinite),
        )) {
      throw ArgumentError('Invalid canonical geometry');
    }
  }
  final Size size;
  final Map<String, Rect> slots;
}

class SlotInstruction {
  SlotInstruction.fromJson(Map<String, dynamic> json)
    : slot = json['slot'] as String,
      action = json['action'] as String,
      description = json['description'] as String,
      qaAnchor = json['qa_anchor'] as String {
    if (!['replace', 'remove'].contains(action) ||
        description.trim().isEmpty ||
        qaAnchor.trim().isEmpty) {
      throw FormatException('Invalid slot instruction');
    }
  }
  final String slot, action, description, qaAnchor;
}

/// Images are owned by the caller; publication happens only after external QA.
class SlotRegistry {
  SlotRegistry(this.rig);
  final BaseRig rig;
  final Map<String, Image> _images = {};
  Map<String, Image> get images => Map.unmodifiable(_images);

  void apply(
    SlotInstruction instruction, {
    Image? image,
    bool qaPassed = false,
  }) {
    if (!rig.slots.containsKey(instruction.slot)) {
      throw ArgumentError('Unknown slot; rig migration required');
    }
    if (instruction.action == 'remove') {
      _images.remove(instruction.slot);
    } else {
      if (image == null || !qaPassed) {
        throw StateError('Replacement requires decoded image and completed QA');
      }
      _images[instruction.slot] = image;
    }
  }
}

class RigKeyframe {
  const RigKeyframe(this.time, this.angle);
  final double time, angle;
}

/// Bounded rigid rotations around slot centers, in radians and seconds.
class ParametricRigMotion {
  ParametricRigMotion({
    required this.duration,
    required Map<String, List<RigKeyframe>> tracks,
  }) : tracks = Map.unmodifiable(
         tracks.map((k, v) => MapEntry(k, List<RigKeyframe>.unmodifiable(v))),
       ) {
    if (!duration.isFinite ||
        duration <= 0 ||
        duration > 10 ||
        tracks.length > 32) {
      throw FormatException('Motion budget exceeded');
    }
    for (final frames in tracks.values) {
      if (frames.isEmpty || frames.length > 64) {
        throw FormatException('Invalid track');
      }
      var previous = -1.0;
      for (final frame in frames) {
        if (!frame.time.isFinite ||
            !frame.angle.isFinite ||
            frame.time <= previous ||
            frame.time < 0 ||
            frame.time > duration ||
            frame.angle.abs() > 0.5) {
          throw FormatException('Unsafe keyframe');
        }
        previous = frame.time;
      }
    }
  }
  final double duration;
  final Map<String, List<RigKeyframe>> tracks;

  double angle(String slot, double seconds) {
    final frames = tracks[slot];
    if (frames == null || !seconds.isFinite) return 0;
    final t = seconds.clamp(0, duration);
    if (t <= frames.first.time) return frames.first.angle;
    for (var i = 1; i < frames.length; i++) {
      final a = frames[i - 1], b = frames[i];
      if (t <= b.time) {
        return a.angle + (b.angle - a.angle) * (t - a.time) / (b.time - a.time);
      }
    }
    return frames.last.angle;
  }
}

class MotionRegistry {
  MotionRegistry(this.rig);
  final BaseRig rig;
  final Map<String, ParametricRigMotion> _motions = {};
  void register(String event, ParametricRigMotion motion) {
    if (motion.tracks.keys.any((k) => !rig.slots.containsKey(k))) {
      throw ArgumentError('Motion references unknown slot');
    }
    _motions[event] = motion;
  }

  ParametricRigMotion resolve(String event) =>
      _motions[event] ?? ParametricRigMotion(duration: 1, tracks: const {});
}

class RigPlayer {
  RigPlayer(this.slots, this.motion);
  final SlotRegistry slots;
  ParametricRigMotion motion;
  double seconds = 0;

  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(
      size.width / slots.rig.size.width,
      size.height / slots.rig.size.height,
    );
    for (final entry in slots.rig.slots.entries) {
      final image = slots.images[entry.key];
      if (image == null) continue;
      final rect = entry.value;
      canvas.save();
      canvas.translate(rect.center.dx, rect.center.dy);
      canvas.rotate(motion.angle(entry.key, seconds));
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromCenter(
          center: Offset.zero,
          width: rect.width,
          height: rect.height,
        ),
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
    }
    canvas.restore();
  }
}
