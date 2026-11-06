import 'dart:io';

import 'package:dsh_pet_flutter/app/pet_stage.dart';
import 'package:dsh_pet_flutter/core/config/animation_manifest.dart';
import 'package:dsh_pet_flutter/core/config/app_config.dart';
import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/features/linkage/assistant_adapters.dart';
import 'package:dsh_pet_flutter/features/pet/behavior/physics.dart';
import 'package:dsh_pet_flutter/features/pet/pet_controller.dart';
import 'package:dsh_pet_flutter/features/settings/sections/appearance_section.dart';
import 'package:dsh_pet_flutter/features/settings/sections/evolution_section.dart';
import 'package:dsh_pet_flutter/learning/guideline_store.dart';
import 'package:dsh_pet_flutter/persona/appearance/appearance_state.dart';
import 'package:dsh_pet_flutter/persona/appearance/trend_outfit.dart';
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

  testWidgets('天气开关与当前装扮实时显示', (tester) async {
    final updates = ValueNotifier(const AppearanceState());
    addTearDown(updates.dispose);
    final sources = <AppearanceWeatherSource>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF26262C),
          body: AppearanceSection(
            state: const AppearanceState(),
            reason: '',
            hint: '',
            onEvolve: () {},
            onRollback: () {},
            onFreeze: (_) {},
            weatherSource: AppearanceWeatherSource.builtin,
            appearanceUpdates: updates,
            onWeatherSourceChanged: sources.add,
          ),
        ),
      ),
    );

    expect(find.text('居家 · 默认'), findsOneWidget);
    updates.value = updates.value.copyWith(
      outfit: 'rain',
      outfitSource: AppearanceOutfitSource.weather,
    );
    await tester.pump();
    expect(find.text('雨 · 天气'), findsOneWidget);

    await tester.tap(find.text('天气装扮'));
    expect(sources, [AppearanceWeatherSource.off]);
  });

  testWidgets('服装选择独立于动作，预览使用真实桌宠且展示经典素材状态', (tester) async {
    final updates = ValueNotifier(const AppearanceState(frozen: true));
    addTearDown(updates.dispose);
    final choices = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AppearanceSection(
              state: updates.value,
              appearanceUpdates: updates,
              petPreview: const Text('实时桌宠预览'),
              reason: '',
              hint: '',
              onEvolve: null,
              onRollback: null,
              onFreeze: null,
              onOutfitChanged: (outfit) {
                choices.add(outfit);
                updates.value = updates.value.copyWith(
                  outfit: outfit ?? 'winter',
                  outfitSource: outfit == null
                      ? AppearanceOutfitSource.seasonal
                      : AppearanceOutfitSource.user,
                );
              },
            ),
          ),
        ),
      ),
    );
    expect(find.text('实时桌宠预览'), findsOneWidget);
    expect(find.byType(AppearancePreview), findsNothing);
    await tester.tap(find.text('雨天主题'));
    await tester.pump();
    expect(find.text('雨 · 手选'), findsOneWidget);
    expect(find.text('当前播放：经典素材包 · 原装角色。换装需要对应的独立动画素材包。'), findsOneWidget);
    await tester.tap(find.text('自动'));
    await tester.pump();
    expect(choices, ['rain', null]);
    expect(find.text('当前播放：经典素材包 · 原装角色。换装需要对应的独立动画素材包。'), findsOneWidget);
  });

  testWidgets('P2-3b 热门趋势装扮：开关与提案卡片的两路回调', (tester) async {
    final proposal = ValueNotifier<TrendOutfitProposal?>(
      TrendOutfitProposal(
        outfit: 'trend-冬日暖阳',
        theme: '冬日暖阳',
        main: 0xFFE23E3E,
        trim: 0xFFF2C14E,
        reason: '暖色围巾呼应初冬氛围',
        proposedAt: DateTime(2026, 1, 1, 12),
      ),
    );
    addTearDown(proposal.dispose);
    var accepted = 0;
    var rejected = 0;
    final sources = <AppearanceTrendSource>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF26262C),
          body: AppearanceSection(
            state: const AppearanceState(),
            reason: '',
            hint: '',
            onEvolve: () {},
            onRollback: () {},
            onFreeze: (_) {},
            trendSource: AppearanceTrendSource.builtin,
            trendSuggestion: proposal,
            onTrendSourceChanged: sources.add,
            onAcceptTrendOutfit: () => accepted++,
            onRejectTrendOutfit: () => rejected++,
          ),
        ),
      ),
    );

    // 开着 + 有提案：开关常驻，卡片带主题、理由与两路按钮。
    expect(find.text('热门趋势装扮'), findsOneWidget);
    expect(find.text('本周提案：冬日暖阳'), findsOneWidget);
    expect(find.text('暖色围巾呼应初冬氛围'), findsOneWidget);

    await tester.tap(find.text('穿上'));
    expect(accepted, 1);
    await tester.tap(find.text('拒绝'));
    expect(rejected, 1);

    // 提案清空（接受/拒绝后内核置 null）：卡片随 ValueListenable 消失。
    proposal.value = null;
    await tester.pump();
    expect(find.text('本周提案：冬日暖阳'), findsNothing);

    // 开关关掉：回传 off（内核据此落盘并进入冷却治理）。
    await tester.tap(find.text('热门趋势装扮'));
    expect(sources, [AppearanceTrendSource.off]);
  });

  testWidgets('P2-5 纪念头像卡片：仅晋升后出现，生成回调与入口关闭', (tester) async {
    final eligible = ValueNotifier<bool>(false);
    addTearDown(eligible.dispose);
    var generated = 0;

    Widget buildHost() => MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF26262C),
        body: AppearanceSection(
          state: const AppearanceState(),
          reason: '',
          hint: '',
          onEvolve: () {},
          onRollback: () {},
          onFreeze: (_) {},
          mementoEligible: eligible,
          onGenerateMemento: () async {
            generated++;
          },
        ),
      ),
    );

    // 默认关：晋升前不出现入口。
    await tester.pumpWidget(buildHost());
    expect(find.text('新形象纪念头像'), findsNothing);

    // 晋升解锁：卡片出现，点击生成走回调。
    eligible.value = true;
    await tester.pump();
    expect(find.text('新形象纪念头像'), findsOneWidget);
    await tester.tap(find.text('生成'));
    expect(generated, 1);

    // 生成后入口关闭：卡片随 ValueListenable 消失（每月限 1 次）。
    eligible.value = false;
    await tester.pump();
    expect(find.text('新形象纪念头像'), findsNothing);
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
