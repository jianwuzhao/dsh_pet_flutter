/// 应用装配：加载配置与清单、装配联动内核、把事件接到宠物控制器。
///
/// 这里只做“组装与转发”，不写姿态/动画/投递细节（各自的模块负责）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../ai/llm_router.dart';
import '../ai/providers/ollama_provider.dart';
import '../ai/providers/openai_provider.dart';
import '../ai/providers/trae_bridge_provider.dart';
import '../core/config/animation_manifest.dart';
import '../core/config/app_config.dart';
import '../core/paths/app_paths.dart';
import '../core/result.dart';
import '../features/ai/chat_memory.dart';
import '../features/ai/llm_client.dart';
import '../features/ai/secret_store.dart';
import '../features/linkage/assistant_adapters.dart';
import '../features/linkage/bridge_hub.dart';
import '../features/linkage/dispatcher.dart';
import '../features/linkage/event_server.dart';
import '../features/linkage/status/app_watch_source.dart';
import '../features/linkage/status/assistant_event.dart';
import '../features/pet/pet_controller.dart';
import '../gateway/hotkey_source.dart';
import '../gateway/interaction_gateway.dart';
import '../gateway/privacy_center.dart';
import '../persona/profile_store.dart';
import '../platform/pet_platform.dart';
import 'pet_stage.dart';

class PetApp extends StatefulWidget {
  const PetApp({super.key});

  @override
  State<PetApp> createState() => _PetAppState();
}

class _PetAppState extends State<PetApp> {
  final PetPlatform _platform = PetPlatform();
  final ConfigRepository _repository = ConfigRepository();

  AppConfig? _config;
  PetController? _controller;
  StatusAggregator? _aggregator;
  PetEventServer? _server;
  AppWatchSource? _watch;
  StreamSubscription<StatusSnapshot?>? _statusSubscription;
  String? _error;
  Timer? _positionSaveTimer;

  /// 四层核心：隐私门禁、LLM 选路、统一输入网关、全局热键。
  PrivacyCenter? _privacy;
  LlmRouter? _router;
  InteractionGateway? _gateway;
  HotkeySource? _hotkey;

  /// Trae 扩展桥：事件服务与适配器注册表共用同一个实例。
  final BridgeHub _bridgeHub = BridgeHub();

  final AiKeyStore _keyStore = AiKeyStore();
  AiService? _ai;
  ChatMemory? _memory;
  Timer? _whisperTimer;
  bool _whisperBusy = false;

  String _thinkingBuffer = '';
  String? _thinkingTask;

