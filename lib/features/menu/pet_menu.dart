/// 宠物右键菜单：单面板深色菜单，桌面右键与触屏长按共用。
///
/// 结构：根视图（高频入口）→「动作」视图（分类分组动画列表）/
/// 「更多」视图（低频维护入口）。不再使用悬停级联：触屏没有 hover，
/// 且父面板滚动后按索引推算子菜单位置必然错位。
/// 定位统一交给 [PetFlyoutLayout]：先量真实尺寸，再按屏幕边界翻转/夹取。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/flyout_layout.dart';
import '../../core/config/animation_manifest.dart';

/// 菜单当前展示的视图。
enum _MenuView { root, actions, more }

class PetMenu extends StatefulWidget {
  const PetMenu({
    super.key,
    required this.screen,
    required this.pet,
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

  /// 宠物身体矩形：浮层定位在锚点失效时用它兜底。
  final Rect pet;

  /// 右键 / 长按位置（窗口本地坐标）。
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
  static const double _panelWidth = 232;
  static const double _maxPanelHeight = 420;
  static const double _rowHeight = 40;

  static const Color _surface = Color(0xF21B1B20);
  static const Color _border = Color(0x26FFFFFF);
  static const Color _primaryText = Color(0xE6FFFFFF);
  static const Color _secondaryText = Color(0x66FFFFFF);
  static const Color _iconColor = Color(0x99FFFFFF);
  static const Color _dangerText = Color(0xFFFF9A8A);
  static const Color _hover = Color(0x14FFFFFF);

  _MenuView _view = _MenuView.root;
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = widget.screen;
    // 布局尚未就绪（极少见）时宁可不显示，也不要在一个无效矩形里定位。
    if (screen.width <= 0 || screen.height <= 0) {
      return const SizedBox.shrink();
    }
    return Stack(
      children: [
        // 点击/右键空白处关闭；菜单打开期间整窗已由控制器接管鼠标。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            onSecondaryTap: widget.onClose,
          ),
        ),
        Positioned.fill(
          child: CustomSingleChildLayout(
            delegate: PetFlyoutLayout(
              screen: screen,
              pet: widget.pet,
              placement: FlyoutPlacement.pointer,
              anchor: widget.anchor,
              padding: 6,
            ),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
              },
              child: Focus(autofocus: true, child: _panel()),
            ),
          ),
        ),
      ],
    );
  }

  Widget _panel() {
    return Container(
      key: const ValueKey('pet-menu-panel'),
      width: _panelWidth,
      constraints: const BoxConstraints(maxHeight: _maxPanelHeight),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
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
        thickness: 4,
        radius: const Radius.circular(2),
        child: SingleChildScrollView(
          controller: _scroll,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _content(),
          ),
        ),
      ),
    );
  }

  List<Widget> _content() => switch (_view) {
    _MenuView.root => _rootRows(),
    _MenuView.actions => _actionRows(),
    _MenuView.more => _moreRows(),
  };

  // ---------------------------------------------------------------------------
  // 根视图：只放高频入口；低频维护项收进「更多」
  // ---------------------------------------------------------------------------

  List<Widget> _rootRows() => [
    _row(
      icon: Icons.chat_bubble_outline,
      label: '对话',
      onTap: () => _activate(widget.onChat),
    ),
    if (widget.onWhisper != null)
      _row(
        icon: Icons.auto_awesome,
        label: '碎碎念',
        onTap: () => _activate(widget.onWhisper!),
      ),
    if (widget.onOpenApp != null)
      _row(
        icon: Icons.open_in_new,
        label: '打开 ${widget.activeName}',
        onTap: () => _activate(widget.onOpenApp!),
      ),
    _row(
      icon: Icons.animation,
      label: '动作',
      chevron: true,
      onTap: () => _show(_MenuView.actions),
    ),
    _row(
      icon: Icons.settings,
      label: '设置',
      onTap: () => _activate(widget.onSettings),
    ),
    _row(
      icon: Icons.more_horiz,
      label: '更多',
      chevron: true,
      onTap: () => _show(_MenuView.more),
    ),
    _divider(),
    _row(
      icon: Icons.power_settings_new,
      label: '退出大肥鱼助手',
      danger: true,
      onTap: () => _activate(widget.onQuit),
    ),
  ];

  // ---------------------------------------------------------------------------
  // 更多视图：低频但有实际用途的维护入口
  // ---------------------------------------------------------------------------

  List<Widget> _moreRows() => [
    _backRow(),
    if (widget.onResetPosition != null)
      _row(
        icon: Icons.my_location,
        label: '回到初始位置',
        onTap: () => _activate(widget.onResetPosition!),
      ),
    if (widget.onReloadConfig != null)
      _row(
        icon: Icons.refresh,
        label: '重载配置',
        onTap: () => _activate(widget.onReloadConfig!),
      ),
  ];

  // ---------------------------------------------------------------------------
  // 动作视图：分类分组 + 动画名，一屏内滚动，点一次即播放
  // ---------------------------------------------------------------------------

  List<Widget> _actionRows() {
    final groups = _actionGroups();
    return [
      _backRow(),
      for (final group in groups) ...[
        _sectionHeader(group.label),
        for (final name in group.names)
          _row(
            label: name,
            onTap: () => _activate(() => widget.onPlayAnimation(name)),
          ),
      ],
    ];
  }

  List<_ActionGroup> _actionGroups() {
    final manifest = widget.manifest;
    final groups = <_ActionGroup>[];

    void add(String label, Iterable<String> names) {
      final usable = names
          .where(manifest.names.contains)
          .toList(growable: false);
      if (usable.isEmpty) return;
      groups.add(_ActionGroup(label, usable));
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

  // ---------------------------------------------------------------------------
  // 行与切换
  // ---------------------------------------------------------------------------

  Widget _backRow() => _row(
    icon: Icons.chevron_left,
    label: '返回',
    onTap: () => _show(_MenuView.root),
  );

  Widget _divider() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Container(height: 1, color: const Color(0x14FFFFFF)),
  );

  Widget _sectionHeader(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
    child: Text(
      label,
      style: const TextStyle(color: _secondaryText, fontSize: 11),
    ),
  );

  Widget _row({
    required String label,
    required VoidCallback onTap,
    IconData? icon,
    bool chevron = false,
    bool danger = false,
  }) {
    final foreground = danger ? _dangerText : _primaryText;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        mouseCursor: SystemMouseCursors.click,
        hoverColor: _hover,
        splashColor: const Color(0x1AFFFFFF),
        highlightColor: const Color(0x10FFFFFF),
        child: SizedBox(
          height: _rowHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: danger ? foreground : _iconColor),
                  const SizedBox(width: 10),
                ] else
                  const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 13,
                      height: 1.25,
                    ),
                  ),
                ),
                if (chevron)
                  const Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: _secondaryText,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _show(_MenuView view) {
    setState(() => _view = view);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// 所有动作项都先关菜单再执行，避免菜单层挡在结果前面。
  void _activate(VoidCallback action) {
    widget.onClose();
    action();
  }
}

class _ActionGroup {
  const _ActionGroup(this.label, this.names);

  final String label;
  final List<String> names;
}
