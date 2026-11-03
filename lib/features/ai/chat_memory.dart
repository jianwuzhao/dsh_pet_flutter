/// 对话记忆：全量落盘、上下文只取最近 N 轮。
///
/// 与上游 memory.json 同义：聊天面板/桌面重启后仍记得之前聊过什么；
/// 文件 0600，只在本机；损坏时明确日志并回到空记忆，不阻塞对话。
/// 超上限被裁剪的旧对话折叠成 rollingSummary（P0-5）：
/// 由注入的 [ChatMemory.summarizer] 异步生成，失败则保留旧摘要。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/paths/app_paths.dart';
import 'llm_client.dart';

/// 聊天原文上限：只保留最近 200 轮，避免 memory.json 无限增长。
/// 长期记忆由 MemoryStore 负责，这里只保留对话上下文所需的近期原文。
const int chatMemoryMaxMessages = 400;

/// 会话摘要器：把被裁剪丢弃的旧对话折叠进一段滚动摘要。
///
/// 入参为本次丢弃的原文与现有摘要，返回合并后的新摘要；
/// 返回 null 表示失败（调用方保留旧摘要不动，即回退到纯丢弃现状）。
typedef ChatSummarizer =
    Future<String?> Function(List<AiMessage> dropped, String currentSummary);

class ChatMemory {
  ChatMemory({File? file}) : _file = file ?? AppPaths.memoryFile {
    _load();
  }

  final File _file;
  final List<AiMessage> _messages = [];

  /// 摘要器由 kernel 装配（随路由现取 provider）；null = 纯丢弃的旧行为。
  ChatSummarizer? summarizer;

  /// 摘要期间新被裁剪的原文：在飞互斥下先缓冲，完成后合并进下一轮。
  final List<AiMessage> _pendingDropped = [];
  bool _summarizing = false;

  String _rollingSummary = '';

  /// 早期对话的滚动摘要（空 = 无）：会话服务把它拼在 system 段之后。
  String get rollingSummary => _rollingSummary;

  /// 摘要防御性上限：提示词约束 200 字，超限说明模型失控，截断保底。
  static const int summaryMaxChars = 600;

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
  ///
  /// 装配了摘要器时，丢弃的原文转喂摘要（异步、单并发），
  /// 否则保持纯丢弃的旧行为。
  void _trim() {
    final overflow = _messages.length - chatMemoryMaxMessages;
    if (overflow <= 0) return;
    final dropped = _messages.sublist(0, overflow);
    _messages.removeRange(0, overflow);
    final summarizer = this.summarizer;
    if (summarizer == null) return;
    _pendingDropped.addAll(dropped);
    unawaited(_maybeSummarize());
  }

  /// 折叠缓冲的丢弃原文：全程最多一个在飞调用，失败保留旧摘要。
  Future<void> _maybeSummarize() async {
    if (_summarizing || _pendingDropped.isEmpty) return;
    final summarizer = this.summarizer;
    if (summarizer == null) {
      _pendingDropped.clear();
      return;
    }
    _summarizing = true;
    final dropped = List<AiMessage>.of(_pendingDropped);
    _pendingDropped.clear();
    try {
      final merged = await summarizer(dropped, _rollingSummary);
      if (merged != null && merged.trim().isNotEmpty) {
        final text = merged.trim();
        _rollingSummary =
            text.length > summaryMaxChars
                ? '${text.substring(0, summaryMaxChars)}…'
                : text;
        save();
      }
    } on Object catch (error) {
      debugPrint('[dafishu] 会话摘要生成失败，保留旧摘要：$error');
    } finally {
      _summarizing = false;
    }
    // 排队期间又有新丢弃：继续折，仍保持单并发。
    if (_pendingDropped.isNotEmpty) unawaited(_maybeSummarize());
  }

  void clear() {
    _messages.clear();
    _rollingSummary = '';
    _pendingDropped.clear();
    save();
  }

  void save() {
    try {
      AppPaths.ensure();
      final tmp = File('${_file.path}.tmp');
      tmp.writeAsStringSync(
        jsonEncode({
          'messages': [for (final message in _messages) message.toJson()],
          'rollingSummary': _rollingSummary,
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
      final summary = raw['rollingSummary'];
      if (summary is String) _rollingSummary = summary;
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
