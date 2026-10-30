/// 宠物右键菜单：与宠物相关的入口都收在这里（对话 / 设置 / 退出）。
///
/// 桌宠窗口默认不抢焦点，菜单只是普通浮层，不依赖系统原生菜单。
/// 视觉上刻意做成“小卡片”而不是系统菜单：分组标题 + 图标底片 + 悬停高亮，
/// 在透明置顶窗里也能看清边界，且尺寸由内容决定，由外层按屏幕边界定位。
library;

import 'package:flutter/material.dart';

class PetMenu extends StatelessWidget {
  const PetMenu({
    super.key,
    required this.petName,
    required this.activeName,
    required this.onChat,
    required this.onSettings,
    required this.onQuit,
    this.onActions,
    this.onResetPosition,
    this.onOpenApp,
    this.onReloadConfig,
    this.onWhisper,
  });

  final String petName;
  final String activeName;
  final VoidCallback onChat;
  final VoidCallback onSettings;
  final VoidCallback onQuit;
  final VoidCallback? onActions;
  final VoidCallback? onResetPosition;
  final VoidCallback? onOpenApp;
  final VoidCallback? onReloadConfig;
  final VoidCallback? onWhisper;

  @override
  Widget build(BuildContext context) {
    final linked = activeName.trim();
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 238,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 7),
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
            BoxShadow(
              color: Color(0x1AFFFFFF),
              blurRadius: 1,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Header(
              petName: petName,
              subtitle: linked.isEmpty ? '桌面伙伴' : '正在与 $linked 联动',
            ),
            const SizedBox(height: 4),
            _MenuEntry(
              icon: Icons.forum_outlined,
              label: '和它说点什么',
              subtitle: linked.isEmpty ? '把话发给当前关联软件' : '把话发给 $linked',
              tint: const Color(0xFF8FB8FF),
              onTap: onChat,
            ),
            if (onWhisper != null)
              _MenuEntry(
                icon: Icons.mode_comment_outlined,
                label: '让它说句话',
                subtitle: '用内置 AI 来一句碎碎念',
                tint: const Color(0xFFFFB3D1),
                onTap: onWhisper!,
              ),
            if (onActions != null)
              _MenuEntry(
                icon: Icons.auto_awesome_motion_rounded,
                label: '动作',
                subtitle: '按分类点播动画',
                tint: const Color(0xFFC39BFF),
                onTap: onActions!,
              ),
            if (onResetPosition != null)
              _MenuEntry(
                icon: Icons.home_outlined,
                label: '回到初始位置',
                subtitle: '停到当前屏幕底部中央',
                tint: const Color(0xFF8FD4C8),
                onTap: onResetPosition!,
              ),
            if (onOpenApp != null && linked.isNotEmpty)
              _MenuEntry(
                icon: Icons.open_in_new_rounded,
                label: '打开 $linked',
                subtitle: '把关联软件唤到前台',
                tint: const Color(0xFFFFC46B),
                onTap: onOpenApp!,
              ),
            if (onReloadConfig != null)
              _MenuEntry(
                icon: Icons.refresh_rounded,
                label: '重新加载配置',
                subtitle: '从 config.jsonc 重读并重启宠物',
                tint: const Color(0xFF9AD9B0),
                onTap: onReloadConfig!,
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 5, 8, 5),
              child: Divider(height: 1, color: Color(0x1FFFFFFF)),
            ),
            _MenuEntry(
              icon: Icons.tune_rounded,
              label: '关联软件设置',
              subtitle: '切换联动软件与投递方式',
              tint: const Color(0xFF9AD9B0),
              onTap: onSettings,
            ),
            _MenuEntry(
              icon: Icons.power_settings_new_rounded,
              label: '退出桌宠',
              subtitle: '菜单栏图标仍可再次唤起',
              tint: const Color(0xFFFF8A8A),
              destructive: true,
              onTap: onQuit,
            ),
          ],
        ),
      ),
    );
  }
}

/// 菜单顶部：宠物名 + 当前联动对象，让“这是谁的菜单”一眼可辨。
class _Header extends StatelessWidget {
  const _Header({required this.petName, required this.subtitle});

  final String petName;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF6C8CFF), Color(0xFF9B7BFF)],
              ),
              borderRadius: BorderRadius.circular(11),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x406C8CFF),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: const Icon(
              Icons.pets_rounded,
              size: 18,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  petName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xF2FFFFFF),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0x80FFFFFF),
                    fontSize: 10.5,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一行菜单：左图标底片 + 主标题/副标题，悬停时整行染色。
///
/// 不用 InkWell：菜单卡片自带不透明底色，InkWell 的水波纹会被盖在下面看不见；
/// 这里用 MouseRegion + AnimatedContainer 给出即时、可预期的悬停反馈。
class _MenuEntry extends StatefulWidget {
  const _MenuEntry({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.tint,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final Color tint;
  final VoidCallback onTap;
  final bool destructive;

  @override
  State<_MenuEntry> createState() => _MenuEntryState();
}

class _MenuEntryState extends State<_MenuEntry> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final hoverColor = widget.destructive
        ? const Color(0x24FF6B6B)
        : const Color(0x14FFFFFF);
    return Semantics(
      button: true,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 110),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            decoration: BoxDecoration(
              color: _hover ? hoverColor : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: widget.tint.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(widget.icon, size: 15, color: widget.tint),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: widget.destructive
                              ? const Color(0xFFFF9A9A)
                              : const Color(0xE6FFFFFF),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        widget.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0x66FFFFFF),
                          fontSize: 10,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
