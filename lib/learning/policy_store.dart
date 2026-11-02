/// 策略版本治理：参数集 + 版本快照 + 手动回滚 + 待确认提案（计划 4.5）。
///
/// 策略只管“表达偏好”（长度/表情/表格/关心语气），
/// 身份声明、价值观、隐私权限、打扰上限、人格底线是 [protectedFields]
/// 里的硬边界——任何学习都不允许自动改写，门禁层会直接拒绝。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/paths/app_paths.dart';
import '../core/result.dart';

/// 策略字段：只有这些允许被学习改动。
const Set<String> protectedFields = {
  'identity', // 身份声明
  'values', // 价值观
  'privacy', // 隐私权限
  'interruptionLimit', // 主动打扰上限
  'bottomLines', // 人格 DNA 底线
};

/// 可学习字段：replyLength / emojiUsage / tablePreference / careTone。
const List<String> learnableFields = [
  'replyLength',
  'emojiUsage',
  'tablePreference',
  'careTone',
];

class PolicyParams {
  const PolicyParams({
    this.replyLength = 'balanced',
    this.emojiUsage = 'light',
    this.tablePreference = 'allow',
    this.careTone = 'warm',
  });

  /// brief | balanced | detailed
  final String replyLength;

  /// none | light
  final String emojiUsage;

  /// avoid | allow
  final String tablePreference;

  /// quiet | warm
  final String careTone;

  /// 允许值白名单：非法值一律拒绝写入（也挡住越界注入）。
  static const Map<String, Set<String>> allowedValues = {
    'replyLength': {'brief', 'balanced', 'detailed'},
    'emojiUsage': {'none', 'light'},
    'tablePreference': {'avoid', 'allow'},
    'careTone': {'quiet', 'warm'},
  };

  /// 按字段名取当前值。
  String valueOf(String field) => switch (field) {
    'replyLength' => replyLength,
    'emojiUsage' => emojiUsage,
    'tablePreference' => tablePreference,
    'careTone' => careTone,
    _ => '',
  };

  /// 只更新一个可学习字段；未知/越界返回 null，让调用方明确失败。
  PolicyParams? withField(String field, String value) {
    if (!learnableFields.contains(field)) return null;
    if (!(allowedValues[field]?.contains(value) ?? false)) return null;
    return switch (field) {
      'replyLength' => copyWith(replyLength: value),
      'emojiUsage' => copyWith(emojiUsage: value),
      'tablePreference' => copyWith(tablePreference: value),
      _ => copyWith(careTone: value),
    };
  }

  PolicyParams copyWith({
    String? replyLength,
    String? emojiUsage,
    String? tablePreference,
    String? careTone,
  }) => PolicyParams(
    replyLength: replyLength ?? this.replyLength,
    emojiUsage: emojiUsage ?? this.emojiUsage,
    tablePreference: tablePreference ?? this.tablePreference,
    careTone: careTone ?? this.careTone,
  );

  factory PolicyParams.fromJson(Map<String, dynamic> json) {
    var params = const PolicyParams();
    for (final field in learnableFields) {
      final value = json[field];
      if (value is String) params = params.withField(field, value) ?? params;
    }
    return params;
  }

  Map<String, dynamic> toJson() => {
    'replyLength': replyLength,
    'emojiUsage': emojiUsage,
    'tablePreference': tablePreference,
    'careTone': careTone,
  };

  /// 注入会话 system prompt 的一句话描述（策略影响表达，不碰底线）。
  String get promptHint {
    final length = switch (replyLength) {
      'brief' => '回复尽量短（一到两句）',
      'detailed' => '回复可以详细一些（必要时分点）',
      _ => '回复长度适中（三句以内）',
    };
    final emoji = emojiUsage == 'none' ? '不使用表情符号' : '可以少量使用表情符号';
    final table = tablePreference == 'avoid' ? '避免使用表格' : '必要时可以用表格';
    final care = careTone == 'quiet' ? '关心时语气克制，不追问' : '关心时语气温暖';
    return '$length；$emoji；$table；$care。';
  }
}

