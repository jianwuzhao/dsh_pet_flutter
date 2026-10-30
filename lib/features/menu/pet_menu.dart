/// 宠物右键菜单：复刻 dsh-pet 的级联系统菜单模式。
///
/// 结构（与上游一致）：
///   一级 = 工具项 + 「动作」
///   二级（动作子级）= 分类：待机/转向/拖拽/点击回应/移动/config 分类/事件档位
///   三级 = 具体动画名
///
/// 交互（与上游一致）：悬停分支向右展开；贴右/下边缘自动向左/上翻转并夹在屏幕内；
/// 每一级是独立面板、各自滚动；指针在整棵菜单树内移动不会收起；离开菜单树 200ms 后关闭；
/// 点击叶子/菜单外关闭。视觉也是上游那套浅色系统菜单（白底、深色 13px 文字、蓝色悬停、圆角 8）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/config/animation_manifest.dart';

/// 菜单节点：叶子可点击；分支带子级。
class PetMenuItem {
  const PetMenuItem.leaf(this.label, this.onTap)
    : children = const <PetMenuItem>[];

  const PetMenuItem.branch(this.label, this.children) : onTap = null;

  final String label;
  final VoidCallback? onTap;
  final List<PetMenuItem> children;

  bool get isBranch => onTap == null;
}

class PetMenu extends StatefulWidget {
  const PetMenu({
    super.key,
    required this.screen,
    required this.anchor,
    required this.manifest,
    required this.activeName,
    required this.onChat,
    required this.onSettings,
    required this.onQuit,
    required this.onPlayAnimation,
    required this.onClose,
    this.onResetPosition,
    this.onOpenApp,
    this.onReloadConfig,
    this.onWhisper,
  });

  /// 当前屏幕可见区（窗口本地坐标）。
  final Rect screen;

  /// 右键位置（窗口本地坐标）。
  final Offset anchor;

  final AnimationManifest manifest;
  final String activeName;
  final VoidCallback onChat;
  final VoidCallback onSettings;
  final VoidCallback onQuit;
  final ValueChanged<String> onPlayAnimation;
  final VoidCallback onClose;
  final VoidCallback? onResetPosition;
  final VoidCallback? onOpenApp;
  final VoidCallback? onReloadConfig;
  final VoidCallback? onWhisper;

  @override
  State<PetMenu> createState() => _PetMenuState();
}

class _PetMenuState extends State<PetMenu> {
  static const double _rowHeight = 28;
  static const double _panelPadding = 4;
  static const double _maxPanelHeight = 460;
  static const double _rootWidth = 196;
  static const double _categoriesWidth = 168;
  static const double _actionsWidth = 236;

  int? _openRootIndex;
  int? _openCategoryIndex;
  Timer? _closeTimer;

  @override
  void dispose() {
    _closeTimer?.cancel();
    super.dispose();
  }

  void _cancelClose() {
    _closeTimer?.cancel();
    _closeTimer = null;
  }

