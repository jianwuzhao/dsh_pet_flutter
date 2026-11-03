import 'package:dsh_pet_flutter/app/pet_stage.dart';
import 'package:dsh_pet_flutter/core/config/animation_manifest.dart';
import 'package:dsh_pet_flutter/core/config/app_config.dart';
import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/features/linkage/assistant_adapters.dart';
import 'package:dsh_pet_flutter/features/pet/behavior/physics.dart';
import 'package:dsh_pet_flutter/features/pet/pet_controller.dart';
import 'package:dsh_pet_flutter/persona/appearance/appearance_state.dart';
import 'package:dsh_pet_flutter/persona/profile_store.dart';
import 'package:dsh_pet_flutter/platform/pet_platform.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePlatform extends PetPlatform {
  @override
  Future<void> showWindow() async {}

  @override
  Future<void> setInteractive(bool value) async {}

  @override
  Future<void> setFocusable(bool value) async {}
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

const AppConfig _config = AppConfig(
  pets: [
    PetConfig(
      id: 'main',
      name: '大肥鱼',
      size: 220,
      display: 'desktop',
      whisperEnabled: false,
      workStatusEnabled: false,
    ),
  ],
  physics: PhysicsParams(),
  linkage: LinkageConfig(
    active: 'builtin',
    adapters: {},
    port: 7341,
    contentRead: false,
  ),
);

void main() {
  testWidgets('从菜单路径打开设置面板不抛异常', (tester) async {
    final platform = _FakePlatform();
    final controller = PetController(
      pet: _config.pets.first,
      physics: _config.physics,
      manifest: _manifest(),
      platform: platform,
    )..setScreens([const Rect.fromLTWH(0, 0, 800, 600)]);

    await tester.pumpWidget(
      MaterialApp(
        home: PetStage(
          controller: controller,
          activeName: '内置对话',
          config: _config,
          privacy: const PrivacySettings(),
          emotion: const EmotionProfile(),
          appearance: const AppearanceState(),
          appearanceReason: '',
          memory: null,
          learning: null,
          onSend: (_) async => const Success(DispatchOutcome.success),
          onSaveConfig: (_, _) async => const Success(null),
          onSaveEmotion: (_) => const Success(null),
          onCheckAccessibility: () async => false,
          onQuit: () {},
          appearanceChanges: null,
        ),
      ),
    );
    await tester.pump();

    controller.openMenu(const Offset(400, 400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 模拟菜单里点“设置”：先关菜单再开面板。
    controller.closeMenu();
    controller.openPanel(PetPanel.settings);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('设置'), findsWidgets);

    // 逐个 Tab 渲染：任何 Material 依赖缺失都会在这里暴露。
    for (final label in ['联动', '大脑', '隐私', '情绪', '形象', '记忆', '学习']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$label Tab 渲染异常');
    }

    controller.dispose();
  });
}