class PolicySnapshot {
  const PolicySnapshot({
    required this.version,
    required this.params,
    required this.appliedAt,
    this.note = '',
  });

  final int version;
  final PolicyParams params;
  final DateTime appliedAt;
  final String note;

  factory PolicySnapshot.fromJson(Map<String, dynamic> json) => PolicySnapshot(
    version: (json['version'] as num?)?.toInt() ?? 0,
    params: PolicyParams.fromJson(
      json['params'] is Map<String, dynamic>
          ? json['params'] as Map<String, dynamic>
          : const {},
    ),
    appliedAt:
        DateTime.tryParse(json['appliedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    note: json['note'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'version': version,
    'params': params.toJson(),
    'appliedAt': appliedAt.toIso8601String(),
    'note': note,
  };
}

/// 待确认的策略提案：用户接受才生效（与记忆候选同一套语义）。
class PolicyProposal {
  const PolicyProposal({
    required this.id,
    required this.field,
    required this.value,
    required this.reason,
    required this.createdAt,
  });

  final String id;
  final String field;
  final String value;

  /// 用户可读的提案说明（来源于拒绝纠正语句）。
  final String reason;
  final DateTime createdAt;

  factory PolicyProposal.fromJson(Map<String, dynamic> json) => PolicyProposal(
    id: json['id'] as String? ?? '',
    field: json['field'] as String? ?? '',
    value: json['value'] as String? ?? '',
    reason: json['reason'] as String? ?? '',
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'field': field,
    'value': value,
    'reason': reason,
    'createdAt': createdAt.toIso8601String(),
  };
}

class PolicyStore {
  PolicyStore({Directory? directory, DateTime Function()? clock})
    : _directory = directory ?? AppPaths.learningDir,
      _clock = clock ?? DateTime.now {
    _load();
  }

  final Directory _directory;
  final DateTime Function() _clock;

  PolicySnapshot _current = PolicySnapshot(
    version: 0,
    params: const PolicyParams(),
    appliedAt: DateTime.fromMillisecondsSinceEpoch(0),
    note: '初始版本',
  );
  final List<PolicySnapshot> _history = [];
  final List<PolicyProposal> _proposals = [];

  PolicyParams get params => _current.params;
  int get version => _current.version;
  DateTime get appliedAt => _current.appliedAt;

  /// 版本历史（旧 → 新），首版也在其中。
  List<PolicySnapshot> get history => List.unmodifiable(_history);

  /// 待确认提案（旧 → 新）。
  List<PolicyProposal> get proposals => List.unmodifiable(_proposals);

  File get _policyFile =>
      File('${_directory.path}${Platform.pathSeparator}policy.json');

  File _snapshotFile(int version) => File(
    '${_directory.path}${Platform.pathSeparator}snapshots'
    '${Platform.pathSeparator}policy.v$version.json',
  );

  /// 新增一个提案；同字段已有提案时用新的替换（避免提案堆积）。
  Result<void> propose(PolicyProposal proposal) {
    if (!learnableFields.contains(proposal.field)) {
      return Failure('policy.protected', '${proposal.field} 不在可学习范围内，不能提案');
    }
    if (!(PolicyParams.allowedValues[proposal.field]?.contains(proposal.value) ??
        false)) {
      return Failure('policy.invalid', '策略值 ${proposal.value} 不合法');
    }
    _proposals.removeWhere((item) => item.field == proposal.field);
    _proposals.add(proposal);
    return _writePolicy();
  }

  /// 接受提案：应用到参数并生成新版本快照。
  Result<void> acceptProposal(String id) {
    final index = _proposals.indexWhere((item) => item.id == id);
    if (index < 0) {
      return const Failure('policy.not-found', '这条提案已经不在队列里了');
    }
    final proposal = _proposals[index];
    final next = _current.params.withField(proposal.field, proposal.value);
    if (next == null) {
      return const Failure('policy.invalid', '提案里的策略值不合法');
    }
    _proposals.removeAt(index);
    return apply(next, note: proposal.reason);
  }

  /// 拒绝提案：直接丢弃，不改变参数。
  Result<void> rejectProposal(String id) {
    final before = _proposals.length;
    _proposals.removeWhere((item) => item.id == id);
    if (_proposals.length == before) {
      return const Failure('policy.not-found', '这条提案已经不在队列里了');
    }
    return _writePolicy();
  }

  /// 应用新参数：版本 +1，写 policy.json，并把该版本存进 snapshots/。
  Result<void> apply(PolicyParams candidate, {String note = ''}) {
    final previous = _current;
    final snapshot = PolicySnapshot(
      version: previous.version + 1,
      params: candidate,
      appliedAt: _clock(),
      note: note,
    );
    _current = snapshot;
    _history.add(snapshot);
    final result = _writePolicy();
    if (result is Failure<void>) {
      // 写盘失败就退回内存，别让界面显示一个没存住的版本。
      _history.removeLast();
      _current = previous;
      return result;
    }
    _writeSnapshot(snapshot);
    return const Success(null);
  }

  /// 手动回滚到上一版；已是最旧版本时结构化失败。
  Result<void> rollback() {
    if (_history.length < 2) {
      return const Failure('policy.no-previous', '已经是最早的版本，没有可回滚的上一版');
    }
    return _switchTo(_history[_history.length - 2]);
  }

  /// 回滚到指定版本（设置页历史列表用）。
  Result<void> rollbackTo(int version) {
    for (final snapshot in _history.reversed) {
      if (snapshot.version == version) return _switchTo(snapshot);
    }
    return Failure('policy.not-found', '版本 v$version 不在历史里');
  }

  /// 回滚实现：不删历史，而是追加一个新版本记录（回滚本身可追溯）。
  Result<void> _switchTo(PolicySnapshot target) {
    return apply(target.params, note: '回滚到 v${target.version}');
  }

  Result<void> _writePolicy() {
    return _writeFile(
      _policyFile,
      jsonEncode({
        'version': _current.version,
        'params': _current.params.toJson(),
        'appliedAt': _current.appliedAt.toIso8601String(),
        'note': _current.note,
        'history': [
          for (final snapshot in _history) snapshot.toJson(),
        ],
        'proposals': [
          for (final proposal in _proposals) proposal.toJson(),
        ],
      }),
    );
  }

  void _writeSnapshot(PolicySnapshot snapshot) {
    // 快照是审计副本，写失败只留痕不影响主流程（主文件已写成功）。
    _writeFile(_snapshotFile(snapshot.version), jsonEncode(snapshot.toJson()));
  }

  /// 原子写：先写 .tmp 再 rename，任何一步失败都不破坏旧文件。
  Result<void> _writeFile(File file, String content) {
    try {
      final parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(content, flush: true);
      tmp.renameSync(file.path);
      return const Success(null);
    } on Object catch (error) {
      return Failure('policy.write-failed', '策略写入失败：$error');
    }
  }

  void _load() {
    _history.add(_current);
    try {
      final file = _policyFile;
      if (!file.existsSync()) return;
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) return;
      _current = PolicySnapshot.fromJson(raw);
      _history
        ..clear()
        ..addAll([
          for (final item in (raw['history'] as List? ?? const []))
            if (item is Map<String, dynamic>) PolicySnapshot.fromJson(item),
        ]);
      if (_history.isEmpty) _history.add(_current);
      _proposals.addAll([
        for (final item in (raw['proposals'] as List? ?? const []))
          if (item is Map<String, dynamic>) PolicyProposal.fromJson(item),
      ]);
    } on Object catch (error) {
      // 策略文件损坏：回默认参数继续运行，不阻塞对话。
      debugPrint('[dafishu] 策略文件损坏，使用默认参数：$error');
    }
  }
}
