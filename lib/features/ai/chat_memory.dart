/// 对话记忆：全量落盘、上下文只取最近 N 轮。
///
/// 与上游 memory.json 同义：聊天面板/桌面重启后仍记得之前聊过什么；
/// 文件 0600，只在本机；损坏时明确日志并回到空记忆，不阻塞对话。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/paths/app_paths.dart';
import 'llm_client.dart';

/// 聊天原文上限：只保留最近 200 轮，避免 memory.json 无限增长。
/// 长期记忆由 MemoryStore 负责，这里只保留对话上下文所需的近期原文。
const int chatMemoryMaxMessages = 400;

class ChatMemory {
  ChatMemory({File? file}) : _file = file ?? AppPaths.memoryFile {
    _load();
  }

  final File _file;
  final List<AiMessage> _messages = [];

  List<AiMessage> get messages => List.unmodifiable(_messages);

  List<AiMessage> context(int rounds) {
    final limit = (rounds <= 0 ? 0 : rounds * 2).clamp(0, _messages.length);
    if (limit == 0) return const [];
    return _messages.sublist(_messages.length - limit);
  }

  void appendRound(String user, String assistant) {
    _messages
      ..add(AiMessage.user(user))
      ..add(AiMessage.assistant(assistant));
    _trim();
    save();
  }

  void append(AiMessage message) {
    _messages.add(message);
    _trim();
    save();
  }

  /// 超出上限时丢弃最旧的整轮原文；长期记忆不在这里，不怕丢。
  void _trim() {
    final overflow = _messages.length - chatMemoryMaxMessages;
    if (overflow > 0) _messages.removeRange(0, overflow);
  }

  void clear() {
    _messages.clear();
    save();
  }

  void save() {
    try {
      AppPaths.ensure();
      final tmp = File('${_file.path}.tmp');
      tmp.writeAsStringSync(
        jsonEncode({
          'messages': [for (final message in _messages) message.toJson()],
        }),
        flush: true,
      );
      tmp.renameSync(_file.path);
      if (Platform.isMacOS || Platform.isLinux) {
        Process.runSync('chmod', ['600', _file.path]);
      }
    } on Object catch (error) {
      debugPrint('[dafishu] 保存对话记忆失败：$error');
    }
  }

  void _load() {
    try {
      if (!_file.existsSync()) return;
      final raw = jsonDecode(_file.readAsStringSync());
      if (raw is! Map) return;
      final list = raw['messages'];
      if (list is! List) return;
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          final message = AiMessage.fromJson(item);
          if (message.content.isNotEmpty) _messages.add(message);
        }
      }
      _trim();
    } on Object catch (error) {
      debugPrint('[dafishu] 读取对话记忆失败，按空记忆继续：$error');
      _messages.clear();
    }
  }
}