  String get _activeName {
    final config = _config;
    if (config == null) return '';
    return config.linkage.activeAdapter?.displayName ?? config.linkage.active;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  @override
  void dispose() {
    _savePosition();
    _positionSaveTimer?.cancel();
    _whisperTimer?.cancel();
    _ai?.dispose();
    final router = _router;
    if (router != null) _disposeRouter(router);
    unawaited(_hotkey?.unregister());
    _statusSubscription?.cancel();
    _watch?.dispose();
    unawaited(_server?.stop());
    _controller?.dispose();
    _aggregator?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '桌宠',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    final error = _error;
    if (error != null) {
      return _ErrorView(message: error, onQuit: _platform.quit);
    }
    final controller = _controller;
    final config = _config;
    if (controller == null || config == null) {
      // 仍在启动或配置加载中：保持完全透明，不闪白底。
      return const SizedBox.expand();
    }
    return PetStage(
      key: ValueKey(controller),
      controller: controller,
      activeName: _activeName,
      config: config,
      privacy: _privacy?.settings ?? const PrivacySettings(),
      onSend: _dispatch,
      onSaveConfig: _saveConfig,
      onCheckAccessibility: _platform.requestAccessibility,
      onQuit: _platform.quit,
      onOpenApp: config.linkage.active == 'builtin'
          ? null
          : () => unawaited(_openActiveApp()),
      onReloadConfig: () => unawaited(_reloadConfig()),
      onWhisper: () => unawaited(_whisperNow(manual: true)),
    );
  }

  // ---------------------------------------------------------------------------
  // 启动
  // ---------------------------------------------------------------------------

  Future<void> _boot() async {
    try {
      final configResult = await _repository.load();
      final config = configResult.valueOrNull;
      if (config == null) {
        _fail(configResult.failureOrNull?.reason ?? '配置加载失败');
        return;
      }
      final pet = config.desktopPet;
      if (pet == null) {
        _fail('没有 display 含 desktop 的宠物，无法在桌面显示');
        return;
      }

      final manifest = AnimationManifest.parse(
        await rootBundle.loadString('assets/animations/manifest.json'),
      );
      final savedPosition = _readSavedPosition();
      if (savedPosition != null && savedPosition.screen > 0) {
        try {
          // 窗口先搬到上次所在屏，出生点才落在同一套本地坐标里。
          await _platform.moveToScreen(savedPosition.screen);
        } on Object catch (error) {
          debugPrint('[pet] 恢复屏幕失败，留在主屏：$error');
        }
      }
      final controller = PetController(
        pet: pet,
        physics: config.physics,
        manifest: manifest,
        platform: _platform,
        initialPosition: savedPosition?.offset,
      );
      // 屏幕列表决定出生点与活动域，必须在第一帧之前就绪。
      controller.setScreens(await _platform.getScreens());
      _platform.onScreensChanged(_onScreensChanged);
      _memory ??= ChatMemory();
      final ai = AiService(config: config.ai, keyLoader: _keyStore.read);
      _ai?.dispose();
      _ai = ai;
      final registry = AdapterRegistry.fromConfig(
        config.linkage,
        _platform,
        bridgeHub: _bridgeHub,
        ai: ai,
        memory: _memory,
        persona: _personaFor(pet),
      );
      final dispatcher = Dispatcher(
        registry: registry,
        activeId: config.linkage.active,
      );
      final router = _buildRouter(config);
      final gateway = InteractionGateway(dispatcher: dispatcher, router: router);
      final privacy = PrivacyCenter(
        legacyContentRead: config.linkage.contentRead,
      );
      final privacyLoad = privacy.load();
      final aggregator = StatusAggregator();
      final server = PetEventServer(
        port: config.linkage.port,
        onEvent: _handleEvent,
        onDispatch: _dispatchFromServer,
        hub: _bridgeHub,
        platform: _platform,
        petState: controller.state,
        onChat: gateway.chat,
      );
      final statusSubscription = aggregator.changes.listen(
        controller.applyStatus,
      );
      final serverError = await server.start();
      final watch = AppWatchSource(
        platform: _platform,
        registry: registry,
        aggregator: aggregator,
        activeId: config.linkage.active,
        privacy: privacy,
      )..start();
      final hotkey = _syncHotkey(config);
      hotkey.listen(() => _onHotkeyPressed());
      controller.start();
      _platform.listenTray(_onTrayAction);
      _positionSaveTimer?.cancel();
      _positionSaveTimer = Timer.periodic(
        const Duration(seconds: 4),
        (_) => _savePosition(),
      );

      if (!mounted) {
        statusSubscription.cancel();
        watch.dispose();
        unawaited(server.stop());
        controller.dispose();
        aggregator.dispose();
        _disposeRouter(router);
        return;
      }

      setState(() {
        _config = config;
        _controller = controller;
        _aggregator = aggregator;
        _server = server;
        _watch = watch;
        _statusSubscription = statusSubscription;
        _privacy = privacy;
        _router = router;
        _gateway = gateway;
        _hotkey = hotkey;
      });

      if (serverError != null) {
        // 服务起不来时宠物多半在屏上不可见处，气泡没人看见；日志必须留痕。
        debugPrint('[pet] $serverError');
        controller.showBubble(serverError);
      }
      if (privacyLoad is Failure<void>) {
        // 隐私档案读不出来：继续用内存默认值，但不能让用户以为授权被记住了。
        debugPrint('[pet] ${privacyLoad.reason}');
        controller.showBubble('隐私授权档案读取失败：${privacyLoad.reason}');
      }
      _restartWhisper();
      Timer(const Duration(milliseconds: 900), () {
        // 触摸平台没有右键，菜单手势是长按（见 PetController 触摸状态机）。
        controller.showBubble(
          PetPlatform.isTouch
              ? '长按宠物有菜单；双击就把话发给 $_activeName'
              : '右键有菜单；双击就把话发给 $_activeName',
        );
      });
    } on Object catch (error) {
      _fail('启动失败：$error');
    }
  }

  /// 读取上次落点；文件损坏时只回到默认出生点，不能阻塞启动。
  ({Offset offset, int screen})? _readSavedPosition() {
    try {
      final file = AppPaths.positionFile;
      if (!file.existsSync()) return null;
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map) return null;
      final x = (json['x'] as num?)?.toDouble();
      final y = (json['y'] as num?)?.toDouble();
      if (x == null || y == null) return null;
      final screen = (json['screen'] as num?)?.toInt() ?? 0;
      return (offset: Offset(x, y), screen: screen);
    } on Object catch (error) {
      debugPrint('[pet] 位置文件损坏，使用默认出生点：$error');
      return null;
    }
  }

