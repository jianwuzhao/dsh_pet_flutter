/// 隐私分区：四项能力开关 + 辅助功能授权检测。
///
/// 开关只改草稿值（copyWith 回传），落盘与运行时生效都在保存时由
/// 装配层经隐私权限中心完成；这里不做任何 IO。
library;

import 'package:flutter/material.dart';

import '../../../persona/profile_store.dart';
import 'settings_controls.dart';

class PrivacySection extends StatelessWidget {
  const PrivacySection({
    super.key,
    required this.privacy,
    required this.onChanged,
    required this.accessibilityChecking,
    required this.accessibilityResult,
    required this.onCheckAccessibility,
  });

  final PrivacySettings privacy;
  final ValueChanged<PrivacySettings> onChanged;

  final bool accessibilityChecking;
  final String accessibilityResult;
  final VoidCallback onCheckAccessibility;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSwitch(
          value: privacy.screenAwareness,
          onChanged: (value) => onChanged(privacy.copyWith(screenAwareness: value)),
          title: '读取前台窗口标题/正文',
          subtitle: '需辅助功能授权；关闭时只看应用名',
        ),
        SettingsSwitch(
          value: privacy.appWatch,
          onChanged: (value) => onChanged(privacy.copyWith(appWatch: value)),
          title: '感知前台应用切换',
          subtitle: '只看应用名，不读内容',
        ),
        SettingsSwitch(
          value: privacy.memoryRecording,
          onChanged: (value) =>
              onChanged(privacy.copyWith(memoryRecording: value)),
          title: '记录长期记忆',
          subtitle: '关闭后记忆库只读不写',
        ),
        SettingsSwitch(
          value: privacy.proactiveCare,
          onChanged: (value) =>
              onChanged(privacy.copyWith(proactiveCare: value)),
          title: '允许主动关心',
          subtitle: '还要再过安静时段与每日预算',
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton(
              onPressed: accessibilityChecking ? null : onCheckAccessibility,
              child: Text(accessibilityChecking ? '检测中…' : '检测辅助功能授权'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                accessibilityResult,
                style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 11),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          '开关立即决定“能看什么”：正文读取关掉后，碎碎念与上下文只依据应用名，'
          '不会再读窗口内容；记忆与主动关心也各自独立。',
          style: TextStyle(color: Color(0x66FFFFFF), fontSize: 10.5),
        ),
      ],
    );
  }
}
