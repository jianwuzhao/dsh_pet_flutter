/// 唤起与回传的唯一入口：按“当前关联软件”选适配器。
///
/// 适配器自己决定用哪种投递模式（uri / clipboard / http / ws），
/// 这里只负责“谁在用”和“别把空消息发出去”。
library;

import '../../core/result.dart';
import 'assistant_adapters.dart';

class Dispatcher {
  Dispatcher({required this.registry, required this.activeId});

  final AdapterRegistry registry;

  /// 设置页保存后由装配层直接改写，注册表也随之重建。
  String activeId;

  Future<Result<DispatchOutcome>> send(String prompt) {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) {
      return Future.value(const Failure('dispatch.empty', '内容为空，没有发送'));
    }
    return registry.dispatch(trimmed, id: activeId);
  }
}