  /// 落点持久化：甩出途中不写，避免下次启动停在半空。
  void _savePosition() {
    final controller = _controller;
    if (controller == null) return;
    final state = controller.state();
    if (state['dragging'] == true || state['thrown'] == true) return;
    try {
      AppPaths.ensure();
      final pos = controller.petRect.topLeft;
      final screen = state['activeScreenIndex'] as int? ?? 0;
      AppPaths.positionFile.writeAsStringSync(
        jsonEncode({'x': pos.dx, 'y': pos.dy, 'screen': screen}),
        flush: true,
      );
    } on Object catch (error) {
      debugPrint('[pet] 保存位置失败：$error');
    }
  }

  /// 右键“打开 <关联软件>”：优先按 bundleId 激活，失败再退回深链。
  Future<void> _openActiveApp() async {
    final adapter = _config?.linkage.activeAdapter;
    if (adapter == null) return;
    if (adapter.bundleId.isNotEmpty &&
        await _platform.activateApp(adapter.bundleId)) {
      _controller?.closeMenu();
      return;
    }
    if (adapter.uriTemplate.isNotEmpty &&
        await _platform.openUrl(adapter.uriTemplate)) {
      _controller?.closeMenu();
      return;
    }
    _controller?.showBubble(
      '没有找到 ${adapter.displayName} 的唤起方式，请在设置里补 bundleId 或深链',
    );
  }

  /// 右键“重新加载配置”：像上游桌面 Helper 一样按最新配置重建整只宠物。
  /// 先停旧服务/旧控制器，再走一遍 _boot；期间窗口保持透明，不闪白底。
  Future<void> _reloadConfig() async {
    final result = await _repository.load();
    final config = result.valueOrNull;
    if (config == null) {
      _controller?.showBubble(result.failureOrNull?.reason ?? '配置加载失败');
      return;
    }
    if (config.desktopPet == null) {
      _controller?.showBubble('配置里没有 display 含 desktop 的宠物');
      return;
    }

    _savePosition();
    _positionSaveTimer?.cancel();
    _positionSaveTimer = null;
    _whisperTimer?.cancel();
    _whisperTimer = null;
    _ai?.dispose();
    _ai = null;
    if (_router != null) _disposeRouter(_router!);
    _router = null;
    _gateway = null;
    unawaited(_hotkey?.unregister());
    _hotkey = null;
    _privacy = null;
    await _statusSubscription?.cancel();
    _statusSubscription = null;
    _watch?.dispose();
    _watch = null;
    await _server?.stop();
    _server = null;
    _controller?.dispose();
    _controller = null;
    _aggregator?.dispose();
    _aggregator = null;
    if (mounted) {
      setState(() => _config = null);
    }
    await _boot();
  }

