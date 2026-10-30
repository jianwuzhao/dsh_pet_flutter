import 'dart:async';

import 'package:dsh_pet_flutter/core/config/animation_manifest.dart';
import 'package:dsh_pet_flutter/core/config/app_config.dart';
import 'package:dsh_pet_flutter/features/pet/behavior/physics.dart';
import 'package:dsh_pet_flutter/features/pet/pet_controller.dart';
import 'package:dsh_pet_flutter/platform/pet_platform.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _primary = Rect.fromLTWH(0, 0, 1512, 845);
const _external = Rect.fromLTWH(1512, -446, 1920, 1050);

/// 只实现拖动/换屏用得到的能力，避免测试碰真实 MethodChannel。
class _FakePlatform extends PetPlatform {
  final StreamController<PetPointer> pointers =
      StreamController<PetPointer>.broadcast();
  final List<bool> interactive = [];
  final List<int> movedTo = [];
  final List<bool> focusable = [];
  Duration moveDelay = Duration.zero;

  @override
  Stream<PetPointer> get cursor => pointers.stream;

  @override
  Future<void> setInteractive(bool value) async => interactive.add(value);

  @override
  Future<void> setFocusable(bool value) async => focusable.add(value);

  @override
  Future<void> showWindow() async {}

  @override
  Future<ScreenMove?> moveToScreen(int index) async {
    if (moveDelay > Duration.zero) await Future<void>.delayed(moveDelay);
    movedTo.add(index);
    return ScreenMove(
      index: index,
      size: index == 1 ? const Size(1920, 1050) : const Size(1512, 845),
      pointer: index == 1 ? const Offset(1600, 900) : const Offset(760, 782),
    );
  }
}

AnimationManifest _manifest() => AnimationManifest.fromJson({
  'width': 240,
  'height': 135,
  'fps': 12,
  'names': <String>[],
  'idle': <String>[],
  'turn': <String>[],
  'drag': <String>[],
  'clicks': <String>[],
  'weights': {'idle': 0, 'turn': 0, 'move': 0},
});

PetController _controller(_FakePlatform platform) =>
    PetController(
        pet: const PetConfig(
          id: 'main',
          name: '测试宠物',
          size: 220,
          display: 'desktop',
          whisperEnabled: false,
          workStatusEnabled: false,
        ),
        physics: const PhysicsParams(),
        manifest: _manifest(),
        platform: platform,
      )
      ..setScreens([_primary, _external])
      ..updateViewport(const Size(1512, 845));

