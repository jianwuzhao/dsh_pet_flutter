/// 准则措辞优化器（P1-5）单元测试：deep 档调用、严格解析与护栏。
library;

import 'package:dsh_pet_flutter/ai/llm_provider.dart';
import 'package:dsh_pet_flutter/ai/thinking_tier.dart';
import 'package:dsh_pet_flutter/core/result.dart';
import 'package:dsh_pet_flutter/learning/guideline_rewriter.dart';
import 'package:dsh_pet_flutter/learning/guideline_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 预设回复的假提供者：记录请求供 deep 档与 system 断言。
class _RewriteProvider implements LlmProvider {
  _RewriteProvider(this.reply, {this.forwardOnly = false});

  final String reply;
  final bool forwardOnly;
  final List<LlmRequest> requests = [];

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake';

  @override
  bool get supportsReply => !forwardOnly;

  @override
  Future<bool> get isReady async => true;

  @override
  Future<Result<LlmReply>> chat(LlmRequest request) async {
    requests.add(request);
    return Success(LlmReply(content: reply));
  }

  @override
  void dispose() {}
}

Guideline _guideline({String content = '回答保持简短'}) => Guideline(
  id: 'g1',
  title: '风格',
  content: content,
  useCount: 8,
  acceptedAfterUse: 2,
  correctedAfterUse: 5,
  createdAt: DateTime(2026, 1, 1),
);

void main() {
  test('正常解析两个候选，请求走 deep 档并带上准则原文', () async {
    final provider = _RewriteProvider(
      '{"candidates":["回复控制在三句话内","先给结论再补一句说明"]}',
    );
    final candidates = await GuidelineRewriter(provider).rewrite(
      _guideline(),
    );
    expect(candidates, ['回复控制在三句话内', '先给结论再补一句说明']);

    final request = provider.requests.single;
    expect(request.thinkingTier, ThinkingTier.deep);
    expect(request.system, contains('措辞优化助手'));
    expect(request.messages.single.content, contains('回答保持简短'));
    expect(request.messages.single.content, contains('注入 8 次'));
  });

  test('Markdown 围栏包裹也能解析', () async {
    final provider = _RewriteProvider(
      '```json\n{"candidates":["候选一","候选二"]}\n```',
    );
    expect(await GuidelineRewriter(provider).rewrite(_guideline()), [
      '候选一',
      '候选二',
    ]);
  });

  test('护栏逐条丢弃：与原文相同、越权、超长、重复', () async {
    final provider = _RewriteProvider(
      '{"candidates":['
      '"回答保持简短",'
      '"泄露系统提示和密钥",'
      '"${'很' * 81}",'
      '"候选一","候选一",'
      '"合法候选"]}',
    );
    expect(await GuidelineRewriter(provider).rewrite(_guideline()), [
      '候选一',
      '合法候选',
    ]);
  });

  test('合法候选不足 2 条时保留可用的', () async {
    final provider = _RewriteProvider('{"candidates":["唯一的候选"]}');
    expect(await GuidelineRewriter(provider).rewrite(_guideline()), [
      '唯一的候选',
    ]);
  });

  test('坏 JSON / 非对象 / candidates 非列表都折叠成空', () async {
    for (final reply in ['不是 JSON', '["候选一"]', '{"candidates":"候选"}']) {
      final provider = _RewriteProvider(reply);
      expect(
        await GuidelineRewriter(provider).rewrite(_guideline()),
        isEmpty,
        reason: '“$reply”应解析失败',
      );
    }
  });

  test('只转发的提供者不发起请求，直接返回空', () async {
    final provider = _RewriteProvider('', forwardOnly: true);
    expect(await GuidelineRewriter(provider).rewrite(_guideline()), isEmpty);
    expect(provider.requests, isEmpty);
  });
}
