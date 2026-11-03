/// 页面装配：把宠物层、气泡层、菜单层、浮层叠成一个全屏透明舞台。
///
/// 只有各层需要重绘的部分挂 ValueListenable，避免 60Hz 重建整个页面。
/// 浮层定位统一走 [PetFlyoutLayout]：按宠物当前所在屏幕决定位置并做翻转，
/// 不再用“整窗并集”的宽高硬算（多屏时会把菜单/面板送到另一块屏或屏缝里）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/config/app_config.dart';
import '../core/result.dart';
import '../features/bubble/bubble_widget.dart';
import '../features/chat/chat_panel.dart';
import '../features/linkage/assistant_adapters.dart';
import '../features/menu/pet_menu.dart';
import '../features/pet/pet_controller.dart';
import '../features/pet/render/pet_view.dart';
import '../features/settings/settings_page.dart';
import '../interop/capability_registry.dart';
import '../learning/guideline_store.dart';
import '../learning/learning_loop.dart';
import '../persona/appearance/appearance_evolution.dart';
import '../persona/appearance/appearance_proposal.dart';
import '../persona/appearance/appearance_state.dart';
import '../persona/memory/memory_store.dart';
import '../persona/persona_dna.dart';
import '../persona/profile_store.dart';
import '../platform/pet_platform.dart';
import 'flyout_layout.dart';

class PetStage extends StatefulWidget {
  const PetStage({
    super.key,
    required this.controller,
    required this.activeName,
    required this.config,
    required this.privacy,
    required this.emotion,
    required this.appearance,
    required this.appearanceReason,
    required this.memory,
    required this.learning,
    this.persona = const PersonaDna(),
    this.onSavePersona,
    this.guidelines,
    this.reflectionCount = 0,
    this.onAcceptGuideline,
    this.onRejectGuideline,
    this.onArchiveGuideline,
    this.onReactivateGuideline,
    required this.onSend,
    required this.onSaveConfig,
    required this.onSaveEmotion,
    required this.onCheckAccessibility,
    required this.onQuit,
    this.onEvolveAppearance,
    this.onRollbackAppearance,
    this.onFreezeAppearance,
    this.appearanceChanges,
    this.appearanceProposal,
    this.onAcceptFormProposal,
    this.onRejectFormProposal,
    this.onOpenApp,
    this.onReloadConfig,
    this.onWhisper,
    this.onAcceptReply,
    this.onRejectReply,
    this.onDismissCare,
    this.capabilities,
    this.onProbeCapabilities,
  });

  final PetController controller;
  final String activeName;
  final AppConfig config;

  /// 隐私四开关当前值：传给设置页当草稿初值。
  final PrivacySettings privacy;

  /// 情绪档案当前值：传给设置页当草稿初值。
  final EmotionProfile emotion;

  /// 形象当前值与最近一次推演理由：传给设置页做参数化预览。
  final AppearanceState appearance;
  final String appearanceReason;

  /// 形象变化流（内核 ValueNotifier）：配色要立刻反映到宠物本体。
  final ValueListenable<AppearanceState>? appearanceChanges;

  /// 推演 / 回滚 / 冻结入口（由内核提供，页面只同步展示结果）。
  final EvolutionOutcome Function()? onEvolveAppearance;
  final Result<AppearanceState> Function()? onRollbackAppearance;
  final Result<void> Function(bool frozen)? onFreezeAppearance;

  /// 形态提案：最显眼的变化需用户接受才生效。
  final AppearanceProposal? appearanceProposal;
  final Result<AppearanceState> Function()? onAcceptFormProposal;
  final Result<void> Function()? onRejectFormProposal;

  /// 记忆库（内核同一实例）：设置页的查看/纠正/遗忘/导出即时生效。
  final MemoryStore? memory;

  /// 学习治理（内核同一实例）：策略版本、提案、回滚。
  final LearningLoop? learning;

  /// 人格 DNA 当前值：设置页“人格”分区用。
  final PersonaDna persona;
  final Result<void> Function(PersonaDna)? onSavePersona;

  /// 经验准则：设置页“进化”分区用。
  final GuidelineStore? guidelines;
  final int reflectionCount;
  final Result<Guideline> Function(String id)? onAcceptGuideline;
  final Result<void> Function(String id)? onRejectGuideline;
  final Result<void> Function(String id)? onArchiveGuideline;

  /// 恢复已停用准则：误停用可逆。
  final Result<Guideline> Function(String id)? onReactivateGuideline;

  final Future<Result<DispatchOutcome>> Function(String prompt) onSend;

  /// 保存时一并回写隐私四开关（配置与隐私档案分开落盘）。
  final Future<Result<void>> Function(AppConfig config, PrivacySettings privacy)
  onSaveConfig;

  /// 保存时回写情绪档案（经内核即时生效）。
  final Result<void> Function(EmotionProfile emotion) onSaveEmotion;

