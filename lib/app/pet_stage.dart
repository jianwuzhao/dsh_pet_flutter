/// 页面装配：把宠物层、气泡层、菜单层、浮层叠成一个全屏透明舞台。
///
/// 只有各层需要重绘的部分挂 ValueListenable，避免 60Hz 重建整个页面。
/// 浮层定位统一走 [PetFlyoutLayout]：按宠物当前所在屏幕决定位置并做翻转，
/// 不再用“整窗并集”的宽高硬算（多屏时会把菜单/面板送到另一块屏或屏缝里）。
library;

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
import 'flyout_layout.dart';

class PetStage extends StatefulWidget {
  const PetStage({
    super.key,
    required this.controller,
    required this.activeName,
    required this.config,
    required this.onSend,
    required this.onSaveConfig,
    required this.onQuit,
    this.onOpenApp,
    this.onReloadConfig,
    this.onWhisper,
  });

  final PetController controller;
  final String activeName;
  final AppConfig config;
  final Future<Result<DispatchOutcome>> Function(String prompt) onSend;
  final Future<Result<void>> Function(AppConfig config) onSaveConfig;
  final VoidCallback onQuit;
  final VoidCallback? onOpenApp;
  final VoidCallback? onReloadConfig;
  final VoidCallback? onWhisper;

  @override
  State<PetStage> createState() => _PetStageState();
}

class _PetStageState extends State<PetStage> {
  Size? _lastSize;

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
    return ValueListenableBuilder<Offset>(
      valueListenable: controller.position,
      builder: (context, position, child) => Positioned(
        left: position.dx,
        top: position.dy,
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
                child: PetView(controller: controller),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _bubbleLayer() {
    final controller = widget.controller;
    return AnimatedBuilder(
      animation: Listenable.merge([controller.bubble, controller.position]),
      builder: (context, _) {
        final state = controller.bubble.value;
        if (state == null) return const SizedBox.shrink();
        final screen = controller.activeScreen;
        final pet = controller.petRect;
        // 头顶空间不够时气泡翻到脚下，避免贴顶时被窗口裁掉。
        final below = pet.top - screen.top < 150;
        return Positioned.fill(
          child: IgnorePointer(
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
              child: BubbleWidget(state: state, tailDown: !below),
            ),
          ),
        );
      },
    );
  }

  Widget _menuLayer() {
    final controller = widget.controller;
    return AnimatedBuilder(
      animation: controller.panel,
      builder: (context, _) {
        if (controller.panel.value != PetPanel.menu) {
          return const SizedBox.shrink();
        }
        // dsh-pet 模式：菜单自己负责根面板/级联子面板的定位与点外关闭。
        return PetMenu(
          screen: controller.activeScreen,
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
          ),
          PetPanel.settings => SettingsPage(
            config: widget.config,
            onSave: widget.onSaveConfig,
            onClose: controller.closePanel,
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
                  // 对话页用自己的输入框 autofocus；设置页没有输入焦点，
                  // 这里补一个 Focus，Esc 才能从设置页冒泡到快捷键。
                  child: panel == PetPanel.settings
                      ? Focus(autofocus: true, child: content)
                      : content,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
