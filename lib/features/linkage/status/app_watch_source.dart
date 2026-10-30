/// 前台应用启发式：把“切到了关联软件”翻译成最低优先级的状态来源。
///
/// 这条来源不需要任何授权，用来在用户没有主动推送时也能让宠物有反应；
/// 一旦有 push/content 来源，聚合器会自动把它压下去。
library;

import 'dart:async';

import '../../../platform/pet_platform.dart';
import '../assistant_adapters.dart';
import 'assistant_event.dart';

class AppWatchSource {
  AppWatchSource({
    required PetPlatform platform,
    required AdapterRegistry registry,
    required StatusAggregator aggregator,
    required this.activeId,
    required this.contentRead,
  }) : _platform = platform,
       _registry = registry,
       _aggregator = aggregator;

  final PetPlatform _platform;
  final AdapterRegistry _registry;
  final StatusAggregator _aggregator;
  final String activeId;
  final bool contentRead;

  StreamSubscription<AppActivation>? _subscription;

  void start() {
    _subscription ??= _platform.appActivations.listen(_onActivation);
  }

  Future<void> _onActivation(AppActivation app) async {
    final adapter = _registry.matchApp(app.bundleId, app.name);
    if (adapter == null || adapter.id != activeId) {
      // 切到无关应用：只回收本来源，不碰用户主动推送的状态。
      _aggregator.clear(StatusSourceKind.watch);
      _aggregator.clear(StatusSourceKind.content);
      return;
    }

    _aggregator.update(
      StatusSourceKind.watch,
      StatusSnapshot(
        state: AssistantStatus.waiting,
        text: '${adapter.displayName} 已在前台',
        source: adapter.id,
        updatedAt: DateTime.now(),
      ),
    );

    if (!contentRead) return;
    final content = await _platform.readFocusedContent();
    if (content == null) return;
    final title = content.title.trim();
    final body = content.text.trim();
    final sample = title.isNotEmpty ? title : body;
    if (sample.isEmpty) return;
    _aggregator.update(
      StatusSourceKind.content,
      StatusSnapshot(
        state: _guess(sample),
        text: _preview(sample),
        source: adapter.id,
        updatedAt: DateTime.now(),
      ),
    );
  }

  /// 关键词猜测只用于“有反应”，不作为事实展示原文，避免误读用户代码。
  AssistantStatus _guess(String text) {
    final lower = text.toLowerCase();
    if (RegExp(r'思考|thinking|planning|生成中').hasMatch(lower)) {
      return AssistantStatus.thinking;
    }
    if (RegExp(r'错误|失败|error|failed|exception').hasMatch(lower)) {
      return AssistantStatus.error;
    }
    if (RegExp(r'完成|成功|done|finished').hasMatch(lower)) {
      return AssistantStatus.success;
    }
    return AssistantStatus.working;
  }

  String _preview(String text) {
    final flattened = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flattened.length <= 60
        ? flattened
        : '${flattened.substring(0, 60)}…';
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}
