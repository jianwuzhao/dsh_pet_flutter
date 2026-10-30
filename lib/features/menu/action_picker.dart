/// 动作点播面板：把 manifest 里的分类/事件动画摊成“分类 → 具体动作”。
///
/// 上游右键菜单的动作项是桌宠最常用的入口（不用等随机链抽到想看的动作）。
/// 这里用同一套分类口径：待机 / 转向 / 拖拽 / 点击回应 / 移动 / manifest.categories
/// / 工作状态 / 碎碎念 / 余额；点一个立即播放并收起面板。
library;

import 'package:flutter/material.dart';

import '../../core/config/animation_manifest.dart';

class ActionPicker extends StatefulWidget {
  const ActionPicker({
    super.key,
    required this.manifest,
    required this.onPick,
    required this.onClose,
  });

  final AnimationManifest manifest;
  final ValueChanged<String> onPick;
  final VoidCallback onClose;

  @override
  State<ActionPicker> createState() => _ActionPickerState();
}

class _ActionCategory {
  const _ActionCategory(this.title, this.names);

  final String title;
  final List<String> names;
}

class _ActionPickerState extends State<ActionPicker> {
  int _selected = 0;

  List<_ActionCategory> get _categories {
    final manifest = widget.manifest;
    final all = <_ActionCategory>[
      _ActionCategory('待机', manifest.idle),
      _ActionCategory('转向', manifest.turn),
      _ActionCategory('拖拽', manifest.drag),
      _ActionCategory('点击回应', manifest.clicks),
      _ActionCategory('移动', [for (final move in manifest.moves) move.name]),
      for (final category in manifest.categories)
        _ActionCategory(category.id, category.actions),
      _ActionCategory('工作状态', manifest.events['workStatus'] ?? const []),
      _ActionCategory('碎碎念', manifest.events['whisper'] ?? const []),
      _ActionCategory('余额', manifest.events['balance'] ?? const []),
    ];
    return [
      for (final category in all)
        if (category.names.any(manifest.names.contains))
          _ActionCategory(
            category.title,
            category.names
                .where(manifest.names.contains)
                .toList(growable: false),
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final categories = _categories;
    if (categories.isEmpty) {
      return _card(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(),
            const SizedBox(height: 18),
            const Text(
              '没有可用动画',
              style: TextStyle(color: Color(0x99FFFFFF), fontSize: 12),
            ),
            const SizedBox(height: 12),
          ],
        ),
      );
    }
    final selected = _selected.clamp(0, categories.length - 1);
    final actions = categories[selected].names;

    return _card(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < categories.length; i++)
                  _CategoryChip(
                    label: categories[i].title,
                    selected: i == selected,
                    onTap: () => setState(() => _selected = i),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          const Divider(height: 1, color: Color(0x1FFFFFFF)),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final name in actions)
                    _ActionChip(name: name, onTap: () => widget.onPick(name)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 320,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(
          color: const Color(0xF71A1A20),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0x1FFFFFFF)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 28,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: child,
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        const Expanded(
          child: Text(
            '动作点播',
            style: TextStyle(
              color: Color(0xF2FFFFFF),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        IconButton(
          onPressed: widget.onClose,
          icon: const Icon(Icons.close, size: 17, color: Color(0xB3FFFFFF)),
          tooltip: '关闭',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? const Color(0x336C8CFF) : const Color(0x14FFFFFF),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? const Color(0x668FB8FF) : Colors.transparent,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected
                  ? const Color(0xFFBBD1FF)
                  : const Color(0x99FFFFFF),
              fontSize: 11,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionChip extends StatefulWidget {
  const _ActionChip({required this.name, required this.onTap});

  final String name;
  final VoidCallback onTap;

  @override
  State<_ActionChip> createState() => _ActionChipState();
}

class _ActionChipState extends State<_ActionChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          constraints: const BoxConstraints(maxWidth: 286),
          decoration: BoxDecoration(
            color: _hover ? const Color(0x1F8FB8FF) : const Color(0x0FFFFFFF),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: _hover ? const Color(0x4D8FB8FF) : const Color(0x14FFFFFF),
            ),
          ),
          child: Text(
            widget.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _hover ? const Color(0xFFE8F0FF) : const Color(0xCCFFFFFF),
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}
