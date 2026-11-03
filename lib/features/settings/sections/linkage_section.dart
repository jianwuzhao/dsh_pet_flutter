/// 联动分区：关联软件选择、投递参数、全局快捷键。
///
/// 只负责展示草稿值；组装与校验留在设置页（保存时统一做）。
library;

import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../interop/capability.dart';
import '../../../interop/capability_registry.dart';
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
    this.capabilities,
    this.onProbeCapabilities,
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

  /// 能力注册表（只读）：展示各外部软件的探测结果。
  final CapabilityRegistry? capabilities;

  /// 手动重新探测（忽略缓存）。
  final VoidCallback? onProbeCapabilities;

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
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            '说明：当「大脑」里配置了可回复的提供者时，输入由本地对话接管；'
            '关联软件只在提供者关闭/不可回复时用于转发与状态回显。',
            style: TextStyle(
              color: Color(0x66FFFFFF),
              fontSize: 10.5,
              height: 1.5,
            ),
          ),
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
            DropdownMenuItem(
              value: DeliveryMode.ws,
              child: Text('WebSocket 端点'),
            ),
          ],
          onChanged: (value) {
            if (value != null) onDeliveryChanged(value);
          },
        ),
        if (delivery == DeliveryMode.http || delivery == DeliveryMode.ws) ...[
          const SettingsLabel('端点地址'),
          SettingsField(
            controller: endpoint,
            hint: '例如 http://127.0.0.1:9000/prompt',
          ),
        ],
        const SettingsDivider('全局快捷键'),
        const SettingsLabel('唤起对话面板（至少一个 cmd/ctrl/alt）'),
        SettingsField(controller: hotkey, hint: '例如 cmd+shift+p'),
        if (capabilities != null) ...[
          const SettingsDivider('能力探测（只读）'),
          const SettingsLabel('本机可用性；M1 只探测，不会发起任务'),
          for (final adapter in capabilities!.adapters)
            _CapabilityRow(
              adapter: adapter,
              availability: capabilities!.snapshot[adapter.descriptor.id],
            ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: onProbeCapabilities,
            child: const Text(
              '重新探测',
              style: TextStyle(color: Color(0xFF80D8FF), fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }
}

/// 单个能力条目：名称 + 接入模式 + 状态 + 原因。
class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({required this.adapter, required this.availability});

  final CapabilityAdapter adapter;
  final Availability? availability;

  @override
  Widget build(BuildContext context) {
    final status = availability;
    final (label, color) = switch (status?.status) {
      AvailabilityStatus.ready => ('可用', const Color(0xFF69F0AE)),
      AvailabilityStatus.unreachable => ('不可达', const Color(0xFFFF8A80)),
      AvailabilityStatus.notConfigured => ('未配置', const Color(0xFFFFD54F)),
      AvailabilityStatus.unsupported => ('不支持', const Color(0x99FFFFFF)),
      null => ('探测中…', const Color(0x99FFFFFF)),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(
              adapter.descriptor.displayName,
              style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 11.5),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status?.reason ?? '正在探测本机可用性',
                  style: const TextStyle(color: Colors.white, fontSize: 11.5),
                ),
                if (status != null && status.detail.isNotEmpty)
                  Text(
                    status.detail,
                    style: const TextStyle(
                      color: Color(0x59FFFFFF),
                      fontSize: 10,
                    ),
                  ),
                Text(
                  _modeLabel(adapter.descriptor.mode),
                  style: const TextStyle(
                    color: Color(0x4DFFFFFF),
                    fontSize: 9.5,
                  ),
                ),
              ],
            ),
          ),
          Text(label, style: TextStyle(color: color, fontSize: 11.5)),
        ],
      ),
    );
  }

  static String _modeLabel(AccessMode mode) => switch (mode) {
    AccessMode.mcp => '接入方式：MCP',
    AccessMode.officialApi => '接入方式：官方 API',
    AccessMode.desktopBridge => '接入方式：桌面桥',
    AccessMode.guiAutomation => '接入方式：GUI 自动化（默认关闭）',
  };
}