  /// 托盘菜单：只负责把面板打开，输入/投递细节仍在各自模块里。
  void _onTrayAction(String action) {
    _controller?.openPanel(
      action == 'settings' ? PetPanel.settings : PetPanel.chat,
    );
  }

  /// 屏幕热插拔后重取列表：宠物被钳回最近的真实屏幕，不会留在死区。
  Future<void> _onScreensChanged() async {
    _controller?.setScreens(await _platform.getScreens());
  }

  void _fail(String reason) {
    if (!mounted) return;
    setState(() => _error = reason);
    // 出错时必须接管窗口，否则用户看不到也点不到这块提示。
    unawaited(_platform.setInteractive(true));
    unawaited(_platform.setFocusable(true));
  }

  // ---------------------------------------------------------------------------
  // 配置
  // ---------------------------------------------------------------------------

  /// 设置页保存：配置落 config.jsonc，授权落 privacy.json（由隐私中心负责）。
  Future<Result<void>> _saveConfig(
    AppConfig config,
    PrivacySettings privacy,
  ) async {
    final result = await _repository.save(config);
    if (result is! Success<void>) return result;

    _applyConfig(config, privacy);
    _controller?.closePanel();
    _controller?.showBubble(
      '已保存：关联 ${config.linkage.activeAdapter?.displayName ?? config.linkage.active}',
    );
    return result;
  }

  void _applyConfig(AppConfig config, [PrivacySettings? privacyUpdate]) {
    final pet = config.desktopPet;
    final ai = AiService(config: config.ai, keyLoader: _keyStore.read);
    _ai?.dispose();
    _ai = ai;
    _memory ??= ChatMemory();
    final registry = AdapterRegistry.fromConfig(
      config.linkage,
      _platform,
      bridgeHub: _bridgeHub,
      ai: ai,
      memory: _memory,
      persona: pet == null ? '' : _personaFor(pet),
    );
    final dispatcher = Dispatcher(
      registry: registry,
      activeId: config.linkage.active,
    );
    final oldRouter = _router;
    final router = _buildRouter(config);
    setState(() {
      _config = config;
      _router = router;
      final gateway = _gateway;
      if (gateway != null) {
        gateway.dispatcher = dispatcher;
        gateway.router = router;
      }
    });
    if (oldRouter != null && !identical(oldRouter, router)) {
      _disposeRouter(oldRouter);
    }
    unawaited(_hotkey?.register(config.gateway.hotkey));
    _restartWhisper();

    if (privacyUpdate != null) _applyPrivacy(privacyUpdate);

    final aggregator = _aggregator;
    if (aggregator == null) return;
    aggregator.clear(StatusSourceKind.watch);

    _watch?.dispose();
    final privacy = _privacy;
    if (privacy == null) return;
    _watch = AppWatchSource(
      platform: _platform,
      registry: registry,
      aggregator: aggregator,
      activeId: config.linkage.active,
      privacy: privacy,
    )..start();
  }

  /// 授权变更：只有写盘成功才改内存门禁，并回收被关掉能力已发布的状态。
  void _applyPrivacy(PrivacySettings update) {
    final privacy = _privacy;
    if (privacy == null) return;
    final result = privacy.update(update);
    if (result is Failure<void>) {
      debugPrint('[pet] 隐私授权保存失败：${result.reason}');
      _controller?.showBubble('隐私授权保存失败：${result.reason}');
      return;
    }
    final aggregator = _aggregator;
    if (aggregator == null) return;
    if (!privacy.settings.appWatch) aggregator.clear(StatusSourceKind.watch);
    if (!privacy.settings.screenAwareness) {
      aggregator.clear(StatusSourceKind.content);
    }
  }

