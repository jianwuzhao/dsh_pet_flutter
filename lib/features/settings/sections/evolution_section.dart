/// 进化分区：反思数量、待确认准则、已生效准则与停用入口。
///
/// 准则全部来自用户纠正的重复出现；接受后才注入 system prompt。
/// 没有“自动应用”按钮，避免自我演化绕过用户判断。
library;

import 'package:flutter/material.dart';

import '../../../learning/guideline_store.dart';
import 'settings_controls.dart';

class EvolutionSection extends StatelessWidget {
  const EvolutionSection({
    super.key,
    required this.guidelines,
    required this.reflectionCount,
    required this.onAccept,
    required this.onReject,
    required this.onArchive,
    required this.onReactivate,
    required this.onAcceptRetire,
    required this.onRejectRetire,
    required this.onAcceptRewrite,
    required this.onRejectRewrite,
    required this.hint,
  });

  final GuidelineStore? guidelines;
  final int reflectionCount;
  final void Function(String id) onAccept;
  final void Function(String id) onReject;
  final void Function(String id) onArchive;
  final void Function(String id) onReactivate;

  /// 停用提案（P1-2 有效性回路）：接受=停用低效准则；拒绝=保留。
  final void Function(String proposalId) onAcceptRetire;
  final void Function(String proposalId) onRejectRetire;

  /// 措辞替换提案（P1-5 影子试验）：接受=只换 content；
  /// 拒绝=保留原文且本次运行不再试验。
  final void Function(String proposalId) onAcceptRewrite;
  final void Function(String proposalId) onRejectRewrite;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final store = guidelines;
    if (store == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text(
          '进化引擎还没准备好，稍后再打开设置试试',
          style: TextStyle(color: Color(0x66FFFFFF), fontSize: 12),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SettingsDivider('反思流水'),
        Text(
          '已记录 $reflectionCount 条任务/纠正/反馈反思；'
          '同一纠正 30 天内出现至少 2 次才会生成准则提案。',
          style: const TextStyle(
            color: Color(0x99FFFFFF),
            fontSize: 11.5,
            height: 1.5,
          ),
        ),
        if (store.pending.isNotEmpty) ...[
          SettingsDivider('待确认准则（${store.pending.length} 条）'),
          for (final item in store.pending)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12.5,
                          ),
                        ),
                        Text(
                          item.content,
                          style: const TextStyle(
                            color: Color(0x99FFFFFF),
                            fontSize: 11,
                            height: 1.45,
                          ),
                        ),
                        if (item.evidence.isNotEmpty)
                          Text(
                            item.evidence.join(' · '),
                            style: const TextStyle(
                              color: Color(0x59FFFFFF),
                              fontSize: 10,
                            ),
                          ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => onAccept(item.id),
                    child: const Text(
                      '接受',
                      style: TextStyle(color: Color(0xFF69F0AE), fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () => onReject(item.id),
                    child: const Text(
                      '拒绝',
                      style: TextStyle(color: Color(0xFFFF8A80), fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
        ],
        if (store.retireProposals.isNotEmpty) ...[
          SettingsDivider('停用提案（${store.retireProposals.length} 条）'),
          for (final proposal in store.retireProposals)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          proposal.title,
                          style: const TextStyle(
                            color: Color(0xFFFFB74D),
                            fontSize: 12.5,
                          ),
                        ),
                        Text(
                          proposal.reason,
                          style: const TextStyle(
                            color: Color(0x99FFFFFF),
                            fontSize: 11,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => onAcceptRetire(proposal.id),
                    child: const Text(
                      '停用',
                      style: TextStyle(color: Color(0xFFFF8A80), fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () => onRejectRetire(proposal.id),
                    child: const Text(
                      '保留',
                      style: TextStyle(color: Color(0xFF69F0AE), fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
        ],
        if (store.rewriteProposals.isNotEmpty) ...[
          SettingsDivider('措辞替换提案（${store.rewriteProposals.length} 条）'),
          for (final proposal in store.rewriteProposals)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          proposal.title,
                          style: const TextStyle(
                            color: Color(0xFFFFB74D),
                            fontSize: 12.5,
                          ),
                        ),
                        Text(
                          '现：${proposal.previousContent}\n新：${proposal.candidate}',
                          style: const TextStyle(
                            color: Color(0x99FFFFFF),
                            fontSize: 11,
                            height: 1.45,
                          ),
                        ),
                        Text(
                          proposal.reason,
                          style: const TextStyle(
                            color: Color(0x59FFFFFF),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => onAcceptRewrite(proposal.id),
                    child: const Text(
                      '换新措辞',
                      style: TextStyle(color: Color(0xFF69F0AE), fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () => onRejectRewrite(proposal.id),
                    child: const Text(
                      '保留原文',
                      style: TextStyle(color: Color(0xFFFFB74D), fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
        ],
        const SettingsDivider('已生效准则'),
        if (store.active.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '还没有已生效准则。拒绝回复时可附一句纠正，重复出现后会生成提案。',
              style: TextStyle(color: Color(0x66FFFFFF), fontSize: 11),
            ),
          )
        else
          for (final item in store.active)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.content,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          'v${item.version} · 已注入 ${item.useCount} 次'
                          '${item.correctedAfterUse > 0 ? ' · 注入后纠正 ${item.correctedAfterUse} 次' : ''}'
                          '${item.approvedAt == null ? '' : ' · ${_formatTime(item.approvedAt!)}'}',
                          style: const TextStyle(
                            color: Color(0x59FFFFFF),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => onArchive(item.id),
                    child: const Text(
                      '停用',
                      style: TextStyle(color: Color(0xFFFFB74D), fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
        if (store.archived.isNotEmpty) ...[
          SettingsDivider('已停用准则（${store.archived.length} 条）'),
          for (final item in store.archived)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.content,
                          style: const TextStyle(
                            color: Color(0xB3FFFFFF),
                            fontSize: 11.5,
                          ),
                        ),
                        Text(
                          'v${item.version}'
                          '${item.history.isEmpty ? '' : ' · ${item.history.length} 次变更'}',
                          style: const TextStyle(
                            color: Color(0x59FFFFFF),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => onReactivate(item.id),
                    child: const Text(
                      '恢复',
                      style: TextStyle(color: Color(0xFF69F0AE), fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
        ],
        const SizedBox(height: 6),
        const Text(
          '准则是注入对话的软规则（倾向性建议），不会替你执行动作或修改代码。'
          '由用户确认后才生效，不能改身份、隐私、权限、打扰上限或人格底线；'
          '接受/拒绝/停用/恢复都会写历史，误停用可随时恢复。',
          style: TextStyle(
            color: Color(0x66FFFFFF),
            fontSize: 10.5,
            height: 1.5,
          ),
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

  static String _formatTime(DateTime at) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}';
  }
}
