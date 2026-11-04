import 'dart:io';

import 'package:dsh_pet_flutter/app/pet_stage.dart';
import 'package:dsh_pet_flutter/core/config/animation_manifest.dart';
import 'package:dsh_pet_flutter/core/config/app_config.dart';
import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/features/linkage/assistant_adapters.dart';
import 'package:dsh_pet_flutter/features/pet/behavior/physics.dart';
import 'package:dsh_pet_flutter/features/pet/pet_controller.dart';
import 'package:dsh_pet_flutter/features/settings/sections/evolution_section.dart';
import 'package:dsh_pet_flutter/learning/guideline_store.dart';
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
    for (final label in [
      '联动',
      '大脑',
      '隐私',
      '情绪',
      '形象',
      '记忆',
      '学习',
      '进化',
      '人格',
    ]) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$label Tab 渲染异常');
    }

    controller.dispose();
  });

  testWidgets('P1-5 措辞替换提案卡片：新旧对照展示与两路回调', (tester) async {
    // 走一遍真实影子试验（单候选 10 轮）生成提案，不伪造状态。
    final dir = Directory.systemTemp.createTempSync('rewrite_card');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = GuidelineStore(directory: dir)..load();
    store.propose(
      Guideline(
        id: 'g1',
        title: '风格',
        content: '原文',
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    store.accept('g1');
    store.startShadowTrial('g1', ['候选一']);
    for (var i = 0; i < 10; i++) {
      final base = store.active.single;
      store.applyShadowArm(base);
      store.markUsed([base]);
      store.recordInjectionOutcome(accepted: i.isOdd);
    }
    expect(store.rewriteProposals, hasLength(1));

    final accepted = <String>[];
    // 模拟 settings_page 的真实接线：回调透传到 store。
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SingleChildScrollView(
          child: EvolutionSection(
            guidelines: store,
            reflectionCount: 0,
            onAccept: (_) {},
            onReject: (_) {},
            onArchive: (_) {},
            onReactivate: (_) {},
            onAcceptRetire: (_) {},
            onRejectRetire: (_) {},
            onAcceptRewrite: (id) {
              accepted.add(id);
              store.acceptRewrite(id);
            },
            onRejectRewrite: (_) {},
            hint: '',
          ),
        ),
      ),
    );

    // 新旧措辞对照与判定依据都可见。
    expect(find.textContaining('现：原文'), findsOneWidget);
    expect(find.textContaining('新：候选一'), findsOneWidget);
    expect(find.textContaining('影子试验'), findsOneWidget);

    await tester.tap(find.text('换新措辞'));
    await tester.pump();
    expect(accepted, ['rewrite-g1']);
    // 接受生效：提案消费掉、准则换成候选措辞。
    expect(store.rewriteProposals, isEmpty);
    expect(store.active.single.content, '候选一');
  });
}