  /// 上游的软关闭：指针离开菜单树 200ms 后才收起；移到相邻子面板会把它取消。
  void _scheduleClose() {
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) widget.onClose();
    });
  }

  List<PetMenuItem> get _rootItems {
    final items = <PetMenuItem>[
      if (widget.onOpenApp != null)
        PetMenuItem.leaf('打开 ${widget.activeName}', widget.onOpenApp!),
      if (widget.onWhisper != null) PetMenuItem.leaf('碎碎念', widget.onWhisper!),
      PetMenuItem.leaf('对话', widget.onChat),
      if (widget.onResetPosition != null)
        PetMenuItem.leaf('回到初始位置', widget.onResetPosition!),
      if (widget.onReloadConfig != null)
        PetMenuItem.leaf('重载配置', widget.onReloadConfig!),
      PetMenuItem.leaf('设置', widget.onSettings),
      PetMenuItem.leaf('退出桌宠', widget.onQuit),
    ];
    final actions = _actionGroups();
    if (actions.isNotEmpty) {
      items.add(PetMenuItem.branch('动作', actions));
    }
    return items;
  }

  List<PetMenuItem> _actionGroups() {
    final manifest = widget.manifest;
    final groups = <PetMenuItem>[];

    void add(String label, Iterable<String> names) {
      final usable = names
          .where(manifest.names.contains)
          .toList(growable: false);
      if (usable.isEmpty) return;
      groups.add(
        PetMenuItem.branch(label, [
          for (final name in usable)
            PetMenuItem.leaf(name, () => widget.onPlayAnimation(name)),
        ]),
      );
    }

    add('待机', manifest.idle);
    add('转向', manifest.turn);
    add('拖拽', manifest.drag);
    add('点击回应', manifest.clicks);
    add('移动', [for (final move in manifest.moves) move.name]);
    for (final category in manifest.categories) {
      add(category.id, category.actions);
    }
    add('工作状态', manifest.events['workStatus'] ?? const []);
    add('碎碎念', manifest.events['whisper'] ?? const []);
    add('余额档位', manifest.events['balance'] ?? const []);
    return groups;
  }

  double _panelHeight(int count) =>
      math.min(_maxPanelHeight, _panelPadding * 2 + count * _rowHeight);

  Offset _placeRoot(double width, double height) {
    final screen = widget.screen;
    final minX = screen.left + 4;
    final minY = screen.top + 4;
    final maxX = math.max(minX, screen.right - 4 - width);
    final maxY = math.max(minY, screen.bottom - 4 - height);
    var x = widget.anchor.dx;
    var y = widget.anchor.dy;
    if (x + width > screen.right - 4) x = widget.anchor.dx - width;
    if (y + height > screen.bottom - 4) y = widget.anchor.dy - height;
    return Offset(x.clamp(minX, maxX), y.clamp(minY, maxY));
  }

  Offset _placeSub({
    required Offset parent,
    required double parentWidth,
    required double itemTop,
    required double width,
    required double height,
    required bool preferLeft,
  }) {
    final screen = widget.screen;
    final minX = screen.left + 4;
    final maxX = math.max(minX, screen.right - 4 - width);
    final minY = screen.top + 4;
    final maxY = math.max(minY, screen.bottom - 4 - height);

    var x = preferLeft ? parent.dx - width - 4 : parent.dx + parentWidth + 4;
    if (x + width > screen.right - 4) x = parent.dx - width - 4;
    if (x < screen.left + 4) x = parent.dx + parentWidth + 4;
    var y = itemTop;
    if (y + height > screen.bottom - 4) y = screen.bottom - 4 - height;
    return Offset(x.clamp(minX, maxX), y.clamp(minY, maxY));
  }

  void _onRootHover(int index, PetMenuItem item) {
    _cancelClose();
    if (item.isBranch) {
      if (_openRootIndex != index || _openCategoryIndex != null) {
        setState(() {
          _openRootIndex = index;
          _openCategoryIndex = null;
        });
      }
    } else if (_openRootIndex != null || _openCategoryIndex != null) {
      setState(() {
        _openRootIndex = null;
        _openCategoryIndex = null;
      });
    }
  }

  void _onRootTap(int index, PetMenuItem item) {
    _cancelClose();
    if (!item.isBranch) {
      _activate(item);
      return;
    }
    setState(() {
      _openRootIndex = index;
      _openCategoryIndex = null;
    });
  }

  void _onCategoryHover(int index) {
    _cancelClose();
    if (_openCategoryIndex != index) {
      setState(() => _openCategoryIndex = index);
    }
  }

  void _onCategoryTap(int index, PetMenuItem item) {
    _cancelClose();
    setState(() => _openCategoryIndex = index);
  }

  void _activate(PetMenuItem item) {
    _cancelClose();
    widget.onClose();
    item.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final root = _rootItems;
    if (root.isEmpty) return const SizedBox.shrink();

    final rootHeight = _panelHeight(root.length);
    final rootPos = _placeRoot(_rootWidth, rootHeight);
    final rootIndex = _openRootIndex;
    final rootBranch =
        rootIndex != null && rootIndex < root.length && root[rootIndex].isBranch
        ? root[rootIndex]
        : null;
    final categories = rootBranch?.children ?? const <PetMenuItem>[];

    final categoriesHeight = _panelHeight(categories.length);
    final categoriesPos = categories.isEmpty
        ? null
        : _placeSub(
            parent: rootPos,
            parentWidth: _rootWidth,
            itemTop: rootPos.dy + _panelPadding + (rootIndex ?? 0) * _rowHeight,
            width: _categoriesWidth,
            height: categoriesHeight,
            preferLeft:
                rootPos.dx + _rootWidth + 4 + _categoriesWidth >
                widget.screen.right - 4,
          );

    final categoryIndex = _openCategoryIndex;
    final categoryBranch =
        categoriesPos != null &&
            categoryIndex != null &&
            categoryIndex < categories.length &&
            categories[categoryIndex].isBranch
        ? categories[categoryIndex]
        : null;
    final actions = categoryBranch?.children ?? const <PetMenuItem>[];

    final actionsHeight = _panelHeight(actions.length);
    final actionsPos = actions.isEmpty || categoriesPos == null
        ? null
        : _placeSub(
            parent: categoriesPos,
            parentWidth: _categoriesWidth,
            itemTop:
                categoriesPos.dy +
                _panelPadding +
                (categoryIndex ?? 0) * _rowHeight,
            width: _actionsWidth,
            height: actionsHeight,
            preferLeft: categoriesPos.dx < rootPos.dx,
          );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            onSecondaryTap: widget.onClose,
          ),
        ),
        _panel(
          nodes: root,
          position: rootPos,
          width: _rootWidth,
          height: rootHeight,
          activeIndex: rootIndex,
          onHover: _onRootHover,
          onTap: _onRootTap,
        ),
        if (categoriesPos != null)
          _panel(
            nodes: categories,
            position: categoriesPos,
            width: _categoriesWidth,
            height: categoriesHeight,
            activeIndex: categoryIndex,
            onHover: (index, _) => _onCategoryHover(index),
            onTap: _onCategoryTap,
          ),
        if (actionsPos != null)
          _panel(
            nodes: actions,
            position: actionsPos,
            width: _actionsWidth,
            height: actionsHeight,
            activeIndex: null,
            onHover: (_, _) {},
            onTap: (_, item) => _activate(item),
          ),
      ],
    );
  }

  Widget _panel({
    required List<PetMenuItem> nodes,
    required Offset position,
    required double width,
    required double height,
    required int? activeIndex,
    required void Function(int index, PetMenuItem item) onHover,
    required void Function(int index, PetMenuItem item) onTap,
  }) {
    return Positioned(
      left: position.dx,
      top: position.dy,
      child: _MenuPanel(
        nodes: nodes,
        width: width,
        height: height,
        activeIndex: activeIndex,
        onHover: onHover,
        onTap: onTap,
        onEnter: _cancelClose,
        onExit: _scheduleClose,
      ),
    );
  }
}

