/// 记忆分区：用户权利四件套（查看/纠正/遗忘/导出）+ 待确认提案队列。
///
/// 反馈全部走接受/拒绝语义（计划 4.5）：LLM 候选是提案，接受才生效、
/// 拒绝即丢弃——不做 👍/👎 评分。分区无状态，数据快照与操作结果
/// 由设置页 State 持有。
library;

import 'package:flutter/material.dart';

import '../../../persona/memory/memory_entry.dart';
import 'settings_controls.dart';

/// 类型中文标签：偏好/事实/待办/事件。
String memoryKindLabel(MemoryKind kind) => switch (kind) {
  MemoryKind.preference => '偏好',
  MemoryKind.fact => '事实',
  MemoryKind.task => '待办',
  MemoryKind.episode => '事件',
};

class MemorySection extends StatelessWidget {
  const MemorySection({
    super.key,
    required this.pending,
    required this.memories,
    required this.filter,
    required this.onFilterChanged,
    required this.onConfirm,
    required this.onReject,
    required this.onEdit,
    required this.onForget,
    required this.onClearKind,
    required this.onExport,
    required this.hint,
  });

  /// 待确认提案：LLM 从对话里学到的候选，接受才生效。
  final List<MemoryEntry> pending;

  /// 当前筛选下的已生效记忆（含 scope=local，仅本地展示不注入对话）。
  final List<MemoryEntry> memories;

  /// null = 全部类型。
  final MemoryKind? filter;
  final ValueChanged<MemoryKind?> onFilterChanged;
  final void Function(String id) onConfirm;
  final void Function(String id) onReject;

  /// 纠正：分区弹框收新内容，回调只带改后的条目。
  final void Function(MemoryEntry entry) onEdit;
  final void Function(String id) onForget;
  final void Function(MemoryKind kind) onClearKind;
  final VoidCallback onExport;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (pending.isNotEmpty) ...[
          SettingsDivider('待确认提案（$pendingCount 条）'),
          for (final proposal in pending)
            _ProposalTile(
              proposal: proposal,
              onConfirm: () => onConfirm(proposal.id),
              onReject: () => onReject(proposal.id),
            ),
        ],
        const SettingsDivider('记忆库'),
        SettingsDropdown<MemoryKind?>(
          value: filter,
          items: [
            const DropdownMenuItem(value: null, child: Text('全部类型')),
            for (final kind in MemoryKind.values)
              DropdownMenuItem(value: kind, child: Text(memoryKindLabel(kind))),
          ],
          onChanged: onFilterChanged,
        ),
        if (memories.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '还没有记忆。对它说“以后叫我老板”试试。',
              style: TextStyle(color: Color(0x66FFFFFF), fontSize: 11.5),
            ),
          )
        else
          for (final entry in memories)
            _MemoryTile(
              entry: entry,
              onEdit: () => _editDialog(context, entry),
              onForget: () => onForget(entry.id),
            ),
        const SizedBox(height: 12),
        Row(
          children: [
            TextButton(
              // 只清当前筛选的类型，防“全部”一键全删。
              onPressed: filter == null ? null : () => onClearKind(filter!),
              child: Text(
                filter == null ? '选择类型后可清空' : '清空${memoryKindLabel(filter!)}',
                style: const TextStyle(color: Color(0xFFFF8A80), fontSize: 12),
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: onExport,
              child: const Text(
                '导出全部记忆',
                style: TextStyle(color: Color(0xFF80D8FF), fontSize: 12),
              ),
            ),
          ],
        ),
        if (hint.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              hint,
              style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 11),
            ),
          ),
      ],
    );
  }

  int get pendingCount => pending.length;

  Future<void> _editDialog(BuildContext context, MemoryEntry entry) async {
    final controller = TextEditingController(text: entry.content);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF26262C),
        title: const Text(
          '纠正记忆',
          style: TextStyle(color: Colors.white, fontSize: 15),
        ),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final content = controller.text.trim();
    controller.dispose();
    if (content.isEmpty || content == entry.content) return;
    onEdit(entry.copyWith(content: content));
  }
}

class _ProposalTile extends StatelessWidget {
  const _ProposalTile({
    required this.proposal,
    required this.onConfirm,
    required this.onReject,
  });

  final MemoryEntry proposal;
  final VoidCallback onConfirm;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  proposal.content,
                  style: const TextStyle(color: Colors.white, fontSize: 12.5),
                ),
                Text(
                  '从对话学到的${memoryKindLabel(proposal.kind)}提案',
                  style: const TextStyle(color: Color(0x59FFFFFF), fontSize: 10),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onConfirm,
            child: const Text(
              '接受',
              style: TextStyle(color: Color(0xFF69F0AE), fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: onReject,
            child: const Text(
              '拒绝',
              style: TextStyle(color: Color(0xFFFF8A80), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemoryTile extends StatelessWidget {
  const _MemoryTile({
    required this.entry,
    required this.onEdit,
    required this.onForget,
  });

  final MemoryEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final subtitle = entry.scope == memoryScopeLocal ? '仅本地展示，不注入对话' : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0x1FFFFFFF),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              memoryKindLabel(entry.kind),
              style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 10),
            ),
          ),
          Expanded(
            child: Text(
              entry.content,
              style: const TextStyle(color: Colors.white, fontSize: 12.5),
            ),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                subtitle,
                style: const TextStyle(color: Color(0x59FFFFFF), fontSize: 10),
              ),
            ),
          TextButton(onPressed: onEdit, child: const Text('纠正')),
          TextButton(
            onPressed: onForget,
            child: const Text(
              '遗忘',
              style: TextStyle(color: Color(0xFFFF8A80)),
            ),
          ),
        ],
      ),
    );
  }
}
