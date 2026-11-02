/// 学习分区：策略版本 / 待确认提案 / 手动回滚 / 安全边界说明（计划 4.5）。
///
/// 反馈只走接受/拒绝语义：提案列表给“接受/拒绝”，没有评分按钮；
/// 安全边界（身份、价值观、隐私、打扰上限、人格底线）只读展示，不可改。
library;

import 'package:flutter/material.dart';

import '../../../learning/policy_store.dart';
import 'settings_controls.dart';

class LearningSection extends StatelessWidget {
  const LearningSection({
    super.key,
    required this.policy,
    required this.onAcceptProposal,
    required this.onRejectProposal,
    required this.onRollback,
    required this.onRollbackTo,
    required this.hint,
  });

  final PolicyStore? policy;
  final void Function(String id) onAcceptProposal;
  final void Function(String id) onRejectProposal;
  final VoidCallback onRollback;
  final void Function(int version) onRollbackTo;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final store = policy;
    if (store == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text(
          '学习治理还没准备好，稍后再打开设置试试',
          style: TextStyle(color: Color(0x66FFFFFF), fontSize: 12),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsDivider('当前策略'),
        _Row('版本', 'v${store.version}'),
        _Row('应用时间', _formatTime(store.appliedAt)),
        const SizedBox(height: 6),
        Text(
          _summary(store.params),
          style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 11.5),
        ),
        if (store.proposals.isNotEmpty) ...[
          SettingsDivider('待确认提案（${store.proposals.length} 条）'),
          for (final proposal in store.proposals)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          proposal.reason,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12.5,
                          ),
                        ),
                        Text(
                          '${proposal.field} → ${proposal.value}',
                          style: const TextStyle(
                            color: Color(0x59FFFFFF),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => onAcceptProposal(proposal.id),
                    child: const Text(
                      '接受',
                      style: TextStyle(color: Color(0xFF69F0AE), fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () => onRejectProposal(proposal.id),
                    child: const Text(
                      '拒绝',
                      style: TextStyle(color: Color(0xFFFF8A80), fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
        ],
        SettingsDivider('版本历史'),
        for (final snapshot in store.history.reversed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'v${snapshot.version}　${_formatTime(snapshot.appliedAt)}'
                    '${snapshot.note.isEmpty ? '' : '　${snapshot.note}'}',
                    style: const TextStyle(
                      color: Color(0xCCFFFFFF),
                      fontSize: 11.5,
                    ),
                  ),
                ),
                if (snapshot.version != store.version)
                  TextButton(
                    onPressed: () => onRollbackTo(snapshot.version),
                    child: const Text(
                      '回滚到此版',
                      style: TextStyle(color: Color(0xFF80D8FF), fontSize: 11),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: store.history.length < 2 ? null : onRollback,
          child: const Text(
            '回滚到上一版',
            style: TextStyle(color: Color(0xFFFFB74D), fontSize: 12),
          ),
        ),
        const SettingsDivider('安全边界（不可由学习改变）'),
        const Text(
          '身份声明、价值观、隐私权限、主动打扰上限、人格 DNA 底线'
          '由人格档案固定，任何反馈与纠正都不能自动改写；'
          '学习只调整回复长度、表情、表格与关心语气这类表达偏好。',
          style: TextStyle(color: Color(0x80FFFFFF), fontSize: 11, height: 1.5),
        ),
        if (hint.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              hint,
              style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 11),
            ),
          ),
      ],
    );
  }

  static String _summary(PolicyParams params) =>
      '回复：${_replyLength(params.replyLength)}'
      '　表情：${params.emojiUsage == 'none' ? '不用' : '少量'}'
      '　表格：${params.tablePreference == 'avoid' ? '避免' : '可用'}'
      '　关心语气：${params.careTone == 'quiet' ? '克制' : '温暖'}';

  static String _replyLength(String value) => switch (value) {
    'brief' => '简短',
    'detailed' => '详细',
    _ => '适中',
  };

  static String _formatTime(DateTime at) {
    if (at.millisecondsSinceEpoch == 0) return '—';
    String two(int value) => value.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}';
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Text(
          label,
          style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 11.5),
        ),
        const SizedBox(width: 12),
        Text(
          value,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ],
    ),
  );
}
