/// Trae 桥提供者：把输入交给现有 Dispatcher 转发到关联软件。
///
/// supportsReply=false——只能“送出”，收不到回复；网关看到它会走
/// 与今天完全一致的转发路径，保证 petctl / Trae 扩展链路体验不变。
library;

import '../../core/result.dart';
import '../../features/linkage/assistant_adapters.dart';
import '../llm_provider.dart';

class TraeBridgeProvider extends LlmProvider {
  TraeBridgeProvider({required this.send});

  /// 直接持有 Dispatcher.send（装配时注入，便于测试与解耦）。
  final Future<Result<DispatchOutcome>> Function(String prompt) send;

  @override
  String get id => 'trae-bridge';

  @override
  String get displayName => 'Trae 桥（只转发）';

  @override
  bool get supportsReply => false;

  @override
  Future<bool> get isReady async => true;

  @override
  Future<Result<LlmReply>> chat(LlmRequest request) {
    // 语义上就不该调到这里：网关对 supportsReply=false 的提供者走转发。
    return Future.value(
      const Failure('llm.no-reply', 'Trae 桥只负责转发，不产生回复'),
    );
  }
}
