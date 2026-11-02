/// 设置：Tab 容器（联动 / 大脑 / 隐私 / 情绪）。
///
/// 草稿状态集中在这一页的 State 里，四个分区无状态只做展示；
/// 保存时统一做热键校验、组装 AppConfig + PrivacySettings + EmotionProfile 并落盘。
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
import '../../persona/memory/memory_entry.dart';
import '../../persona/memory/memory_store.dart';
import '../../persona/profile_store.dart';
import '../ai/secret_store.dart';
import 'sections/brain_section.dart';
import 'sections/emotion_section.dart';
import 'sections/linkage_section.dart';
import 'sections/memory_section.dart';
import 'sections/privacy_section.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.config,
    required this.privacy,
    required this.emotion,
    required this.memory,
    required this.onSave,
    required this.onSaveEmotion,
    required this.onCheckAccessibility,
    required this.onClose,
  });

  final AppConfig config;

  /// 隐私四开关的当前值（来自隐私权限中心，保存时整体回写）。
  final PrivacySettings privacy;

  /// 情绪档案当前值（来自内核，保存时经内核回写并即时生效）。
  final EmotionProfile emotion;

  /// 记忆库（内核实例）：查看/纠正/遗忘/导出直接操作，即时生效。
  final MemoryStore? memory;

  final Future<Result<void>> Function(
    AppConfig config,
    PrivacySettings privacy,
  ) onSave;

  /// 情绪档案独立落盘（emotion_profile.json）；与主配置分开保存。
  final Result<void> Function(EmotionProfile emotion) onSaveEmotion;

  /// 辅助功能授权检测（含触发系统授权弹窗），由装配层接平台实现。
  final Future<bool> Function() onCheckAccessibility;

  final VoidCallback onClose;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 5, vsync: this);

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

  late EmotionProfile _emotion = widget.emotion;
  late final TextEditingController _quietStart;
  late final TextEditingController _quietEnd;
  late final TextEditingController _dailyCareLimit;
  late final TextEditingController _comfortPhrases;
  late final TextEditingController _avoidedTopics;

  // ---- 记忆库：数据快照 + 筛选 + 操作提示（分区无状态，只做展示） ----
  MemoryKind? _memoryFilter;
  String _memoryHint = '';
  List<MemoryEntry> _memoryPending = const [];
  List<MemoryEntry> _memoryActive = const [];

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
    _quietStart = TextEditingController(text: widget.emotion.quietStart);
    _quietEnd = TextEditingController(text: widget.emotion.quietEnd);
    _dailyCareLimit = TextEditingController(
      text: '${widget.emotion.dailyCareLimit}',
    );
    _comfortPhrases = TextEditingController(
      text: widget.emotion.comfortPhrases.join('\n'),
    );
    _avoidedTopics = TextEditingController(
      text: widget.emotion.avoidedTopics.join('\n'),
    );
    _refreshMemories();
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
    _quietStart.dispose();
    _quietEnd.dispose();
    _dailyCareLimit.dispose();
    _comfortPhrases.dispose();
    _avoidedTopics.dispose();
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
    // 情绪档案独立落盘：失败不回滚主配置，但提示要说清哪份没存上。
    // 预算计数（careDate/careCount/…）不在设置页编辑，原样带回；
    // 面板开着期间内核恰好消耗额度的极端情况会丢一次计数，后果可接受。
    final emotionResult = widget.onSaveEmotion(_assembleEmotion());
    setState(() {
      _busy = false;
      _hint = switch (result) {
        Success() => switch (emotionResult) {
          Success() => '已保存并生效',
          Failure(reason: final reason) => reason,
        },
        Failure(reason: final reason) => reason,
      };
    });
  }

  /// 组装情绪档案草稿：开关来自 _emotion，文本字段来自输入框，
  /// 计数字段与亲密度基线拷贝打开面板时的快照（无编辑入口）。
  EmotionProfile _assembleEmotion() {
    final limit = int.tryParse(_dailyCareLimit.text.trim());
    return _emotion.copyWith(
      quietStart: _quietStart.text.trim(),
      quietEnd: _quietEnd.text.trim(),
      dailyCareLimit: (limit ?? _emotion.dailyCareLimit).clamp(0, 50),
      comfortPhrases: _linesOf(_comfortPhrases.text),
      avoidedTopics: _linesOf(_avoidedTopics.text),
    );
  }

  /// 多行文本 → 去空白行后的列表（话术池/话题列表的统一口径）。
  static List<String> _linesOf(String raw) => [
    for (final line in raw.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  /// 校验不过：提示原因并保持未保存状态（返回 null 让调用方停下）。
  String? _reject(String message) {
    setState(() => _hint = message);
    return null;
  }

  // ---------------------------------------------------------------------------
  // 记忆库操作：直接写内核的 MemoryStore，即时生效；提示走 _memoryHint
  // ---------------------------------------------------------------------------

  void _refreshMemories() {
    final store = widget.memory;
    if (store == null) return;
    final filter = _memoryFilter;
    _memoryPending = store.pending;
    _memoryActive = [
      for (final entry in store.entries(
        kind: filter,
        status: MemoryStatus.active,
      ))
        entry,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  void _runMemory(Result<void> result, String successHint) {
    setState(() {
      _memoryHint = switch (result) {
        Success() => successHint,
        Failure(:final reason) => reason,
      };
      _refreshMemories();
    });
  }

  void _confirmMemory(String id) =>
      _runMemory(widget.memory?.confirm(id) ?? const Failure('memory.offline', '记忆库还没准备好'), '已记住这条提案');

  void _rejectMemory(String id) =>
      _runMemory(widget.memory?.reject(id) ?? const Failure('memory.offline', '记忆库还没准备好'), '已拒绝，这条提案丢弃了');

  void _editMemory(MemoryEntry entry) =>
      _runMemory(widget.memory?.update(entry) ?? const Failure('memory.offline', '记忆库还没准备好'), '已纠正');

  void _forgetMemory(String id) =>
      _runMemory(widget.memory?.remove(id) ?? const Failure('memory.offline', '记忆库还没准备好'), '已遗忘');

  void _clearMemoryKind(MemoryKind kind) =>
      _runMemory(widget.memory?.clearKind(kind) ?? const Failure('memory.offline', '记忆库还没准备好'), '这一类记忆已清空');

  void _exportMemories() {
    final store = widget.memory;
    if (store == null) return;
    switch (store.export()) {
      case Success(value: final file):
        setState(() => _memoryHint = '已导出到 ${file.path}');
      case Failure(:final reason):
        setState(() => _memoryHint = reason);
    }
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
  void _disposeTestProvider(LlmProvider provider) => provider.dispose();

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
                Tab(text: '情绪'),
                Tab(text: '记忆'),
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
                    EmotionSection(
                      profile: _emotion,
                      onChanged: (value) => setState(() => _emotion = value),
                      quietStart: _quietStart,
                      quietEnd: _quietEnd,
                      dailyCareLimit: _dailyCareLimit,
                      comfortPhrases: _comfortPhrases,
                      avoidedTopics: _avoidedTopics,
                    ),
                    if (widget.memory == null)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          '记忆库还没准备好，稍后再打开设置试试',
                          style: TextStyle(color: Color(0x66FFFFFF), fontSize: 12),
                        ),
                      )
                    else
                      MemorySection(
                        pending: _memoryPending,
                        memories: _memoryActive,
                        filter: _memoryFilter,
                        onFilterChanged: (value) => setState(() {
                          _memoryFilter = value;
                          _refreshMemories();
                        }),
                        onConfirm: _confirmMemory,
                        onReject: _rejectMemory,
                        onEdit: _editMemory,
                        onForget: _forgetMemory,
                        onClearKind: _clearMemoryKind,
                        onExport: _exportMemories,
                        hint: _memoryHint,
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