  /// 辅助功能授权检测（含触发系统授权弹窗）。
  final Future<bool> Function() onCheckAccessibility;

  final VoidCallback onQuit;
  final VoidCallback? onOpenApp;
  final VoidCallback? onReloadConfig;
  final VoidCallback? onWhisper;

  /// 聊天回复被采纳 / 被拒绝（重说，可附纠正）的反馈入口。
  final VoidCallback? onAcceptReply;
  final void Function(String correction)? onRejectReply;

  /// 主动关心气泡被提前关闭：记一条拒绝样本（自动过期仍是中性）。
  final VoidCallback? onDismissCare;

  /// 能力注册表（只读）：设置页展示各外部软件的探测结果。
  final CapabilityRegistry? capabilities;
  final VoidCallback? onProbeCapabilities;

  @override
  State<PetStage> createState() => _PetStageState();
}

class _PetStageState extends State<PetStage> {
  Size? _lastSize;
  Rect? _lastHitRect;

  @override
  void initState() {
    super.initState();
    // 触摸平台：穿透窗下只有原生哨兵层可触摸，且必须跟着宠物走，
    // 每帧把宠物矩形同步过去；桌面平台穿透切换走指针命中，无需同步。
    if (PetPlatform.isTouch) _scheduleHitRectSync();
  }