void main() {
  testWidgets('拖拽可到屏幕顶部，左右最多半个身体探出屏幕', (tester) async {
    final platform = _FakePlatform();
    final controller = _controller(platform);
    controller.start();
    await tester.pump();

    final grab = controller.petRect.center;
    controller.onDragStart(grab);
    // 指针拖到左上角之外：上边必须能到 0，左右允许半个身体探出。
    controller.onDragUpdate(const Offset(-200, 0));
    controller.onDragEnd();

    expect(controller.dragging.value, isFalse);
    expect(controller.petRect.top, 0, reason: '顶部不能再被重力拉回地面');
    expect(
      controller.petRect.left,
      closeTo(-controller.petSize.width / 2, 0.01),
      reason: '左右边缘允许半个身体探出',
    );
    expect(controller.state()['pinned'], isTrue);

    // 松手后连续跑一秒，不允许再自己掉下去。
    await tester.pump(const Duration(seconds: 1));
    expect(controller.petRect.top, 0);
    expect(
      controller.petRect.left,
      closeTo(-controller.petSize.width / 2, 0.01),
    );
    controller.dispose();
  });

  testWidgets('换屏边缘有 28 像素滞回，不会来回切窗', (tester) async {
    final platform = _FakePlatform();
    final controller = _controller(platform);
    controller.start();
    await tester.pump();

    final grab = controller.petRect.center;
    platform.pointers.add(PetPointer(position: grab, down: true));
    await tester.pump();
    controller.onDragStart(grab);

    // 刚越过边界 8px：视为手抖，不换屏。
    platform.pointers.add(
      const PetPointer(position: Offset(1520, 500), down: true),
    );
    await tester.pump();
    await tester.pump();
    expect(platform.movedTo, isEmpty);

    // 越过边界 33px：确实进入另一块屏，换窗。
    platform.pointers.add(
      const PetPointer(position: Offset(1545, 500), down: true),
    );
    await tester.pump();
    await tester.pump();
    expect(platform.movedTo, [1]);
    expect(controller.state()['activeScreenIndex'], 1);
    controller.dispose();
  });

  testWidgets('换屏途中松开左键，换屏完成后收尾并钉住', (tester) async {
    final platform = _FakePlatform()
      ..moveDelay = const Duration(milliseconds: 80);
    final controller = _controller(platform);
    controller.start();
    await tester.pump();

    final grab = controller.petRect.center;
    platform.pointers.add(PetPointer(position: grab, down: true));
    await tester.pump();
    controller.onDragStart(grab);

    platform.pointers.add(
      const PetPointer(position: Offset(1545, 500), down: true),
    );
    await tester.pump();
    // 换屏请求还没回来，左键先松开：不能停在半拖拽态。
    platform.pointers.add(
      const PetPointer(position: Offset(1545, 500), down: false),
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(controller.dragging.value, isTrue, reason: '换屏未完成，先别结束');

    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.dragging.value, isFalse);
    expect(controller.state()['pinned'], isTrue);
    expect(controller.state()['pendingRelease'], isFalse);
    controller.dispose();
  });

  testWidgets('跨屏后继续由全局指针驱动，松开时钉在新屏', (tester) async {
    final platform = _FakePlatform();
    final controller = _controller(platform);
    controller.start();
    await tester.pump();

    final grab = controller.petRect.center;
    platform.pointers.add(PetPointer(position: grab, down: true));
    await tester.pump();
    controller.onDragStart(grab);

    platform.pointers.add(
      const PetPointer(position: Offset(1600, 500), down: true),
    );
    await tester.pump();
    await tester.pump();
    expect(platform.movedTo, [1]);
    expect(controller.petRect.left, closeTo(1490, 0.01));

    // 原生 push 的新屏幕列表（新活动屏在本地 (0,0)）。
    // 原生 screenRects 的顺序是 NSScreen.screens（主屏在前）：
    // 换到外接屏后，主屏在本地坐标里是负的，活动屏仍在下标 1。
    controller.setScreens(const [
      Rect.fromLTWH(-1512, 446, 1512, 845),
      Rect.fromLTWH(0, 0, 1920, 1050),
    ]);

    platform.pointers.add(
      const PetPointer(position: Offset(1700, 900), down: true),
    );
    await tester.pump();
    controller.onDragCancel();
    expect(controller.dragging.value, isTrue, reason: '左键没松，不能半路结束拖动');

    platform.pointers.add(
      const PetPointer(position: Offset(1700, 900), down: false),
    );
    await tester.pump();
    expect(controller.dragging.value, isFalse);
    expect(controller.state()['pinned'], isTrue);
    expect(controller.petRect.left, closeTo(1590, 1));
    expect(controller.petRect.top, closeTo(838.125, 1));
    controller.dispose();
  });

  test('快速甩出保留拖拽动画并进入物理抛掷', () async {
    final platform = _FakePlatform();
    final controller = _controller(platform);
    final grab = controller.petRect.center;
    controller.onDragStart(grab);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    controller.onDragUpdate(grab + const Offset(150, -100));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    controller.onDragEnd();

    final state = controller.state();
    expect(state['thrown'], isTrue);
    expect(state['pinned'], isFalse, reason: '甩出后交给重力，不能钉住');
    expect(state['mode'], 'drag', reason: '落地前继续播放拖拽悬空动画');
    controller.dispose();
  });

  test('松手前停顿则钉住，不触发甩出', () async {
    final platform = _FakePlatform();
    final controller = _controller(platform);
    final grab = controller.petRect.center;
    controller.onDragStart(grab);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    controller.onDragUpdate(grab + const Offset(150, -100));
    // 停住超过 120ms 再松手：这是摆放，不是甩出。
    await Future<void>.delayed(const Duration(milliseconds: 180));
    controller.onDragEnd();

    final state = controller.state();
    expect(state['thrown'], isFalse);
    expect(state['pinned'], isTrue);
    expect(state['mode'], 'pose');
    controller.dispose();
  });

  testWidgets('保存的落点会在首次视口恢复，越界会被钳制', (tester) async {
    final platform = _FakePlatform();
    final controller =
        PetController(
            pet: const PetConfig(
              id: 'main',
              name: '测试宠物',
              size: 220,
              display: 'desktop',
              whisperEnabled: false,
              workStatusEnabled: false,
            ),
            physics: const PhysicsParams(),
            manifest: _manifest(),
            platform: platform,
            initialPosition: const Offset(1400, 800),
          )
          ..setScreens([_primary, _external])
          ..updateViewport(const Size(1512, 845));

    expect(controller.petRect.left, closeTo(1400, 0.01));
    expect(controller.petRect.top, closeTo(721.25, 0.01));
    expect(controller.state()['pinned'], isTrue);
    controller.dispose();
  });

  testWidgets('回到初始位置会停到当前屏底部中央并触发 Q 弹', (tester) async {
    final platform = _FakePlatform();
    final controller = _controller(platform);
    controller.onDragStart(controller.petRect.center);
    controller.onDragUpdate(const Offset(100, 100));
    controller.onDragEnd();
    expect(controller.petRect.top, lessThan(721));

    controller.resetPosition();
    expect(controller.petRect.left, closeTo(646, 0.01));
    expect(controller.petRect.top, closeTo(721.25, 0.01));
    expect(controller.squash.value.dy, lessThan(1), reason: '重置也要有 Q 弹反馈');
    controller.dispose();
  });
}
