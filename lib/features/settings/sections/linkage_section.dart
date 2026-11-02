/// 联动分区：关联软件选择、投递参数、全局快捷键。
///
/// 只负责展示草稿值；组装与校验留在设置页（保存时统一做）。
library;

import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import 'settings_controls.dart';

class LinkageSection extends StatelessWidget {
  const LinkageSection({
    super.key,
    required this.adapters,
    required this.active,
    required this.onActiveChanged,
    required this.bundleId,
    required this.uriTemplate,
    required this.endpoint,
    required this.delivery,
    required this.onDeliveryChanged,
    required this.hotkey,
  });

  final List<AdapterConfig> adapters;
  final String active;
  final ValueChanged<String> onActiveChanged;

  final TextEditingController bundleId;
  final TextEditingController uriTemplate;
  final TextEditingController endpoint;

  final DeliveryMode delivery;
  final ValueChanged<DeliveryMode> onDeliveryChanged;

  /// 全局唤起热键（cmd+shift+p 形式；校验在保存时做，这里只收草稿）。
  final TextEditingController hotkey;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SettingsLabel('当前关联'),
        SettingsDropdown<String>(
          value: active.isEmpty ? null : active,
          items: [
            for (final adapter in adapters)
              DropdownMenuItem(
                value: adapter.id,
                child: Text(adapter.displayName),
              ),
          ],
          onChanged: (value) {
            if (value != null) onActiveChanged(value);
          },
        ),
        const SettingsLabel('Bundle ID'),
        SettingsField(controller: bundleId, hint: '例如 cn.trae.app'),
        const SettingsLabel('唤起深链（{prompt} 会被替换）'),
        SettingsField(controller: uriTemplate, hint: '例如 trae-cn://'),
        const SettingsLabel('投递模式'),
        SettingsDropdown<DeliveryMode>(
          value: delivery,
          items: const [
            DropdownMenuItem(
              value: DeliveryMode.clipboard,
              child: Text('剪贴板 + 激活 + 回车'),
            ),
            DropdownMenuItem(value: DeliveryMode.uri, child: Text('深链唤起')),
            DropdownMenuItem(value: DeliveryMode.http, child: Text('HTTP 端点')),
            DropdownMenuItem(value: DeliveryMode.ws, child: Text('WebSocket 端点')),
          ],
          onChanged: (value) {
            if (value != null) onDeliveryChanged(value);
          },
        ),
        if (delivery == DeliveryMode.http || delivery == DeliveryMode.ws) ...[
          const SettingsLabel('端点地址'),
          SettingsField(controller: endpoint, hint: '例如 http://127.0.0.1:9000/prompt'),
        ],
        const SettingsDivider('全局快捷键'),
        const SettingsLabel('唤起对话面板（至少一个 cmd/ctrl/alt）'),
        SettingsField(controller: hotkey, hint: '例如 cmd+shift+p'),
      ],
    );
  }
}