  /// 装配 LLM 路由：openai / ollama 共用扁平 ai 配置段的 baseUrl/model
  ///（provider 决定谁是 active，另一路 isReady 不过自然沉到降级链后面）；
  /// trae 桥永远在，兜底转发到关联软件。
  LlmRouter _buildRouter(AppConfig config) {
    return LlmRouter(
      providers: [
        OpenAiProvider(
          baseUrl: config.ai.baseUrl,
          model: config.ai.model,
          keyLoader: _keyStore.read,
        ),
        OllamaProvider(baseUrl: config.ai.baseUrl, model: config.ai.model),
        TraeBridgeProvider(
          send: (prompt) {
            final gateway = _gateway;
            if (gateway == null) {
              return Future.value(
                const Failure('dispatch.not-ready', '联动通道还没准备好'),
              );
            }
            return gateway.dispatcher.send(prompt);
          },
        ),
      ],
      activeId: config.ai.provider,
    );
  }

  /// 路由整体替换后，旧 provider 里自建的 http client 必须显式关掉。
  void _disposeRouter(LlmRouter router) {
    for (final provider in router.providers) {
      if (provider is OpenAiProvider) provider.dispose();
      if (provider is OllamaProvider) provider.dispose();
    }
  }

  /// 热键同步：注册失败只留日志——唤起入口缺位不该打断启动。
  HotkeySource _syncHotkey(AppConfig config) {
    final hotkey = _hotkey ?? HotkeySource();
    unawaited(
      hotkey.register(config.gateway.hotkey).then((result) {
        if (result is Failure<bool>) {
          debugPrint('[pet] 热键注册失败（${config.gateway.hotkey}）：${result.reason}');
        }
      }),
    );
    return hotkey;
  }

  void _onHotkeyPressed() {
    _controller?.openPanel(PetPanel.chat);
  }

  // ---------------------------------------------------------------------------
  // 内置 AI：碎碎念与对话人格
  // ---------------------------------------------------------------------------

  static const List<String> _memeAssets = [
    'assets/memes/可爱.png',
    'assets/memes/吃饱饱摸肚子.png',
    'assets/memes/哦鲸鲸.png',
    'assets/memes/大的要来啦.png',
    'assets/memes/深度睡眠.png',
    'assets/memes/先养着吧.png',
    'assets/memes/死掉了.png',
    'assets/memes/我不更新你们用什么.png',
    'assets/memes/压力一只大肥鱼.png',
    'assets/memes/厉害了我的鲸.png',
  ];

  String _personaFor(PetConfig pet) {
    final custom = pet.whisperPrompt.trim();
    if (custom.isNotEmpty) return custom;
    return '你是「${pet.name}」，一只住在桌面上的小桌宠。'
        '用简短、自然、有点可爱的中文说话；不假装能执行做不到的操作，'
        '不主动索取隐私，也不制造依赖。';
  }

  void _restartWhisper() {
    _whisperTimer?.cancel();
    _whisperTimer = null;
    final config = _config;
    final pet = config?.desktopPet;
    final ai = _ai;
    if (config == null ||
        pet == null ||
        ai == null ||
        !ai.canChat ||
        !pet.whisperEnabled) {
      return;
    }
    final seconds = config.ai.whisperIntervalSec;
    if (seconds <= 0) return;
    _whisperTimer = Timer.periodic(
      Duration(seconds: seconds.clamp(30, 86400)),
      (_) => unawaited(_whisperNow()),
    );
  }

  /// 手动/定时碎碎念：模型生成一句短话 + 随机表情包。
  Future<void> _whisperNow({bool manual = false}) async {
    if (_whisperBusy) return;
    final ai = _ai;
    final controller = _controller;
    final pet = _config?.desktopPet;
    if (ai == null || controller == null || pet == null) return;
    if (!ai.canChat) {
      if (manual) {
        controller.showBubble('碎碎念需要先配置内置 AI（设置 → 内置对话）');
      }
      return;
    }
    _whisperBusy = true;
    try {
      final result = await ai.chat(
        messages: const [AiMessage.user('用一句不超过 25 字的中文说一句此刻的碎碎念，不要提问，不要解释。')],
        system: _personaFor(pet),
      );
      // 重载配置可能已换掉控制器；旧请求回来时不要再碰已 dispose 的 notifier。
      if (!mounted || !identical(_controller, controller)) return;
      switch (result) {
        case Success(value: final text):
          final meme = _memeAssets[math.Random().nextInt(_memeAssets.length)];
          controller.showBubble(text, meme: meme, source: 'whisper');
        case Failure(reason: final reason):
          if (manual) controller.showBubble(reason);
          debugPrint('[pet] 碎碎念失败：$reason');
      }
    } finally {
      _whisperBusy = false;
    }
  }

