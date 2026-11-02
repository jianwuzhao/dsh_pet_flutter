/// 设置：Tab 容器（联动 / 大脑 / 隐私）。
///
/// 草稿状态集中在这一页的 State 里，三个分区无状态只做展示；
/// 保存时统一做热键校验、组装 AppConfig + PrivacySettings 并落盘。
/// API Key 不写进 jsonc，保存时进系统安全存储（不可用时回退 0600 文件）。
library;

import 'package:flutter/material.dart';

import '../../ai/llm_provider.dart';
import '../../ai/providers/ollama_provider.dart';
import '../../ai/providers/openai_provider.dart';
import '../../core/config/ai_config.dart';
import '../../core/config/app_config.dart';
import '../../core/result.dart';
import '../../gateway/hotkey_source.dart';
import '../../persona/profile_store.dart';
import '../ai/secret_store.dart';
import 'sections/brain_section.dart';
import 'sections/linkage_section.dart';
import 'sections/privacy_section.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.config,
    required this.privacy,
    required this.onSave,
    required this.onCheckAccessibility,
    required this.onClose,
  });

  final AppConfig config;

  /// 隐私四开关的当前值（来自隐私权限中心，保存时整体回写）。
  final PrivacySettings privacy;

  final Future<Result<void>> Function(
    AppConfig config,
    PrivacySettings privacy,
  ) onSave;

  /// 辅助功能授权检测（含触发系统授权弹窗），由装配层接平台实现。
  final Future<bool> Function() onCheckAccessibility;

  final VoidCallback onClose;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  late String _active =
      widget.config.linkage.activeAdapter?.id ??
      widget.config.linkage.adapters.keys.firstOrNull ??
      '';
  late final TextEditingController _bundleId;
  late final TextEditingController _uriTemplate;
  late final TextEditingController _endpoint;
  DeliveryMode _delivery = DeliveryMode.clipboard;
  late final TextEditingController _hotkey = TextEditingController(
    text: widget.config.gateway.hotkey,
  );

  late String _aiProvider = widget.config.ai.provider;
  late final TextEditingController _aiBase;
  late final TextEditingController _aiModel;
  late final TextEditingController _aiKey;
  late final TextEditingController _aiInterval;
  bool _aiKeyLoaded = false;

  late PrivacySettings _privacy = widget.privacy;
  bool _accessChecking = false;
  String _accessResult = '';

  bool _aiTesting = false;
  String _aiTestResult = '';

  final AiKeyStore _keyStore = AiKeyStore();
  bool _busy = false;
  String _hint = '';

  AdapterConfig? get _adapter => widget.config.linkage.adapters[_active];

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_onTabChanged);
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
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    _bundleId.dispose();
    _uriTemplate.dispose();
    _endpoint.dispose();
    _hotkey.dispose();
    _aiBase.dispose();
    _aiModel.dispose();
    _aiKey.dispose();
    _aiInterval.dispose();
    super.dispose();
  }

  /// IndexedStack 跟随 TabController 需要 rebuild，这里补一次 setState。
  void _onTabChanged() => setState(() {});

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

  // ---------------------------------------------------------------------------
  // 保存：校验热键 → 组装 AppConfig（含 gateway 与旧 contentRead 同步）+ 隐私
  // ---------------------------------------------------------------------------

  Future<void> _save() async {
    final adapter = _adapter;
    if (adapter == null || _busy) return;

    // 热键留空视为回到默认，非法组合直接拦下（注册不会生效，别让它存进配置）。
    final hotkeyText = _hotkey.text.trim();
    final combo = hotkeyText.isEmpty
        ? GatewayConfig.defaultHotkey
        : switch (HotkeySpec.parse(hotkeyText)) {
            Success(value: final spec) => spec.combo,
            Failure(reason: final reason) => _reject('快捷键无效：$reason'),
          };
    if (combo == null) return;

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
        // 旧字段跟随隐私开关同步写，外部脚本读 config 仍能看到正文读取授权。
        contentRead: _privacy.screenAwareness,
      ),
      ai: AiConfig(
        provider: _aiProvider,
        baseUrl: _aiBase.text.trim(),
        model: _aiModel.text.trim(),
        whisperIntervalSec: (interval ?? widget.config.ai.whisperIntervalSec)
            .clamp(0, 86400),
        memoryRounds: widget.config.ai.memoryRounds,
      ),
      gateway: GatewayConfig(hotkey: combo),
    );

    // Key 不跟随配置写盘；读取完成前保存不碰 key，避免把已存的 key 清空。
    if (_aiKeyLoaded) {
      await _keyStore.write(_aiKey.text.trim());
    }
    final result = await widget.onSave(updated, _privacy);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _hint = switch (result) {
        Success() => '已保存并生效',
        Failure(reason: final reason) => reason,
      };
    });
  }

  /// 校验不过：提示原因并保持未保存状态（返回 null 让调用方停下）。
  String? _reject(String message) {
    setState(() => _hint = message);
    return null;
  }

  // ---------------------------------------------------------------------------
  // 大脑连通性测试：用草稿值现场建 provider 发一条 ping，测完立即释放
  // ---------------------------------------------------------------------------

  Future<void> _testAi() async {
    if (_aiTesting) return;
    setState(() {
      _aiTesting = true;
      _aiTestResult = '测试中…';
    });
    final LlmProvider? provider = switch (_aiProvider) {
      'openai' => OpenAiProvider(
        baseUrl: _aiBase.text.trim(),
        model: _aiModel.text.trim(),
        // 用输入框里的草稿 key，用户可能还没点保存。
        keyLoader: () async => _aiKey.text.trim(),
      ),
      'ollama' => OllamaProvider(
        baseUrl: _aiBase.text.trim(),
        model: _aiModel.text.trim(),
      ),
      _ => null,
    };
    if (provider == null) {
      setState(() {
        _aiTesting = false;
        _aiTestResult = '当前提供者（关闭/转发）不需要测试';
      });
      return;
    }
    if (!await provider.isReady) {
      _disposeTestProvider(provider);
      setState(() {
        _aiTesting = false;
        _aiTestResult = '参数不完整：Base URL / 模型 / API Key 都要有值';
      });
      return;
    }
    final reply = await provider.chat(
      const LlmRequest(messages: [LlmMessage.user('ping，请只回复 pong')]),
    );
    _disposeTestProvider(provider);
    if (!mounted) return;
    setState(() {
      _aiTesting = false;
      _aiTestResult = switch (reply) {
        Success(value: final value) =>
          '连通正常：${value.content.isEmpty ? '(空回复)' : value.content}',
        Failure(reason: final reason) => reason,
      };
    });
  }

  /// 现场建的 provider 自建了 http client，测完必须显式释放。
  void _disposeTestProvider(LlmProvider provider) {
    if (provider is OpenAiProvider) provider.dispose();
    if (provider is OllamaProvider) provider.dispose();
  }

  Future<void> _checkAccessibility() async {
    if (_accessChecking) return;
    setState(() {
      _accessChecking = true;
      _accessResult = '检测中…';
    });
    final trusted = await widget.onCheckAccessibility();
    if (!mounted) return;
    setState(() {
      _accessChecking = false;
      _accessResult = trusted
          ? '已授权'
          : '未授权：请在 系统设置 › 隐私与安全性 › 辅助功能 勾选本应用';
    });
  }

  // ---------------------------------------------------------------------------
  // UI 布局
  // ---------------------------------------------------------------------------

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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '设置',
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
            TabBar(
              controller: _tabs,
              labelColor: const Color(0xF2FFFFFF),
              unselectedLabelColor: const Color(0x80FFFFFF),
              indicatorColor: const Color(0xCCFFFFFF),
              dividerColor: const Color(0x1FFFFFFF),
              tabs: const [
                Tab(text: '联动'),
                Tab(text: '大脑'),
                Tab(text: '隐私'),
              ],
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(top: 4),
                child: IndexedStack(
                  index: _tabs.index,
                  children: [
                    LinkageSection(
                      adapters: adapters,
                      active: _active,
                      onActiveChanged: (value) => setState(() {
                        _active = value;
                        _syncFields();
                      }),
                      bundleId: _bundleId,
                      uriTemplate: _uriTemplate,
                      endpoint: _endpoint,
                      delivery: _delivery,
                      onDeliveryChanged: (value) =>
                          setState(() => _delivery = value),
                      hotkey: _hotkey,
                    ),
                    BrainSection(
                      provider: _aiProvider,
                      onProviderChanged: (value) =>
                          setState(() => _aiProvider = value),
                      baseUrl: _aiBase,
                      model: _aiModel,
                      interval: _aiInterval,
                      apiKey: _aiKey,
                      apiKeyLoaded: _aiKeyLoaded,
                      testing: _aiTesting,
                      testResult: _aiTestResult,
                      onTest: _testAi,
                    ),
                    PrivacySection(
                      privacy: _privacy,
                      onChanged: (value) => setState(() => _privacy = value),
                      accessibilityChecking: _accessChecking,
                      accessibilityResult: _accessResult,
                      onCheckAccessibility: _checkAccessibility,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
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
    );
  }
}