/// 一级独立面板：白底、圆角 8、独立滚动，绝不把子面板嵌进父面板里。
class _MenuPanel extends StatefulWidget {
  const _MenuPanel({
    required this.nodes,
    required this.width,
    required this.height,
    required this.activeIndex,
    required this.onHover,
    required this.onTap,
    required this.onEnter,
    required this.onExit,
  });

  final List<PetMenuItem> nodes;
  final double width;
  final double height;
  final int? activeIndex;
  final void Function(int index, PetMenuItem item) onHover;
  final void Function(int index, PetMenuItem item) onTap;
  final VoidCallback onEnter;
  final VoidCallback onExit;

  @override
  State<_MenuPanel> createState() => _MenuPanelState();
}

class _MenuPanelState extends State<_MenuPanel> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => widget.onEnter(),
      onExit: (_) => widget.onExit(),
      // 面板背景也要吃掉点击：dsh-pet 里点面板空白处不会把整棵菜单关掉。
      // 没有这层时，面板 padding/行间空隙的点击会穿透到后面的 barrier。
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: Container(
          width: widget.width,
          height: widget.height,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: const Color(0xFAFFFFFF),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0x1F000000)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 18,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            thickness: 6,
            radius: const Radius.circular(3),
            child: SingleChildScrollView(
              controller: _scroll,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < widget.nodes.length; i++)
                    _MenuRow(
                      node: widget.nodes[i],
                      active: widget.activeIndex == i,
                      onEnter: () => widget.onHover(i, widget.nodes[i]),
                      onTap: () => widget.onTap(i, widget.nodes[i]),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatefulWidget {
  const _MenuRow({
    required this.node,
    required this.active,
    required this.onEnter,
    required this.onTap,
  });

  final PetMenuItem node;
  final bool active;
  final VoidCallback onEnter;
  final VoidCallback onTap;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final background = _hover
        ? const Color(0x242B63FF)
        : widget.active
        ? const Color(0x142B63FF)
        : Colors.transparent;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hover = true);
        widget.onEnter();
      },
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.node.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF2B2B2B),
                    fontSize: 13,
                    height: 1.3,
                  ),
                ),
              ),
              if (widget.node.isBranch)
                const Icon(
                  Icons.chevron_right,
                  size: 16,
                  color: Color(0xFF9AA0A6),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