  // ---------------------------------------------------------------------------
  // 事件转发
  // ---------------------------------------------------------------------------

  void _handleEvent(AssistantEvent event) {
    final aggregator = _aggregator;
    final controller = _controller;
    if (aggregator == null || controller == null) return;

    if (event.type == EventType.clear) {
      _thinkingBuffer = '';
      aggregator.clear(StatusSourceKind.push);
      return;
    }

    var text = event.text;
    if (event.type == EventType.thinking) {
      if (event.delta) {
        if (_thinkingTask != event.taskId) {
          _thinkingTask = event.taskId;
          _thinkingBuffer = '';
        }
        _thinkingBuffer += text;
        text = _thinkingBuffer;
      } else {
        _thinkingTask = event.taskId;
        _thinkingBuffer = text;
      }
    }
    if (event.type == EventType.progress && event.total != null) {
      text = '${event.current ?? 0}/${event.total} $text';
    }

    // 显式通知事件：桌面气泡 + macOS 系统通知（dsh-pet 的通知能力）。
    if (event.type == EventType.notify) {
      controller.showBubble(text.isEmpty ? '有新的消息' : text);
      unawaited(
        _platform
            .notify(
              title: event.source.isEmpty ? '桌宠' : '桌宠 · ${event.source}',
              body: text.isEmpty ? '有新的消息' : text,
            )
            .catchError((Object error) => debugPrint('[pet] 系统通知失败：$error')),
      );
      return;
    }

    final state = event.state;
    if (state == null) {
      controller.showBubble(text);
      return;
    }

    aggregator.update(
      StatusSourceKind.push,
      StatusSnapshot(
        state: state,
        text: text,
        source: event.source,
        updatedAt: DateTime.now(),
        taskId: event.taskId,
      ),
    );
    if (event.isTerminal) _thinkingBuffer = '';
  }

  /// 面板与本地事件服务共用的投递入口：统一走交互网关。
  Future<Result<DispatchOutcome>> _dispatch(
    String prompt, [
    InputSource source = InputSource.panel,
  ]) async {
    final gateway = _gateway;
    if (gateway == null) {
      return const Failure('dispatch.not-ready', '联动通道还没准备好');
    }
    final result = await gateway.submit(prompt, source);
    final controller = _controller;
    if (!mounted || !identical(_controller, controller)) return result;
    switch (result) {
      case Success(value: final outcome):
        if (!outcome.ok) {
          controller?.showBubble(outcome.reason);
        } else if (outcome.reply.trim().isNotEmpty) {
          controller?.showBubble(outcome.reply, source: _activeName);
        } else {
          controller?.showBubble('已发送到 $_activeName');
        }
      case Failure(reason: final reason):
        controller?.showBubble(reason);
    }
    return result;
  }

  /// 事件服务的 /dispatch 只返回原因串（空串表示成功）。
  Future<String> _dispatchFromServer(String prompt) async {
    final result = await _dispatch(prompt, InputSource.eventServer);
    return switch (result) {
      Success(value: final outcome) => outcome.ok ? '' : outcome.reason,
      Failure(reason: final reason) => reason,
    };
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onQuit});

  final String message;
  final Future<void> Function() onQuit;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xE60E0E12),
      child: Center(
        child: Container(
          width: 460,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF1B1B20),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x26FFFFFF)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '桌宠启动失败',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 13),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => onQuit(),
                  child: const Text('退出'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
