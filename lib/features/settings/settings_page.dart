/// 设置：关联软件的切换/投递参数 + 内置 AI 对话与碎碎念。
///
/// 只暴露真正影响行为的字段；API Key 不写进 jsonc，保存时进系统安全存储
/// （Keychain 不可用时回退 0600 文件）。面板可滚动，避免小屏上保存按钮被顶出屏。
library;

import 'package:flutter/material.dart';

import '../../core/config/ai_config.dart';
import '../../core/config/app_config.dart';
import '../../core/result.dart';
import '../ai/secret_store.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.config,
    required this.onSave,
    required this.onClose,
  });

  final AppConfig config;
  final Future<Result<void>> Function(AppConfig config) onSave;
  final VoidCallback onClose;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late String _active =
      widget.config.linkage.activeAdapter?.id ??
      widget.config.linkage.adapters.keys.firstOrNull ??
      '';
  late bool _contentRead = widget.config.linkage.contentRead;
  late final TextEditingController _bundleId;
  late final TextEditingController _uriTemplate;
  late final TextEditingController _endpoint;
  DeliveryMode _delivery = DeliveryMode.clipboard;

  late String _aiProvider = widget.config.ai.provider;
  late final TextEditingController _aiBase;
  late final TextEditingController _aiModel;
  late final TextEditingController _aiKey;
  late final TextEditingController _aiInterval;
  bool _aiKeyLoaded = false;

  final AiKeyStore _keyStore = AiKeyStore();
  bool _busy = false;
  String _hint = '';

  AdapterConfig? get _adapter => widget.config.linkage.adapters[_active];

  @override
  void initState() {
    super.initState();
    _bundleId = TextEditingController();
    _uriTemplate = TextEditingController();
    _endpoint = TextEditingController();
    _aiBase = TextEditingController(text: widget.config.ai.baseUrl);
    _aiModel = TextEditingController(text: widget.config.ai.model);
    _aiKey = TextEditingController();
    _aiInterval = TextEditingController(
      text: '${widget.config.ai.whisperIntervalSec}',
    );
    _syncFields();
    _loadKey();
  }

  @override
  void dispose() {
    _bundleId.dispose();
    _uriTemplate.dispose();
    _endpoint.dispose();
    _aiBase.dispose();
    _aiModel.dispose();
    _aiKey.dispose();
    _aiInterval.dispose();
    super.dispose();
  }

  Future<void> _loadKey() async {
    final key = await _keyStore.read();
    if (!mounted) return;
    setState(() {
      _aiKey.text = key;
      _aiKeyLoaded = true;
    });
  }

  void _syncFields() {
    final adapter = _adapter;
    _bundleId.text = adapter?.bundleId ?? '';
    _uriTemplate.text = adapter?.uriTemplate ?? '';
    _endpoint.text = adapter?.endpoint ?? '';
    _delivery = adapter?.delivery ?? DeliveryMode.clipboard;
  }

  Future<void> _save() async {
    final adapter = _adapter;
    if (adapter == null || _busy) return;
    setState(() {
      _busy = true;
      _hint = '';
    });

    final adapters = Map<String, AdapterConfig>.from(
      widget.config.linkage.adapters,
    );
    adapters[_active] = adapter.copyWith(
      bundleId: _bundleId.text.trim(),
      uriTemplate: _uriTemplate.text.trim(),
      endpoint: _endpoint.text.trim(),
      delivery: _delivery,
    );
    final interval = int.tryParse(_aiInterval.text.trim());
    final updated = AppConfig(
      pets: widget.config.pets,
      physics: widget.config.physics,
      linkage: LinkageConfig(
        active: _active,
        adapters: adapters,
        port: widget.config.linkage.port,
        contentRead: _contentRead,
      ),
      ai: AiConfig(
        provider: _aiProvider,
        baseUrl: _aiBase.text.trim(),
        model: _aiModel.text.trim(),
        whisperIntervalSec: (interval ?? widget.config.ai.whisperIntervalSec)
            .clamp(0, 86400),
        memoryRounds: widget.config.ai.memoryRounds,
      ),
    );

    // Key 不跟随配置写盘；读取完成前保存不碰 key，避免把已存的 key 清空。
    if (_aiKeyLoaded) {
      await _keyStore.write(_aiKey.text.trim());
    }
    final result = await widget.onSave(updated);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _hint = switch (result) {
        Success() => '已保存并生效',
        Failure(reason: final reason) => reason,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final adapters = widget.config.linkage.adapters.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));

    return Container(
      width: 460,
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: BoxDecoration(
        color: const Color(0xF51B1B20),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x26FFFFFF)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x59000000),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 620),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '联动与内置对话',
                      style: TextStyle(
                        color: Color(0xF2FFFFFF),
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(
                      Icons.close,
                      size: 18,
                      color: Color(0xB3FFFFFF),
                    ),
                    tooltip: '关闭',
                  ),
                ],
              ),
              const SizedBox(height: 6),
              _label('当前关联'),
              DropdownButton<String>(
                value: _active.isEmpty ? null : _active,
                isExpanded: true,
                dropdownColor: const Color(0xFF26262C),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                items: [
                  for (final adapter in adapters)
                    DropdownMenuItem(
                      value: adapter.id,
                      child: Text(adapter.displayName),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _active = value;
                    _syncFields();
                  });
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _contentRead,
                onChanged: (value) => setState(() => _contentRead = value),
                title: const Text(
                  '读取前台窗口标题/正文（需辅助功能授权）',
                  style: TextStyle(color: Color(0xCCFFFFFF), fontSize: 12),
                ),
              ),
              _label('Bundle ID'),
              _field(_bundleId, '例如 cn.trae.app'),
              _label('唤起深链（{prompt} 会被替换）'),
              _field(_uriTemplate, '例如 trae-cn://'),
              _label('投递模式'),
              DropdownButton<DeliveryMode>(
                value: _delivery,
                isExpanded: true,
                dropdownColor: const Color(0xFF26262C),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                items: const [
                  DropdownMenuItem(
                    value: DeliveryMode.clipboard,
                    child: Text('剪贴板 + 激活 + 回车'),
                  ),
                  DropdownMenuItem(
                    value: DeliveryMode.uri,
                    child: Text('深链唤起'),
                  ),
                  DropdownMenuItem(
                    value: DeliveryMode.http,
                    child: Text('HTTP 端点'),
                  ),
                  DropdownMenuItem(
                    value: DeliveryMode.ws,
                    child: Text('WebSocket 端点'),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _delivery = value);
                },
              ),
              if (_delivery == DeliveryMode.http ||
                  _delivery == DeliveryMode.ws) ...[
                _label('端点地址'),
                _field(_endpoint, '例如 http://127.0.0.1:9000/prompt'),
              ],
              const _SectionDivider(title: '内置 AI（对话与碎碎念）'),
              _label('提供者'),
              DropdownButton<String>(
                value: _aiProvider,
                isExpanded: true,
                dropdownColor: const Color(0xFF26262C),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                items: const [
                  DropdownMenuItem(value: 'none', child: Text('关闭')),
                  DropdownMenuItem(value: 'openai', child: Text('OpenAI 兼容接口')),
                  DropdownMenuItem(value: 'ollama', child: Text('本地 Ollama')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _aiProvider = value);
                },
              ),
              _label('Base URL'),
              _field(_aiBase, '例如 https://api.openai.com/v1'),
              _label('模型'),
              _field(_aiModel, '例如 gpt-4o-mini / qwen2.5'),
              if (_aiProvider == 'openai') ...[
                _label('API Key（保存在系统安全存储）'),
                TextField(
                  controller: _aiKey,
                  obscureText: true,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: _aiKeyLoaded ? '留空表示清除已保存的 key' : '读取中…',
                    hintStyle: const TextStyle(
                      color: Color(0x59FFFFFF),
                      fontSize: 12,
                    ),
                    filled: true,
                    fillColor: const Color(0x1AFFFFFF),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ],
              _label('自动碎碎念间隔（秒，0 = 只手动）'),
              _field(_aiInterval, '例如 300'),
              const SizedBox(height: 6),
              const Text(
                '选择“内置对话”后，聊天面板会显示 AI 回复；碎碎念可从右键菜单“让它说句话”立即触发。',
                style: TextStyle(color: Color(0x66FFFFFF), fontSize: 10.5),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _hint,
                      style: const TextStyle(
                        color: Color(0xB3FFFFFF),
                        fontSize: 11,
                      ),
                    ),
                  ),
                  FilledButton(
                    onPressed: _busy ? null : _save,
                    child: Text(_busy ? '保存中…' : '保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 4),
    child: Text(
      text,
      style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 11),
    ),
  );

  Widget _field(TextEditingController controller, String hint) => TextField(
    controller: controller,
    style: const TextStyle(color: Colors.white, fontSize: 13),
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0x59FFFFFF), fontSize: 12),
      filled: true,
      fillColor: const Color(0x1AFFFFFF),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
    ),
  );
}

class _SectionDivider extends StatelessWidget {
  const _SectionDivider({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 2),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xCCFFFFFF),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(child: Divider(height: 1, color: Color(0x1FFFFFFF))),
        ],
      ),
    );
  }
}
