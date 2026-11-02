/// 大脑分区：AI 提供者、接口参数与连通性测试。
///
/// 测试逻辑不在这里：设置页用草稿值现场建 provider 发一条 ping，
/// 分区只负责展示结果，保证无状态、可复用。
library;

import 'package:flutter/material.dart';

import 'settings_controls.dart';

class BrainSection extends StatelessWidget {
  const BrainSection({
    super.key,
    required this.provider,
    required this.onProviderChanged,
    required this.baseUrl,
    required this.model,
    required this.interval,
    required this.apiKey,
    required this.apiKeyLoaded,
    required this.testing,
    required this.testResult,
    required this.onTest,
  });

  final String provider;
  final ValueChanged<String> onProviderChanged;

  final TextEditingController baseUrl;
  final TextEditingController model;
  final TextEditingController interval;

  final TextEditingController apiKey;

  /// false = 系统 key 还没读回来：此时清空输入框不代表“清除 key”。
  final bool apiKeyLoaded;

  final bool testing;
  final String testResult;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final canTest = provider != 'none' && !testing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SettingsLabel('提供者'),
        SettingsDropdown<String>(
          value: provider,
          items: const [
            DropdownMenuItem(value: 'none', child: Text('关闭')),
            DropdownMenuItem(value: 'openai', child: Text('OpenAI 兼容接口')),
            DropdownMenuItem(value: 'ollama', child: Text('本地 Ollama')),
          ],
          onChanged: (value) {
            if (value != null) onProviderChanged(value);
          },
        ),
        const SettingsLabel('Base URL'),
        SettingsField(controller: baseUrl, hint: '例如 https://api.openai.com/v1'),
        const SettingsLabel('模型'),
        SettingsField(controller: model, hint: '例如 gpt-4o-mini / qwen2.5'),
        if (provider == 'openai') ...[
          const SettingsLabel('API Key（保存在系统安全存储）'),
          SettingsField(
            controller: apiKey,
            hint: apiKeyLoaded ? '留空表示清除已保存的 key' : '读取中…',
            obscure: true,
          ),
        ],
        const SettingsLabel('自动碎碎念间隔（秒，0 = 只手动）'),
        SettingsField(controller: interval, hint: '例如 300'),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton(
              onPressed: canTest ? onTest : null,
              child: Text(testing ? '测试中…' : '测试连接'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                testResult,
                style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 11),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          '选择“OpenAI 兼容 / 本地 Ollama”后可直接对话；关闭时输入只转发到关联软件。'
          '碎碎念可从右键菜单“让它说句话”立即触发。',
          style: TextStyle(color: Color(0x66FFFFFF), fontSize: 10.5),
        ),
      ],
    );
  }
}
