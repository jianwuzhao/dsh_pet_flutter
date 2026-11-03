/// LLM 纠正解析器：规则解析未命中时的二级解析（P0-2）。
///
/// 现状问题：规则解析只认「别用表格」这类显式短语，用户说
/// 「以后数据对比用列表就好，表格看着眼晕」就漏掉了——策略学习
/// 的召回率被硬编码短语表卡死。
///
/// 约束（防止 LLM 幻觉污染策略字段）：
/// - field/value 双白名单：直接复用 [PolicyParams.allowedValues]，
///   不在白名单内一律返回 null，后续仍要走 EvalGate 门禁；
/// - 每条纠正最多 1 次 LLM 调用（预算守护，不重试）；
/// - 输出命中 unsafe 正则或 confidence 低于阈值 → null；
/// - provider 不可用/超时/解析失败 → 静默降级返回 null（等于回到现状）。
library;

import 'dart:async';
import 'dart:convert';

import '../ai/llm_provider.dart';
import '../ai/thinking_tier.dart';
import '../core/result.dart';
import 'llm_reflection_synthesizer.dart' show LlmReflectionSynthesizer;
import 'policy_store.dart';

/// 解析结果：field/value 已通过白名单校验。
class ParsedCorrection {
  const ParsedCorrection({
    required this.field,
    required this.value,
    required this.confidence,
    required this.rawText,
  });

  final String field;
  final String value;

  /// 模型自报的置信度（0~1），低于 [CorrectionParser.minConfidence] 丢弃。
  final double confidence;

  /// 原始纠正文本：写进提案 reason 时给用户看「当时说了什么」。
  final String rawText;
}

class CorrectionParser {
  /// [providerLoader] 每次解析时现取 provider：跟随路由降级/切换，
  /// 不在构造期绑定死某个提供者。
  CorrectionParser(this._providerLoader, {this.timeout = const Duration(seconds: 20)});

  final Future<LlmProvider?> Function() _providerLoader;

  /// 单次解析超时：超时按失败降级，不阻塞反馈链路。
  final Duration timeout;

  /// 置信度门槛：低于此值宁可漏掉也不猜。
  static const double minConfidence = 0.6;

  /// 白名单提示词片段：直接枚举合法字段与取值，模型只需做归类。
  static String get _whitelistHint {
    final entries = [
      for (final field in learnableFields)
        '$field ∈ {${PolicyParams.allowedValues[field]!.join(' | ')}}',
    ];
    return entries.join('\n');
  }

  /// 解析一条纠正语句；任何失败路径都返回 null（调用方回到规则路径的行为）。
  Future<ParsedCorrection?> parse(String correction) async {
    final text = correction.trim();
    if (text.isEmpty) return null;
    final provider = await _providerLoader();
    if (provider == null || !provider.supportsReply) return null;
    if (!await provider.isReady) return null;

    final request = LlmRequest(
      system: '你是偏好解析器，只输出 JSON，不要解释。',
      messages: [
        LlmMessage.user(
          '用户对助手的表达方式提了一条纠正。请判断它想调整哪个偏好字段。\n'
          '合法字段与取值（只能从中选择）：\n'
          '$_whitelistHint\n'
          '若纠正与这些字段无关，输出 {"field": null}。\n'
          '输出格式：{"field": "…", "value": "…", "confidence": 0.0~1.0}\n'
          '纠正原文：「$text」',
        ),
      ],
      thinkingTier: ThinkingTier.fast,
    );

    final Result<LlmReply> reply;
    try {
      reply = await provider.chat(request).timeout(timeout);
    } on TimeoutException {
      return null;
    } on Exception {
      return null;
    }
    if (reply is Failure<LlmReply>) return null;

    final content = (reply as Success<LlmReply>).value.content;
    // 与反思总结共用同一套越权判定口径。
    if (content.isEmpty ||
        LlmReflectionSynthesizer.unsafePattern.hasMatch(content)) {
      return null;
    }
    return _fromRawJson(_extractJson(content), text);
  }

  /// 从 ```json 围栏或裸文本中抠出第一段 JSON 对象；抠不出返回 null。
  static Map<String, dynamic>? _extractJson(String content) {
    final start = content.indexOf('{');
    final end = content.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    final candidate = content.substring(start, end + 1);
    try {
      final decoded = jsonDecode(candidate);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// 白名单 + 置信度校验；不通过一律 null。
  static ParsedCorrection? _fromRawJson(
    Map<String, dynamic>? json,
    String rawText,
  ) {
    if (json == null) return null;
    final field = json['field'];
    final value = json['value'];
    if (field is! String || value is! String) return null;
    final allowedValues = PolicyParams.allowedValues[field];
    if (allowedValues == null || !allowedValues.contains(value)) return null;
    final confidence = (json['confidence'] as num?)?.toDouble() ?? 0;
    if (confidence < minConfidence) return null;
    return ParsedCorrection(
      field: field,
      value: value,
      confidence: confidence,
      rawText: rawText,
    );
  }
}