  /// 帧回调链：宠物静止时矩形不变，跳过重复的通道调用。
  void _scheduleHitRectSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rect = widget.controller.petRect;
      if (rect != _lastHitRect) {
        _lastHitRect = rect;
        widget.controller.platform.updateHitRect(rect);
      }
      _scheduleHitRectSync();
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _scheduleViewport(size);
        return Stack(
          fit: StackFit.expand,
          children: [_petLayer(), _bubbleLayer(), _menuLayer(), _panelLayer()],
        );
      },
    );
  }

  /// 视口变化必须等这一帧布局结束再通知控制器，否则会在 build 期间触发重绘。
  void _scheduleViewport(Size size) {
    if (_lastSize == size) return;
    _lastSize = size;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.updateViewport(size);
    });
  }

  Widget _petLayer() {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller.position,
        controller.bodyScaleNotifier,
      ]),
      builder: (context, child) => Positioned(
        left: controller.position.value.dx,
        top: controller.position.value.dy,
        width: controller.petSize.width,
        height: controller.petSize.height,
        child: child!,
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: controller.onTapPet,
        onDoubleTap: () => controller.openPanel(PetPanel.chat),
        onSecondaryTapUp: (details) =>
            controller.openMenu(details.globalPosition),
        onPanStart: (details) => controller.onDragStart(details.globalPosition),
        onPanUpdate: (details) =>
            controller.onDragUpdate(details.globalPosition),
        onPanEnd: (_) => controller.onDragEnd(),
        // 手势被系统取消（窗口失焦、Esc、触控板手势打断）时必须收尾，
        // 否则会永久停在拖拽态，后续既不能漫游也不能再拖。
        onPanCancel: controller.onDragCancel,
        child: ListenableBuilder(
          listenable: Listenable.merge([
            controller.dragging,
            controller.squash,
          ]),
          builder: (context, _) {
            final scale = controller.squash.value;
            return MouseRegion(
              cursor: controller.dragging.value
                  ? SystemMouseCursors.grabbing
                  : SystemMouseCursors.grab,
              child: Transform(
                alignment: Alignment.bottomCenter,
                transform: Matrix4.diagonal3Values(scale.dx, scale.dy, 1),
                child: _petView(controller),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 配色随形象变化即时重绘；没有变化流时退回当前快照。
  Widget _petView(PetController controller) {
    final changes = widget.appearanceChanges;
    if (changes == null) {
      return PetView(
        controller: controller,
        palette: widget.appearance.palette,
        accessory: widget.appearance.accessory,
      );
    }
    return ValueListenableBuilder<AppearanceState>(
      valueListenable: changes,
      builder: (context, appearance, _) => PetView(
        controller: controller,
        palette: appearance.palette,
        accessory: appearance.accessory,
      ),
    );
  }

  Widget _bubbleLayer() {
    final controller = widget.controller;
    return AnimatedBuilder(
      animation: Listenable.merge([
        controller.bubble,
        controller.position,
        controller.bodyScaleNotifier,
      ]),
      builder: (context, _) {
        final state = controller.bubble.value;
        if (state == null) return const SizedBox.shrink();
        final screen = controller.activeScreen;
        final pet = controller.petRect;
        // 头顶空间不够时气泡翻到脚下，避免贴顶时被窗口裁掉。
        final below = pet.top - screen.top < 150;
        // 可交互（可关闭/带动作）气泡才放开指针命中：
        // 默认整层仍 IgnorePointer，桌面点击完全穿透，行为不变。
        final dismissible = state.dismissible && widget.onDismissCare != null;
        final interactive = dismissible || state.onTap != null;
        return Positioned.fill(
          child: IgnorePointer(
            ignoring: !interactive,
            child: CustomSingleChildLayout(
              delegate: PetFlyoutLayout(
                screen: screen,
                pet: pet,
                placement: below
                    ? FlyoutPlacement.below
                    : FlyoutPlacement.above,
                gap: 8,
                padding: 8,
              ),
              child: BubbleWidget(
                state: state,
                tailDown: !below,
                onDismiss: dismissible ? _dismissCare : null,
                // 动作点击：先收气泡再执行（打开面板等），与关闭钮同语义。
                onOpen:
                    state.onTap == null
                        ? null
                        : () {
                            controller.hideBubble();
                            state.onTap!();
                          },
              ),
            ),
          ),
        );
      },
    );
  }

  /// 主动关心被提前关闭：先收起气泡，再记一条拒绝样本。
  void _dismissCare() {
    widget.controller.hideBubble();
    widget.onDismissCare?.call();
  }

  Widget _menuLayer() {
    final controller = widget.controller;
    return AnimatedBuilder(
      animation: controller.panel,
      builder: (context, _) {
        if (controller.panel.value != PetPanel.menu) {
          return const SizedBox.shrink();
        }
        // 单面板菜单：内部按「根/动作/更多」切换视图，定位与点外关闭都在菜单里。
        return PetMenu(
          screen: controller.activeScreen,
          pet: controller.petRect,
          anchor: controller.menuAnchor ?? controller.petRect.center,
          manifest: controller.manifest,
          activeName: widget.activeName,
          onChat: () => controller.openPanel(PetPanel.chat),
          onSettings: () => controller.openPanel(PetPanel.settings),
          onQuit: widget.onQuit,
          onPlayAnimation: controller.playAnimation,
          onClose: controller.closeMenu,
          onResetPosition: controller.resetPosition,
          onOpenApp: widget.onOpenApp,
          onReloadConfig: widget.onReloadConfig,
          onWhisper: widget.onWhisper,
        );
      },
    );
  }

  Widget _panelLayer() {
    final controller = widget.controller;
    return AnimatedBuilder(
      animation: controller.panel,
      builder: (context, _) {
        final panel = controller.panel.value;
        if (panel == null || panel == PetPanel.menu) {
          return const SizedBox.shrink();
        }
        final screen = controller.activeScreen;
        final content = switch (panel) {
          PetPanel.chat => ChatPanel(
            activeName: widget.activeName,
            onSend: widget.onSend,
            onClose: controller.closePanel,
            onAcceptReply: widget.onAcceptReply,
            onRejectReply: widget.onRejectReply,
          ),
          PetPanel.settings => SettingsPage(
            config: widget.config,
            privacy: widget.privacy,
            emotion: widget.emotion,
            appearance: widget.appearance,
            appearanceReason: widget.appearanceReason,
            appearanceProposal: widget.appearanceProposal,
            onAcceptFormProposal: widget.onAcceptFormProposal,
            onRejectFormProposal: widget.onRejectFormProposal,
            memory: widget.memory,
            learning: widget.learning,
            persona: widget.persona,
            onSavePersona: widget.onSavePersona,
            guidelines: widget.guidelines,
            reflectionCount: widget.reflectionCount,
            onAcceptGuideline: widget.onAcceptGuideline,
            onRejectGuideline: widget.onRejectGuideline,
            onArchiveGuideline: widget.onArchiveGuideline,
            onReactivateGuideline: widget.onReactivateGuideline,
            onSave: widget.onSaveConfig,
            onSaveEmotion: widget.onSaveEmotion,
            onEvolveAppearance: widget.onEvolveAppearance,
            onRollbackAppearance: widget.onRollbackAppearance,
            onFreezeAppearance: widget.onFreezeAppearance,
            onCheckAccessibility: widget.onCheckAccessibility,
            onClose: controller.closePanel,
            capabilities: widget.capabilities,
            onProbeCapabilities: widget.onProbeCapabilities,
          ),
          PetPanel.menu => const SizedBox.shrink(),
        };
        // 面板同样点空白处收起；Esc 也收起，避免只能摸鼠标。
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape):
                controller.closePanel,
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: controller.closePanel,
                ),
              ),
              Positioned.fill(
                child: CustomSingleChildLayout(
                  delegate: PetFlyoutLayout(
                    screen: screen,
                    pet: controller.petRect,
                    placement: FlyoutPlacement.panel,
                    padding: 14,
                    gap: 14,
                  ),
                  // 面板直接挂在透明桌宠窗口上，没有 Scaffold：补一层透明
                  // Material，DropdownButton / TextField 等 Material 组件才合法。
                  child: Material(
                    type: MaterialType.transparency,
                    // 对话页用自己的输入框 autofocus；设置页没有输入焦点，
                    // 这里补一个 Focus，Esc 才能从设置页冒泡到快捷键。
                    child: panel == PetPanel.settings
                        ? Focus(autofocus: true, child: content)
                        : content,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
